`timescale 1ns/1ns

// S requests a fresh image. Stored-photo mode supports R for the latest photo,
// L for album metadata, and G/T followed by a 1-based photo number.
// Packet: OVS1, width and height (u16 LE), row-major Y8, payload CRC32 (u32 LE).
module ov5640_uart_snapshot #(
    parameter integer WIDTH = 320,
    parameter integer HEIGHT = 240,
    parameter integer ADDRESS_WIDTH = 17,
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer BAUD = 115_200,
    parameter STORED_PHOTO = 1'b0,
    parameter [6:0] ALBUM_SLOTS = 7'd0
) (
    input wire clk, rst_n,
    input wire uart_rx,
    output wire uart_tx,
    input wire frame_valid,
    input wire [6:0] photo_count,
    input wire [2:0] album_flags,
    output reg [5:0] read_slot,
    output wire frame_release,
    output wire [ADDRESS_WIDTH-1:0] read_addr,
    input wire [7:0] read_y,
    output reg sent,
    input wire read_ready, read_error,
    output wire read_request, active
);
    localparam integer BIT_CYCLES = CLK_FREQ / BAUD;
    localparam integer TIMER_WIDTH = $clog2(BIT_CYCLES);
    localparam [1:0] RX_IDLE = 0, RX_START = 1, RX_DATA = 2, RX_STOP = 3;
    reg [1:0] rx_sync, rx_state;
    reg [TIMER_WIDTH-1:0] rx_timer;
    reg [2:0] rx_bit;
    reg [7:0] rx_data;
    reg rx_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync <= 2'b11;
            rx_state <= RX_IDLE;
            rx_timer <= 0;
            rx_bit <= 0;
            rx_data <= 0;
            rx_valid <= 1'b0;
        end else begin
            rx_sync <= {rx_sync[0], uart_rx};
            rx_valid <= 1'b0;
            if (rx_state == RX_IDLE) begin
                if (!rx_sync[1]) begin
                    rx_state <= RX_START;
                    rx_timer <= BIT_CYCLES/2 - 1;
                end
            end else if (rx_timer != 0) begin
                rx_timer <= rx_timer - 1'b1;
            end else begin
                rx_timer <= BIT_CYCLES - 1;
                case (rx_state)
                    RX_START: begin
                        rx_bit <= 0;
                        rx_state <= rx_sync[1] ? RX_IDLE : RX_DATA;
                    end
                    RX_DATA: begin
                        rx_data <= {rx_sync[1], rx_data[7:1]};
                        rx_bit <= rx_bit + 1'b1;
                        if (rx_bit == 7) rx_state <= RX_STOP;
                    end
                    RX_STOP: begin
                        rx_valid <= rx_sync[1];
                        rx_state <= RX_IDLE;
                    end
                    default: rx_state <= RX_IDLE;
                endcase
            end
        end
    end

    function [31:0] crc32_byte;
        input [31:0] value;
        input [7:0] data;
        integer bit_index;
        reg [31:0] next;
        begin
            next = value ^ {24'b0, data};
            for (bit_index=0; bit_index<8; bit_index=bit_index+1)
                next = (next >> 1) ^ (next[0] ? 32'hedb88320 : 32'b0);
            crc32_byte = next;
        end
    endfunction

    localparam [3:0] IDLE = 0, DROP_FRAME = 1, GET_FRAME = 2,
                     SEND = 3, ACCEPT = 4, DRAIN = 5, NO_PHOTO = 6,
                     ABORT = 7, WAIT_PHOTO_ID = 8;
    localparam [ADDRESS_WIDTH-1:0] HEADER_BYTES = 8;
    localparam [15:0] THUMB_WIDTH = WIDTH / 8, THUMB_HEIGHT = HEIGHT / 8;
    localparam [15:0] IMAGE_WIDTH = WIDTH, IMAGE_HEIGHT = HEIGHT;
    localparam integer THUMB_COL_BITS = $clog2(THUMB_WIDTH < 2 ? 2 : THUMB_WIDTH);
    localparam integer ID_TIMEOUT = CLK_FREQ / 4;
    reg [3:0] state;
    reg [ADDRESS_WIDTH:0] byte_index;
    reg [31:0] crc;
    reg [7:0] tx_data;
    reg listing, thumbnail;
    reg [6:0] listed_count;
    reg [2:0] listed_flags;
    reg [$clog2(ID_TIMEOUT)-1:0] id_timer;
    reg [ADDRESS_WIDTH-1:0] thumb_addr;
    reg [THUMB_COL_BITS-1:0] thumb_col;

    wire [ADDRESS_WIDTH:0] payload_end = thumbnail ?
        8 + THUMB_WIDTH*THUMB_HEIGHT : 8 + WIDTH*HEIGHT;
    wire [ADDRESS_WIDTH:0] last_byte = listing ? 6 : payload_end + 3;
    wire [15:0] send_width = thumbnail ? THUMB_WIDTH : IMAGE_WIDTH;
    wire [15:0] send_height = thumbnail ? THUMB_HEIGHT : IMAGE_HEIGHT;
    wire [31:0] final_crc = ~crc;
    wire [1:0] crc_index = byte_index[1:0] - payload_end[1:0];
    wire pixel_byte = !listing && byte_index >= HEADER_BYTES && byte_index < payload_end;
    wire tx_busy;
    wire album_command = ALBUM_SLOTS != 0 && (rx_data == "L" || rx_data == "G" || rx_data == "T");
    wire receive_command = rx_valid && (STORED_PHOTO ? rx_data == "R" || album_command : rx_data == "S");
    assign read_request = STORED_PHOTO && state == SEND && pixel_byte && !tx_busy && !read_error;
    assign active = state != IDLE || receive_command;
    wire tx_start = !tx_busy && (state == NO_PHOTO ||
                    (state == SEND && (!STORED_PHOTO || !pixel_byte || read_ready) &&
                     (!STORED_PHOTO || !read_error)));

    // Release the pre-existing snapshot once. The capture block then locks the
    // next complete frame until another request, including the whole UART transfer.
    assign frame_release = state == DROP_FRAME && frame_valid;
    assign read_addr = !pixel_byte ? 0 :
                       thumbnail ? thumb_addr : byte_index[ADDRESS_WIDTH-1:0] - HEADER_BYTES;

    always @* begin
        if (state == NO_PHOTO) begin
            tx_data = "N";
        end else if (listing) begin
            case (byte_index)
                0: tx_data = "O";
                1: tx_data = "V";
                2: tx_data = "A";
                3: tx_data = "1";
                4: tx_data = {1'b0, listed_count};
                5: tx_data = {1'b0, ALBUM_SLOTS};
                default: tx_data = {5'b0, listed_flags};
            endcase
        end else if (pixel_byte) begin
            tx_data = read_y;
        end else begin
            case (byte_index)
                0: tx_data = "O";
                1: tx_data = "V";
                2: tx_data = "S";
                3: tx_data = "1";
                4: tx_data = send_width[7:0];
                5: tx_data = send_width[15:8];
                6: tx_data = send_height[7:0];
                7: tx_data = send_height[15:8];
                default: tx_data = final_crc[{crc_index, 3'b000} +: 8];
            endcase
        end
    end

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) transmitter (
        .clk(clk), .rst_n(rst_n), .data(tx_data), .start(tx_start),
        .tx(uart_tx), .busy(tx_busy)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            byte_index <= 0;
            crc <= 32'hffffffff;
            sent <= 1'b0;
            listing <= 0;
            thumbnail <= 0;
            listed_count <= 0;
            listed_flags <= 0;
            id_timer <= 0;
            read_slot <= 0;
            thumb_addr <= 0;
            thumb_col <= 0;
        end else begin
            case (state)
                IDLE: if (receive_command) begin
                    sent <= 1'b0;
                    listing <= 0;
                    thumbnail <= 0;
                    if (STORED_PHOTO) begin
                        byte_index <= 0;
                        crc <= 32'hffffffff;
                        if (rx_data == "L") begin
                            listing <= 1;
                            listed_count <= photo_count;
                            listed_flags <= album_flags;
                            state <= SEND;
                        end else if (rx_data == "R") begin
                            read_slot <= photo_count[5:0] - 1'b1;
                            state <= frame_valid ? SEND : NO_PHOTO;
                        end else begin
                            thumbnail <= rx_data == "T";
                            id_timer <= 0;
                            thumb_addr <= 0;
                            thumb_col <= 0;
                            state <= WAIT_PHOTO_ID;
                        end
                    end else begin
                        state <= DROP_FRAME;
                    end
                end
                WAIT_PHOTO_ID: begin
                    if (rx_valid) begin
                        read_slot <= rx_data[5:0] - 1'b1;
                        state <= frame_valid && rx_data != 0 && rx_data <= photo_count ?
                                 SEND : NO_PHOTO;
                    end else if (id_timer == ID_TIMEOUT - 1) begin
                        state <= IDLE;
                    end else begin
                        id_timer <= id_timer + 1'b1;
                    end
                end
                DROP_FRAME: if (frame_valid) state <= GET_FRAME;
                GET_FRAME: if (frame_valid) begin
                    byte_index <= 0;
                    crc <= 32'hffffffff;
                    state <= SEND;
                end
                SEND: begin
                    if (STORED_PHOTO && read_error) begin
                        state <= IDLE;
                    end else if (tx_start) begin
                        if (pixel_byte) crc <= crc32_byte(crc, tx_data);
                        state <= ACCEPT;
                    end
                end
                ACCEPT: if (tx_busy) begin
                    if (thumbnail && pixel_byte) begin
                        if (thumb_col == THUMB_WIDTH - 1) begin
                            thumb_col <= 0;
                            // From the last sampled column to the first in row y+8.
                            thumb_addr <= thumb_addr + 7*WIDTH + 8;
                        end else begin
                            thumb_col <= thumb_col + 1'b1;
                            thumb_addr <= thumb_addr + 8;
                        end
                    end
                    if (byte_index == last_byte) state <= DRAIN;
                    else begin
                        byte_index <= byte_index + 1'b1;
                        state <= SEND;
                    end
                end
                DRAIN: if (!tx_busy) begin
                    sent <= 1'b1;
                    state <= IDLE;
                end
                NO_PHOTO: if (tx_start) state <= ABORT;
                ABORT: if (!tx_busy) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
