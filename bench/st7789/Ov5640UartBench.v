`timescale 1ns/1ns

// Camera-only bench for the built-in CH340N serial port.
module Ov5640UartBench (
    input wire clk, rst_n,
    input wire cmos_pclk, cmos_href, cmos_vsync,
    input wire [7:0] cmos_data,
    input wire cmos_sdat_IN,
    output wire cmos_sclk, cmos_sdat_OUT, cmos_sdat_OE,
    output wire cmos_ctl1, cmos_rst_n, cmos_pwdn,
    input wire uart_rx,
    output wire uart_tx,
    output wire [5:0] led,
    output wire motor_stby, ml_pwm, mr_pwm,
    output wire ml_in1, ml_in2, mr_in1, mr_in2
);
    localparam integer INPUT_WIDTH = 640;
    localparam integer INPUT_HEIGHT = 480;
    localparam integer ADDRESS_WIDTH = $clog2((INPUT_WIDTH/2)*(INPUT_HEIGHT/2)+1);
    reg [2:0] reset_pipe = 3'b000;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) reset_pipe <= 3'b000;
        else reset_pipe <= {reset_pipe[1:0], 1'b1};
    wire ready = reset_pipe[2];

    // cmos_xclk is routed directly from the oscillator in the interface file.
    assign {cmos_ctl1, cmos_rst_n, cmos_pwdn} = 3'b000;
    wire sccb_start, sccb_done, vs_active;
    cam_probe probe (
        .clk(clk), .rst_n(ready), .vsync(cmos_vsync), .ready(sccb_start),
        .vs_cnt(), .vs_act(vs_active)
    );
    cam_sccb_cfg #(.FULL_FOV_VGA(1'b1)) cfg (
        .clk(clk), .rst_n(ready), .start(sccb_start), .done(sccb_done),
        .sclk(cmos_sclk), .sdat_in(cmos_sdat_IN), .sdat_out(cmos_sdat_OUT),
        .sdat_oe(cmos_sdat_OE)
    );

    wire [ADDRESS_WIDTH-1:0] read_addr;
    wire [7:0] read_y;
    wire frame_valid, frame_release, sent;
    ov5640_preview_frame #(
        .INPUT_WIDTH(INPUT_WIDTH), .INPUT_HEIGHT(INPUT_HEIGHT),
        .SAMPLE_LOG2(1), .ADDRESS_WIDTH(ADDRESS_WIDTH)
    ) capture (
        .clk(clk), .rst_n(ready && sccb_done), .pclk(cmos_pclk),
        .href(cmos_href), .vsync(cmos_vsync), .data(cmos_data),
        .frame_release(frame_release), .frame_valid(frame_valid),
        .read_addr(read_addr), .read_y(read_y)
    );
    ov5640_uart_snapshot #(
        .WIDTH(INPUT_WIDTH/2), .HEIGHT(INPUT_HEIGHT/2), .ADDRESS_WIDTH(ADDRESS_WIDTH)
    ) snapshot (
        .clk(clk), .rst_n(ready), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .frame_valid(frame_valid), .frame_release(frame_release),
        .read_addr(read_addr), .read_y(read_y), .sent(sent)
    );

    reg [23:0] heartbeat;
    always @(posedge clk or negedge ready)
        if (!ready) heartbeat <= 0;
        else heartbeat <= heartbeat + 1'b1;
    // LED5 heartbeat, LED3 frame locked, LED2 VSYNC, LED1 SCCB, LED0 photo sent.
    assign led = ~{heartbeat[23], 1'b0, frame_valid, vs_active, sccb_done, sent};
    assign {motor_stby, ml_pwm, mr_pwm, ml_in1, ml_in2, mr_in1, mr_in2} = 7'd0;
endmodule
