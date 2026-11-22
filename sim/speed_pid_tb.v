// =============================================================================
// speed_pid_tb.v —— 速度环自测
// 覆盖三条行为：
//   1) 编码器没脉冲 → NOENC_WIN 个窗口后 enc_ok 掉 0，占空比直通（降级路径）
//   2) 编码器正常且两轮同向 → 快的一侧减速、慢的一侧加速，且修正对称
//   3) 两轮反向（原地转/找线）→ 不修正，直通
// =============================================================================
`timescale 1ns/1ps

module speed_pid_tb;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20.8335 clk = ~clk;         // 24 MHz

    reg               en      = 1'b1;
    reg signed [15:0] spd_l   = 16'sd0;
    reg signed [15:0] spd_r   = 16'sd0;
    reg               valid_l = 1'b0;
    reg               valid_r = 1'b0;
    reg               dir_l   = 1'b1;
    reg               dir_r   = 1'b1;
    reg  [10:0]       duty_l_in = 11'd600;
    reg  [10:0]       duty_r_in = 11'd600;

    wire [10:0]        duty_l_out;
    wire [10:0]        duty_r_out;
    wire signed [10:0] sync_corr;
    wire               enc_ok;

    integer errors = 0;

    speed_pid #(
        .DUTY_MAX     (1200),
        .K_SYNC       (12),
        .I_SYNC_SHIFT (4),
        .I_SYNC_LIMIT (400),
        .SYNC_MAX     (180),
        .NOENC_WIN    (3)
    ) u_dut (
        .clk (clk), .rst_n (rst_n), .en (en),
        .spd_l (spd_l), .spd_r (spd_r),
        .valid_l (valid_l), .valid_r (valid_r),
        .dir_l (dir_l), .dir_r (dir_r),
        .duty_l_in (duty_l_in), .duty_r_in (duty_r_in),
        .duty_l_out (duty_l_out), .duty_r_out (duty_r_out),
        .sync_corr (sync_corr), .enc_ok (enc_ok)
    );

    // 一个测速窗口：先设好速度值，再打一拍 valid
    task tick_win (input signed [15:0] sl, input signed [15:0] sr);
        begin
            spd_l   <= sl;
            spd_r   <= sr;
            @(posedge clk);
            valid_l <= 1'b1;
            valid_r <= 1'b1;
            @(posedge clk);
            valid_l <= 1'b0;
            valid_r <= 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    integer k;
    reg [10:0] base_l, base_r;

    initial begin
        #200 rst_n = 1'b1;
        @(posedge clk);

        // ---------------- 用例 1：编码器无脉冲 → 自动回退直通 ----------------
        duty_l_in = 11'd600;
        duty_r_in = 11'd600;
        for (k = 0; k < 5; k = k + 1) tick_win(16'sd0, 16'sd0);
        if (enc_ok === 1'b0) $display("PASS: 无脉冲 %0d 窗口后 enc_ok=0（回退）", 5);
        else begin $display("FAIL: 编码器无脉冲却仍 enc_ok=1"); errors = errors + 1; end
        if (duty_l_out == 11'd600 && duty_r_out == 11'd600)
            $display("PASS: 回退时占空比直通 600/600");
        else begin
            $display("FAIL: 回退时占空比未直通 %0d/%0d", duty_l_out, duty_r_out);
            errors = errors + 1;
        end

        // ---------------- 用例 2：编码器正常，左快右慢 → 拉平 ----------------
        dir_l = 1'b1;  dir_r = 1'b1;
        for (k = 0; k < 6; k = k + 1) tick_win(16'sd10, 16'sd4);
        if (enc_ok === 1'b1) $display("PASS: 有脉冲后 enc_ok=1（闭环生效）");
        else begin $display("FAIL: 有脉冲却 enc_ok=0"); errors = errors + 1; end

        base_l = duty_l_out;  base_r = duty_r_out;
        if (base_l < 11'd600 && base_r > 11'd600)
            $display("PASS: 左快 → 左减速/右加速 (%0d/%0d)", base_l, base_r);
        else begin
            $display("FAIL: 未按预期修正 (%0d/%0d)", base_l, base_r);
            errors = errors + 1;
        end
        // 修正必须对称：偏离量相等（都由同一个 sum_lim 生成）
        if ((11'd600 - base_l) == (base_r - 11'd600))
            $display("PASS: 修正对称，偏移量=%0d", 11'd600 - base_l);
        else begin
            $display("FAIL: 修正不对称 L=%0d R=%0d", 11'd600 - base_l, base_r - 11'd600);
            errors = errors + 1;
        end
        // 修正不得越界
        if (base_l <= 11'd1200 && base_r <= 11'd1200)
            $display("PASS: 输出在 0..1200 内");
        else begin $display("FAIL: 输出越界"); errors = errors + 1; end

        // ---------------- 用例 3：两轮反向 → 不修正 ----------------
        dir_l = 1'b1;  dir_r = 1'b0;
        for (k = 0; k < 6; k = k + 1) tick_win(16'sd10, -16'sd10);
        if (duty_l_out == 11'd600 && duty_r_out == 11'd600)
            $display("PASS: 两轮反向时不修正（直通）");
        else begin
            $display("FAIL: 两轮反向仍在修正 %0d/%0d", duty_l_out, duty_r_out);
            errors = errors + 1;
        end

        // ---------------- 用例 4：en=0 直通且清积分 ----------------
        en = 1'b0;
        @(posedge clk); @(posedge clk); #1;
        duty_l_in = 11'd300;  duty_r_in = 11'd900;
        @(posedge clk); #1;
        if (duty_l_out == 11'd300 && duty_r_out == 11'd900)
            $display("PASS: en=0 时直通 %0d/%0d", duty_l_out, duty_r_out);
        else begin
            $display("FAIL: en=0 未直通 %0d/%0d", duty_l_out, duty_r_out);
            errors = errors + 1;
        end

        if (errors == 0) $display("ALL PASS: speed_pid_tb");
        else             $display("FAIL: speed_pid_tb 共 %0d 处错误", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TIMEOUT: speed_pid_tb hung");
        $finish;
    end

endmodule
