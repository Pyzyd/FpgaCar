`timescale 1ns/1ns

module obstacle_confirm (
    input wire clk, rst_n, sample,
    input wire [15:0] cm,
    output reg near,
    output reg approach_slow
);
    reg [1:0] near_frames, far_frames;
    reg [2:0] missing_frames;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            near <= 0;
            approach_slow <= 0;
            near_frames <= 0;
            far_frames <= 0;
            missing_frames <= 0;
        end else if (sample) begin
            if (cm == 16'hffff) begin
                near_frames <= 0;
                far_frames <= 0;
                if (missing_frames < 6) missing_frames <= missing_frames + 1'b1;
                if (missing_frames >= 5) begin
                    near <= 0;
                    approach_slow <= 0;
                end
            end else begin
                missing_frames <= 0;
                if (cm <= 40) approach_slow <= 1;
                else if (cm > 45) approach_slow <= 0;
                if (cm <= 28) begin
                    far_frames <= 0;
                    if (near_frames < 2) near_frames <= near_frames + 1'b1;
                    if (near_frames >= 2) near <= 1;
                end else if (cm > 34) begin
                    near_frames <= 0;
                    if (far_frames < 2) far_frames <= far_frames + 1'b1;
                    if (far_frames >= 2) near <= 0;
                end else begin
                    near_frames <= 0;
                    far_frames <= 0;
                end
            end
        end
    end
endmodule
