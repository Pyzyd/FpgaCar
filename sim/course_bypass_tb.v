`timescale 1ns/1ns
module course_bypass_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, run_enable = 0, request = 0, aligned = 1;
    reg obstacle = 0, dist_valid = 0, line_seen = 1, line_valid = 1;
    reg [15:0] dist_cm = 16'hffff;
    reg signed [4:0] line_pos = 0;
    reg signed [31:0] pos_l = 0, pos_r = 0;
    wire owns, drive, fault, stop_request, near;
    wire [3:0] phase;
    wire [7:0] fault_info;
    wire [10:0] duty_l, duty_r;
    integer model_ms;

    course_bypass #(.CLK_FREQ(1000)) dut (
        .clk(clk), .rst_n(rst_n), .run_enable(run_enable), .request(request),
        .entry_aligned(aligned), .obstacle(obstacle), .dist_valid(dist_valid),
        .dist_cm(dist_cm), .line_seen(line_seen), .line_valid(line_valid),
        .line_pos(line_pos), .pos_l(pos_l), .pos_r(pos_r), .owns_motors(owns),
        .drive(drive), .fault(fault), .stop_request(stop_request),
        .phase(phase), .fault_info(fault_info), .duty_l(duty_l), .duty_r(duty_r)
    );
    obstacle_confirm range_filter (
        .clk(clk), .rst_n(rst_n), .sample(dist_valid), .cm(dist_cm), .near(near)
    );

    task cycles(input integer num);
        repeat(num) @(negedge clk);
    endtask
    task check(input condition, input [8*84-1:0] description);
        begin
            if (condition !== 1'b1) $fatal(1, "FAIL: %0s (B=%x)", description, phase);
            $display("PASS: %0s", description);
        end
    endtask
    task sample(input [15:0] value);
        begin
            dist_cm = value;
            dist_valid = 1;
            cycles(1);
            dist_valid = 0;
            cycles(1);
        end
    endtask
    task reset_route;
        begin
            rst_n = 0; run_enable = 0; request = 0; aligned = 1; obstacle = 0;
            pos_l = 0; pos_r = 0; line_seen = 1; line_valid = 1; line_pos = 0;
            cycles(3);
            rst_n = 1; run_enable = 1;
            cycles(1);
        end
    endtask
    task trigger_at(input [15:0] distance);
        begin
            sample(distance);
            request = 1; obstacle = 1;
            cycles(1);
            request = 0;
        end
    endtask
    task begin_out;
        begin
            reset_route();
            trigger_at(23);
            cycles(124);
            line_seen = 0; line_valid = 0;
            cycles(27);
            if (phase != 3) $fatal(1, "FAIL: no outbound arc");
        end
    endtask
    task finish_arc_plan;
        begin
            pos_l = 3282; pos_r = 1094; cycles(2);
            pos_l = 4376; pos_r = 4376; cycles(2);
            pos_l = 6336; pos_r = 6336; cycles(2);
            pos_l = 7430; pos_r = 9618; cycles(2);
            pos_l = 10712; pos_r = 10712; cycles(2);
        end
    endtask

    initial begin
        reset_route();
        sample(20); sample(20); sample(40);
        check(!near, "40 cm cannot complete a near-frame sequence");
        sample(24); sample(24); sample(24);
        check(near, "three near echoes assert the obstacle");
        repeat(5) sample(16'hffff);
        check(near, "short echo dropout holds obstacle status");
        sample(16'hffff);
        check(!near, "prolonged no-echo releases stale obstacle");
        sample(24); sample(24); sample(24);
        sample(40); sample(40); sample(30);
        check(near, "hysteresis sample interrupts far-echo vote");
        sample(40); sample(40); sample(40);
        check(!near, "three far echoes clear obstacle");

        reset_route();
        trigger_at(25);
        check(phase == 1 && duty_l == duty_r && duty_l != 0, "approach straight when beyond entry range");
        sample(23);
        cycles(3);
        check(phase == 2 && drive && duty_l == 0 && duty_r == 0, "brake before starting bypass");
        cycles(121);
        check(phase == 3 && duty_l > duty_r, "right outbound arc uses faster physical left wheel");
        line_seen = 0; line_valid = 0;
        cycles(27);
        pos_l = 3282;
        cycles(2);
        check(phase == 3 && duty_l == 0 && duty_r != 0, "left completion does not conceal right shortfall");
        pos_r = 1094;
        cycles(2);
        check(phase == 4 && duty_r > duty_l, "both outbound targets reached before counter arc");
        pos_l = 4376; pos_r = 4376;
        cycles(2);
        check(phase == 5 && duty_l == duty_r && dut.pass_end == 6336, "distance depends on actual 23 cm approach");
        line_seen = 1; line_valid = 1;
        cycles(25);
        check(phase == 5, "seeing the line cannot cut the side pass short");
        pos_l = 6336; pos_r = 6335;
        cycles(2);
        check(phase == 5, "complete both pass targets before merging");
        pos_r = 6336; cycles(2);
        check(phase == 6 && duty_r > duty_l, "merge arc bends toward the original line");
        pos_l = 7430; pos_r = 9618; cycles(2);
        check(phase == 7 && duty_l > duty_r, "last arc restores the original heading");
        pos_l = 10712; pos_r = 10712; cycles(12);
        check(phase == 8 && owns, "line sample alone cannot hand over early");
        line_pos = 3; cycles(1); line_pos = 0;
        cycles(34);
        check(phase == 8, "center must be stable for 35 ms");
        cycles(2);
        check(phase == 9 && !owns && !fault, "stable center hands the motors back to tracking");
        request = 1; cycles(50);
        check(phase == 9, "same latched obstacle cannot trigger a second bypass");
        request = 0; obstacle = 0; pos_l = 12150; pos_r = 12150; cycles(2);
        check(phase == 0, "clear obstacle plus forward progress re-arms bypass");

        begin_out();
        // 让两侧电机的每单位占空比速度相差约 18%。
        for (model_ms = 0; model_ms < 7500 && phase != 8 && !fault; model_ms = model_ms + 1) begin
            pos_l = pos_l + duty_l / 35;
            pos_r = pos_r + duty_r / 41;
            cycles(1);
        end
        check(phase == 8 && !fault, "unequal motors still complete the arc plan using counts");

        begin_out();
        pos_l = -37; cycles(2);
        check(phase == 15 && stop_request && !drive, "backwards encoder motion stops the bypass");
        check(fault_info == 8'h31, "trace reports outbound wrong direction");
        run_enable = 0; cycles(2);
        check(fault && !stop_request && !owns, "fault remains visible after panel stops");
        run_enable = 1; cycles(2);
        check(phase == 0 && !fault, "new K1 run clears fault");

        begin_out();
        pos_l = 3282; cycles(853);
        check(fault && !drive, "one working encoder cannot mask a stalled wheel");
        check(fault_info == 8'h33, "trace reports outbound right wheel stall");
        begin_out();
        finish_arc_plan();
        pos_l = 10867; pos_r = 10867; cycles(2);
        check(fault && owns && !drive, "no center within search distance stops");

        reset_route(); trigger_at(19); cycles(2);
        check(fault && !drive, "too close to start the validated arc stops");

        reset_route(); aligned = 0; trigger_at(23); cycles(1);
        check(fault && !drive, "off-line trigger stops rather than invoking legacy reverse");
        begin_out();
        run_enable = 0; #1;
        check(!owns && !drive && duty_l == 0 && duty_r == 0, "K2 drops bypass drive immediately");
        $finish;
    end
    initial begin
        #150000;
        $fatal(1, "FAIL: simulation watchdog");
    end
endmodule
