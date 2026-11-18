`timescale 1ns/1ns

// Bench receiver only. Match the production link and pins, leave all motors in standby.
module TurnLinkBench #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer ALIVE_MS = 2000
) (
    input wire clk,
    input wire rst_n,
    input wire [2:0] k230_d,
    input wire k230_stb,
    output wire [5:0] led,
    output wire motor_stby, ml_pwm, mr_pwm,
    output wire ml_in1, ml_in2, mr_in1, mr_in2
);
    reg [2:0] reset_pipe = 3'b000;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) reset_pipe <= 3'b000;
        else        reset_pipe <= {reset_pipe[1:0], 1'b1};
    wire ready = reset_pipe[2];

    wire online;
    wire [2:0] turn;
    wire [7:0] errors;
    wire [3:0] unused_color;
    wire [7:0] unused_command;
    k230_link #(.CLK_FREQ(CLK_FREQ), .ALIVE_MS(ALIVE_MS)) rx (
        .clk(clk), .rst_n(ready), .k230_d(k230_d), .k230_stb(k230_stb),
        .color_evt(unused_color), .dir_evt(turn), .cmd_evt(unused_command),
        .link_alive(online), .err_cnt(errors)
    );

    reg [23:0] clock_count;
    reg [2:0] last_turn;
    reg event_toggle;
    always @(posedge clk or negedge ready) begin
        if (!ready) begin
            clock_count <= 24'd0;
            last_turn <= 3'd0;
            event_toggle <= 1'b0;
        end else begin
            clock_count <= clock_count + 1'b1;
            if (turn == 3'd1 || turn == 3'd2) begin
                last_turn <= turn;
                event_toggle <= ~event_toggle;
            end
        end
    end

    // Active-low: LED0 online, LED1 left, LED2 right, LED3 protocol error,
    // LED4 changes once per received direction, LED5 FPGA local heartbeat.
    assign led = ~{clock_count[23], event_toggle, (|errors),
                   (last_turn == 3'd2), (last_turn == 3'd1), online};
    assign {motor_stby, ml_pwm, mr_pwm, ml_in1, ml_in2, mr_in1, mr_in2} = 7'd0;
endmodule
