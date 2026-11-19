`timescale 1ns/1ns

// Standalone 240x320 LCD checkout. All motor inputs are held low.
module St7789Bench #(
    parameter integer CLK_HZ = 24_000_000,
    parameter integer SPI_HALF_CYCLES = 4,
    parameter [7:0] MADCTL = 8'h00,
    parameter [7:0] INVERSION_CMD = 8'h21
) (
    input wire clk, rst_n,
    output reg lcd_rst_n, lcd_cs_n,
    output wire lcd_sclk, lcd_mosi, lcd_dc,
    output wire [5:0] led,
    output wire motor_stby, ml_pwm, mr_pwm,
    output wire ml_in1, ml_in2, mr_in1, mr_in2
);
    localparam integer RESET_CYCLES = (CLK_HZ / 1000) * 20;
    localparam integer WAKE_CYCLES = (CLK_HZ / 1000) * 120;
    localparam integer PAUSE_CYCLES = CLK_HZ / 2;
    localparam [3:0] RESET_LCD = 0, AFTER_RESET = 1, SLEEP_OUT = 2,
                     WAIT_SLEEP_BYTE = 3, WAKE_DELAY = 4, INIT_LCD = 5,
                     START_FRAME = 6, PIXELS = 7, END_FRAME = 8,
                     DISPLAY_ON = 9, END_DISPLAY_ON = 10, PAUSE = 11;

    reg [2:0] reset_pipe = 3'b000;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) reset_pipe <= 3'b000;
        else reset_pipe <= {reset_pipe[1:0], 1'b1};
    wire ready = reset_pipe[2];

    reg [3:0] state;
    reg [31:0] wait_count;
    reg [23:0] heartbeat;
    reg [3:0] init_index;
    reg [7:0] x;
    reg [8:0] y;
    reg low_byte, marker, first_frame_done;
    reg byte_valid;
    reg [8:0] byte_word; // bit 8 is D/C, bits 7:0 are sent MSB first
    wire byte_ready;
    wire send = byte_valid && byte_ready;

    reg [15:0] pixel;
    wire [2:0] gray = x[7:5];
    always @* begin
        if (x < 2 || x >= 238 || y < 2 || y >= 318)
            pixel = 16'hffff;
        else if (x >= 8 && x < 24 && y >= 8 && y < 24)
            pixel = marker ? 16'h0000 : 16'hffff;
        else if (y < 144) begin
            if (x < 80)       pixel = 16'hf800;
            else if (x < 160) pixel = 16'h07e0;
            else              pixel = 16'h001f;
        end else if (y < 232) begin
            if (x < 80)       pixel = 16'h0000;
            else if (x < 160) pixel = 16'h8410;
            else              pixel = 16'hffff;
        end else begin
            pixel = {gray, gray[2:1], gray, gray, gray, gray[2:1]};
        end
    end

    // Controller setup and full 0..239 x 0..319 address window.
    // RAMWR data follows its command with CS held low through the entire frame.
    always @* begin
        byte_word = 9'h000;
        byte_valid = 1'b1;
        case (state)
            SLEEP_OUT:   byte_word = {1'b0, 8'h11};
            INIT_LCD: begin
                case (init_index)
                    0:  byte_word = {1'b0, 8'h36}; // MADCTL
                    1:  byte_word = {1'b1, MADCTL};
                    2:  byte_word = {1'b0, 8'h3a}; // COLMOD
                    3:  byte_word = {1'b1, 8'h55}; // RGB565
                    4:  byte_word = {1'b0, INVERSION_CMD};
                    5:  byte_word = {1'b0, 8'h13}; // NORON
                    6:  byte_word = {1'b0, 8'h2a}; // CASET
                    7, 8, 9: byte_word = {1'b1, 8'h00};
                    10: byte_word = {1'b1, 8'hef}; // last column 239
                    11: byte_word = {1'b0, 8'h2b}; // RASET
                    12, 13: byte_word = {1'b1, 8'h00};
                    14: byte_word = {1'b1, 8'h01};
                    15: byte_word = {1'b1, 8'h3f}; // last row 319
                    default: byte_word = 9'h000;
                endcase
            end
            START_FRAME: byte_word = {1'b0, 8'h2c};
            PIXELS:      byte_word = {1'b1, low_byte ? pixel[7:0] : pixel[15:8]};
            DISPLAY_ON:  byte_word = {1'b0, 8'h29};
            default:     byte_valid = 1'b0;
        endcase
    end

    st7789_spi_byte #(.HALF_CYCLES(SPI_HALF_CYCLES)) spi (
        .clk(clk), .rst_n(ready), .valid(byte_valid), .word(byte_word),
        .ready(byte_ready), .sclk(lcd_sclk), .mosi(lcd_mosi), .dc(lcd_dc)
    );

    always @(posedge clk or negedge ready) begin
        if (!ready) begin
            state <= RESET_LCD;
            lcd_rst_n <= 1'b0;
            lcd_cs_n <= 1'b1;
            wait_count <= 0;
            heartbeat <= 0;
            init_index <= 0;
            x <= 0;
            y <= 0;
            low_byte <= 1'b0;
            marker <= 1'b0;
            first_frame_done <= 1'b0;
        end else begin
            heartbeat <= heartbeat + 1'b1;
            case (state)
                RESET_LCD: begin
                    if (wait_count == RESET_CYCLES - 1) begin
                        lcd_rst_n <= 1'b1;
                        wait_count <= 0;
                        state <= AFTER_RESET;
                    end else wait_count <= wait_count + 1'b1;
                end
                AFTER_RESET: begin
                    if (wait_count == WAKE_CYCLES - 1) begin
                        lcd_cs_n <= 1'b0;
                        state <= SLEEP_OUT;
                    end else wait_count <= wait_count + 1'b1;
                end
                SLEEP_OUT: if (send) state <= WAIT_SLEEP_BYTE;
                WAIT_SLEEP_BYTE: if (byte_ready) begin
                    lcd_cs_n <= 1'b1;
                    wait_count <= 0;
                    state <= WAKE_DELAY;
                end
                WAKE_DELAY: begin
                    if (wait_count == WAKE_CYCLES - 1) begin
                        lcd_cs_n <= 1'b0;
                        state <= INIT_LCD;
                    end else wait_count <= wait_count + 1'b1;
                end
                INIT_LCD: if (send) begin
                    if (init_index == 15) state <= START_FRAME;
                    else init_index <= init_index + 1'b1;
                end
                START_FRAME: if (send) state <= PIXELS;
                PIXELS: if (send) begin
                    low_byte <= ~low_byte;
                    if (low_byte) begin
                        if (x == 239) begin
                            x <= 0;
                            if (y == 319) begin
                                y <= 0;
                                state <= END_FRAME;
                            end else y <= y + 1'b1;
                        end else x <= x + 1'b1;
                    end
                end
                END_FRAME: if (byte_ready) begin
                    if (!first_frame_done) state <= DISPLAY_ON;
                    else begin
                        lcd_cs_n <= 1'b1;
                        wait_count <= 0;
                        state <= PAUSE;
                    end
                end
                DISPLAY_ON: if (send) state <= END_DISPLAY_ON;
                END_DISPLAY_ON: if (byte_ready) begin
                    lcd_cs_n <= 1'b1;
                    first_frame_done <= 1'b1;
                    wait_count <= 0;
                    state <= PAUSE;
                end
                PAUSE: begin
                    if (wait_count == PAUSE_CYCLES - 1) begin
                        lcd_cs_n <= 1'b0;
                        marker <= ~marker;
                        state <= START_FRAME;
                    end else wait_count <= wait_count + 1'b1;
                end
                default: state <= RESET_LCD;
            endcase
        end
    end

    // LED0 shows completion of the first transmission. LED5 is the board heartbeat.
    assign led = ~{heartbeat[23], 4'b0000, first_frame_done};
    assign {motor_stby, ml_pwm, mr_pwm, ml_in1, ml_in2, mr_in1, mr_in2} = 7'd0;
endmodule

// SPI mode 0. Change data only with clock low or on a falling edge.
// The caller controls CS independently to group bytes into one transaction.
module st7789_spi_byte #(
    parameter integer HALF_CYCLES = 4
) (
    input wire clk, rst_n, valid,
    input wire [8:0] word,
    output wire ready,
    output reg sclk, mosi, dc
);
    localparam integer COUNT_WIDTH = HALF_CYCLES > 1 ? $clog2(HALF_CYCLES) : 1;
    reg busy;
    reg [COUNT_WIDTH-1:0] divider;
    reg [2:0] bit_index;
    reg [7:0] shifter;
    assign ready = ~busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            divider <= 0;
            bit_index <= 0;
            shifter <= 0;
            sclk <= 1'b0;
            mosi <= 1'b0;
            dc <= 1'b0;
        end else if (!busy) begin
            if (valid) begin
                busy <= 1'b1;
                bit_index <= 3'd7;
                shifter <= word[7:0];
                dc <= word[8];
                mosi <= word[7];
            end
        end else if (divider == HALF_CYCLES - 1) begin
            divider <= 0;
            sclk <= ~sclk;
            if (sclk) begin
                if (bit_index == 0) busy <= 1'b0;
                else begin
                    bit_index <= bit_index - 1'b1;
                    shifter <= {shifter[6:0], 1'b0};
                    mosi <= shifter[6];
                end
            end
        end else divider <= divider + 1'b1;
    end
endmodule
