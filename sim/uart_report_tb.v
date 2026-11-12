// =============================================================================
// uart_report_tb.v —— uart_report 自测（两行报文整体比对）
// iverilog -g2012 -Wall -s uart_report_tb -o uart_report_tb.vvp \
//          src/uart_tx.v src/uart_report.v sim/uart_report_tb.v && vvp uart_report_tb.vvp
// -----------------------------------------------------------------------------
// 每个 dist_valid 打两行：
//   第 1 行（64 字节）D=123cm T=00011000 P=+02 O=0 V=03 C=1 W=1280 H=720 Q=1 XY=F800 CR LF
//   第 2 行（54 字节）R=00000 G=00000 B=00000 Y=00000 S=00 SB=0000 LB=0000 CR LF
// 验收：
//   1) 123cm / 中间两路 / pos=+2 / 无障碍 / 有帧统计
//   2) 无效距离 --- / 两端各一路 / pos=-7 / 有障碍 / 统计全 0
//   3) 7cm / 全丢线 / pos=0 / 无障碍 / 计数饱和 0xFFFFF
// =============================================================================
`timescale 1ns/1ps

module uart_report_tb;

    localparam real BIT_NS = 1.0e9 / 115200.0;
    localparam integer MSG_LEN  = 64;
    localparam integer MSG2_LEN = 54;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    always #20.8335 clk = ~clk;

    reg  [15:0] dist_cm = 16'd0;
    reg         dist_valid = 1'b0;
    reg  [7:0]  line = 8'h00;
    reg  signed [4:0] pos = 5'sd0;
    reg         obstacle = 1'b0;
    reg  [7:0]  vs_cnt = 8'd0;
    reg         cam_done = 1'b0;
    reg  [15:0] cam_width  = 16'd0;
    reg  [15:0] cam_height = 16'd0;
    reg  [2:0]  cam_color  = 3'd0;
    reg  [7:0]  cam_b0     = 8'hF8;
    reg  [7:0]  cam_b1     = 8'h00;
    reg  [19:0] cam_cnt_r  = 20'd0;
    reg  [19:0] cam_cnt_g  = 20'd0;
    reg  [19:0] cam_cnt_b  = 20'd0;
    reg  [19:0] cam_cnt_y  = 20'd0;
    reg  [6:0]  cam_sat    = 7'd0;
    reg  [7:0]  cam_sb0    = 8'h00;
    reg  [7:0]  cam_sb1    = 8'h00;
    reg  [7:0]  cam_lb0    = 8'h00;
    reg  [7:0]  cam_lb1    = 8'h00;
    wire        tx;

    uart_report #(.CLK_FREQ(24_000_000), .BAUD(115_200), .REPORT_EN(1)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .dist_cm(dist_cm), .dist_valid(dist_valid),
        .line(line), .pos(pos), .obstacle(obstacle), .vs_cnt(vs_cnt), .cam_done(cam_done), .cam_width(cam_width), .cam_height(cam_height), .cam_color(cam_color), .cam_b0(cam_b0), .cam_b1(cam_b1),
        .cam_cnt_r(cam_cnt_r), .cam_cnt_g(cam_cnt_g), .cam_cnt_b(cam_cnt_b), .cam_cnt_y(cam_cnt_y),
        .cam_sat(cam_sat), .cam_sb0(cam_sb0), .cam_sb1(cam_sb1), .cam_lb0(cam_lb0), .cam_lb1(cam_lb1),
        .tx(tx)
    );

    integer fails = 0;

    task rx_byte (output [7:0] b);
        integer k;
        begin
            @(negedge tx);
            #(BIT_NS * 1.5);
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = tx;
                if (k < 7) #(BIT_NS);
            end
            #(BIT_NS * 0.5);          // 停在停止位中点
        end
    endtask

    // 收 n 字节拼成字符串（右对齐：第 0 个字节落在最高有效位置，低位留 0）
    // 注意必须右对齐再按 8*n-1:0 切片比对，否则 54 字节的第二行和 64 字节的
    // 期望值宽度不同，整向量比较会"看起来相等"而漏掉错位。
    task rx_line (input integer n, output [8*MSG_LEN-1:0] got);
        reg [7:0] b;
        integer k;
        begin
            got = 0;
            for (k = 0; k < n; k = k + 1) begin
                rx_byte(b);
                got = (got << 8) | {504'd0, b};
            end
            // 拼接时每来一个字节就 <<8，所以报文自然落在低位、顺序正确，
            // 与 "..." 字面量（同样低位对齐）可直接比较，不需要再移位。
        end
    endtask

    // 送一帧并比对两行
    task check_frame (
        input [15:0] d,
        input [7:0]  l,
        input signed [4:0] p,
        input        o,
        input [7:0]  v,
        input        c,
        input [15:0] w,
        input [15:0] h,
        input [2:0]  q,
        input [19:0] sr, sg, sb, sy,
        input [6:0]  ssat,
        input [8*MSG2_LEN-1:0] exp_str2,
        input [8*MSG_LEN-1:0] exp_str
    );
        reg [8*MSG_LEN-1:0] got, got2;
        begin
            @(posedge clk); #1;
            dist_cm = d; line = l; pos = p; obstacle = o; vs_cnt = v; cam_done = c;
            cam_width = w; cam_height = h; cam_color = q;
            cam_cnt_r = sr; cam_cnt_g = sg; cam_cnt_b = sb; cam_cnt_y = sy;
            cam_sat = ssat;
            dist_valid = 1'b1;
            @(posedge clk); #1;
            dist_valid = 1'b0;

            rx_line(MSG_LEN, got);
            if (got !== exp_str) begin
                $display("FAIL line1: dist=%0d line=%b pos=%0d o=%b v=%0d\n      got \"%s\"\n      exp \"%s\"",
                         d, l, p, o, v, got, exp_str);
                fails = fails + 1;
            end else
                $display("PASS line1: \"%s\"", got);

            rx_line(MSG2_LEN, got2);
            if (got2[8*MSG2_LEN-1:0] !== exp_str2) begin
                $display("FAIL line2:\n      got \"%s\"\n      exp \"%s\"",
                         got2[8*MSG2_LEN-1:0], exp_str2);
                fails = fails + 1;
            end else
                $display("PASS line2: \"%s\"", got2[8*MSG2_LEN-1:0]);
        end
    endtask

    // 看门狗
    initial begin
        #60_000_000;
        $display("TIMEOUT: uart_report_tb hung");
        $finish;
    end

    initial begin
        #200 rst_n = 1'b1;
        #500;

        // 1) 正常：红的 300 个像素，最大饱和度 0x3F，最亮/最饱和像素都是 F800
        cam_sb0 = 8'hF8; cam_sb1 = 8'h00; cam_lb0 = 8'hF8; cam_lb1 = 8'h00;
        check_frame(16'd123, 8'b0001_1000, 5'sd2, 1'b0, 8'd3, 1'b1, 16'd1280, 16'd720, 3'd1,
                    20'h00300, 20'd0, 20'd0, 20'd0, 7'h3F,
                    {"R=00300 G=00000 B=00000 Y=00000 S=3F SB=F800 LB=F800", 8'h0D, 8'h0A},
                    {"D=123cm T=00011000 P=+02 O=0 V=03 C=1 W=1280 H=720 Q=1 XY=F800", 8'h0D, 8'h0A});

        // 2) 无效距离：统计全 0（SB/LB 也回到 0000）
        cam_sb0 = 8'h00; cam_sb1 = 8'h00; cam_lb0 = 8'h00; cam_lb1 = 8'h00;
        check_frame(16'hFFFF, 8'b1000_0001, -5'sd7, 1'b1, 8'd0, 1'b0, 16'd0, 16'd0, 3'd0,
                    20'd0, 20'd0, 20'd0, 20'd0, 7'd0,
                    {"R=00000 G=00000 B=00000 Y=00000 S=00 SB=0000 LB=0000", 8'h0D, 8'h0A},
                    {"D=---cm T=10000001 P=-07 O=1 V=00 C=0 W=0000 H=000 Q=0 XY=F800", 8'h0D, 8'h0A});

        // 3) 计数饱和：0xFFFFF 要打出 FFFFF（验证 hexd 高位）
        cam_sb0 = 8'h1F; cam_sb1 = 8'h2E; cam_lb0 = 8'h7F; cam_lb1 = 8'h00;
        check_frame(16'd7, 8'b0000_0000, 5'sd0, 1'b0, 8'd42, 1'b1, 16'd9999, 16'd999, 3'd3,
                    20'hFFFFF, 20'd5, 20'd11, 20'h0ABCD, 7'h16,
                    {"R=FFFFF G=00005 B=0000B Y=0ABCD S=16 SB=1F2E LB=7F00", 8'h0D, 8'h0A},
                    {"D=007cm T=00000000 P=+00 O=0 V=42 C=1 W=9999 H=999 Q=3 XY=F800", 8'h0D, 8'h0A});

        if (fails == 0) $display("INFO: uart_report_tb ALL PASS");
        else            $display("INFO: uart_report_tb FAILURES=%0d", fails);
        $finish;
    end

endmodule
