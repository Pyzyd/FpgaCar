`timescale 1ns/1ns

// One request toggle arms the next full frame. Produce 16 Y8 pixels per word.
module ov5640_photo_capture #(
    parameter integer WIDTH = 1280,
    parameter integer HEIGHT = 720
) (
    input wire pclk, rst_n,
    input wire href, vsync,
    input wire [7:0] data,
    input wire request,
    output reg done, good,
    input wire full,
    output wire push,
    output wire [127:0] word
);
    localparam integer LINE_BYTES = WIDTH * 2;
    (* async_reg = "true" *) reg [1:0] request_sync;
    reg capturing, bad, href_prev, vsync_prev;
    reg [$clog2(LINE_BYTES+2)-1:0] byte_count;
    reg [$clog2(HEIGHT+2)-1:0] line_count;
    reg [7:0] high_byte;
    reg [119:0] first_pixels;
    wire frame_edge = vsync && !vsync_prev;
    wire line_end = href_prev && !href;
    wire all_lines = !href && ((!line_end && line_count == HEIGHT) ||
                    (line_end && line_count == HEIGHT-1 && byte_count == LINE_BYTES));
    wire pixel = capturing && href && !frame_edge && byte_count[0] &&
                 byte_count < LINE_BYTES && line_count < HEIGHT;
    wire [7:0] r = {high_byte[7:3], high_byte[7:5]};
    wire [7:0] g = {high_byte[2:0], data[7:5], high_byte[2:1]};
    wire [7:0] b = {data[4:0], data[4:2]};
    wire [11:0] luma = {2'b0,r,2'b0} + {4'b0,r} +
                      {1'b0,g,3'b0} + {4'b0,g} + {3'b0,b,1'b0};
    // Byte 0 at the low end of the DDR word. Every line is a multiple of 16 pixels.
    assign word = {luma[11:4], first_pixels};
    assign push = pixel && byte_count[4:0] == 31;

    always @(posedge pclk) begin
        if (href && !byte_count[0]) high_byte <= data;
        if (pixel) first_pixels <= {luma[11:4], first_pixels[119:8]};
    end

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            request_sync <= 0;
            done <= 0;
            good <= 0;
            capturing <= 0;
            bad <= 0;
            href_prev <= 0;
            vsync_prev <= 0;
            byte_count <= 0;
            line_count <= 0;
        end else begin
            request_sync <= {request_sync[0], request};
            href_prev <= href;
            vsync_prev <= vsync;
            if (frame_edge) begin
                if (capturing) begin
                    done <= request_sync[1];
                    good <= all_lines && !bad;
                    capturing <= 0;
                end else begin
                    capturing <= request_sync[1] != done;
                end
                bad <= 0;
                byte_count <= 0;
                line_count <= 0;
            end else if (capturing) begin
                if (href && byte_count <= LINE_BYTES)
                    byte_count <= byte_count + 1'b1;
                if (push && full) bad <= 1;
                if (line_end) begin
                    if (byte_count != LINE_BYTES || line_count >= HEIGHT) bad <= 1;
                    byte_count <= 0;
                    if (line_count <= HEIGHT) line_count <= line_count + 1'b1;
                end
            end
        end
    end
endmodule
