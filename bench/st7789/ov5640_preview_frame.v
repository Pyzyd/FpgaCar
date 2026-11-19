`timescale 1ns/1ns

// 1280x720 RGB565 DVP in, 160x90 Y8 snapshot out.
// PCLK writes one complete frame, then stops until the LCD returns ownership.
module ov5640_preview_frame (
    input wire clk, rst_n,
    input wire pclk, href, vsync,
    input wire [7:0] data,
    input wire frame_release,
    output wire frame_valid,
    input wire [13:0] read_addr,
    output reg [7:0] read_y
);
    localparam [11:0] LINE_BYTES = 12'd2560;
    localparam [9:0] FRAME_LINES = 10'd720;
    localparam [13:0] FRAME_SAMPLES = 14'd14400;

    reg request, ack;
    reg [1:0] pclk_reset;
    reg [1:0] request_sync, ack_sync;

    always @(posedge pclk or negedge rst_n)
        if (!rst_n) pclk_reset <= 2'b00;
        else pclk_reset <= {pclk_reset[0], 1'b1};
    wire pclk_ready = pclk_reset[1];

    always @(posedge pclk or negedge pclk_ready)
        if (!pclk_ready) request_sync <= 2'b00;
        else request_sync <= {request_sync[0], request};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            request <= 1'b1; // automatically request the first snapshot
            ack_sync <= 2'b00;
        end else begin
            ack_sync <= {ack_sync[0], ack};
            if (frame_release && frame_valid) request <= ~request;
        end
    end
    assign frame_valid = ack_sync[1] == request;

    reg [7:0] frame [0:14399];
    reg href_prev, vsync_prev, capturing, bad_line;
    reg [11:0] byte_count;
    reg [9:0] line_count;
    reg [13:0] write_addr;
    reg [7:0] high_byte;
    wire new_frame = vsync && !vsync_prev;
    wire line_end = href_prev && !href;
    // Accept the last HREF falling on the same clock as the frame boundary.
    wire all_lines = !href && ((!line_end && line_count == FRAME_LINES) ||
                     (line_end && line_count == FRAME_LINES - 1 && byte_count == LINE_BYTES));

    // Take x=4,12,... and y=4,12,..., the center of each 8x8 block.
    wire sample_pixel = pclk_ready && capturing && href && !new_frame &&
                        line_count[2:0] == 3'd4 && byte_count[3:0] == 4'd9 &&
                        byte_count < LINE_BYTES && line_count < FRAME_LINES &&
                        write_addr < FRAME_SAMPLES;

    wire [7:0] red = {high_byte[7:3], high_byte[7:5]};
    wire [7:0] green = {high_byte[2:0], data[7:5], high_byte[2:1]};
    wire [7:0] blue = {data[4:0], data[4:2]};
    // Approximate luma as (5R + 9G + 2B) / 16 with shifts and adds.
    wire [11:0] luma = {2'b0, red, 2'b0} + {4'b0, red} +
                       {1'b0, green, 3'b0} + {4'b0, green} + {3'b0, blue, 1'b0};

    always @(posedge pclk)
        if (sample_pixel) frame[write_addr] <= luma[11:4];
    always @(posedge clk)
        read_y <= frame[read_addr];

    always @(posedge pclk or negedge pclk_ready) begin
        if (!pclk_ready) begin
            href_prev <= 1'b0;
            vsync_prev <= 1'b0;
            capturing <= 1'b0;
            bad_line <= 1'b0;
            byte_count <= 0;
            line_count <= 0;
            write_addr <= 0;
            high_byte <= 0;
            ack <= 1'b0;
        end else begin
            href_prev <= href;
            vsync_prev <= vsync;
            if (new_frame) begin
                byte_count <= 0;
                line_count <= 0;
                write_addr <= 0;
                bad_line <= 1'b0;
                if (capturing && !bad_line && all_lines &&
                    write_addr == FRAME_SAMPLES) begin
                    ack <= request_sync[1];
                    capturing <= 1'b0;
                end else begin
                    // Retry at the next VSYNC if the previous DVP frame was malformed.
                    capturing <= request_sync[1] != ack;
                end
            end else if (capturing) begin
                // HREF delimits valid bytes for either VSYNC blanking polarity.
                if (href) begin
                    if (!byte_count[0]) high_byte <= data;
                    if (byte_count <= LINE_BYTES) byte_count <= byte_count + 1'b1;
                    if (sample_pixel) write_addr <= write_addr + 1'b1;
                end else if (line_end) begin
                    if (byte_count != LINE_BYTES || line_count >= FRAME_LINES)
                        bad_line <= 1'b1;
                    byte_count <= 0;
                    if (line_count <= FRAME_LINES) line_count <= line_count + 1'b1;
                end
            end
        end
    end
endmodule
