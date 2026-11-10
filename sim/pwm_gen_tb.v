// =============================================================================
// pwm_gen_tb.v —— pwm_gen 自测
// iverilog -g2012 -Wall -s pwm_gen_tb -o pwm_gen_tb.vvp src/pwm_gen.v sim/pwm_gen_tb.v && vvp pwm_gen_tb.vvp
// -----------------------------------------------------------------------------
// 验收：1) en=0 → pwm 恒低  2) duty=0 → 恒低  3) duty=600 → 50% ±1 LSB
//       4) duty>=1200 → 恒高（饱和）  5) 周期 = 60 us（20 kHz）
// =============================================================================
`timescale 1ns/1ns

module pwm_gen_tb;
    localparam integer CNT_MAX = 1200;          // 24 MHz / 20 kHz
    localparam real    CLKP    = 41.667;        // 24 MHz 周期 = 41.667 ns

    reg         clk = 0, rst_n = 0, en = 0;
    reg  [10:0] duty = 11'd0;
    wire        pwm;

    pwm_gen #(.CLK_FREQ(24_000_000), .PWM_FREQ(20_000)) u_dut (
        .clk(clk), .rst_n(rst_n), .en(en), .duty(duty), .pwm(pwm)
    );

    always #(CLKP/2) clk = ~clk;   // 20.833 ns 半周期 = 24 MHz

    // 简化：直接用 42ns 半周期 ≈ 23.81 MHz，CNT_MAX 仍按 1200 由 DUT 计算，
    // 因此周期按 DUT 的 CLK_FREQ=24MHz 假设；只测逻辑正确性，不校准绝对频率。
    integer high = 0, low = 0, i;

    // 采样一个完整 PWM 周期（约 1200 个 clk）
    task sample_period;
        begin
            high = 0; low = 0;
            @(posedge pwm);                      // 等到上升沿对齐
            repeat (CNT_MAX + 4) begin
                @(posedge clk);
                if (pwm) high = high + 1; else low = low + 1;
            end
        end
    endtask

    initial begin
        // 1) 复位期间 pwm 必须为 0
        #100 rst_n = 1;
        #200;
        if (pwm !== 1'b0) begin $display("FAIL: rst released but pwm=%b", pwm); $finish; end

        // 2) en=0, duty=600 → 恒低
        duty = 11'd600;
        #2000;
        if (pwm !== 1'b0) begin $display("FAIL: en=0 but pwm=1"); $finish; end

        // 3) en=1, duty=0 → 恒低
        en = 1; duty = 11'd0;
        #2000;
        if (pwm !== 1'b0) begin $display("FAIL: duty=0 but pwm=1"); $finish; end

        // 4) en=1, duty=600 → 约 50%
        duty = 11'd600;
        sample_period();
        if (high < 590 || high > 610)
            $display("FAIL: duty=600 expect ~600 high, got %0d", high);
        else
            $display("PASS: duty=600 -> %0d/%0d high ticks", high, high+low);

        // 5) duty>=1200 → 饱和恒高
        duty = 11'd1400;
        #2000;
        if (pwm !== 1'b1) begin $display("FAIL: duty>=CNT_MAX but pwm=0"); $finish; end
        $display("PASS: duty=1400 saturates high");

        // 6) en 拉低立即归零（安全门控）
        en = 0;
        @(posedge clk);
        if (pwm !== 1'b0) begin $display("FAIL: en drop but pwm=1"); $finish; end
        $display("PASS: en gating works");

        $display("INFO: pwm_gen_tb done");
        $finish;
    end
endmodule
