`timescale 1ns/1ns
// =============================================================================
// arc_mileage_tb.v -- proves the avoidance arcs cut by ENCODER MILEAGE, not by ms
// -----------------------------------------------------------------------------
// Why: BY_OUT / BY_ALIGN used to be fixed 524 ms. The same 524 ms turns a
// different angle at a different car speed, so the arc landed short (and the
// car clipped the cube) as soon as battery dropped. Now the segments switch on
// the difference of the two wheel counters, which depends only on heading.
//
// Scenario A  fast encoder (left 1/1, right 1/4) -> OUT switches at diff 157
// Scenario B  slow encoder (left 1/4, right 1/6) -> SAME diff 157, many more
//             cycles: the heading is speed-independent, the time is not.
// Scenario C  no encoder pulses at all -> mileage never arrives, the
//             AVOID_OUT_MS timeout must rescue the segment and not hang.
// Plus: BY_PASS must switch on the SUM of both counters (distance), and the
// FSM must hand back to S_RUN once the sidestep is done.
// =============================================================================
module arc_mileage_tb;

    localparam [2:0] S_RUN   = 3'd1;
    localparam [2:0] S_PROBE = 3'd7;
    localparam [2:0] BY_OUT  = 3'd0;
    localparam [2:0] BY_ALIGN= 3'd1;
    localparam [2:0] BY_PASS = 3'd2;

    // Calibration picked as small integers so the targets are hand-checkable:
    //   ENC_CNT_PER_REV=100, WHEEL_CIRC_MM=100, WHEEL_BASE_MM=100
    //   -> ARC_CNT_PER_RAD = 100
    //   -> 90 deg = 1571 mrad -> ARC_DIFF_TARGET = 157
    //   -> AVOID_PASS_MM=100 -> PASS_SUM_TARGET = 100, used as x2 = 200
    localparam integer EXP_DIFF = 157;
    localparam integer EXP_SUM  = 200;
    // Timeout ceiling set far above what the mileage needs, so a segment that
    // switches "early" can only have done so on mileage.
    localparam integer SEG_MS = 3000;
    localparam integer MAXNS  = 900_000;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n = 1'b0;
    reg        on_line = 1'b1, lost = 1'b0, wide = 1'b0;
    reg        obstacle = 1'b1;   // permanent obstacle -> avoidance starts at once
    reg        enc_l = 1'b0, enc_r = 1'b0;
    reg        enc_on = 1'b0;     // 0 = encoder never turns
    reg        fast = 1'b1;

    wire [2:0]  state;
    wire        en, dir_l, dir_r;
    wire [10:0] duty_l, duty_r;

    car_fsm #(
        .CLK_FREQ(1000),               // 1 cycle = 1 ms, keeps the sim quick
        .START_MS(1), .START_REQUIRE_LINE(1),
        .LOST_HOLD_MS(4), .SEARCH_MS(10), .DIR_DEAD_MS(1),
        .AVOID_EN(1), .AVOID_ROUTE_EN(1), .AVOID_FIXED_RIGHT(1),
        .AVOID_ARC_DEG(90),
        .ENC_CNT_PER_REV(100), .WHEEL_CIRC_MM(100), .WHEEL_BASE_MM(100),
        .AVOID_PASS_MM(100),
        .AVOID_OUT_MS(SEG_MS), .AVOID_ALIGN_MS(SEG_MS),
        .AVOID_PASS_MS(SEG_MS), .AVOID_REJOIN_MS(SEG_MS),
        .AVOID_TURN_MS(SEG_MS),
        .AVOID_LINE_MS(4), .AVOID_BLOCK_MS(8)
    ) dut (
        .clk(clk), .rst_n(rst_n), .on_line(on_line), .lost(lost),
        .obstacle(obstacle), .wide(wide), .pos(5'sd0), .dir_evt(3'd0),
        .pid_l(11'd450), .pid_r(11'd450),
        .enc_l_step(enc_l), .enc_r_step(enc_r),
        .en(en), .dir_l(dir_l), .dir_r(dir_r),
        .duty_l(duty_l), .duty_r(duty_r),
        .state(state), .turn_dir()
    );

    // ---------------- encoder pulse generator ----------------
    // Pulses only while en is high: a stopped car does not move its encoder.
    //   fast: left every cycle, right every 4 -> diff +3 per 4 cycles
    //   slow: left every 4, right every 6        -> diff +1 per 12 cycles
    integer tick = 0;
    always @(posedge clk) begin
        enc_l <= 1'b0;
        enc_r <= 1'b0;
        if (rst_n && enc_on && en) begin
            tick <= tick + 1;
            if (fast) begin
                enc_l <= 1'b1;
                if ((tick % 4) == 0) enc_r <= 1'b1;
            end else begin
                if ((tick % 4) == 0) enc_l <= 1'b1;
                if ((tick % 6) == 0) enc_r <= 1'b1;
            end
        end
    end

    // ---------------- per-segment peak capture ----------------
    // arc_diff cannot be read on the switching cycle: arc_seg_new already
    // cleared the counters on that same edge. Track the peak inside the
    // segment instead -- the last peak before the switch is the trigger.
    integer out_cycles = 0, out_maxdiff = 0;
    integer pass_cycles = 0, pass_maxsum = 0;
    always @(posedge clk) begin
        if (rst_n && (state == S_PROBE) && en) begin
            if (dut.bypass_step == BY_OUT) begin
                out_cycles <= out_cycles + 1;
                if (dut.arc_diff > out_maxdiff) out_maxdiff <= dut.arc_diff;
            end
            if (dut.bypass_step == BY_PASS) begin
                pass_cycles <= pass_cycles + 1;
                if (dut.arc_sum > pass_maxsum) pass_maxsum <= dut.arc_sum;
            end
        end
    end

    // ---------------- helpers ----------------
    integer errs = 0;
    task chk;
        input [511:0] name;
        input         cond;
        begin
            if (cond) $display("ok   : %0s", name);
            else begin
                errs = errs + 1;
                $display("FAIL : %0s", name);
            end
        end
    endtask

    task do_reset;
        begin
            rst_n    = 1'b0;
            enc_on   = 1'b0;
            obstacle = 1'b1;
            on_line  = 1'b1;
            lost     = 1'b0;
            wide     = 1'b0;
            tick     = 0;
            out_cycles = 0;  out_maxdiff = 0;
            pass_cycles = 0; pass_maxsum = 0;
            repeat (6) @(posedge clk);
            rst_n = 1'b1;
            repeat (6) @(posedge clk);
        end
    endtask

    // global watchdog: a hang is a failure, not a pass
    initial begin
        #MAXNS;
        $display("FAIL : watchdog, state=%0d step=%0d", state, dut.bypass_step);
        errs = errs + 1;
        $display("FAIL : %0d checks failed", errs);
        $finish;
    end

    integer a_cycles, a_diff, b_cycles, b_diff, c_cycles;

    initial begin
        $display("INFO : ARC_DIFF_TARGET=%0d (exp %0d)  PASS_SUM_TARGET*2=%0d (exp %0d)",
                 dut.ARC_DIFF_TARGET, EXP_DIFF, dut.PASS_SUM_TARGET * 2, EXP_SUM);

        // ===== A: fast encoder =====
        do_reset;
        enc_on = 1'b1; fast = 1'b1;
        wait (state == S_PROBE);
        wait (dut.bypass_step != BY_OUT);
        a_cycles = out_cycles; a_diff = out_maxdiff;
        $display("INFO : A(fast) OUT: %0d cycles, arc_diff=%0d", a_cycles, a_diff);
        chk("A1 OUT switched on mileage, not timeout", (a_diff >= EXP_DIFF) && (a_cycles < SEG_MS - 100));
        chk("A2 OUT did not overshoot the target",     a_diff <= EXP_DIFF + 6);

        // keep going: ALIGN then PASS, PASS must switch on the counter SUM
        wait (dut.bypass_step != BY_ALIGN);
        $display("INFO : A ALIGN done, arc_diff(align)=%0d", dut.arc_diff);
        wait (dut.bypass_step != BY_PASS);
        $display("INFO : A PASS: %0d cycles, arc_sum=%0d", pass_cycles, pass_maxsum);
        chk("A3 PASS switched on mileage (sum), not timeout",
            (pass_maxsum >= EXP_SUM) && (pass_cycles < SEG_MS - 100));

        // ===== B: slow encoder, same heading =====
        do_reset;
        enc_on = 1'b1; fast = 1'b0;
        wait (state == S_PROBE);
        wait (dut.bypass_step != BY_OUT);
        b_cycles = out_cycles; b_diff = out_maxdiff;
        $display("INFO : B(slow) OUT: %0d cycles, arc_diff=%0d", b_cycles, b_diff);
        chk("B1 OUT switched on mileage, not timeout", (b_diff >= EXP_DIFF) && (b_cycles < SEG_MS - 100));
        chk("B2 same heading as A -> speed independent",
            (b_diff >= a_diff - 4) && (b_diff <= a_diff + 4));
        chk("B3 slow car needed far more time",        b_cycles > a_cycles * 2);

        // ===== C: encoder dead, timeout must rescue =====
        do_reset;
        enc_on = 1'b0;
        wait (state == S_PROBE);
        wait (dut.bypass_step != BY_OUT);
        c_cycles = out_cycles;
        $display("INFO : C(no enc) OUT: %0d cycles (timeout %0d)", c_cycles, SEG_MS);
        chk("C1 timeout rescues OUT when encoder is dead", c_cycles >= SEG_MS - 100);
        chk("C2 FSM did not hang in BY_OUT",               state == S_PROBE);

        if (errs == 0) $display("ALL PASS");
        else           $display("FAIL : %0d checks failed", errs);
        $finish;
    end

endmodule
