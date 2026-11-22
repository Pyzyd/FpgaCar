`timescale 1ns/1ns

// Append complete frames, one 1 MiB DDR slot per photo. A failed capture can
// only affect the unpublished slot. Addresses on the DDR AXI port are bytes.
module ov5640_photo_store #(
    parameter integer WIDTH = 1280,
    parameter integer HEIGHT = 720,
    parameter integer FIFO_BITS = 9,
    parameter [6:0] SLOTS = 7'd64
) (
    input wire clk, rst_n,
    input wire shoot, uart_active,
    output reg request,
    input wire capture_done, capture_good,
    output reg busy, error,
    output reg [6:0] photo_count,
    input wire [FIFO_BITS:0] available,
    output wire pop,
    input wire read_request,
    input wire [5:0] read_slot,
    input wire [19:0] read_addr,
    output wire [7:0] read_y,
    output wire read_ready,
    output reg read_error,
    output wire avalid, atype,
    output wire [31:0] aaddr,
    output wire [7:0] alen,
    input wire aready,
    output wire wvalid, wlast,
    input wire wready,
    input wire bvalid,
    input wire [1:0] bresp,
    input wire rvalid, rlast,
    input wire [1:0] rresp,
    input wire [127:0] rdata
);
    localparam integer FRAME_WORDS = WIDTH*HEIGHT/16;
    localparam [2:0] IDLE=0, WRITE_ADDR=1, LOAD_WORD=2, WRITE_WORD=3,
                     WRITE_RESP=4, READ_ADDR=5, READ_WORD=6;
    reg [2:0] state;
    (* async_reg = "true" *) reg [1:0] done_sync, good_sync;
    reg done_settled;
    wire finished = done_settled == request;
    reg write_failed;
    reg [15:0] words_written;
    reg [15:0] start_word;
    reg [4:0] burst_words, words_left;
    reg cache_valid;
    reg [21:0] cache_addr, read_word_addr;
    reg [127:0] cache;

    assign avalid = state == WRITE_ADDR || state == READ_ADDR;
    assign atype = state == WRITE_ADDR;
    assign aaddr = atype ? {6'd0, photo_count[5:0], start_word, 4'b0} :
                           {6'd0, read_word_addr, 4'b0};
    assign alen = atype ? {3'b0, burst_words} - 1'b1 : 8'd0;
    assign pop = state == LOAD_WORD;
    assign wvalid = state == WRITE_WORD;
    assign wlast = words_left == 1;
    assign read_ready = cache_valid && cache_addr == {read_slot, read_addr[19:4]};
    assign read_y = cache[{read_addr[3:0], 3'b000} +: 8];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_sync <= 0;
            good_sync <= 0;
            done_settled <= 0;
        end else begin
            done_sync <= {done_sync[0], capture_done};
            good_sync <= {good_sync[0], capture_good};
            done_settled <= done_sync[1];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            request <= 0;
            busy <= 0;
            photo_count <= 0;
            error <= 0;
            write_failed <= 0;
            words_written <= 0;
            start_word <= 0;
            burst_words <= 0;
            words_left <= 0;
            cache_valid <= 0;
            cache_addr <= 0;
            read_word_addr <= 0;
            read_error <= 0;
            cache <= 0;
        end else begin
            read_error <= 0;
            case (state)
                IDLE: begin
                    if (busy && available >= 16) begin
                        start_word <= words_written;
                        burst_words <= 16;
                        state <= WRITE_ADDR;
                    end else if (busy && finished) begin
                        if (available != 0) begin
                            start_word <= words_written;
                            burst_words <= available[4:0];
                            state <= WRITE_ADDR;
                        end else begin
                            busy <= 0;
                            if (good_sync[1] && !write_failed && words_written == FRAME_WORDS) begin
                                photo_count <= photo_count + 1'b1;
                            end else begin
                                error <= 1;
                            end
                        end
                    end else if (!busy && shoot && !uart_active && photo_count < SLOTS) begin
                        request <= ~request;
                        words_written <= 0;
                        write_failed <= 0;
                        error <= 0;
                        busy <= 1;
                    end else if (!busy && read_request && !read_ready) begin
                        read_word_addr <= {read_slot, read_addr[19:4]};
                        state <= READ_ADDR;
                    end
                end
                WRITE_ADDR: if (aready) begin
                    words_left <= burst_words;
                    state <= LOAD_WORD;
                end
                LOAD_WORD: state <= WRITE_WORD;
                WRITE_WORD: if (wready) begin
                    words_left <= words_left - 1'b1;
                    words_written <= words_written + 1'b1;
                    state <= wlast ? WRITE_RESP : LOAD_WORD;
                end
                WRITE_RESP: if (bvalid) begin
                    if (bresp != 0) write_failed <= 1;
                    state <= IDLE;
                end
                READ_ADDR: if (aready) state <= READ_WORD;
                READ_WORD: if (rvalid && rlast) begin
                    if (rresp == 0) begin
                        cache <= rdata;
                        cache_addr <= read_word_addr;
                        cache_valid <= 1;
                    end else begin
                        error <= 1;
                        read_error <= 1;
                    end
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
