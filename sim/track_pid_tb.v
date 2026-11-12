// =============================================================================
// track_pid_tb.v —— 循迹 PID 自测
// 控制周期缩到 1 ms。验收点：
//   1) pos=0 → 两轮都是 BASE（600），corr=0（D 项此时为 0）
//   2) pos=+7（线在右）→ duty_l > duty_r，corr > 0
//   3) pos=-7 → duty_r > duty_l，corr < 0
//   4) 长时间同侧误差 → 积分使 corr 继续增大（抗饱和：不超过 ±BASE）
//   5) lost=1 → 占空比保持（不清零）
//   6) en=0 → 输出归零、corr 归零
// =============================================================================
`timescale 1ns/1ps

module track_pid_tb;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20.8335 clk = ~clk;

    reg               en = 1'b1;
    reg signed [4:0]  pos = 5'sd0;
    reg               on_line = 1'b1;
    reg               lost = 1'b0;
    wire [10:0]       duty_l, duty_r;
    wire signed [10:0] corr;

    track_pid #(
        .CLK_FREQ  (24_000_000),
        .TICK_MS   (1),
        .DUTY_MAX  (1200),
        .BASE_DUTY (600),
        .P_GAIN    (40),
        .D_GAIN    (24),
        .I_SHIFT   (5),
        .I_LIMIT   (640)
    ) u_dut (
        .clk (clk), .rst_n (rst_n), .en (en),
        .pos (pos), .on_line (on_line), .lost (lost),
        .duty_l (duty_l), .duty_r (duty_r), .corr (corr)
    );

    task wait_ticks (input integer n);
        begin
            repeat (n * 24000) @(posedge clk);
            #1;
        end
    endtask

    reg [10:0] hold_l, hold_r;
    reg signed [10:0] c1, c2, c3;

    initial begin
        #200 rst_n = 1'b1;

        // ---- 1) 居中 ----
        pos = 5'sd0; lost = 1'b0; on_line = 1'b1;
        wait_ticks(2);
        if (duty_l == 11'd600 && duty_r == 11'd600 && corr == 11'sd0)
            $display("PASS: centered -> duty 600/600, corr=0");
        else
            $display("FAIL: centered -> duty %0d/%0d corr=%0d", duty_l, duty_r, corr);

        // ---- 2) 线在右 ----
        // 注意：pos 突变的头一两个周期 D 项会打一个尖峰，等它衰减后再取样，
        // 否则测到的 corr 是 P+D 的峰值，拿它跟后面比会因为尖峰消失而"变小"。
        pos = 5'sd7;
        wait_ticks(5);
        c1 = corr;
        if (duty_l > duty_r && corr > 0)
            $display("PASS: pos=+7 -> duty %0d/%0d corr=%0d (left faster)", duty_l, duty_r, corr);
        else
            $display("FAIL: pos=+7 -> duty %0d/%0d corr=%0d", duty_l, duty_r, corr);

        // 占空比必须在 0..1200
        if (duty_l <= 11'd1200 && duty_r <= 11'd1200)
            $display("PASS: duties within 0..1200");
        else
            $display("FAIL: duty out of range %0d/%0d", duty_l, duty_r);

        // ---- 4) 持续同侧 → 积分增大，但被限幅 ----
        wait_ticks(100);          // 100 个控制周期同侧误差
        c2 = corr;
        if (c2 > c1 && c2 <= 11'sd600)
            $display("PASS: integral windup bounded: corr %0d -> %0d (<=600)", c1, c2);
        else
            $display("FAIL: corr %0d -> %0d (expect grow but <=600)", c1, c2);

        // ---- 3) 线在左 ----
        pos = -5'sd7;
        wait_ticks(120);          // 够积分从正侧回摆
        c3 = corr;
        if (duty_r > duty_l && corr < 0)
            $display("PASS: pos=-7 -> duty %0d/%0d corr=%0d (right faster)", duty_l, duty_r, corr);
        else
            $display("FAIL: pos=-7 -> duty %0d/%0d corr=%0d", duty_l, duty_r, corr);

        // ---- 5) 丢线保持 ----
        hold_l = duty_l; hold_r = duty_r;
        lost = 1'b1;
        wait_ticks(20);
        if (duty_l == hold_l && duty_r == hold_r)
            $display("PASS: lost -> duties held (%0d/%0d)", duty_l, duty_r);
        else
            $display("FAIL: lost -> duties changed %0d/%0d (held %0d/%0d)",
                     duty_l, duty_r, hold_l, hold_r);
        lost = 1'b0;

        // ---- 6) en=0 归零 ----
        en = 1'b0;
        wait_ticks(2);
        if (duty_l == 11'd0 && duty_r == 11'd0 && corr == 11'sd0)
            $display("PASS: en=0 -> all zero");
        else
            $display("FAIL: en=0 -> duty %0d/%0d corr=%0d", duty_l, duty_r, corr);

        $display("INFO: track_pid_tb done");
        $finish;
    end

    initial begin
        #600_000_000;
        $display("TIMEOUT: track_pid_tb hung");
        $finish;
    end

endmodule
