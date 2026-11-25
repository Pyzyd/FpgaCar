`timescale 1ns/1ns

// Tap the 720p DVP stream without interacting with the DDR album.
module ov5640_album_preview #(
    parameter integer CLK_HZ = 96_000_000,
    parameter integer SPI_HALF_CYCLES = CLK_HZ / 6_000_000  // 3 MHz SPI
) (
    input wire clk, rst_n, camera_ready,
    input wire pclk, href, vsync,
    input wire [7:0] data,
    output wire lcd_rst_n, lcd_cs_n, lcd_sclk, lcd_mosi, lcd_dc
);
    wire [8:0] x, y;
    wire image_row = y >= 9'd30 && y < 9'd210;
    wire [8:0] image_y = y - 9'd30;
    wire [14:0] sample_row = {7'b0, image_y[8:1]};
    wire [14:0] sample_col = {7'b0, x[8:1]};
    wire [14:0] sample_addr =
        image_row ? (sample_row << 7) + (sample_row << 5) + sample_col : 15'd0;

    wire frame_valid, frame_release;
    wire [7:0] gray;
    ov5640_preview_frame #(
        .INPUT_WIDTH(1280), .INPUT_HEIGHT(720), .SAMPLE_LOG2(3)
    ) capture (
        .clk(clk), .rst_n(rst_n && camera_ready), .pclk(pclk),
        .href(href), .vsync(vsync), .data(data),
        .frame_release(frame_release), .frame_valid(frame_valid),
        .read_addr(sample_addr), .read_y(gray)
    );

    // Double 160x90 to 320x180 and center it on the 320x240 panel.
    wire [15:0] pixel = image_row ? {gray[7:3], gray[7:2], gray[7:3]} : 16'h0000;
    st7789_panel #(
        .CLK_HZ(CLK_HZ), .SPI_HALF_CYCLES(SPI_HALF_CYCLES),
        .LANDSCAPE(1'b1), .MADCTL(8'h60), .INVERSION_CMD(8'h20)
    ) panel (
        .clk(clk), .rst_n(rst_n), .preview_valid(camera_ready && frame_valid),
        .preview_pixel(pixel), .x(x), .y(y), .preview_used(),
        .preview_release(frame_release), .lcd_rst_n(lcd_rst_n), .lcd_cs_n(lcd_cs_n),
        .lcd_sclk(lcd_sclk), .lcd_mosi(lcd_mosi), .lcd_dc(lcd_dc), .led()
    );
endmodule
