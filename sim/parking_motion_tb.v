`timescale 1ns/1ns

module parking_motion_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, run_enable = 0;
    reg signed [31:0] pos_l = 0, pos_r = 0;
    reg line_seen = 0, line_valid = 0, line_centered = 0;
    wire active, following, stopped, fault, forward_l, forward_r;
    wire [2:0] status;
    wire [10:0] duty_l, duty_r;

    // 每个模拟时钟推进一毫秒，里程和持续时间阈值与实机一致。
    parking_motion #(.CLK_FREQ(1000)) dut (
        .clk(clk), .rst_n(rst_n), .run_enable(run_enable),
        .position_l(pos_l), .position_r(pos_r), .line_seen(line_seen),
        .line_valid(line_valid), .line_centered(line_centered),
        .follow_duty_l(11'd400), .follow_duty_r(11'd210),
        .active(active), .following(following), .stopped(stopped),
        .fault(fault), .status(status), .forward_l(forward_l), .forward_r(forward_r),
        .duty_l(duty_l), .duty_r(duty_r)
    );

    task step_ms;
        input integer n;
        begin repeat (n) @(negedge clk); end
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
        check(status == 2 && !forward_l && duty_l == 300 && duty_r == 0,
              "entry pivots left wheel backward with right brake");
        pos_l = -3076;
        step_ms(2);
        check(duty_l == 300, "left turn waits for 3077 counts");
        pos_l = -3077;
        step_ms(2);
        check(status == 2 && duty_l == 0 && duty_r == 0, "brake at 90 degree target");
        pos_l = -3080;
        step_ms(150);
        check(status == 3 && !forward_l && !forward_r, "reverse starts after braking");

        pos_l = -3180;
        pos_r = -84;
        step_ms(2);
        check(duty_l == 296 && duty_r == 304, "distance error slows the leading wheel");
        pos_l = -3080 - 3582;
        pos_r = -3582;
        step_ms(2);
        check(status == 3, "keep reversing below 300 mm mean distance");
        pos_l = -3080 - 3584;
        step_ms(1);
        check(status == 4 && duty_l == 0 && duty_r == 0, "park at 300 mm");
        step_ms(5149);
        check(status == 4, "five full seconds after brake settles");
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
        check(status == 6 && forward_l && duty_l == 300 && duty_r == 0,
              "pivot right with left wheel forward");

        pos_l = pos_l + 1400;
        line_valid = 1;
        line_centered = 1;
        step_ms(30);
        check(status == 6, "center hit before minimum turn angle is ignored");
        pos_l = pos_l + 1650;
        step_ms(24);
        check(status == 6, "center must hold before handing over");
        step_ms(3);
        check(following && status == 7 && duty_l == 300 && duty_r == 210,
              "right turn hands over to speed-limited tracking");
        line_valid = 0;
        step_ms(182);
        check(fault && stopped && !active, "stop after losing line");

        begin_turn();
        check(status == 2 && !fault, "fresh K1 clears prior fault");
        pos_r = 181;
        step_ms(2);
        check(fault && !active, "stop if the braked right wheel drifts");

        begin_turn();
        pos_l = 37;
        step_ms(2);
        check(fault && !active, "stop if left encoder reports the wrong direction");

        begin_turn();
        step_ms(902);
        check(fault && !active, "stop if left encoder never moves");

        begin_turn();
        run_enable = 0;
        #1;
        check(!active && duty_l == 0 && duty_r == 0, "K2 cancels motor output");
        step_ms(3);
        check(status == 0 && !active, "stay stopped with K1 released");
        $finish;
    end
endmodule
