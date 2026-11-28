`timescale 1ns/1ns

module parking_motion_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, run_enable = 0;
    reg signed [31:0] pos_l = 0, pos_r = 0;
    reg line_seen = 0, line_valid = 0, line_centered = 0;
    wire active, following, stopped, fault, forward_l, forward_r;
    wire [2:0] status;
    wire [1:0] reverse_fault, entry_fault;
    wire [10:0] duty_l, duty_r;

    // 每个模拟时钟推进一毫秒，里程和持续时间阈值与实机一致。
    localparam [10:0] PIVOT_DUTY = 500;
    parking_motion #(.CLK_FREQ(1000), .PIVOT_DUTY(PIVOT_DUTY), .ENTRY_SECOND_BOOST_STEP(11'd60)) dut (
        .clk(clk), .rst_n(rst_n), .run_enable(run_enable),
        .position_l(pos_l), .position_r(pos_r), .line_seen(line_seen),
        .line_valid(line_valid), .line_centered(line_centered),
        .follow_duty_l(11'd400), .follow_duty_r(11'd210),
        .active(active), .following(following), .stopped(stopped),
        .fault(fault), .reverse_fault(reverse_fault), .entry_fault(entry_fault), .status(status),
        .forward_l(forward_l), .forward_r(forward_r),
        .duty_l(duty_l), .duty_r(duty_r)
    );

    task step_ms;
        input integer n;
        begin repeat (n) @(negedge clk); end
    endtask

    task begin_reverse;
        begin
            begin_turn();
            pos_l = -2940;
            step_ms(152);
        end
    endtask

    task check;
        input condition;
        input [8*88-1:0] description;
        begin
            if (condition !== 1'b1) begin
                $display("FAIL: %0s (state=%d, left=%d, right=%d)",
                         description, status, duty_l, duty_r);
                $fatal(1);
            end
            $display("PASS: %0s", description);
        end
    endtask

    task begin_turn;
        begin
            run_enable = 0;
            pos_l = 0;
            pos_r = 0;
            step_ms(2);
            run_enable = 1;
            step_ms(2002);
        end
    endtask

    initial begin
        step_ms(3);
        rst_n = 1;
        step_ms(2);
        check(!active && status == 0, "idle without K1");

        run_enable = 1;
        step_ms(2000);
        check(status == 1 && duty_l == 0 && duty_r == 0, "full 2 second start delay");
        step_ms(2);
        check(status == 2 && !forward_l && duty_l == PIVOT_DUTY && duty_r == 0,
              "entry pivots left wheel backward with right brake");
        pos_l = -2939;
        step_ms(2);
        check(duty_l == PIVOT_DUTY && duty_r == 0, "keep left pivot until entry brake threshold");
        pos_l = -2940;
        step_ms(2);
        check(status == 2 && duty_l == 0 && duty_r == 0, "brake at 2940 counts for 4 degree lead");
        pos_l = -3077;
        step_ms(150);
        check(status == 3 && !forward_l && !forward_r, "reverse starts after braking");

        pos_l = -3177;
        pos_r = -84;
        step_ms(2);
        check(duty_l == 296 && duty_r == 304, "distance error slows the leading wheel");
        pos_l = -3077 - 325;
        step_ms(2);
        check(status == 3 && duty_l == 0 && duty_r == 360,
              "startup mismatch beyond old cutoff uses catch-up instead of stopping");
        pos_r = -250;
        step_ms(2);
        check(duty_l == 0 && duty_r == 360, "keep leader braked until gap closes");
        pos_r = -255;
        step_ms(2);
        check(duty_l != 0 && duty_r != 0, "resume both wheels after catch-up");
        pos_l = -3077 - 3584;
        pos_r = -3582;
        step_ms(2);
        check(status == 3 && duty_l == 0 && duty_r != 0, "wait for each wheel to reach 300 mm");
        pos_r = -3583;
        step_ms(1);
        check(status == 4 && duty_l == 0 && duty_r == 0, "park at 300 mm");
        step_ms(7149);
        check(status == 4, "seven full seconds after brake settles");
        step_ms(2);
        check(status == 5 && forward_l && forward_r && duty_l == 300 && duty_r == 300,
              "drive both wheels forward to exit");

        line_seen = 1;
        step_ms(40);
        check(duty_l != 0 && duty_r != 0, "ignore line already under probes on exit");
        line_seen = 0;
        step_ms(32);
        line_seen = 1;
        step_ms(11);
        check(duty_l != 0 && duty_r != 0, "confirm front line before braking");
        step_ms(3);
        check(status == 5 && duty_l == 0 && duty_r == 0, "brake once front probes see line");
        step_ms(151);
        check(status == 6 && forward_l && duty_l == PIVOT_DUTY && duty_r == 0,
              "pivot right with left wheel forward");

        pos_l = pos_l + 1400;
        line_valid = 1;
        line_centered = 1;
        step_ms(30);
        check(status == 6, "center hit before minimum turn angle is ignored");
        pos_l = pos_l + 200;
        step_ms(2);
        check(duty_l == 420 && duty_r == 0, "slow the exit pivot before the expected line");
        step_ms(180);
        check(duty_l == PIVOT_DUTY, "restore exit pivot torque if slowing stalled the wheel");
        pos_l = pos_l + 600;
        step_ms(8);
        check(status == 6 && duty_l == 0 && duty_r == 0,
              "above 60 degrees, brake on a centered line before handoff");
        line_centered = 0;
        step_ms(2);
        check(status == 6 && duty_l != 0, "resume searching after a transient center hit");
        line_centered = 1;
        step_ms(14);
        check(status == 6 && duty_l == 0, "require a fresh 15 ms stable center");
        step_ms(2);
        check(following && status == 7 && duty_l == 300 && duty_r == 210,
              "right turn hands over to speed-limited tracking");
        line_valid = 0;
        step_ms(182);
        check(fault && stopped && !active, "stop after losing line");

        begin_turn();
        check(status == 2 && !fault, "fresh K1 clears prior fault");
        pos_l = -2740;
        pos_r = 200;
        step_ms(2);
        check(!fault && status == 2 && duty_l == 0, "allow limited right drift at the target yaw");
        step_ms(151);
        check(status == 3 && !fault, "transition to reverse after limited drift");

        begin_turn();
        pos_r = 241;
        step_ms(2);
        check(fault && !active && entry_fault == 3, "stop and mark right wheel drift");

        begin_turn();
        pos_l = 37;
        step_ms(2);
        check(fault && !active && entry_fault == 1, "stop and mark wrong left encoder direction");

        begin_turn();
        step_ms(179);
        check(status == 2 && duty_l == PIVOT_DUTY && duty_r == 0,
              "start the entry pivot at the original duty");
        step_ms(1);
        check(status == 2 && duty_l == PIVOT_DUTY+60 && duty_r == 0 && !forward_l,
              "boost only the left wheel after 180 ms without progress");
        pos_l = -23;
        step_ms(2);
        check(duty_l == PIVOT_DUTY+60, "keep boost through small encoder changes");
        pos_l = -24;
        step_ms(2);
        check(duty_l == PIVOT_DUTY && duty_r == 0, "restore original duty after 24 net counts");
        pos_l = -500;
        step_ms(1);
        step_ms(179);
        check(duty_l == PIVOT_DUTY, "watch renewed left wheel progress after it starts");
        step_ms(1);
        check(duty_l == PIVOT_DUTY+60 && duty_r == 0, "boost again if the wheel stalls partway through entry");
        pos_l = -2940;
        step_ms(2);
        check(status == 2 && duty_l == 0 && duty_r == 0, "target angle overrides an active boost");

        begin_turn();
        step_ms(399);
        check(!fault && duty_l == PIVOT_DUTY+60, "use the first boost just before 400 ms");
        step_ms(1);
        check(status == 2 && duty_l == PIVOT_DUTY+120 && duty_r == 0, "raise only left PWM after 400 ms without progress");
        step_ms(399);
        check(!fault && duty_l == PIVOT_DUTY+120, "allow torque recovery before the entry stall timeout");
        step_ms(2);
        check(fault && !active && duty_l == 0 && duty_r == 0 && entry_fault == 2,
              "stop if the wheel never moves even with boost");

        begin_reverse();
        pos_l = -2940 - 160;
        step_ms(251);
        check(!fault && duty_l == 0 && duty_r == 420, "boost the stalled reverse wheel only");
        step_ms(551);
        check(fault && !active && reverse_fault == 2, "report reverse stall on commanded wheel");

        begin_reverse();
        step_ms(251);
        check(!fault && duty_l == 420 && duty_r == 420, "help both wheels break away in reverse");
        pos_l = -2940 - 30;
        pos_r = -30;
        step_ms(2);
        check(!fault && duty_l == 300 && duty_r == 300, "restore straight duty once reverse motion begins");

        begin_reverse();
        pos_r = 37;
        step_ms(2);
        check(fault && !active && reverse_fault == 1, "report reverse wrong direction");

        begin_reverse();
        pos_r = -601;
        step_ms(2);
        check(fault && !active && reverse_fault == 3, "report extreme reverse mismatch");

        begin_reverse();
        line_seen = 0;
        line_valid = 0;
        line_centered = 0;
        pos_l = pos_l - 3583;
        pos_r = pos_r - 3583;
        step_ms(7187);
        pos_l = pos_l + 500;
        pos_r = pos_r + 500;
        line_seen = 1;
        step_ms(167);
        check(status == 6 && !fault, "start exit pivot after the line is seen");
        pos_l = pos_l + 3800;
        step_ms(2);
        check(status == 6 && !fault, "continue searching beyond the old 105 degree limit");
        pos_l = pos_l + 150;
        step_ms(2);
        check(fault && !active, "stop at the widened turn limit without a centered line");

        begin_turn();
        run_enable = 0;
        #1;
        check(!active && duty_l == 0 && duty_r == 0, "K2 cancels motor output");
        step_ms(3);
        check(status == 0 && !active, "stay stopped with K1 released");
        $finish;
    end
endmodule
