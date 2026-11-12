// =============================================================================
// frame_snap_tb.v —— frame_snap 自测（缩小参数 + 高速波特率，快速跑完一次抓帧）
// iverilog -g2012 -Wall -s frame_snap_tb -o frame_snap_tb.vvp \
//          src/frame_snap.v src/uart_tx.v sim/frame_snap_tb.v
// -----------------------------------------------------------------------------
// 参数缩小：GW=4, GH=2（8 个格）、PXS_LOG2=3（每格 8 像素，行宽 32）、
//           STRIDE=2（每 2 行采一行，4 行里采第 0、2 行）、
//           FIRST_MS=1, GAP_MS=1, NDUMP=1、BAUD=2.4 MHz（加速 20 倍）
// 送固定像素 0xABCD，期望每行是 'S' + "ABCD"×4 + CR LF
// 验收：
//   1) 恰好收到 GH=2 行
//   2) 每行以 'S' 开头、CR LF 结尾
//   3) hex 内容就是送进去的像素值
// =============================================================================
`timescale 1ns/1ps

module frame_snap_tb;

    localparam integer GW = 4;
    localparam integer GH = 2;
    localparam integer PXL = 1 << 3;        // PXS_LOG2=3

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20.8335 clk = ~clk;             // 24 MHz

    reg pclk = 1'b0;
    always #11.9 pclk = ~pclk;              // ≈42 MHz

    reg  href = 1'b0;
    reg  vsync = 1'b0;
    reg  [7:0] data = 8'h00;

    wire tx, busy;

    frame_snap #(
        .CLK_FREQ (24_000_000),
        .BAUD     (2_400_000),
        .GW       (GW),
        .GH       (GH),
        .PXS_LOG2 (3),
        .STRIDE   (2),
        .FIRST_MS (1),
        .GAP_MS   (1),
        .NDUMP    (1)
    ) u_dut (
        .clk (clk), .rst_n (rst_n),
        .pclk (pclk), .href (href), .vsync (vsync), .data (data),
        .tx (tx), .busy (busy)
    );

    // ---------------- 造 DVP 时序：像素固定 0xABCD ----------------
    task one_frame;
        integer l, p;
        begin
            @(negedge pclk);
            vsync = 1'b1;
            @(negedge pclk);
            vsync = 1'b0;

            for (l = 0; l < 4; l = l + 1) begin       // 4 行
                @(negedge pclk);
                href = 1'b1;
                for (p = 0; p < GW * PXL; p = p + 1) begin
                    data = 8'hAB;                     // 高字节
                    @(negedge pclk);
                    data = 8'hCD;                     // 低字节
                    @(negedge pclk);
                end
                href = 1'b0;
            end
            repeat (4) @(negedge pclk);
        end
    endtask

    // ---------------- 简易 UART 接收（BAUD=2.4 MHz → 位宽 ~416 us）----------------
    // timescale 是 1ns/1ps -> #N 的单位是 ns。2.4 Mbaud 的位宽 = 416.667 ns
    localparam real BIT_NS = 416.667;

    // 期望的 hex 字符（A/B/C/D），Verilog 的字符串不能直接下标取字符
    reg [7:0] hexexp [0:3];
    reg [7:0] rx_byte;
    integer   rx_cnt = 0;
    integer   nline  = 0;

    task rx_one (output [7:0] b);
        integer i;
        begin
            @(negedge tx);                       // 起始位
            #(BIT_NS / 2.0);
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_NS);
                b[i] = tx;
            end
            #(BIT_NS);                           // 停止位
        end
    endtask

    // 收一整行并打印
    reg [8*40-1:0] linebuf;
    task rx_line;
        integer k;
        reg [7:0] b;
        begin
            rx_one(b);
            if (b !== 8'h53) $display("FAIL: line does not start with 'S' (got %02h)", b);
            else             $display("PASS: line starts with 'S'");
            for (k = 0; k < GW * 4; k = k + 1) begin
                rx_one(b);
                if (b !== hexexp[k % 4])
                    $display("FAIL: hex[%0d]=%02h expect %02h", k, b, hexexp[k % 4]);
            end
            rx_one(b);
            if (b !== 8'h0D) $display("FAIL: no CR (got %02h)", b);
            rx_one(b);
            if (b !== 8'h0A) $display("FAIL: no LF (got %02h)", b);
            nline = nline + 1;
            $display("PASS: line %0d complete ('S' + ABCD*%0d + CRLF)", nline, GW);
        end
    endtask

    initial begin
        hexexp[0] = 8'h41; hexexp[1] = 8'h42; hexexp[2] = 8'h43; hexexp[3] = 8'h44;
    end

    initial begin
        #400 rst_n = 1'b1;
        #200;

        // 先造几帧，让 fb 填满
        one_frame();
        one_frame();

        // FIRST_MS=1 → 1 ms 后开始抓；抓帧期间 fb 被冻结，之后按 GAP 再发
        // 等第一行出现
        repeat (GH) rx_line();

        // 抓完后 busy 应回到 0
        #2_000_000;
        if (busy !== 1'b0) $display("FAIL: busy still high after dump");
        else               $display("PASS: busy released");

        if (nline != GH) $display("FAIL: got %0d lines, expect %0d", nline, GH);
        else             $display("PASS: %0d lines as expected", nline);

        $display("INFO: frame_snap_tb done");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT: frame_snap_tb hung (nline=%0d)", nline);
        $finish;
    end

endmodule
