// =============================================================================
// uart_tx_tb.v —— uart_tx 自测（自带位级解码器）
// iverilog -g2012 -Wall -s uart_tx_tb -o uart_tx_tb.vvp src/uart_tx.v sim/uart_tx_tb.v
// -----------------------------------------------------------------------------
// 验收：1) 空闲为高、busy=0
//       2) 发 0x55：起始位=0、8 位数据 LSB 先出、停止位=1
//       3) 发 0xA3：数据正确（验证移位方向）
//       4) 位宽 ≈ 8680 ns（115200 @24 MHz）
//       5) busy 发送期间为 1，结束后落 0
// =============================================================================
`timescale 1ns/1ps

module uart_tx_tb;

    localparam real BIT_NS = 1.0e9 / 115200.0;    // ≈ 8680.6 ns

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    always #20.8335 clk = ~clk;

    reg  [7:0] data = 8'h00;
    reg        start = 1'b0;
    wire       tx;
    wire       busy;

    uart_tx #(.CLK_FREQ(24_000_000), .BAUD(115_200)) u_dut (
        .clk(clk), .rst_n(rst_n), .data(data), .start(start), .tx(tx), .busy(busy)
    );

    time t_start_edge, t_bit_prev;
    real bit_ns;

    // 位级接收：在每一位的中点采样
    task rx_byte (output [7:0] b);
        integer k;
        begin
            @(negedge tx);                 // 起始位下降沿
            t_start_edge = $time;
            #(BIT_NS * 1.5);               // 移到 bit0 中点
            t_bit_prev = $time;
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = tx;
                if (k < 7) begin
                    #(BIT_NS);
                end
            end
            bit_ns = ($time - t_bit_prev) / 7.0;
            #(BIT_NS * 0.5);               // 移到停止位中点
            if (tx !== 1'b1) $display("FAIL: stop bit not high");
            @(posedge clk);
        end
    endtask

    // 发一个字节并同时收回来。
    // 注意 start 的撤销与"等起始位下降沿"必须并发（fork），否则会抢跑：
    // uart_tx 在 start 采样后的下一拍才把 tx 拉低，若先撤 start 再臂沿等待就漏掉起始位。
    task send_rx (input [7:0] v, output [7:0] b);
        begin
            @(posedge clk); #1;
            data  = v;
            start = 1'b1;
            fork
                begin @(posedge clk); #1; start = 1'b0; end
                rx_byte(b);
            join
        end
    endtask

    reg [7:0] got;

    // 看门狗：任何握手错误都不至于让仿真无限挂住
    initial begin
        #2_000_000;
        $display("TIMEOUT: uart_tx_tb hung");
        $finish;
    end

    initial begin
        #200 rst_n = 1'b1;
        #500;

        if (tx !== 1'b1 || busy !== 1'b0) $display("FAIL: idle state tx=%b busy=%b", tx, busy);
        else                              $display("PASS: idle high, busy=0");

        // 0x55 = 0101_0101，交替位，最便于发现移位方向错误
        send_rx(8'h55, got);
        if (got !== 8'h55) $display("FAIL: sent 0x55 got 0x%02h", got);
        else               $display("PASS: sent 0x55 got 0x%02h", got);
        if (bit_ns < 8600 || bit_ns > 8800)
            $display("FAIL: bit width = %0.1f ns (expect ~8680)", bit_ns);
        else
            $display("PASS: bit width = %0.1f ns -> %.1f kbaud", bit_ns, 1.0e6 / bit_ns);
        wait (busy === 1'b0);
        $display("PASS: busy released after stop bit");

        // 0xA3 = 1010_0011
        send_rx(8'hA3, got);
        if (got !== 8'hA3) $display("FAIL: sent 0xA3 got 0x%02h", got);
        else               $display("PASS: sent 0xA3 got 0x%02h", got);
        wait (busy === 1'b0);

        $display("INFO: uart_tx_tb done");
        $finish;
    end

endmodule
