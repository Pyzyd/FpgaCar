// =============================================================================
// uart_report_tb.v —— uart_report 自测（整行 ASCII 解码比对）
// iverilog -g2012 -Wall -s uart_report_tb -o uart_report_tb.vvp \
//          src/uart_tx.v src/uart_report.v sim/uart_report_tb.v && vvp uart_report_tb.vvp
// -----------------------------------------------------------------------------
// 验收：1) dist=123 -> "D=123cm\r\n"
//       2) dist=7   -> "D=007cm\r\n"
//       3) dist=16'hFFFF -> "D=---cm\r\n"
//       4) dist=1234（超 999）-> "D=---cm\r\n"（钳位判无效前的近似，实际路径同一分支）
// =============================================================================
`timescale 1ns/1ps

module uart_report_tb;

    localparam real BIT_NS = 1.0e9 / 115200.0;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    always #20.8335 clk = ~clk;

    reg  [15:0] dist_cm = 16'd0;
    reg         dist_valid = 1'b0;
    wire        tx;

    uart_report #(.CLK_FREQ(24_000_000), .BAUD(115_200), .REPORT_EN(1)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .dist_cm(dist_cm), .dist_valid(dist_valid), .tx(tx)
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
            #(BIT_NS * 0.5);
        end
    endtask

    // 收一整行（9 字节）并与期望比较
    task check_line (input [15:0] d, input [8*9-1:0] exp_str);
        reg [7:0] b;
        integer k;
        reg [8*9-1:0] got;
        begin
            @(posedge clk); #1;
            dist_cm = d;
            dist_valid = 1'b1;
            @(posedge clk); #1;
            dist_valid = 1'b0;

            got = 0;
            for (k = 0; k < 9; k = k + 1) begin
                rx_byte(b);
                got = {got[8*8-1:0], b};
            end

            if (got !== exp_str)
                $display("FAIL: dist=%0d line=\"%s\" (expect \"%s\")", d, got, exp_str);
            else
                $display("PASS: dist=%0d -> \"%s\"", d, got);
        end
    endtask

    // 看门狗：任何握手错误都不至于让仿真无限挂住
    initial begin
        #20_000_000;
        $display("TIMEOUT: uart_report_tb hung");
        $finish;
    end

    initial begin
        #200 rst_n = 1'b1;
        #500;

        // "D=123cm\r\n"
        check_line(16'd123, {"D=123cm", 8'h0D, 8'h0A});
        // "D=007cm\r\n"
        check_line(16'd7,   {"D=007cm", 8'h0D, 8'h0A});
        // "D=---cm\r\n"（无效）
        check_line(16'hFFFF, {"D=---cm", 8'h0D, 8'h0A});
        // "D=400cm\r\n"
        check_line(16'd400, {"D=400cm", 8'h0D, 8'h0A});

        $display("INFO: uart_report_tb done");
        $finish;
    end

endmodule
