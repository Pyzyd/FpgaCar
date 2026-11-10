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
    localparam integer MSG_LEN = 30;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    always #20.8335 clk = ~clk;

    reg  [15:0] dist_cm = 16'd0;
    reg         dist_valid = 1'b0;
    reg  [7:0]  line = 8'h00;
    reg  signed [4:0] pos = 5'sd0;
    reg         obstacle = 1'b0;
    wire        tx;

    uart_report #(.CLK_FREQ(24_000_000), .BAUD(115_200), .REPORT_EN(1)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .dist_cm(dist_cm), .dist_valid(dist_valid),
        .line(line), .pos(pos), .obstacle(obstacle),
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
        input [8*MSG_LEN-1:0] exp_str
    );
        reg [7:0] b;
        reg [8*MSG_LEN-1:0] got;
        integer k;
        begin
            @(posedge clk); #1;
            dist_cm = d; line = l; pos = p; obstacle = o;
            dist_valid = 1'b1;
            @(posedge clk); #1;
            dist_valid = 1'b0;

            got = 0;
            for (k = 0; k < MSG_LEN; k = k + 1) begin
                rx_byte(b);
                got = {got[8*(MSG_LEN-1)-1:0], b};
            end

            if (got !== exp_str)
                $display("FAIL: dist=%0d line=%b pos=%0d o=%b\n      got \"%s\"\n      exp \"%s\"",
                         d, l, p, o, got, exp_str);
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

        check_frame(16'd123, 8'b0001_1000, 5'sd2, 1'b0,
                    {"D=123cm T=00011000 P=+02 O=0", 8'h0D, 8'h0A});

        check_frame(16'hFFFF, 8'b1000_0001, -5'sd7, 1'b1,
                    {"D=---cm T=10000001 P=-07 O=1", 8'h0D, 8'h0A});

        check_frame(16'd7, 8'b0000_0000, 5'sd0, 1'b0,
                    {"D=007cm T=00000000 P=+00 O=0", 8'h0D, 8'h0A});

        $display("INFO: uart_report_tb done");
        $finish;
    end

endmodule
