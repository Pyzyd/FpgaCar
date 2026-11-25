`timescale 1ns/1ns

module parking_approach_tb;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst_n = 0, run = 0, request = 0;
    reg frame_done = 0, corner = 0, pair_valid = 0;
    reg [9:0] center = 0;
    wire slow, pair_seen, brake, stopped;
    wire [10:0] duty_l, duty_r;
    parking_approach #(.CLK_FREQ(1000), .BRAKE_MS(4)) dut (
        .clk(clk), .rst_n(rst_n), .run_enable(run), .parking_request(request),
        .frame_done(frame_done), .corner_seen(corner), .pair_valid(pair_valid),
        .center_x_sum(center), .track_duty_l(11'd340), .track_duty_r(11'd620),
        .duty_l(duty_l), .duty_r(duty_r), .slow(slow), .pair_seen(pair_seen),
        .brake(brake), .stopped(stopped)
    );

    task frame(input seen, input both, input [9:0] midpoint);
        begin
            @(negedge clk);
            frame_done = 1; corner = seen; pair_valid = both; center = midpoint;
            @(negedge clk); frame_done = 0;
        end
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1; run = 1;
        frame(1, 1, 320);
        if (slow || pair_seen || brake || duty_l != 340 || duty_r != 620)
            $fatal(1, "parking must be armed to change the original drive");
        request = 1;
        frame(0, 0, 0);
        request = 0;
        if (slow || brake || duty_l != 255 || duty_r != 465)
            $fatal(1, "P must scale both original commands to 75 percent");
        frame(1, 0, 0);
        if (!slow || pair_seen || brake || duty_l != 136 || duty_r != 248)
            $fatal(1, "first corner must scale the original commands to 40 percent");
        frame(0, 0, 0);
        if (!slow || brake || duty_l != 136 || duty_r != 248)
            $fatal(1, "short corner loss must keep the slow command");
        frame(1, 1, 320);
        frame(1, 1, 332);
        if (!pair_seen || brake) $fatal(1, "off-center pair must interrupt confirmation");
        frame(1, 1, 307);
        if (brake) $fatal(1, "one centered frame must not stop");
        frame(1, 1, 331);
        if (!brake || stopped || duty_l != 0 || duty_r != 0)
            $fatal(1, "two centered frames must start short brake");
        repeat (4) @(negedge clk);
        if (!brake || !stopped) $fatal(1, "short brake must settle before latching stop");
        run = 0;
        @(negedge clk);
        if (slow || brake || stopped || pair_seen) $fatal(1, "stop or abort must clear the run");
        $display("PASS: P 75%, corner 40%, dropouts, two-frame confirmation, short brake and reset");
        $finish;
    end
endmodule
