`timescale 1ns/1ns

// 单角先降速，两角中点连续确认后短刹。停车事件仅交给面板锁停。
module parking_approach #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer BRAKE_MS = 150
) (
    input  wire clk, rst_n, run_enable, parking_request,
    input  wire frame_done, corner_seen, pair_valid,
    input  wire [9:0] center_x_sum,
    output reg  slow, brake, stopped
);
    localparam integer BRAKE_CLOCKS = CLK_FREQ / 1000 * BRAKE_MS;
    localparam integer TIMER_BITS = $clog2(BRAKE_CLOCKS + 1);
    reg armed;
    reg [1:0] centered_frames;
    reg [TIMER_BITS-1:0] brake_timer;

    // 同一帧中 xL+xR 按 320 对应 720p 中心 x=640。两角分别量化到 320x180。
    wire centered = pair_valid && center_x_sum >= 307 && center_x_sum <= 331;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed <= 0;
            slow <= 0;
            brake <= 0;
            stopped <= 0;
            centered_frames <= 0;
            brake_timer <= 0;
        end else if (!run_enable) begin
            armed <= 0;
            slow <= 0;
            brake <= 0;
            stopped <= 0;
            centered_frames <= 0;
            brake_timer <= 0;
        end else if (brake) begin
            if (brake_timer == BRAKE_CLOCKS - 1) stopped <= 1;
            else brake_timer <= brake_timer + 1'b1;
        end else begin
            if (parking_request) armed <= 1;
            if ((armed || parking_request) && frame_done) begin
                if (corner_seen) slow <= 1;
                if (!centered) centered_frames <= 0;
                else if (centered_frames == 2) brake <= 1;
                else centered_frames <= centered_frames + 1'b1;
            end
        end
    end
endmodule
