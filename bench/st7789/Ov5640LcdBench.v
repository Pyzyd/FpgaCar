`timescale 1ns/1ns

// Independent rear-camera bring-up on the existing DVP and LCD pin assignments.
module Ov5640LcdBench (
    input wire clk, rst_n,
    input wire cmos_pclk, cmos_href, cmos_vsync,
    input wire [7:0] cmos_data,
    input wire cmos_sdat_IN,
    output wire cmos_sclk, cmos_sdat_OUT, cmos_sdat_OE,
    output wire cmos_ctl1, cmos_rst_n, cmos_pwdn,
    output wire lcd_rst_n, lcd_cs_n, lcd_sclk, lcd_mosi, lcd_dc,
    output wire [5:0] led,
    output wire motor_stby, ml_pwm, mr_pwm,
    output wire ml_in1, ml_in2, mr_in1, mr_in2
);
    reg [2:0] reset_pipe = 3'b000;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) reset_pipe <= 3'b000;
        else reset_pipe <= {reset_pipe[1:0], 1'b1};
    wire ready = reset_pipe[2];

    // XCLK is routed from the 24 MHz oscillator in the Interface Designer.
    // The same three CTL levels were validated in the existing OV5640 project.
    assign {cmos_ctl1, cmos_rst_n, cmos_pwdn} = 3'b000;
    wire sccb_start, sccb_done, vs_active;
    cam_probe probe (
        .clk(clk), .rst_n(ready), .vsync(cmos_vsync), .ready(sccb_start),
        .vs_cnt(), .vs_act(vs_active)
    );
    cam_sccb_cfg #(.FULL_FOV_VGA(1'b1)) cfg (
        .clk(clk), .rst_n(ready), .start(sccb_start), .done(sccb_done),
        .sclk(cmos_sclk), .sdat_in(cmos_sdat_IN),
        .sdat_out(cmos_sdat_OUT), .sdat_oe(cmos_sdat_OE)
    );

    wire [8:0] x, y;
    wire [14:0] sample_row = {7'b0, y[8:1]};
    // Double every 160x120 sample to fill 320x240 without cropping or stretching.
    wire [14:0] sample_addr = (sample_row << 7) + (sample_row << 5) + {7'b0, x[8:1]};
    wire [7:0] gray;
    wire frame_valid, frame_release, preview_used;
    wire capture_ready = ready && sccb_done;
    ov5640_preview_frame #(
        .INPUT_WIDTH(640), .INPUT_HEIGHT(480), .SAMPLE_LOG2(2)
    ) capture (
        .clk(clk), .rst_n(capture_ready), .pclk(cmos_pclk),
        .href(cmos_href), .vsync(cmos_vsync), .data(cmos_data),
        .frame_release(frame_release), .frame_valid(frame_valid),
        .read_addr(sample_addr), .read_y(gray)
    );

    wire [5:0] panel_led;
    wire [15:0] preview_pixel = {gray[7:3], gray[7:2], gray[7:3]};
    st7789_panel #(.LANDSCAPE(1'b1), .MADCTL(8'h60), .INVERSION_CMD(8'h20)) panel (
        .clk(clk), .rst_n(rst_n), .preview_valid(capture_ready && frame_valid),
        .preview_pixel(preview_pixel), .x(x), .y(y), .preview_used(preview_used),
        .preview_release(frame_release), .lcd_rst_n(lcd_rst_n), .lcd_cs_n(lcd_cs_n),
        .lcd_sclk(lcd_sclk), .lcd_mosi(lcd_mosi), .lcd_dc(lcd_dc), .led(panel_led)
    );

    // Active-low LEDs. SCCB done is table completion; LED3 requires real frame content.
    assign led = {panel_led[5], 1'b1, !preview_used, !vs_active, !sccb_done, panel_led[0]};
    assign {motor_stby, ml_pwm, mr_pwm, ml_in1, ml_in2, mr_in1, mr_in2} = 7'd0;
endmodule
