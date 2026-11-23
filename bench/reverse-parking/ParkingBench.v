`timescale 1ns/1ns

module ParkingBench (
    input  wire       clk, key_start_n, key_stop_n,
    input  wire [7:0] track,
    input  wire       enc_la, enc_lb, enc_ra, enc_rb,
    output wire       motor_stby, ml_pwm, mr_pwm,
    output wire       ml_in1, ml_in2, mr_in1, mr_in2,
    output wire [5:0] led,
    output wire       uart_tx
);
    localparam integer CLOCK_HZ = 24_000_000;
    localparam integer FILTER_CYCLES = CLOCK_HZ / 100_000;

    reg [3:0] power_on = 0;
    always @(posedge clk) power_on <= {power_on[2:0], 1'b1};
    wire rst_n = power_on[3];

    wire run_enable, motion_stopped;
    car_panel #(.CLK_FREQ(CLOCK_HZ)) keys (
        .clk(clk), .rst_n(rst_n), .key_start_n(key_start_n), .key_stop_n(key_stop_n),
        .line_ready(1'b1), .motion_stopped(motion_stopped),
        .run_enable(run_enable), .clear_result(), .status()
    );

    wire [31:0] pos_l, pos_r;
    wire step_l, step_r, dir_l, dir_r;

    // 实测 enc_ra/rb 接实际左轮，enc_la/lb 接实际右轮。交换 A/B 后前进为正。
    encoder_dec #(.STABLE_TICKS(FILTER_CYCLES)) left_encoder (
        .clk(clk), .rst_n(rst_n), .a(enc_rb), .b(enc_ra),
        .step(step_l), .direction(dir_l), .position(pos_l)
    );
    encoder_dec #(.STABLE_TICKS(FILTER_CYCLES)) right_encoder (
        .clk(clk), .rst_n(rst_n), .a(enc_lb), .b(enc_la),
        .step(step_r), .direction(dir_r), .position(pos_r)
    );

    wire [7:0] line, raw;
    wire on_line, wide;
    wire signed [4:0] line_pos;
    track_line #(.CLK_FREQ(CLOCK_HZ), .ACTIVE_HIGH(0)) line_sensors (
        .clk(clk), .rst_n(rst_n), .track(track), .line(line), .raw(raw),
        .cnt(), .on_line(on_line), .lost(), .pos(line_pos), .wide(wide)
    );
    wire line_valid = on_line && !wide;
    wire line_centered = line_valid && (line_pos >= -5'sd1) && (line_pos <= 5'sd1);

    wire [10:0] follow_l, follow_r, duty_l, duty_r;
    wire signed [10:0] follow_corr;
    wire following, forward_l, forward_r, fault;
    wire [2:0] status;
    wire [1:0] reverse_fault;
    track_pid #(
        .CLK_FREQ(CLOCK_HZ), .BASE_DUTY(240), .P_GAIN(18), .D_GAIN(8), .I_LIMIT(0)
    ) line_controller (
        .clk(clk), .rst_n(rst_n), .en(following), .pos(line_pos),
        .on_line(line_valid), .lost(!line_valid),
        .duty_l(follow_l), .duty_r(follow_r), .corr(follow_corr)
    );

    parking_motion #(.CLK_FREQ(CLOCK_HZ)) motion (
        .clk(clk), .rst_n(rst_n), .run_enable(run_enable),
        .position_l(pos_l), .position_r(pos_r), .line_seen(on_line),
        .line_valid(line_valid), .line_centered(line_centered),
        .follow_duty_l(follow_l), .follow_duty_r(follow_r),
        .active(motor_stby), .following(following), .stopped(motion_stopped),
        .fault(fault), .reverse_fault(reverse_fault), .status(status),
        .forward_l(forward_l), .forward_r(forward_r),
        .duty_l(duty_l), .duty_r(duty_r)
    );

    // 沿用新版底盘的 A 路接实际右轮、B 路接实际左轮。01 为物理前进。
    function [1:0] motor_inputs;
        input enabled, moving, forward;
        begin
            if (!enabled) motor_inputs = 2'b00;
            else if (!moving) motor_inputs = 2'b11;
            else motor_inputs = {~forward, forward};
        end
    endfunction

    assign {ml_in1, ml_in2} = motor_inputs(motor_stby, duty_r != 0, forward_r);
    assign {mr_in1, mr_in2} = motor_inputs(motor_stby, duty_l != 0, forward_l);
    pwm_gen #(.CLK_FREQ(CLOCK_HZ)) channel_a (
        .clk(clk), .rst_n(rst_n), .en(motor_stby), .duty(duty_r), .pwm(ml_pwm)
    );
    pwm_gen #(.CLK_FREQ(CLOCK_HZ)) channel_b (
        .clk(clk), .rst_n(rst_n), .en(motor_stby), .duty(duty_l), .pwm(mr_pwm)
    );

    wire signed [15:0] speed_l, speed_r;
    wire report_tick;
    speed_meter #(.CLK_FREQ(CLOCK_HZ), .WIN_MS(50)) left_speed (
        .clk(clk), .rst_n(rst_n), .step(step_l), .dir(dir_l), .speed(speed_l), .valid(report_tick)
    );
    speed_meter #(.CLK_FREQ(CLOCK_HZ), .WIN_MS(50)) right_speed (
        .clk(clk), .rst_n(rst_n), .step(step_r), .dir(dir_r), .speed(speed_r), .valid()
    );

    uart_report #(.CLK_FREQ(CLOCK_HZ)) reporter (
        .clk(clk), .rst_n(rst_n), .dist_cm(16'hffff), .dist_valid(report_tick),
        .line(line), .raw(raw), .pos(line_pos), .corr(follow_corr),
        .duty_l(duty_l), .duty_r(duty_r), .wide(wide), .turn_dir(reverse_fault),
        .obstacle(fault), .state(status), .enc_l(pos_l), .enc_r(pos_r),
        .spd_l(speed_l), .spd_r(speed_r), .tx(uart_tx)
    );

    reg [23:0] heartbeat;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) heartbeat <= 0;
        else heartbeat <= heartbeat + 1'b1;
    assign led = ~{heartbeat[23], status, fault, motor_stby};
endmodule
