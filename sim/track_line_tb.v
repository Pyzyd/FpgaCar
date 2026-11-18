// =============================================================================
// track_line_tb.v —— track_line 自测
// iverilog -g2012 -Wall -s track_line_tb -o track_line_tb.vvp src/track_line.v sim/track_line_tb.v
// -----------------------------------------------------------------------------
// 默认参数 ACTIVE_HIGH=0（低电平 = 压线），所以 tb 里"压线"用 0 表示：
//   line = 0000_0001  =>  原始 track = 1111_1110
// 验收：
//   1) 中间两路压线 (bit3,bit4) -> cnt=2, pos=0
//   2) 最左一路 (bit0)          -> cnt=1, pos=-7
//   3) 最右一路 (bit7)          -> cnt=1, pos=+7
//   4) 偏左三路 (bit1,2,3)      -> cnt=3, pos=-3（验证加权平均+四舍五入）
//   5) 全白                     -> lost=1, on_line=0, pos=0
//   6) 单拍毛刺（4 次采样内）    -> 被消抖滤掉，line 不变
//   7) 八路全压（影子）           -> wide=1、lost=0、pos 保持上一拍（不采信质心）
//   8) 宽黑持续超过 WIDE_MS       -> 降级成丢线（lost=1、on_line=0）
// 为了在毫秒级仿真里看到 WIDE_MS 生效，用例 7/8 各用一个缩短 WIDE_MS 的实例。
// =============================================================================
`timescale 1ns/1ps

module track_line_tb;

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    always #20.8335 clk = ~clk;      // 24 MHz

    reg  [7:0] track = 8'hFF;
    wire [7:0] line;
    wire [7:0] raw;
    wire [3:0] cnt;
    wire       on_line, lost;
    wire signed [4:0] pos;
    wire       wide;

    track_line #(
        .CLK_FREQ(24_000_000), .SAMPLE_KHZ(1_000), .DEBOUNCE_N(4), .ACTIVE_HIGH(0)
    ) u_dut (
        .clk(clk), .rst_n(rst_n), .track(track),
        .line(line), .raw(raw), .cnt(cnt), .on_line(on_line), .lost(lost),
        .pos(pos), .wide(wide)
    );

    // 用例 7：宽黑（影子）但永不超时 —— 用来验证 wide=1 且 pos 冻结
    wire [7:0] line2;
    wire [3:0] cnt2;
    wire       on_line2, lost2, wide2;
    wire signed [4:0] pos2;

    track_line #(
        .CLK_FREQ(24_000_000), .SAMPLE_KHZ(1_000), .DEBOUNCE_N(4), .ACTIVE_HIGH(0),
        .WIDE_CNT_TH(5'd5), .WIDE_MS(1000)
    ) u_dut2 (
        .clk(clk), .rst_n(rst_n), .track(track),
        .line(line2), .raw(), .cnt(cnt2), .on_line(on_line2), .lost(lost2),
        .pos(pos2), .wide(wide2)
    );

    // 用例 8：宽黑 3 ms 就降级成丢线
    wire [7:0] line3;
    wire [3:0] cnt3;
    wire       on_line3, lost3, wide3;
    wire signed [4:0] pos3;

    track_line #(
        .CLK_FREQ(24_000_000), .SAMPLE_KHZ(1_000), .DEBOUNCE_N(4), .ACTIVE_HIGH(0),
        .WIDE_CNT_TH(5'd5), .WIDE_MS(3)
    ) u_dut3 (
        .clk(clk), .rst_n(rst_n), .track(track),
        .line(line3), .raw(), .cnt(cnt3), .on_line(on_line3), .lost(lost3),
        .pos(pos3), .wide(wide3)
    );

    // 施加"线位置"(1=压线)，内部取反成原始电平
    task set_line (input [7:0] l);
        begin
            @(posedge clk); #1;
            track = ~l;
        end
    endtask

    // 等消抖稳定：1 ms 采样一次、要连续 4 次，等 7 ms 足够
    // （timescale 1ns/1ps 下 #7_000_000 = 7,000,000 ns = 7 ms）

    initial begin
        #200 rst_n = 1'b1;
        #200;

        // 1) 中间两路
        set_line(8'b0001_1000);
        #7_000_000;
        if (cnt !== 4'd2)       $display("FAIL: mid2 cnt=%0d (expect 2)", cnt);
        else if (pos !== 5'sd0) $display("FAIL: mid2 pos=%0d (expect 0)", pos);
        else                    $display("PASS: mid2 -> cnt=2 pos=0");

        // 2) 最左
        set_line(8'b0000_0001);
        #7_000_000;
        if (cnt !== 4'd1)       $display("FAIL: left1 cnt=%0d", cnt);
        else if (pos !== -5'sd7) $display("FAIL: left1 pos=%0d (expect -7)", pos);
        else                    $display("PASS: left1 -> cnt=1 pos=-7");

        // 3) 最右
        set_line(8'b1000_0000);
        #7_000_000;
        if (cnt !== 4'd1)        $display("FAIL: right1 cnt=%0d", cnt);
        else if (pos !== 5'sd7)  $display("FAIL: right1 pos=%0d (expect +7)", pos);
        else                     $display("PASS: right1 -> cnt=1 pos=+7");

        // 4) 偏左三路 bit1,2,3 -> 权重 -5,-3,-1 -> 平均 -3
        set_line(8'b0000_1110);
        #7_000_000;
        if (cnt !== 4'd3)        $display("FAIL: left3 cnt=%0d (expect 3)", cnt);
        else if (pos !== -5'sd3) $display("FAIL: left3 pos=%0d (expect -3)", pos);
        else                     $display("PASS: left3 -> cnt=3 pos=-3");

        // 5) 全白（丢线）
        set_line(8'b0000_0000);
        #7_000_000;
        if (lost !== 1'b1 || on_line !== 1'b0)
            $display("FAIL: lost flag not set (lost=%b on_line=%b)", lost, on_line);
        else if (pos !== 5'sd0)
            $display("FAIL: lost pos=%0d (expect 0)", pos);
        else
            $display("PASS: all white -> lost=1, pos=0");

        // 6) 毛刺：只在两个采样点之间抖一下，不应改变 line
        set_line(8'b0001_1000);
        #7_000_000;
        set_line(8'b1111_1111);      // 假的全压线
        #800_000;                    // 0.8 ms：短于 4 次采样所需
        set_line(8'b0001_1000);
        #7_000_000;
        if (line !== 8'b0001_1000)
            $display("FAIL: glitch leaked through, line=%b", line);
        else
            $display("PASS: short glitch filtered, line=%b", line);

        // 7) 宽黑（影子）不采信：先把 pos 打到 +7，再八路全压
        set_line(8'b1000_0000);
        #7_000_000;
        if (pos2 !== 5'sd7) $display("FAIL: wide pre pos2=%0d (expect +7)", pos2);
        set_line(8'b1111_1111);          // 影子盖住整排
        #7_000_000;
        if (wide2 !== 1'b1)
            $display("FAIL: wide flag not set (wide2=%b cnt2=%0d)", wide2, cnt2);
        else if (lost2 !== 1'b0)
            $display("FAIL: wide short should not be lost (lost2=%b)", lost2);
        else if (pos2 !== 5'sd7)
            $display("FAIL: wide froze pos2=%0d (expect keep +7)", pos2);
        else
            $display("PASS: wide black -> wide=1, pos held");

        // 8) 宽黑超时（WIDE_MS=3）降级成丢线
        if (lost3 !== 1'b1 || on_line3 !== 1'b0)
            $display("FAIL: wide timeout lost3=%b on_line3=%b", lost3, on_line3);
        else if (pos3 !== 5'sd0)
            $display("FAIL: wide timeout pos3=%0d (expect 0)", pos3);
        else
            $display("PASS: wide timeout -> degraded to lost");

        $display("INFO: track_line_tb done");
        $finish;
    end

    // 看门狗
    initial begin
        #150_000_000;
        $display("TIMEOUT: track_line_tb hung");
        $finish;
    end

endmodule
