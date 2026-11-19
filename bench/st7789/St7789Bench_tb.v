`timescale 1ns/1ns

module St7789Bench_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    wire lcd_rst_n, cs, sclk, mosi, dc;
    wire [5:0] led;
    wire [6:0] motors;

    // Shorten the run while retaining the relative delays and verifying each byte.
    St7789Bench #(.CLK_HZ(1000), .SPI_HALF_CYCLES(4)) dut (
        .clk(clk), .rst_n(rst_n), .lcd_rst_n(lcd_rst_n), .lcd_cs_n(cs),
        .lcd_sclk(sclk), .lcd_mosi(mosi), .lcd_dc(dc), .led(led),
        .motor_stby(motors[6]), .ml_pwm(motors[5]), .mr_pwm(motors[4]),
        .ml_in1(motors[3]), .ml_in2(motors[2]), .mr_in1(motors[1]), .mr_in2(motors[0])
    );

    localparam integer BYTES_PER_FRAME = 240 * 320 * 2;
    localparam integer FIRST_PIXEL = 20;
    localparam integer FRAME_END = FIRST_PIXEL + BYTES_PER_FRAME;
    localparam integer SECOND_PIXEL = FRAME_END + 1;
    reg [8:0] init [0:FIRST_PIXEL-1];
    initial begin
        // 0xx = command, 1xx = data.
        init[0]=9'h001;  init[1]=9'h011;  init[2]=9'h03a;  init[3]=9'h155;
        init[4]=9'h036;  init[5]=9'h100;  init[6]=9'h021;  init[7]=9'h02a;
        init[8]=9'h100;  init[9]=9'h100;  init[10]=9'h100; init[11]=9'h1ef;
        init[12]=9'h02b; init[13]=9'h100; init[14]=9'h100; init[15]=9'h101;
        init[16]=9'h13f; init[17]=9'h013; init[18]=9'h029; init[19]=9'h02c;
        #30 rst_n = 1;
        #110_000_000 $fatal(1, "SPI test timeout");
    end

    function [15:0] expected_pixel;
        input integer address;
        input second_frame;
        integer col, row, red_blue, green;
        begin
            col = address % 240;
            row = address / 240;
            if (col <= 1 || col >= 238 || row <= 1 || row >= 318)
                expected_pixel = 16'hffff;
            else if (col >= 8 && col <= 23 && row >= 8 && row <= 23)
                expected_pixel = second_frame ? 16'h0000 : 16'hffff;
            else if (row < 144)
                case (col / 80)
                    0: expected_pixel = 16'hf800;
                    1: expected_pixel = 16'h07e0;
                    2: expected_pixel = 16'h001f;
                endcase
            else if (row < 232)
                case (col / 80)
                    0: expected_pixel = 16'h0000;
                    1: expected_pixel = 16'h8410;
                    2: expected_pixel = 16'hffff;
                endcase
            else begin
                red_blue = (col / 32) * 4 + (col / 64);
                green = (col / 32) * 9;
                expected_pixel = (red_blue << 11) | (green << 5) | red_blue;
            end
        end
    endfunction

    integer bits = 0, bytes = 0;
    reg [7:0] received;
    reg byte_dc;
    time reset_released, cs_released, cs_asserted, previous_sclk_fall;
    integer transaction_count = 0;
    time last_data_change;
    always @(posedge lcd_rst_n) begin
        if ($time < 200) $fatal(1, "LCD reset pulse too short");
        reset_released = $time;
    end
    always @(negedge cs) cs_asserted = $time;
    always @(posedge cs) if (lcd_rst_n) begin
        if (bits != 0 || sclk !== 1'b0) $fatal(1, "CS released mid-byte");
        case (bytes)
            1, 2, 4, 6, 7, 12, 17, 18, 19, FRAME_END: transaction_count = transaction_count + 1;
            default: $fatal(1, "Unexpected CS boundary at byte %0d", bytes);
        endcase
        cs_released = $time;
        if ($time - previous_sclk_fall < 10) $fatal(1, "CS hold too short");
    end
    always @(negedge sclk) previous_sclk_fall = $time;
    always @(mosi or dc) last_data_change = $time;

    integer pixel_byte;
    reg [15:0] pixel;
    reg [8:0] expected;
    always @(posedge sclk) begin
        if (cs !== 0 || lcd_rst_n !== 1 || motors !== 0)
            $fatal(1, "SCLK with invalid CS, reset or motors");
        if ($time - cs_asserted < 40 || $time - last_data_change < 40)
            $fatal(1, "SPI setup too short");
        if (bytes == 0 && $time - reset_released < 1200)
            $fatal(1, "LCD reset recovery too short");
        if ((bytes == 1 || bytes == 2) && (cs_released == 0 || $time - cs_released < 1200))
            $fatal(1, "Software reset or sleep-out delay too short");
        if (bytes == 19 && $time - cs_released < 200)
            $fatal(1, "Display-on delay too short");
        if (bits == 0) byte_dc = dc;
        else if (dc !== byte_dc) $fatal(1, "D/C changed mid-byte");
        received = {received[6:0], mosi};
        bits = bits + 1;
        if (bits == 8) begin
            if (bytes < FIRST_PIXEL) expected = init[bytes];
            else if (bytes == SECOND_PIXEL - 1) expected = 9'h02c;
            else begin
                pixel_byte = bytes - (bytes >= SECOND_PIXEL ? SECOND_PIXEL : FIRST_PIXEL);
                pixel = expected_pixel(pixel_byte / 2, bytes >= SECOND_PIXEL);
                expected = {1'b1, (pixel_byte % 2) ? pixel[7:0] : pixel[15:8]};
            end
            if ({byte_dc, received} !== expected)
                $fatal(1, "Byte %0d: expected %h got %h", bytes, expected, {byte_dc, received});
            if (bytes == SECOND_PIXEL + (240 * 8 + 23) * 2 + 1) begin
                if (led[0] !== 0) $fatal(1, "First-frame LED should be on");
                if (transaction_count != 10) $fatal(1, "Missing CS transitions");
                $display("PASS: init, SPI timing, 76800 first-frame pixels and next-frame marker");
                $finish;
            end
            bytes = bytes + 1;
            bits = 0;
        end
    end
endmodule
