`timescale 1ns/1ns

module ov5640_album_preview_tb;
    reg clk = 0, pclk = 0;
    always #5 clk = ~clk;
    always #3 pclk = ~pclk;
    reg rst_n = 0;
    reg href = 0, vsync = 0;
    reg [7:0] data = 0;
    wire cs, sclk, mosi, dc;

    ov5640_album_preview #(.CLK_HZ(1000), .SPI_HALF_CYCLES(1)) dut (
        .clk(clk), .rst_n(rst_n), .camera_ready(rst_n),
        .pclk(pclk), .href(href), .vsync(vsync), .data(data),
        .lcd_rst_n(), .lcd_cs_n(cs), .lcd_sclk(sclk), .lcd_mosi(mosi), .lcd_dc(dc)
    );

    task frame_edge;
        @(negedge pclk);
        vsync = 1;
        repeat (4) @(negedge pclk);
        vsync = 0;
    endtask

    integer col, row;
    reg [15:0] color;
    initial begin
        #100 rst_n = 1;
        repeat (10) @(negedge pclk);
        frame_edge();
        for (row = 0; row < 720; row = row + 1) begin
            for (col = 0; col < 1280; col = col + 1) begin
                if (row < 360)
                    color = col < 640 ? 16'hf800 : 16'h07e0;
                else
                    color = col < 640 ? 16'h001f : 16'hffff;
                @(negedge pclk); href = 1; data = color[15:8];
                @(negedge pclk); data = color[7:0];
            end
            @(negedge pclk); href = 0;
        end
        frame_edge();
    end

    function [15:0] expected_pixel(input integer y, input integer x);
        reg [7:0] gray;
        begin
            if (y < 30 || y >= 210) gray = 0;
            else if (y < 120) gray = x < 160 ? 8'd79 : 8'd143;
            else gray = x < 160 ? 8'd31 : 8'd255;
            expected_pixel = {gray[7:3], gray[7:2], gray[7:3]};
        end
    endfunction

    integer bits = 0, bytes = 0;
    reg [7:0] received, first_byte;
    reg [15:0] expected;
    always @(posedge sclk) if (!cs) begin
        received = {received[6:0], mosi};
        if (bits == 7) begin
            bits = 0;
            if (dc && dut.panel.show_preview) begin
                if (bytes % 2 == 0) first_byte = received;
                else begin
                    expected = expected_pixel(bytes / 640, (bytes / 2) % 320);
                    if ({first_byte, received} !== expected)
                        $fatal(1, "Preview byte %0d got %h expected %h",
                               bytes, {first_byte, received}, expected);
                end
                bytes = bytes + 1;
            end
        end else bits = bits + 1;
    end

    initial begin
        @(posedge dut.frame_release);
        if (bytes != 320 * 240 * 2)
            $fatal(1, "LCD streamed %0d bytes instead of a full frame", bytes);
        $display("PASS: 720p DVP to ST7789, grayscale, 320x180 letterbox and frame ownership");
        $finish;
    end

    initial #100_000_000 $fatal(1, "Preview did not refresh");
endmodule
