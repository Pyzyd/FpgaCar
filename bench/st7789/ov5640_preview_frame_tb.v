`timescale 1ns/1ns

module ov5640_preview_frame_tb #(
    parameter integer INPUT_WIDTH = 640,
    parameter integer INPUT_HEIGHT = 480,
    parameter integer SAMPLE_LOG2 = 2
);
    localparam integer SAMPLE_STEP = 1 << SAMPLE_LOG2;
    localparam integer SAMPLE_COLS = INPUT_WIDTH / SAMPLE_STEP;
    localparam integer SAMPLES = SAMPLE_COLS * (INPUT_HEIGHT / SAMPLE_STEP);
    localparam integer ADDRESS_WIDTH = $clog2(SAMPLES+1);
    reg clk = 0, pclk = 0;
    always #7 clk = ~clk;
    always #5 pclk = ~pclk;
    reg rst_n = 0, href = 0, vsync = 0, frame_release = 0;
    reg active_low_vsync = 0;
    reg [7:0] data = 0;
    reg [ADDRESS_WIDTH-1:0] addr = 0;
    wire frame_valid;
    wire [7:0] y;

    ov5640_preview_frame #(
        .INPUT_WIDTH(INPUT_WIDTH), .INPUT_HEIGHT(INPUT_HEIGHT), .SAMPLE_LOG2(SAMPLE_LOG2),
        .ADDRESS_WIDTH(ADDRESS_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .pclk(pclk), .href(href), .vsync(vsync),
        .data(data), .frame_release(frame_release), .frame_valid(frame_valid),
        .read_addr(addr), .read_y(y)
    );

    // Frame source has a different color outside the centers of the sample cells.
    function [15:0] rgb565;
        input integer col, row, seed;
        begin
            case ((col + row + seed) % 5)
                0: rgb565 = 16'h0000;
                1: rgb565 = 16'hf800;
                2: rgb565 = 16'h07e0;
                3: rgb565 = 16'h001f;
                4: rgb565 = 16'hffff;
            endcase
        end
    endfunction

    task frame_boundary;
        begin
            @(negedge pclk); vsync = !active_low_vsync;
            repeat (4) @(negedge pclk);
            vsync = active_low_vsync;
        end
    endtask

    task send_frame;
        input integer seed;
        input malformed;
        integer line, col;
        reg [15:0] color;
        begin
            for (line = 0; line < INPUT_HEIGHT; line = line + 1) begin
                for (col = 0; col < INPUT_WIDTH; col = col + 1) begin
                    if (!malformed || line != 0 || col != INPUT_WIDTH - 1) begin
                        color = rgb565(col, line, seed);
                        @(negedge pclk); href = 1; data = color[15:8];
                        @(negedge pclk); data = color[7:0];
                    end
                end
                @(negedge pclk); href = 0;
            end
            frame_boundary;
            repeat (6) @(negedge clk);
        end
    endtask

    task check_frame;
        input integer seed;
        integer index;
        reg [7:0] expected;
        begin
            if (frame_valid !== 1) $fatal(1, "Snapshot was not delivered");
            for (index = 0; index < SAMPLES; index = index + 1) begin
                case ((((index % SAMPLE_COLS) + (index / SAMPLE_COLS) + 1) * SAMPLE_STEP + seed) % 5)
                    0: expected = 0;
                    1: expected = 79;
                    2: expected = 143;
                    3: expected = 31;
                    4: expected = 255;
                endcase
                @(negedge clk); addr = index;
                @(negedge clk);
                if (y !== expected) $fatal(1, "Sample %0d expected %0d got %0d", index, expected, y);
            end
        end
    endtask

    initial begin
        repeat (10) @(negedge clk);
        rst_n = 1;
        repeat (8) @(negedge pclk);
        frame_boundary;
        send_frame(0, 1'b1);
        if (frame_valid !== 0) $fatal(1, "Accepted malformed frame");
        send_frame(1, 1'b0);
        check_frame(1);

        // More input frames must leave the displayed snapshot intact until release.
        send_frame(2, 1'b0);
        check_frame(1);
        @(negedge clk); frame_release = 1;
        @(negedge clk); frame_release = 0;
        if (frame_valid !== 0) $fatal(1, "Release did not invalidate old snapshot");
        active_low_vsync = 1;
        repeat (8) @(negedge pclk);
        frame_boundary;
        send_frame(3, 1'b0);
        check_frame(3);
        $display("PASS: DVP geometry, %0d grayscale samples, snapshot ownership and refresh", SAMPLES);
        $finish;
    end

    initial begin
        #100_000_000;
        $fatal(1, "Camera preview timeout");
    end
endmodule
