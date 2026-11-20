`timescale 1ns/1ns

// Standalone 240x320 LCD checkout. All motor inputs are held low.
// 面板驱动本体在 src/st7789_panel.v（主工程与 bench 共用同一份，不要在这里复制）。
module St7789Bench #(
    parameter integer CLK_HZ = 24_000_000,
    parameter integer SPI_HALF_CYCLES = 16,
    parameter [7:0] MADCTL = 8'h00,
    parameter [7:0] INVERSION_CMD = 8'h21
) (
    input wire clk, rst_n,
    output wire lcd_rst_n, lcd_cs_n,
    output wire lcd_sclk, lcd_mosi, lcd_dc,
    output wire [5:0] led,
    output wire motor_stby, ml_pwm, mr_pwm,
    output wire ml_in1, ml_in2, mr_in1, mr_in2
);
    st7789_panel #(.CLK_HZ(CLK_HZ), .SPI_HALF_CYCLES(SPI_HALF_CYCLES),
                   .MADCTL(MADCTL), .INVERSION_CMD(INVERSION_CMD)) panel (
        .clk(clk), .rst_n(rst_n), .preview_valid(1'b0), .preview_pixel(16'd0),
        .x(), .y(), .preview_used(), .preview_release(),
        .lcd_rst_n(lcd_rst_n), .lcd_cs_n(lcd_cs_n), .lcd_sclk(lcd_sclk),
        .lcd_mosi(lcd_mosi), .lcd_dc(lcd_dc), .led(led)
    );
    assign {motor_stby, ml_pwm, mr_pwm, ml_in1, ml_in2, mr_in1, mr_in2} = 7'd0;
endmodule
