`timescale 1ns/1ns

// ST7789 240x320 SPI 屏驱动（面板初始化 + 帧发送 + 9 位 SPI 字节机）。
// 主工程 src/FpgaCar.v 与 bench/st7789 共用这一份，不要各自复制。
//
// 像素来源：调用方用 preview_pixel 同步喂像素，x/y 是当前要发的坐标。
// 每个字节约有一个完整 SPI 字节时间可以响应 x/y，因此 READ 可以打一拍寄存器。
// preview_release 在整帧发完时打一拍，表示缓冲可以交还采集侧。

// The preview source owns a completed frame until preview_release pulses.
// The synchronous pixel source has a full SPI byte time to respond to x/y.
module st7789_panel #(
    parameter integer CLK_HZ = 24_000_000,
    parameter integer SPI_HALF_CYCLES = 16,
    parameter [7:0] MADCTL = 8'h00,
    parameter [7:0] INVERSION_CMD = 8'h21,
    parameter LANDSCAPE = 1'b0
) (
    input wire clk, rst_n,
    input wire preview_valid,
    input wire [15:0] preview_pixel,
    output reg [8:0] x, y,
    output reg preview_used,
    output wire preview_release,
    output reg lcd_rst_n, lcd_cs_n,
    output wire lcd_sclk, lcd_mosi, lcd_dc,
    output wire [5:0] led
);
    localparam integer RESET_CYCLES = (CLK_HZ / 1000) * 20;
    localparam integer WAKE_CYCLES = (CLK_HZ / 1000) * 120;
    localparam integer PAUSE_CYCLES = LANDSCAPE ? CLK_HZ / 10 : CLK_HZ / 2;
    localparam [8:0] LAST_COL = LANDSCAPE ? 9'd319 : 9'd239;
    localparam [8:0] LAST_ROW = LANDSCAPE ? 9'd239 : 9'd319;
    localparam integer STRIPE_1 = LANDSCAPE ? 106 : 80;
    localparam integer STRIPE_2 = LANDSCAPE ? 213 : 160;
    localparam integer RGB_END = LANDSCAPE ? 108 : 144;
    localparam integer GRAY_START = LANDSCAPE ? 174 : 232;
    localparam [3:0] RESET_LCD = 0, AFTER_RESET = 1, INIT_WRITE = 2,
                     END_INIT_WRITE = 3, INIT_DELAY = 4,
                     START_FRAME = 6, PIXELS = 7, END_FRAME = 8, PAUSE = 11;

    reg [2:0] reset_pipe = 3'b000;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) reset_pipe <= 3'b000;
        else reset_pipe <= {reset_pipe[1:0], 1'b1};
    wire ready = reset_pipe[2];

    reg [3:0] state;
    reg [31:0] wait_count;
    reg [23:0] heartbeat;
    reg [4:0] init_index;
    reg low_byte, marker, first_frame_done;
    reg show_preview;
    reg byte_valid;
    reg [8:0] byte_word; // bit 8 is D/C, bits 7:0 are sent MSB first
    wire byte_ready;
    wire send = byte_valid && byte_ready;
    assign preview_release = state == END_FRAME && byte_ready && show_preview;
    wire init_write_done = init_index == 0 || init_index == 1 || init_index == 3 ||
                           init_index == 5 || init_index == 6 || init_index == 11 ||
                           init_index == 16 || init_index == 17 || init_index == 18;
    wire [31:0] init_delay_cycles = init_index < 2 ? WAKE_CYCLES :
                                    init_index == 18 ? RESET_CYCLES : 2;

    reg [15:0] pixel;
    wire [2:0] gray = LANDSCAPE && x[8] ? 3'd7 : x[7:5];
    always @* begin
        if (show_preview)
            pixel = preview_pixel;
        else if (x < 2 || x >= LAST_COL - 1 || y < 2 || y >= LAST_ROW - 1)
            pixel = 16'hffff;
        else if (x >= 8 && x < 24 && y >= 8 && y < 24)
            pixel = marker ? 16'h0000 : 16'hffff;
        else if (y < RGB_END) begin
            if (x < STRIPE_1)       pixel = 16'hf800;
            else if (x < STRIPE_2)  pixel = 16'h07e0;
            else                    pixel = 16'h001f;
        end else if (y < GRAY_START) begin
            if (x < STRIPE_1)       pixel = 16'h0000;
            else if (x < STRIPE_2)  pixel = 16'h8410;
            else                    pixel = 16'hffff;
        end else begin
            pixel = {gray, gray[2:1], gray, gray, gray, gray[2:1]};
        end
    end

    // Controller setup and full portrait or landscape address window.
    // RAMWR data follows its command with CS held low through the entire frame.
    always @* begin
        byte_word = 9'h000;
        byte_valid = 1'b1;
        case (state)
            INIT_WRITE: begin
                case (init_index)
                    0:  byte_word = {1'b0, 8'h01}; // SWRESET
                    1:  byte_word = {1'b0, 8'h11}; // SLPOUT
                    2:  byte_word = {1'b0, 8'h3a}; // COLMOD
                    3:  byte_word = {1'b1, 8'h55}; // RGB565
                    4:  byte_word = {1'b0, 8'h36}; // MADCTL
                    5:  byte_word = {1'b1, MADCTL};
                    6:  byte_word = {1'b0, INVERSION_CMD};
                    7:  byte_word = {1'b0, 8'h2a}; // CASET
                    8, 9: byte_word = {1'b1, 8'h00};
                    10: byte_word = {1'b1, 7'b0, LAST_COL[8]};
                    11: byte_word = {1'b1, LAST_COL[7:0]};
                    12: byte_word = {1'b0, 8'h2b}; // RASET
                    13, 14: byte_word = {1'b1, 8'h00};
                    15: byte_word = {1'b1, 7'b0, LAST_ROW[8]};
                    16: byte_word = {1'b1, LAST_ROW[7:0]};
                    17: byte_word = {1'b0, 8'h13}; // NORON
                    18: byte_word = {1'b0, 8'h29}; // DISPON
                    default: byte_word = 9'h000;
                endcase
            end
            START_FRAME: byte_word = {1'b0, 8'h2c};
            PIXELS:      byte_word = {1'b1, low_byte ? pixel[7:0] : pixel[15:8]};
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
            show_preview <= 1'b0;
            preview_used <= 1'b0;
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
                        state <= INIT_WRITE;
                    end else wait_count <= wait_count + 1'b1;
                end
                INIT_WRITE: if (send) begin
                    if (init_write_done) state <= END_INIT_WRITE;
                    else init_index <= init_index + 1'b1;
                end
                END_INIT_WRITE: if (byte_ready) begin
                    lcd_cs_n <= 1'b1;
                    wait_count <= 0;
                    state <= INIT_DELAY;
                end
                INIT_DELAY: begin
                    if (wait_count == init_delay_cycles - 1) begin
                        lcd_cs_n <= 1'b0;
                        if (init_index == 18) state <= START_FRAME;
                        else begin
                            init_index <= init_index + 1'b1;
                            state <= INIT_WRITE;
                        end
                    end else wait_count <= wait_count + 1'b1;
                end
                START_FRAME: if (send) begin
                    show_preview <= preview_valid;
                    state <= PIXELS;
                end
                PIXELS: if (send) begin
                    low_byte <= ~low_byte;
                    if (low_byte) begin
                        if (x == LAST_COL) begin
                            x <= 0;
                            if (y == LAST_ROW) begin
                                y <= 0;
                                state <= END_FRAME;
                            end else y <= y + 1'b1;
                        end else x <= x + 1'b1;
                    end
                end
                END_FRAME: if (byte_ready) begin
                    lcd_cs_n <= 1'b1;
                    first_frame_done <= 1'b1;
                    preview_used <= preview_used || show_preview;
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
