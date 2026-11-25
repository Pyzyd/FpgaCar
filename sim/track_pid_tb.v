// =============================================================================
// track_pid_tb.v —— 循迹 PID 自测
// 控制周期缩到 1 ms。验收点：
//   1) pos=0 → 两轮都是 BASE（600），corr=0（D 项此时为 0）
//   2) pos=+7（线在右）→ duty_l > duty_r，corr > 0
//   3) pos=-7 → duty_r > duty_l，corr < 0
//   4) 长时间同侧误差 → 积分使 corr 继续增大（抗饱和：不超过 ±BASE）
//   5) lost=1 → 占空比保持（不清零）
//   6) en=0 → 输出归零、corr 归零
//   7) TRIM 前馈 → pos=0 稳态 corr = TRIM(-140)
//   8) SLEW_STEP=64 → pos 阶跃时 corr 每拍最多 +64（约 6 拍到满量程轴 504）
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
        .P_GAIN    (72),
        .D_GAIN    (40),
        .I_SHIFT   (5),
        .I_LIMIT   (640),
        .SLEW_STEP (0)          // 本实例专测 P/I/D 语义，关掉变化率限制，别让它掩盖 D 尖峰
    ) u_dut (
        .clk (clk), .rst_n (rst_n), .en (en),
        .pos (pos), .on_line (on_line), .lost (lost),
        .duty_l (duty_l), .duty_r (duty_r), .corr (corr)
    );

    // ---- 第二个实例：专门验证新增的前馈 TRIM（TRIM 只影响本实例，不影响上面 6 条）----
    // 期望：pos=0 且积分收敛后 corr = TRIM = -140，即 duty_l = 600-140 = 460、
    // duty_r = 600+140 = 740 —— 右轮更快，正好抵消「右轮约只有左轮 0.55」的不对称。
    reg               en2 = 1'b0;
    reg signed [4:0]  pos2 = 5'sd0;
    reg               lost2 = 1'b0;
    wire [10:0]        duty_l2, duty_r2;
    wire signed [10:0] corr2;

    track_pid #(
        .CLK_FREQ  (24_000_000),
        .TICK_MS   (1),
        .DUTY_MAX  (1200),
        .BASE_DUTY (600),
        .P_GAIN    (80),
        .D_GAIN    (30),
        .I_SHIFT   (5),
        .I_LIMIT   (640),
        .SLEW_STEP (0),         // 同上：TRIM 稳态断言要求对阶跃立即响应
        .TRIM      (-140)
    ) u_trim (
        .clk (clk), .rst_n (rst_n), .en (en2),
        .pos (pos2), .on_line (1'b1), .lost (lost2),
        .duty_l (duty_l2), .duty_r (duty_r2), .corr (corr2)
    );

    // ---- 第三个实例：corr 变化率限制（SLEW_STEP=64）----
    // D_GAIN=0 让波形只由 P 决定：pos=+7 时目标 corr=504，若没有 slew 一拍就到顶。
    reg               en3 = 1'b0;
    reg signed [4:0]  pos3 = 5'sd0;
    wire [10:0]        duty_l3, duty_r3;
    wire signed [10:0] corr3;

    track_pid #(
        .CLK_FREQ  (24_000_000),
        .TICK_MS   (1),
        .DUTY_MAX  (1200),
        .BASE_DUTY (600),
        .P_GAIN    (72),
        .D_GAIN    (0),
        .I_SHIFT   (5),
        .I_LIMIT   (192),
        .SLEW_STEP (64)
    ) u_slew (
        .clk (clk), .rst_n (rst_n), .en (en3),
        .pos (pos3), .on_line (1'b1), .lost (1'b0),
        .duty_l (duty_l3), .duty_r (duty_r3), .corr (corr3)
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
        // 注意：pos 突变的头几个周期 D 项会打一个尖峰，等它衰减后再取样，
        // 否则测到的 corr 是 P+D 的峰值，拿它跟后面比会因为尖峰消失而"变小"。
        // 2026-11-25 起 D 项经过一阶低通（α=1/4），本 tb 的 TICK_MS=1 时时间常数
        // 约 4 个 tick，所以这里从 5 拍到 20 拍：0.75^20≈0.3%，D 已衰减干净。
        pos = 5'sd7;
        wait_ticks(20);
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

        // ---- 5b) 重新压线不许打 D 尖峰 ----
        // track_line 丢线时把 pos 强制清 0。若 pos_d 跟着被清零，重新压线那一拍
        // err_d 会突变成 7 格，D 项打出 7*40=280 计数（23% 占空比）的尖峰。
        // 这里模拟：丢线期间 pos 变 0，然后恢复到 +7，第一拍就必须稳住。
        pos = 5'sd0;
        wait_ticks(5);                       // 丢线期间 pos 被下游清 0
        pos = 5'sd7;                         // 重新压线，线在右边
        lost = 1'b0;
        wait_ticks(1);                       // 恢复后第一拍
        c3 = corr;
        // 无尖峰时应为 P 项 7*72=504 加积分残量（约 -20），明显低于 560；
        // 若 D 项没屏蔽，这里会是 504+7*40=784，必然超限。
        if (c3 <= 11'sd560)
            $display("PASS: re-acquire no D spike (corr=%0d)", c3);
        else
            $display("FAIL: re-acquire D spike (corr=%0d, expect <=560)", c3);

        // ---- 6) en=0 归零 ----
        en = 1'b0;
        wait_ticks(2);
        if (duty_l == 11'd0 && duty_r == 11'd0 && corr == 11'sd0)
            $display("PASS: en=0 -> all zero");
        else
            $display("FAIL: en=0 -> duty %0d/%0d corr=%0d", duty_l, duty_r, corr);

        // ---- 7) TRIM 前馈 ----
        // pos 恒 0、积分稳态收敛后，corr 必须等于 TRIM 而不是 0。
        en2 = 1'b1; pos2 = 5'sd0; lost2 = 1'b0;
        wait_ticks(5);
        if (duty_l2 == 11'd460 && duty_r2 == 11'd740 && corr2 == -11'sd140)
            $display("PASS: TRIM=-140 -> duty %0d/%0d corr=%0d", duty_l2, duty_r2, corr2);
        else
            $display("FAIL: TRIM=-140 -> duty %0d/%0d corr=%0d (expect 460/740,-140)",
                     duty_l2, duty_r2, corr2);

        // ---- 7b) TRIM 与 P 项叠加且仍被 ±BASE 钳位 ----
        // TRIM(-140) + P(7*80=560) + 少量积分，落在 410~440 之间，用区间断言避免把拍数算死。
        // 2026-11-25 起 D 项有低通，等 D 衰减干净再取样（25 拍，τ≈4 拍），
        // 否则量到的是 TRIM+P+D(Q2 低通尾巴) 的混合值。
        pos2 = 5'sd7;
        wait_ticks(25);
        if (corr2 > 11'sd400 && corr2 < 11'sd460)
            $display("PASS: TRIM+P -> corr=%0d (expect ~425)", corr2);
        else
            $display("FAIL: TRIM+P -> corr=%0d (expect 400<corr<460)", corr2);

        pos2 = 5'sd7; wait_ticks(150);   // 积分 92 拍就到 I_LIMIT，150 拍足够
        if (corr2 <= 11'sd600)
            $display("PASS: TRIM windup clamped (corr=%0d <= 600)", corr2);
        else
            $display("FAIL: TRIM windup over clamp corr=%0d", corr2);

        // ---- 8) corr 变化率限制（SLEW_STEP=64 / 拍）----
        // 目标 corr = 7*72 = 504 + 少量积分；没有 slew 时一拍就到位。
        en3 = 1'b1; pos3 = 5'sd0;
        wait_ticks(3);
        pos3 = 5'sd7;
        wait_ticks(1);
        if (corr3 >= 11'sd64 && corr3 <= 11'sd128)
            $display("PASS: slew limits first tick to ~64 (corr=%0d, target 504)", corr3);
        else
            $display("FAIL: slew let corr jump to %0d (expect 64..128, target 504)", corr3);
        wait_ticks(11);
        if (corr3 >= 11'sd480 && corr3 <= 11'sd560)
            $display("PASS: slew reaches target after 12 ticks (corr=%0d)", corr3);
        else
            $display("FAIL: slew stalls at corr=%0d (expect 480..560)", corr3);

        $display("INFO: track_pid_tb done");
        $finish;
    end

    initial begin
        #1_200_000_000;   // 加了 TRIM 用例后总时长 620 ms 左右，watchdog 留一倍余量
        $display("TIMEOUT: track_pid_tb hung");
        $finish;
    end

endmodule
