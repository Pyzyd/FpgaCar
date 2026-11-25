`timescale 1ns/1ns

// 收到 P 先降速，单角出现后继续降速，两角中点连续确认后短刹。
module parking_approach #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer BRAKE_MS = 150
) (
    input  wire clk, rst_n, run_enable, parking_request,
    input  wire frame_done, corner_seen, pair_valid,
    input  wire [9:0] center_x_sum,
    input  wire [10:0] track_duty_l, track_duty_r,
    output wire [10:0] duty_l, duty_r,
    output reg  slow, pair_seen, brake, stopped
);
    localparam integer BRAKE_CLOCKS = CLK_FREQ / 1000 * BRAKE_MS;
    localparam integer TIMER_BITS = $clog2(BRAKE_CLOCKS + 1);
    reg armed;
    reg previous_centered;
    reg [TIMER_BITS-1:0] brake_timer;

    // 同一帧中 xL+xR 按 320 对应 720p 中心 x=640。两角分别量化到 320x180。
    wire centered = pair_valid && center_x_sum >= 307 && center_x_sum <= 331;

    function [10:0] adjusted_duty;
        input [10:0] duty;
        input p_active, corner_active, brake_active;
        reg [12:0] tripled;
        begin
            tripled = {2'b0,duty} + {1'b0,duty,1'b0};
            if (brake_active) adjusted_duty = 0;
            else if (corner_active) adjusted_duty = {1'b0,duty,1'b0} / 13'd5;
            else if (p_active) adjusted_duty = tripled[12:2];
            else adjusted_duty = duty;
        end
    endfunction

    assign duty_l = adjusted_duty(track_duty_l, armed || parking_request, slow, brake);
    assign duty_r = adjusted_duty(track_duty_r, armed || parking_request, slow, brake);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed <= 0;
            slow <= 0;
            brake <= 0;
            stopped <= 0;
            previous_centered <= 0;
            pair_seen <= 0;
            brake_timer <= 0;
        end else if (!run_enable) begin
            armed <= 0;
            slow <= 0;
            brake <= 0;
            stopped <= 0;
            previous_centered <= 0;
            pair_seen <= 0;
            brake_timer <= 0;
        end else if (brake) begin
            if (brake_timer == BRAKE_CLOCKS - 1) stopped <= 1;
            else brake_timer <= brake_timer + 1'b1;
        end else begin
            if (parking_request) armed <= 1;
            if ((armed || parking_request) && frame_done) begin
                if (corner_seen) slow <= 1;
                if (pair_valid) pair_seen <= 1;
                if (centered && previous_centered) brake <= 1;
                previous_centered <= centered;
            end
        end
    end
endmodule
