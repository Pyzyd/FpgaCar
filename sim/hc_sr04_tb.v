// =============================================================================
// hc_sr04_tb.v —— hc_sr04 自测（含 HC-SR04 行为模型）
// iverilog -g2012 -Wall -s hc_sr04_tb -o hc_sr04_tb.vvp src/hc_sr04.v sim/hc_sr04_tb.v
// -----------------------------------------------------------------------------
// 模型：检测 Trig 上升沿 → 延迟 ECHO_DELAY_US → Echo 拉高 WIDTH_US → 拉低。
//       WIDTH_US = 0 表示"模块不接/无回波"，用于验证超时路径。
// 验收：1) Echo 1450 us -> 25 cm (+-1)
//       2) Echo 5800 us -> 100 cm (+-1)
//       3) 无回波 -> dist_cm=16'hFFFF
//       4) Trig 脉宽 10 us
// =============================================================================
`timescale 1ns/1ps

module hc_sr04_tb;

    localparam integer CLK_FREQ    = 24_000_000;
    localparam integer PERIOD_US   = 10_000;  // 仿真里缩短到 10 ms（必须大于 400+5800 us，
                                              // 否则下一次 Trig 会在上次 Echo 还没落下时发出）
    localparam integer ECHO_DELAY  = 400;     // 模型：Trig 后 400 us Echo 才抬起来

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    always #20.8335 clk = ~clk;

    wire        trig;
    reg         echo = 1'b0;
    wire [15:0] dist_cm;
    wire        valid;

    hc_sr04 #(
        .CLK_FREQ(CLK_FREQ), .PERIOD_US(PERIOD_US)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .trig(trig), .echo(echo),
        .dist_cm(dist_cm), .valid(valid)
    );

    // ---- HC-SR04 行为模型 ----
    integer model_width_us = 0;    // 0 = 不回波
    integer trig_hi_ns = 0;
    time    t_trig_rise = 0;

    always @(posedge trig) begin
        t_trig_rise = $time;
        if (model_width_us > 0) begin
            #(ECHO_DELAY * 1000);
            echo = 1'b1;
            #(model_width_us * 1000);
            echo = 1'b0;
        end
    end
    always @(negedge trig) trig_hi_ns = $time - t_trig_rise;

    // ---- 等一次测量完成 ----
    task wait_meas;
        begin
            @(posedge valid);
            @(posedge clk); #1;
        end
    endtask

    initial begin
        #200 rst_n = 1'b1;

        // 1) 25 cm = 1450 us
        model_width_us = 1450;
        wait_meas();
        if (dist_cm < 16'd24 || dist_cm > 16'd26)
            $display("FAIL: 1450us echo -> %0d cm (expect ~25)", dist_cm);
        else
            $display("PASS: 1450us echo -> %0d cm", dist_cm);
        if (trig_hi_ns < 13000 || trig_hi_ns > 16000)
            $display("FAIL: trig width = %0d ns (expect ~15000 ns, spec >=10000)", trig_hi_ns);
        else
            $display("PASS: trig width = %0d ns", trig_hi_ns);

        // 2) 100 cm = 5800 us
        model_width_us = 5800;
        wait_meas();
        if (dist_cm < 16'd99 || dist_cm > 16'd101)
            $display("FAIL: 5800us echo -> %0d cm (expect ~100)", dist_cm);
        else
            $display("PASS: 5800us echo -> %0d cm", dist_cm);

        // 3) 无回波 -> 无效
        model_width_us = 0;
        wait_meas();
        if (dist_cm !== 16'hFFFF)
            $display("FAIL: no echo -> %0d cm (expect FFFF)", dist_cm);
        else
            $display("PASS: no echo -> dist_cm=0x%04h (invalid)", dist_cm);

        $display("INFO: hc_sr04_tb done");
        $finish;
    end

endmodule
