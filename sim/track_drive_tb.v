`timescale 1ns/1ns

module track_drive_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg signed [4:0] pos = 0;
    reg lost = 0;
    wire en, dir_l, dir_r;
    wire [2:0] state;
    wire [10:0] pid_l, pid_r, cmd_l, cmd_r, pwm_l, pwm_r;
    wire follow = (state == 3'd1 || state == 3'd2) && dir_l == dir_r;

    // 1 clk = 1 ms in the control modules. Use the main project's tuning.
    track_pid #(
        .CLK_FREQ(1000), .TICK_MS(10), .BASE_DUTY(480),
        .P_GAIN(48), .D_GAIN(0), .I_LIMIT(0), .EDGE_POS(4), .EDGE_SLOWDOWN(48)
    ) u_pid (
        .clk(clk), .rst_n(rst_n), .en(en), .pos(pos), .on_line(!lost), .lost(lost),
        .duty_l(pid_l), .duty_r(pid_r), .corr()
    );

    car_fsm #(
        .CLK_FREQ(1000), .START_MS(1), .LOST_HOLD_MS(80), .LOST_SLOWDOWN(1),
        .DIR_DEAD_MS(10), .SEARCH_DUTY(500), .AVOID_EN(0)
    ) u_car (
        .clk(clk), .rst_n(rst_n), .on_line(!lost), .lost(lost), .obstacle(1'b0),
        .pos(pos), .wide(1'b0), .dir_evt(3'd0), .pid_l(pid_l), .pid_r(pid_r),
        .enc_l_step(1'b0), .enc_r_step(1'b0), .en(en), .dir_l(dir_l), .dir_r(dir_r),
        .duty_l(cmd_l), .duty_r(cmd_r), .state(state), .turn_dir()
    );

    duty_shaper #(.CLK_FREQ(1000), .DIFF_SHIFT(1)) u_shaper (
        .clk(clk), .rst_n(rst_n), .en(en), .follow(follow),
        .duty_l_in(cmd_l), .duty_r_in(cmd_r), .duty_l_out(pwm_l), .duty_r_out(pwm_r)
    );

    task check_pwm(input [10:0] left, input [10:0] right, input string name);
        if (pwm_l !== left || pwm_r !== right)
            $fatal(1, "FAIL: %s, got %0d/%0d expected %0d/%0d", name, pwm_l, pwm_r, left, right);
        else
            $display("PASS: %s -> %0d/%0d", name, pwm_l, pwm_r);
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (20) @(negedge clk);
        check_pwm(480, 480, "straight");

        pos = 1;
        repeat (13) @(negedge clk);
        check_pwm(504, 456, "small error, within one PID period plus output latency");

        pos = 4;
        repeat (13) @(negedge clk);
        check_pwm(528, 336, "right edge slows and steers right");

        pos = -4;
        repeat (13) @(negedge clk);
        check_pwm(336, 528, "left edge slows and steers left");

        lost = 1;
        pos = 0;
        repeat (4) @(negedge clk);
        check_pwm(252, 396, "lost line slows immediately and holds left bias");

        lost = 0;
        repeat (13) @(negedge clk);
        check_pwm(480, 480, "reacquire center without a steering spike");

        pos = -4;
        repeat (13) @(negedge clk);
        lost = 1;
        pos = 0;
        repeat (75) @(negedge clk);
        if (state !== 3'd2) $fatal(1, "FAIL: stopped holding too early");
        repeat (18) @(negedge clk);
        if (state !== 3'd3 || dir_l !== 1'b0 || dir_r !== 1'b1)
            $fatal(1, "FAIL: search must turn toward last visible side");
        check_pwm(500, 500, "search left after timeout");
        $finish;
    end
endmodule
