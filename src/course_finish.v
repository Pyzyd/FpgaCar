`timescale 1ns/1ns

// 起步区只旁路宽黑判定。出库归线后才确认终点横边，并用编码器直行到停车点。
module course_finish #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer COUNTS_PER_REV = 2532,
    parameter integer WHEEL_CIRC_MM = 212,
    parameter integer START_BOX_MM = 400,
    parameter integer FINISH_MM = 300,
    parameter integer CONFIRM_MS = 8,
    parameter integer DRIVE_DUTY = 268,
    parameter integer DRIVE_TRIM = 24
) (
    input wire clk, rst_n, run_enable, finish_armed, wide_marker,
    input wire signed [31:0] position_l, position_r, // 向前为正
    output reg start_zone,
    output wire driving, braking, stopped,
    output wire [10:0] duty_l, duty_r
);
    localparam [1:0] WAIT_MARKER = 0, DRIVE = 1, BRAKE = 2, STOP = 3;
    localparam integer MS_CYCLES = CLK_FREQ / 1000;
    localparam integer TICK_BITS = (MS_CYCLES <= 1) ? 1 : $clog2(MS_CYCLES);
    localparam integer START_COUNTS =
        (START_BOX_MM * COUNTS_PER_REV + WHEEL_CIRC_MM / 2) / WHEEL_CIRC_MM;
    localparam integer FINISH_COUNTS =
        (FINISH_MM * COUNTS_PER_REV + WHEEL_CIRC_MM / 2) / WHEEL_CIRC_MM;
    localparam integer DRIVE_LIMIT_MS = 8000, BRAKE_MS = 150;
    localparam integer MAX_SKEW = 600, REVERSE_COUNTS = 36;

    reg [1:0] state;
    reg [TICK_BITS-1:0] tick_count;
    reg [15:0] elapsed_ms;
    reg signed [31:0] origin_l, origin_r;
    wire ms_tick = tick_count == MS_CYCLES - 1;
    wire signed [31:0] delta_l = position_l - origin_l;
    wire signed [31:0] delta_r = position_r - origin_r;
    wire signed [32:0] sum_delta = $signed({delta_l[31], delta_l}) +
                                  $signed({delta_r[31], delta_r});
    wire signed [32:0] skew = $signed({delta_l[31], delta_l}) -
                             $signed({delta_r[31], delta_r});
    wire signed [32:0] trim_raw = DRIVE_TRIM - (skew >>> 2);
    wire signed [32:0] trim = trim_raw > 60 ? 33'sd60 :
                              trim_raw < -60 ? -33'sd60 : trim_raw;
    wire signed [32:0] pwm_l = DRIVE_DUTY + trim;
    wire signed [32:0] pwm_r = DRIVE_DUTY - trim;
    wire bad_motion = delta_l < -REVERSE_COUNTS || delta_r < -REVERSE_COUNTS ||
                      skew > MAX_SKEW || skew < -MAX_SKEW;

    assign driving = run_enable && state == DRIVE;
    assign braking = run_enable && state == BRAKE;
    assign stopped = run_enable && state == STOP;
    assign duty_l = driving && pwm_l > 0 ? (pwm_l > 1200 ? 11'd1200 : pwm_l[10:0]) : 11'd0;
    assign duty_r = driving && pwm_r > 0 ? (pwm_r > 1200 ? 11'd1200 : pwm_r[10:0]) : 11'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= WAIT_MARKER;
            tick_count <= 0;
            elapsed_ms <= 0;
            start_zone <= 1'b1;
            origin_l <= 0;
            origin_r <= 0;
        end else if (!run_enable) begin
            state <= WAIT_MARKER;
            tick_count <= 0;
            elapsed_ms <= 0;
            start_zone <= 1'b1;
            origin_l <= position_l;
            origin_r <= position_r;
        end else begin
            tick_count <= ms_tick ? 0 : tick_count + 1'b1;
            if (start_zone && sum_delta >= 2 * START_COUNTS)
                start_zone <= 1'b0;

            case (state)
                WAIT_MARKER: begin
                    if (!finish_armed || !wide_marker) elapsed_ms <= 0;
                    else if (ms_tick) begin
                        if (elapsed_ms >= CONFIRM_MS - 1) begin
                            origin_l <= position_l;
                            origin_r <= position_r;
                            elapsed_ms <= 0;
                            state <= DRIVE;
                        end else elapsed_ms <= elapsed_ms + 1'b1;
                    end
                end
                DRIVE: begin
                    if (sum_delta >= 2 * FINISH_COUNTS || bad_motion || elapsed_ms >= DRIVE_LIMIT_MS) begin
                        elapsed_ms <= 0;
                        state <= BRAKE;
                    end else if (ms_tick) elapsed_ms <= elapsed_ms + 1'b1;
                end
                BRAKE: if (ms_tick) begin
                    if (elapsed_ms >= BRAKE_MS - 1) state <= STOP;
                    else elapsed_ms <= elapsed_ms + 1'b1;
                end
                default: state <= STOP;
            endcase
        end
    end
endmodule
