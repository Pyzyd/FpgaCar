`timescale 1ns/1ns
module wheel_jog_tb;
    reg clk=0, rst_n=0, key_l=0, key_r=1;
    wire l, r;
    always #5 clk = ~clk;
    wheel_jog #(.DEBOUNCE_TICKS(4), .MAX_PULSE_TICKS(12)) dut (
        .clk(clk), .rst_n(rst_n), .key_start_n(key_l), .key_stop_n(key_r),
        .drive_l(l), .drive_r(r)
    );
    always @(negedge clk) if (l && r) $fatal(1, "Both wheels enabled.");
    task ticks(input integer n);
        repeat (n) @(negedge clk);
    endtask
    initial begin
        ticks(4); rst_n=1;
        ticks(20); if (l || r) $fatal(1, "Held key at startup ran a wheel.");
        key_l=1; ticks(10);
        key_l=0; ticks(2); key_l=1; ticks(10);
        if (l || r) $fatal(1, "Short key bounce ran a wheel.");
        key_l=0; ticks(9);
        if (!l || r) $fatal(1, "K1 should run left only.");
        key_l=1; ticks(3);
        if (l || r) $fatal(1, "Release did not stop.");
        ticks(10); key_r=0; ticks(9);
        if (l || !r) $fatal(1, "K2 should run right only.");
        ticks(35); if (l || r) $fatal(1, "Held key repeated or never timed out.");
        key_r=1; ticks(10);
        key_l=0; key_r=0; ticks(10);
        if (l || r) $fatal(1, "Two keys ran a wheel.");
        key_l=1; ticks(10);
        if (l || r) $fatal(1, "Release of one key incorrectly re-armed the other.");
        key_r=1; ticks(10); key_l=0; ticks(9);
        if (!l || r) $fatal(1, "Fresh press did not re-arm.");
        key_r=0; ticks(3);
        if (l || r) $fatal(1, "Other key did not stop motion.");
        $display("PASS: startup held key, debounce, one wheel, release, timeout and two-key lockout");
        $finish;
    end
endmodule
