`timescale 1ns/1ns

// Cross from the sensor pixel clock to the DDR user clock. Only Gray pointers
// cross clock domains. The payload is read from dual-clock block RAM.
module ov5640_photo_fifo #(
    parameter integer ADDRESS_BITS = 9
) (
    input wire pclk, sensor_rst_n, push,
    input wire [127:0] word,
    output wire full,
    input wire clk, rst_n, pop,
    output reg [127:0] payload,
    output wire [ADDRESS_BITS:0] available
);
    reg [127:0] memory [0:(1<<ADDRESS_BITS)-1];
    reg [ADDRESS_BITS:0] wr_pointer, rd_pointer, wr_gray, rd_gray;
    (* async_reg = "true" *) reg [ADDRESS_BITS:0] wr_sync1, wr_sync2, rd_sync1, rd_sync2;
    wire [ADDRESS_BITS:0] wr_next = wr_pointer + 1'b1;
    wire [ADDRESS_BITS:0] rd_next = rd_pointer + 1'b1;
    assign full = wr_gray == (rd_sync2 ^ {2'b11, {ADDRESS_BITS-1{1'b0}}});

    function [ADDRESS_BITS:0] gray_to_binary;
        input [ADDRESS_BITS:0] gray;
        integer i;
        begin
            gray_to_binary[ADDRESS_BITS] = gray[ADDRESS_BITS];
            for (i = ADDRESS_BITS-1; i >= 0; i = i-1)
                gray_to_binary[i] = gray_to_binary[i+1] ^ gray[i];
        end
    endfunction
    reg [ADDRESS_BITS:0] wr_seen;
    assign available = wr_seen - rd_pointer;

    always @(posedge pclk)
        if (push && !full) memory[wr_pointer[ADDRESS_BITS-1:0]] <= word;
    always @(posedge clk)
        if (pop) payload <= memory[rd_pointer[ADDRESS_BITS-1:0]];

    always @(posedge pclk or negedge sensor_rst_n) begin
        if (!sensor_rst_n) begin
            wr_pointer <= 0;
            wr_gray <= 0;
            rd_sync1 <= 0;
            rd_sync2 <= 0;
        end else begin
            rd_sync1 <= rd_gray;
            rd_sync2 <= rd_sync1;
            if (push && !full) begin
                wr_pointer <= wr_next;
                wr_gray <= wr_next ^ (wr_next >> 1);
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_pointer <= 0;
            rd_gray <= 0;
            wr_sync1 <= 0;
            wr_sync2 <= 0;
            wr_seen <= 0;
        end else begin
            wr_sync1 <= wr_gray;
            wr_sync2 <= wr_sync1;
            wr_seen <= gray_to_binary(wr_sync2);
            if (pop) begin
                rd_pointer <= rd_next;
                rd_gray <= rd_next ^ (rd_next >> 1);
            end
        end
    end
endmodule
