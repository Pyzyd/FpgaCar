`timescale 1ns/1ns

// Receive an ASCII S (115200 8N1) and transmit a fresh, complete Y8 image.
// Packet: OVS1, width and height (u16 LE), row-major Y8, payload CRC32 (u32 LE).
module ov5640_uart_snapshot #(
    parameter integer WIDTH = 320,
    parameter integer HEIGHT = 240,
    parameter integer ADDRESS_WIDTH = 17,
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer BAUD = 115_200
) (
    input wire clk, rst_n,
    input wire uart_rx,
    output wire uart_tx,
    input wire frame_valid,
    output wire frame_release,
    output wire [ADDRESS_WIDTH-1:0] read_addr,
    input wire [7:0] read_y,
    output reg sent
);
    localparam integer BIT_CYCLES = CLK_FREQ / BAUD;
    localparam integer TIMER_WIDTH = $clog2(BIT_CYCLES);
    localparam [1:0] RX_IDLE = 0, RX_START = 1, RX_DATA = 2, RX_STOP = 3;
    reg [1:0] rx_sync, rx_state;
    reg [TIMER_WIDTH-1:0] rx_timer;
    reg [2:0] rx_bit;
    reg [7:0] rx_data;
    reg snap_request;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync <= 2'b11;
            rx_state <= RX_IDLE;
            rx_timer <= 0;
            rx_bit <= 0;
            rx_data <= 0;
            snap_request <= 1'b0;
        end else begin
            rx_sync <= {rx_sync[0], uart_rx};
            snap_request <= 1'b0;
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
                        snap_request <= rx_sync[1] && rx_data == 8'h53;
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

    localparam [2:0] IDLE = 0, DROP_FRAME = 1, GET_FRAME = 2,
                     SEND = 3, ACCEPT = 4, DRAIN = 5;
    localparam integer HEADER_BYTES = 8;
    localparam integer PAYLOAD_END = HEADER_BYTES + WIDTH*HEIGHT;
    localparam integer LAST_BYTE = PAYLOAD_END + 3;
    reg [2:0] state;
    reg [ADDRESS_WIDTH:0] byte_index;
    reg [31:0] crc;
    reg [7:0] tx_data;
    wire [31:0] final_crc = ~crc;
    wire pixel_byte = byte_index >= HEADER_BYTES && byte_index < PAYLOAD_END;
    wire tx_busy;
    wire tx_start = state == SEND && !tx_busy;

    // Release the pre-existing snapshot once. The capture block then locks the
    // next complete frame until another request, including the whole UART transfer.
    assign frame_release = state == DROP_FRAME && frame_valid;
    assign read_addr = pixel_byte ? byte_index[ADDRESS_WIDTH-1:0] - HEADER_BYTES : 0;

    always @* begin
        if (pixel_byte) begin
            tx_data = read_y;
        end else begin
            case (byte_index)
                0: tx_data = "O";
                1: tx_data = "V";
                2: tx_data = "S";
                3: tx_data = "1";
                4: tx_data = WIDTH[7:0];
                5: tx_data = WIDTH[15:8];
                6: tx_data = HEIGHT[7:0];
                7: tx_data = HEIGHT[15:8];
                PAYLOAD_END:   tx_data = final_crc[7:0];
                PAYLOAD_END+1: tx_data = final_crc[15:8];
                PAYLOAD_END+2: tx_data = final_crc[23:16];
                default:       tx_data = final_crc[31:24];
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
        end else begin
            case (state)
                IDLE: if (snap_request) begin
                    sent <= 1'b0;
                    state <= DROP_FRAME;
                end
                DROP_FRAME: if (frame_valid) state <= GET_FRAME;
                GET_FRAME: if (frame_valid) begin
                    byte_index <= 0;
                    crc <= 32'hffffffff;
                    state <= SEND;
                end
                SEND: if (tx_start) begin
                    if (pixel_byte) crc <= crc32_byte(crc, tx_data);
                    state <= ACCEPT;
                end
                ACCEPT: if (tx_busy) begin
                    if (byte_index == LAST_BYTE) state <= DRAIN;
                    else begin
                        byte_index <= byte_index + 1'b1;
                        state <= SEND;
                    end
                end
                DRAIN: if (!tx_busy) begin
                    sent <= 1'b1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
