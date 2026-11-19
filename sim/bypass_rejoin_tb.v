`timescale 1ns/1ns

module bypass_rejoin_tb;
    localparam [2:0] RUN = 1, LOST = 2, SEARCH = 3, STOP = 4, TURN = 6, BYPASS = 7;
    localparam [2:0] OUT = 0, ALIGN = 1, PASS_SIDE = 2, REJOIN = 4;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst_n = 0, on_line = 1, lost = 0, obstacle = 0, wide = 0;
    reg signed [4:0] pos = 0;
    wire [2:0] state;
    wire en, dir_l, dir_r;
    reg inside_bypass = 0;

    car_fsm #(
        .CLK_FREQ(1000), .START_MS(1), .LOST_HOLD_MS(2), .DIR_DEAD_MS(1),
        .AVOID_ROUTE_EN(1), .AVOID_BACK_MS(4), .AVOID_TURN_MS(6), .AVOID_PROBE_MS(6),
        .AVOID_PASS_MS(14), .AVOID_REJOIN_MS(20), .AVOID_LINE_MS(3), .AVOID_BLOCK_MS(5)
    ) dut (
        .clk(clk), .rst_n(rst_n), .on_line(on_line), .lost(lost), .obstacle(obstacle),
        .wide(wide), .pos(pos), .dir_evt(3'd0), .pid_l(11'd450), .pid_r(11'd450),
        .en(en), .dir_l(dir_l), .dir_r(dir_r), .duty_l(), .duty_r(), .state(state), .turn_dir()
    );

    always @(negedge clk)
        if (inside_bypass && (state == LOST || state == SEARCH)) begin
            $display("FAIL: bypass handed control to ordinary line search");
            $finish;
        end

    task check(input condition, input [383:0] message);
        if (condition === 1'b1) $display("PASS: %0s", message);
        else                     $display("FAIL: %0s", message);
    endtask

    task begin_bypass(input signed [4:0] initial_pos);
        begin
            inside_bypass = 0;
            rst_n = 0; on_line = 1; lost = 0; obstacle = 0; wide = 0; pos = initial_pos;
            repeat (3) @(negedge clk);
            rst_n = 1;
            wait (state == RUN);
            @(negedge clk); obstacle = 1; inside_bypass = 1;
            wait (state == TURN);
            @(negedge clk); on_line = 0; lost = 1;
        end
    endtask

    task wait_drive(input [2:0] step);
        begin
            @(negedge clk);
            while (state != BYPASS || dut.bypass_step != step || !en)
                @(negedge clk);
        end
    endtask

    initial begin
        begin_bypass(0);
        obstacle = 0;
        wait_drive(ALIGN);
        check(dir_l && !dir_r, "left detour rotates right to align");
        wait_drive(PASS_SIDE);
        check(dir_l && dir_r, "both wheels advance along the obstacle side");
        on_line = 1; lost = 0;
        repeat (2) @(negedge clk);
        check(state == BYPASS && dut.bypass_step == PASS_SIDE, "brief line alongside does not end bypass");
        on_line = 0; lost = 1;

        wait_drive(REJOIN);
        on_line = 1; lost = 0; wide = 1;
        repeat (4) @(negedge clk);
        check(state == BYPASS, "wide black does not qualify as the return line");
        wide = 0;
        repeat (2) @(negedge clk);
        check(state == BYPASS, "short reacquisition does not enable normal tracking");
        on_line = 0; lost = 1;
        repeat (2) @(negedge clk);
        on_line = 1; lost = 0;
        repeat (4) @(negedge clk);
        check(state == RUN, "stable return line resumes normal tracking");

        begin_bypass(0);
        wait (state == BYPASS && dut.bypass_step == OUT);
        @(negedge clk);
        check(!en, "obstacle still ahead cuts drive during exit");
        wait (state == STOP);
        @(negedge clk); obstacle = 0;
        repeat (5) @(negedge clk);
        check(state == STOP && !en, "persistent blockage latches stop without repeated attempts");

        begin_bypass(-5'sd2);
        obstacle = 0;
        wait_drive(ALIGN);
        check(!dir_l && dir_r, "right detour mirrors alignment turn");
        wait_drive(REJOIN);
        wait (state == STOP);
        @(negedge clk);
        check(!en, "missing return line times out and stays stopped");
        $finish;
    end

    initial begin
        #8000;
        $display("TIMEOUT: bypass phase did not complete");
        $finish;
    end
endmodule
