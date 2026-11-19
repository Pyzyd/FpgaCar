`timescale 1ns/1ns

module turn_at_corner_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, on_line = 1, lost = 0, wide = 0;
    reg [2:0] dir_evt = 0;
    wire dir_l, dir_r;
    wire [1:0] turn_dir;

    car_fsm #(
        .CLK_FREQ(10000), .START_MS(2), .TURN_WAIT_FOR_CORNER(1),
        .TURN_REQUEST_MS(35), .TURN_MS(8), .DIR_DEAD_MS(1),
        .CORNER_WIDE_MS(15), .DEFAULT_TURN_LEFT(0), .LOST_HOLD_MS(5)
    ) dut (
        .clk(clk), .rst_n(rst_n), .on_line(on_line), .lost(lost),
        .wide(wide), .obstacle(1'b0), .pos(5'sd1), .dir_evt(dir_evt),
        .pid_l(11'd300), .pid_r(11'd300), .en(), .dir_l(dir_l),
        .dir_r(dir_r), .duty_l(), .duty_r(), .state(), .turn_dir(turn_dir)
    );

    task tick;
        input integer ms;
        repeat (ms * 10) @(negedge clk);
    endtask

    task arrow;
        input [2:0] value;
        begin
            dir_evt = value;
            @(negedge clk);
            dir_evt = 0;
        end
    endtask

    initial begin
        tick(1);
        rst_n = 1;
        tick(4);
        arrow(1);
        tick(6);
        if (turn_dir != 0 || !dir_l || !dir_r) $fatal(1, "FAIL: early arrow steered on straight line");

        wide = 1;
        tick(3);
        if (turn_dir != 0 || !dir_l || !dir_r) $fatal(1, "FAIL: wide-only signal steered");
        wide = 0;
        on_line = 0;
        lost = 1;
        tick(4);
        if (turn_dir != 1 || dir_l || !dir_r) $fatal(1, "FAIL: latched left arrow was not used at corner");

        arrow(2);
        tick(1);
        if (turn_dir != 1 || dir_l || !dir_r) $fatal(1, "FAIL: second message interrupted active turn");
        $display("PASS: direction is latched, waits for corner, and stays fixed while turning");

        rst_n = 0;
        on_line = 1;
        lost = 0;
        tick(1);
        rst_n = 1;
        tick(4);
        arrow(1);
        tick(40);
        wide = 1;
        tick(3);
        wide = 0;
        on_line = 0;
        lost = 1;
        tick(8);
        if (!dir_l || dir_r || turn_dir != 2) $fatal(1, "FAIL: expired arrow overrode normal line search");
        $display("PASS: expired arrow does not affect line search");
        $finish;
    end
endmodule
