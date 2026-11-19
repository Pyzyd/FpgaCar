`timescale 1ns/1ns

module car_panel_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, start_n = 0, stop_n = 1;
    reg line_ready = 1, motion_stopped = 0;
    wire run_enable, clear_result;
    wire [1:0] status;
    integer clears = 0;

    car_panel #(.CLK_FREQ(1000), .DEBOUNCE_MS(3), .CLEAR_MS(8)) dut (
        .clk(clk), .rst_n(rst_n), .key_start_n(start_n), .key_stop_n(stop_n),
        .line_ready(line_ready), .motion_stopped(motion_stopped),
        .run_enable(run_enable), .clear_result(clear_result), .status(status)
    );

    always @(posedge clk) if (clear_result) clears = clears + 1;

    task wait_ticks(input integer ticks);
        repeat (ticks) @(negedge clk);
    endtask

    task check(input [1:0] expected_status, input expected_run, input [511:0] message);
        if (status === expected_status && run_enable === expected_run)
            $display("PASS: %0s", message);
        else
            $display("FAIL: %0s (status=%0d, run=%b)", message, status, run_enable);
    endtask

    initial begin
        wait_ticks(2); rst_n = 1;
        wait_ticks(12); check(0, 0, "K1 held at power-up cannot start");
        start_n = 1; wait_ticks(6);
        start_n = 0; wait_ticks(1); start_n = 1; wait_ticks(6);
        check(0, 0, "short K1 glitch is rejected");

        line_ready = 0; start_n = 0; wait_ticks(6);
        check(3, 0, "off-line start is rejected and shows LINE");
        line_ready = 1; wait_ticks(9);
        check(3, 0, "putting the car back on line requires a new press");

        start_n = 1; wait_ticks(6); start_n = 0; wait_ticks(6);
        check(1, 1, "fresh K1 press starts");
        stop_n = 0; wait_ticks(3);
        check(2, 0, "K2 stops before the long-press threshold");
        stop_n = 1; wait_ticks(6);
        check(2, 0, "release K2 does not restart even while K1 is held");
        if (clears != 0) $display("FAIL: short K2 press cleared results");

        start_n = 1; wait_ticks(6); start_n = 0; stop_n = 0; wait_ticks(6);
        check(2, 0, "K2 takes priority over simultaneous K1");
        wait_ticks(12); check(0, 0, "long K2 press goes to READY");
        if (clears == 1) $display("PASS: long K2 press emits one clear pulse");
        else $display("FAIL: expected one clear pulse, got %0d", clears);
        stop_n = 1; start_n = 1; wait_ticks(6); start_n = 0; wait_ticks(6);
        motion_stopped = 1; wait_ticks(2); motion_stopped = 0;
        check(2, 0, "a terminal motion stop latches STOP");
        $finish;
    end
endmodule
