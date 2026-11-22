`timescale 1ns/1ns

module Mc130WheelBench (
    input wire clk, key_start_n, key_stop_n,
    input wire enc_la, enc_lb, enc_ra, enc_rb,
    output wire motor_stby, ml_pwm, mr_pwm,
    output wire ml_in1, ml_in2, mr_in1, mr_in2,
    output wire [5:0] led,
    output wire uart_tx
);
    localparam integer CLOCK_HZ=24_000_000;
    localparam [10:0] DUTY=11'd300;
    reg [3:0] power_on = 0;
    always @(posedge clk) power_on <= {power_on[2:0], 1'b1};
    wire rst_n = power_on[3];
    wire drive_l, drive_r;
    wheel_jog jog (
        .clk(clk), .rst_n(rst_n), .key_start_n(key_start_n),
        .key_stop_n(key_stop_n), .drive_l(drive_l), .drive_r(drive_r)
    );
    assign motor_stby = drive_l || drive_r;
    assign {ml_in1, ml_in2} = {drive_l, 1'b0};
    // This chassis rolls forward with the right motor wired P->BO2, M->BO1.
    assign {mr_in1, mr_in2} = {drive_r, 1'b0};
    pwm_gen #(.CLK_FREQ(CLOCK_HZ), .PWM_FREQ(20_000)) pwm_l (
        .clk(clk), .rst_n(rst_n), .en(drive_l), .duty(DUTY), .pwm(ml_pwm)
    );
    pwm_gen #(.CLK_FREQ(CLOCK_HZ), .PWM_FREQ(20_000)) pwm_r (
        .clk(clk), .rst_n(rst_n), .en(drive_r), .duty(DUTY), .pwm(mr_pwm)
    );
    wire [31:0] pos_l, pos_r;
    wire step_l, step_r, dir_l, dir_r;
    wire [1:0] clean_l, clean_r;
    wire signed [15:0] speed_l, speed_r;
    wire report_tick;
    // 240 cycles at 24 MHz filter glitches shorter than 10 us. The MC130
    // rated output edge interval is about 69–71 us for either gear ratio.
    encoder_input_filter filter_l (
        .clk(clk), .rst_n(rst_n), .raw({enc_la,enc_lb}), .settled(clean_l)
    );
    encoder_input_filter filter_r (
        .clk(clk), .rst_n(rst_n), .raw({enc_ra,enc_rb}), .settled(clean_r)
    );
    encoder_dec count_l (
        .clk(clk), .rst_n(rst_n), .a(clean_l[1]), .b(clean_l[0]),
        .step(step_l), .direction(dir_l), .position(pos_l)
    );
    encoder_dec count_r (
        // The right wheel rolls forward with A leading B at the physical pins.
        // Reverse only the decoded direction so the odometer follows the chassis.
        .clk(clk), .rst_n(rst_n), .a(clean_r[0]), .b(clean_r[1]),
        .step(step_r), .direction(dir_r), .position(pos_r)
    );
    speed_meter #(.CLK_FREQ(CLOCK_HZ), .WIN_MS(50)) rate_l (
        .clk(clk), .rst_n(rst_n), .step(step_l), .dir(dir_l), .speed(speed_l), .valid(report_tick)
    );
    speed_meter #(.CLK_FREQ(CLOCK_HZ), .WIN_MS(50)) rate_r (
        .clk(clk), .rst_n(rst_n), .step(step_r), .dir(dir_r), .speed(speed_r), .valid()
    );
    uart_report #(.CLK_FREQ(CLOCK_HZ)) reporter (
        .clk(clk), .rst_n(rst_n), .dist_cm(16'hffff), .dist_valid(report_tick),
        .line(8'd0), .raw({6'd0,key_stop_n,key_start_n}), .pos(5'd0), .corr(11'd0),
        .duty_l(drive_l ? DUTY : 11'd0), .duty_r(drive_r ? DUTY : 11'd0),
        .wide(1'b0), .turn_dir(2'd0), .obstacle(1'b0), .state({2'd0,motor_stby}),
        .enc_l(pos_l), .enc_r(pos_r), .spd_l(speed_l), .spd_r(speed_r), .tx(uart_tx)
    );
    reg [23:0] heartbeat;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) heartbeat <= 0;
        else heartbeat <= heartbeat + 1'b1;
    assign led = ~{heartbeat[23], 1'b0, 1'b0, !motor_stby, drive_r, drive_l};
endmodule
