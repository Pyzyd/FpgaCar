// =============================================================================
// uart_report_tb.v —— uart_report 自测（整行 30 字节 ASCII 比对）
// iverilog -g2012 -Wall -s uart_report_tb -o uart_report_tb.vvp \
//          src/uart_tx.v src/uart_report.v sim/uart_report_tb.v && vvp uart_report_tb.vvp
// -----------------------------------------------------------------------------
// 行格式：D=xxxcm T=00011000 P=+02 O=0\r\n   （28 字符 + CRLF = 30 字节）
// 验收：
//   1) 123cm / 中间两路 / pos=+2 / 无障碍
//   2) 无效距离 --- / 两端各一路 / pos=-7 / 有障碍
//   3) 7cm / 全丢线 / pos=0 / 无障碍
// =============================================================================
`timescale 1ns/1ps

module uart_report_tb;

    localparam real BIT_NS = 1.0e9 / 115200.0;
    localparam integer MSG_LEN = 56;

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
    wire        tx;

    uart_report #(.CLK_FREQ(24_000_000), .BAUD(115_200), .REPORT_EN(1)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .dist_cm(dist_cm), .dist_valid(dist_valid),
        .line(line), .pos(pos), .obstacle(obstacle), .vs_cnt(vs_cnt), .cam_done(cam_done), .cam_width(cam_width), .cam_height(cam_height), .cam_color(cam_color),
        .tx(tx)
    );

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

    // 送一帧并比对整行
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
        input [8*MSG_LEN-1:0] exp_str
    );
        reg [7:0] b;
        reg [8*MSG_LEN-1:0] got;
        integer k;
        begin
            @(posedge clk); #1;
            dist_cm = d; line = l; pos = p; obstacle = o; vs_cnt = v; cam_done = c;
            cam_width = w; cam_height = h; cam_color = q;
            dist_valid = 1'b1;
            @(posedge clk); #1;
            dist_valid = 1'b0;

            got = 0;
            for (k = 0; k < MSG_LEN; k = k + 1) begin
                rx_byte(b);
                got = {got[8*(MSG_LEN-1)-1:0], b};
            end

            if (got !== exp_str)
                $display("FAIL: dist=%0d line=%b pos=%0d o=%b v=%0d\n      got \"%s\"\n      exp \"%s\"",
                         d, l, p, o, v, got, exp_str);
            else
                $display("PASS: \"%s\"", got);
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

        check_frame(16'd123, 8'b0001_1000, 5'sd2, 1'b0, 8'd3, 1'b1, 16'd1280, 16'd720, 3'd1,
                    {"D=123cm T=00011000 P=+02 O=0 V=03 C=1 W=1280 H=720 Q=1", 8'h0D, 8'h0A});

        check_frame(16'hFFFF, 8'b1000_0001, -5'sd7, 1'b1, 8'd0, 1'b0, 16'd0, 16'd0, 3'd0,
                    {"D=---cm T=10000001 P=-07 O=1 V=00 C=0 W=0000 H=000 Q=0", 8'h0D, 8'h0A});

        check_frame(16'd7, 8'b0000_0000, 5'sd0, 1'b0, 8'd42, 1'b1, 16'd9999, 16'd999, 3'd3,
                    {"D=007cm T=00000000 P=+00 O=0 V=42 C=1 W=9999 H=999 Q=3", 8'h0D, 8'h0A});

        $display("INFO: uart_report_tb done");
        $finish;
    end

endmodule
