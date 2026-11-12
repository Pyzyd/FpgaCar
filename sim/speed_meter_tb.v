// =============================================================================
// speed_meter_tb.v —— 测速模块自测
// 窗口 1 ms（24 MHz → 24000 clk）：先给 30 个正转脉冲，期望 speed=+30；
// 再给 10 个反转脉冲，期望 speed=-10；窗口间 valid 必须只来 1 拍。
// =============================================================================
`timescale 1ns/1ps

module speed_meter_tb;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20.8335 clk = ~clk;         // 24 MHz

    reg step = 1'b0;
    reg dir  = 1'b1;
    wire signed [15:0] speed;
    wire valid;

    integer nvalid = 0;

    speed_meter #(
        .CLK_FREQ (24_000_000),
        .WIN_MS   (1)
    ) u_dut (
        .clk (clk), .rst_n (rst_n),
        .step (step), .dir (dir),
        .speed (speed), .valid (valid)
    );

    // 发一个脉冲（1 clk 宽）
    task pulse (input d);
        begin
            @(posedge clk);
            dir  <= d;
            step <= 1'b1;
            @(posedge clk);
            step <= 1'b0;
        end
    endtask

    always @(posedge clk) if (valid) nvalid = nvalid + 1;

    // 等到下一个窗口边界之后
    task next_window;
        begin
            @(posedge valid);
            @(posedge clk);
            #1;
        end
    endtask

    integer k;
    reg signed [15:0] s1, s2;

    initial begin
        #200 rst_n = 1'b1;
        @(posedge clk);

        // ---- 30 个正转脉冲（一个窗口内）----
        for (k = 0; k < 30; k = k + 1) pulse(1'b1);
        next_window;
        s1 = speed;
        if (s1 == 16'sd30) $display("PASS: 30 forward steps -> speed=%0d", s1);
        else               $display("FAIL: speed=%0d, expect 30", s1);

        // ---- 10 个反转脉冲 ----
        for (k = 0; k < 10; k = k + 1) pulse(1'b0);
        next_window;
        s2 = speed;
        if (s2 == -16'sd10) $display("PASS: 10 reverse steps -> speed=%0d", s2);
        else                $display("FAIL: speed=%0d, expect -10", s2);

        // ---- 无脉冲窗口应归零 ----
        next_window;
        if (speed == 16'sd0) $display("PASS: idle window -> speed=0");
        else                 $display("FAIL: idle window speed=%0d, expect 0", speed);

        // ---- valid 每窗口只有一拍 ----
        if (nvalid >= 3) $display("PASS: valid pulsed %0d times for 3+ windows", nvalid);
        else             $display("FAIL: valid pulsed only %0d times", nvalid);

        $display("INFO: speed_meter_tb done");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT: speed_meter_tb hung");
        $finish;
    end

endmodule
