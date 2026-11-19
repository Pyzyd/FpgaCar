// hc_sr04_period_tb.v -- 验证两次 Trig 之间的间隔是否等于 PERIOD_US
// 目的：抓 hc_sr04.v S_PERIOD 状态未用 us_tick 门控导致的周期缩短
`timescale 1ns/1ps

module hc_sr04_period_tb;

    localparam integer CLK_FREQ  = 24_000_000;
    localparam integer PERIOD_US = 60_000;   // 与顶层默认值一致

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20.8335 clk = ~clk;

    wire trig;
    reg  echo = 1'b0;
    wire [15:0] dist_cm;
    wire valid;

    hc_sr04 #(.CLK_FREQ(CLK_FREQ), .PERIOD_US(PERIOD_US)) u_dut (
        .clk(clk), .rst_n(rst_n), .trig(trig), .echo(echo),
        .dist_cm(dist_cm), .valid(valid)
    );

    // 固定 100 cm 回波：Trig 后 400 us 抬起，5800 us 宽
    always @(posedge trig) begin
        #(400*1000);
        echo = 1'b1;
        #(5800*1000);
        echo = 1'b0;
    end

    time t_prev = 0;
    integer n = 0;
    real    gap_us;

    always @(posedge trig) begin
        n = n + 1;
        if (n > 1) begin
            gap_us = ($time - t_prev) / 1000.0;
            $display("TRIG#%0d gap = %0.1f us (%.3f ms)", n, gap_us, gap_us/1000.0);
            // 容差：下界 0.98×PERIOD_US，上界 1.20×。
            // 理论值不是正好 60 ms —— 一个完整周期 = PERIOD_US + Trig 15 us
            // + Echo 等待与回波宽（本 tb 是 400 + 5800 us），约 1.10×。
            // 早期上界放到 1.60× 太宽：1.5× 这类真实偏差能溜过去。
            if (gap_us < PERIOD_US * 0.98 || gap_us > PERIOD_US * 1.20)
                $display("FAIL: trig gap %0.1f us, expect %0d~%0d us",
                         gap_us, PERIOD_US * 0.98, PERIOD_US * 1.20);
            else
                $display("PASS: trig gap %0.1f us ~= %0d us", gap_us, PERIOD_US);
        end
        t_prev = $time;
    end

    initial begin
        #200 rst_n = 1'b1;
        #(300_000_000);   // 300 ms：够看 4~5 次触发
        // 用标准 PASS:/FAIL: 标记，回归脚本按这两种字符串判定。
        // 早期只打 "ALLPASS=%0d"，n<4 时既没有 PASS: 也没有 FAIL:，
        // 回归脚本仍报 OK（0 失败）—— 这是一个真实的假绿灯。
        if (n >= 4) $display("PASS: period tb done, %0d triggers", n);
        else        $display("FAIL: only %0d triggers, expect >= 4", n);
        $display("INFO: hc_sr04_period_tb %s", (n >= 4) ? "ALL PASS" : "FAILED");
        $finish;
    end

endmodule
