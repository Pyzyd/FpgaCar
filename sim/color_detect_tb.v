// =============================================================================
// color_detect_tb.v —— color_detect 自测（按真实 DVP 时序造 RGB565 字节流）
// iverilog -g2012 -Wall -s color_detect_tb -o color_detect_tb.vvp \
//          src/color_detect.v sim/color_detect_tb.v && vvp color_detect_tb.vvp
// -----------------------------------------------------------------------------
// 【关键：时序模型】OV5640 在 PCLK **下降沿**改变数据，上升沿处数据稳定。
// 所以本 tb 一律在 negedge 更新 data/href/vsync，DUT 在 posedge 采样。
// （之前在 posedge 更新数据，等于和采样沿打架，字节奇偶必然错位 ——
//  这也是本轮踩到的坑，记进 PROJECT_PLAN）
//
// 每帧 NPIX=256 像素（> MIN_PIX=200），VSYNC 上升沿表示"一帧结束"。
// 验收：红→1 绿→2 蓝→3 黄→4 黑→0，小色斑（各 128 < 200）→0
// =============================================================================
`timescale 1ns/1ps

module color_detect_tb;

    localparam integer NPIX = 256;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    always #20.8335 clk = ~clk;        // 24 MHz

    reg  pclk = 1'b0;
    always #11.9 pclk = ~pclk;         // ≈42 MHz

    reg  href = 1'b0;
    reg  vsync = 1'b0;
    reg  [7:0] data = 8'h00;

    wire [2:0] color;
    wire       new_color;

    color_detect u_dut (
        .clk(clk), .rst_n(rst_n),
        .pclk(pclk), .href(href), .vsync(vsync), .data(data),
        .color(color), .new_color(new_color)
    );

    integer nfr = 0;
    always @(posedge clk) if (rst_n && new_color) nfr = nfr + 1;

    // 送 n 个像素，末尾给一个 VSYNC 上升沿结束本帧
    task send_frame (input [7:0] r, input [7:0] g, input [7:0] b, input integer n);
        reg [4:0] r5;
        reg [5:0] g6;
        reg [4:0] b5;
        integer i;
        begin
            r5 = r[7:3];
            g6 = g[7:2];
            b5 = b[7:3];

            @(negedge pclk);
            href = 1'b1;
            for (i = 0; i < n; i = i + 1) begin
                data = {r5, g6[5:3]};        // 高字节 R[4:0] G[5:3]
                @(negedge pclk);
                data = {g6[2:0], b5};        // 低字节 G[2:0] B[4:0]
                @(negedge pclk);
            end
            href = 1'b0;
            repeat (2) @(negedge pclk);
            vsync = 1'b1;                    // 帧结束
            @(negedge pclk);
            vsync = 1'b0;
            repeat (3) @(negedge pclk);
        end
    endtask

    task check (input [2:0] exp, input [8*8-1:0] name);
        begin
            #3000;                           // 等跨域同步（24 MHz 几个周期）
            if (color !== exp)
                $display("FAIL: %0s -> color=%0d (expect %0d)", name, color, exp);
            else
                $display("PASS: %0s -> color=%0d", name, color);
        end
    endtask

    initial begin
        #400 rst_n = 1'b1;
        #400;

        send_frame(8'd255, 8'd0,   8'd0,   NPIX); check(3'd1, "red   ");
        send_frame(8'd0,   8'd255, 8'd0,   NPIX); check(3'd2, "green ");
        send_frame(8'd0,   8'd0,   8'd255, NPIX); check(3'd3, "blue  ");
        send_frame(8'd255, 8'd255, 8'd0,   NPIX); check(3'd4, "yellow");
        send_frame(8'd0,   8'd0,   8'd0,   NPIX); check(3'd0, "black ");

        // 红 64 + 绿 64：都 < MIN_PIX=200，应判"其他"
        send_frame(8'd255, 8'd0, 8'd0, 64);
        send_frame(8'd0, 8'd255, 8'd0, 64);
        check(3'd0, "sparse");

        if (nfr < 6) $display("FAIL: new_color pulses=%0d (expect >=6)", nfr);
        else         $display("PASS: new_color pulses=%0d", nfr);

        $display("INFO: color_detect_tb done");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT: color_detect_tb hung");
        $finish;
    end

endmodule
