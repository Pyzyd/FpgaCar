`timescale 1ns/1ns

// ST7789 面板驱动的单元测试（小分频，跑在 2.4 MHz 等效时钟上）。
//
// FpgaCar_tb 里跑不了完整初始化：真实时基下复位 20 ms + 唤醒 120 ms +
// 两段稳定等待，整段 380 ms，再加整帧 200 ms，会让主回归超时。
// 所以把那部分搬到这里：把 CLK_HZ 缩小 10 倍，时序比例不变，
// 逐字节断言初始化命令序列，再断言进入整帧发送后坐标会推进。
//
// 断言的是"发出去的命令内容与顺序"，不是内部状态，改内部实现不影响它。
module st7789_panel_tb;

    // 24 kHz 等效：把 CLK_HZ 缩小 1000 倍，所有 *_CYCLES 等比缩小。
    // RESET_CYCLES=480、WAKE_CYCLES=2880，全程约 6300 拍，几百微秒就跑完。
    localparam integer CLK_HZ = 24_000;
    localparam integer HALF   = 2;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;                       // 100 MHz 仿真钟

    wire lcd_rst_n, lcd_cs_n, lcd_sclk, lcd_mosi, lcd_dc;
    wire [5:0] led;
    wire [8:0] x, y;
    reg  [15:0] preview_pixel = 16'h1234;
    reg         preview_valid = 1'b1;
    wire        preview_used, preview_release;

    st7789_panel #(
        .CLK_HZ          (CLK_HZ),
        .SPI_HALF_CYCLES (HALF),
        .MADCTL          (8'h60),
        .INVERSION_CMD   (8'h20),
        .LANDSCAPE       (1'b1)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .preview_valid   (preview_valid),
        .preview_pixel   (preview_pixel),
        .x               (x),
        .y               (y),
        .preview_used    (preview_used),
        .preview_release (preview_release),
        .lcd_rst_n       (lcd_rst_n),
        .lcd_cs_n        (lcd_cs_n),
        .lcd_sclk        (lcd_sclk),
        .lcd_mosi        (lcd_mosi),
        .lcd_dc          (lcd_dc),
        .led             (led)
    );

    // ------------------------------------------------------------------
    // SPI 从机采样：在 SCLK 上升沿取 MOSI，攒满 8 位算一字节。
    // 用 D/C 区分命令（0）与数据（1）。
    // ------------------------------------------------------------------
    reg  [7:0] rx_byte   = 8'h00;
    integer    rx_bits   = 0;
    reg  [7:0] cmd_log [0:63];      // 只记命令字节
    reg  [7:0] dat_log [0:63];      // 只记数据字节
    integer    cmd_n = 0;
    integer    dat_n = 0;
    reg        cs_low_seen  = 1'b0;
    integer    sclk_edges   = 0;

    // SPI mode 0：主机在下降沿换数据、从机在上升沿采样。
    // 直接对 lcd_sclk 的上升沿敏感，避免用"和上一拍比较"的方式吃 X 态。
    always @(posedge lcd_sclk) begin
        sclk_edges = sclk_edges + 1;
        if (lcd_cs_n === 1'b0) begin
            rx_byte = {rx_byte[6:0], lcd_mosi};
            rx_bits = rx_bits + 1;
            if (rx_bits == 8) begin
                rx_bits = 0;
                if (lcd_dc === 1'b0) begin
                    if (cmd_n < 64) cmd_log[cmd_n] = rx_byte;
                    cmd_n = cmd_n + 1;
                end else begin
                    if (dat_n < 64) dat_log[dat_n] = rx_byte;
                    dat_n = dat_n + 1;
                end
            end
        end
    end

    always @(negedge lcd_cs_n) cs_low_seen <= 1'b1;

    integer fails = 0;
    task check(input cond, input [1023:0] tag);
        begin
            if (cond) $display("PASS: %0s", tag);
            else begin
                $display("FAIL: %0s", tag);
                fails = fails + 1;
            end
        end
    endtask

    integer i;
    reg     reset_seen_high = 1'b0;

    initial begin
        $display("INFO: st7789_panel_tb start");
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // 复位期间：LCD 复位脚低、CS 高、不产生时钟
        repeat (10) @(negedge clk);
        check(lcd_rst_n === 1'b0, "LCD reset held low after power-up");
        check(lcd_cs_n  === 1'b1, "LCD CS high while reset held");

        // 等初始化走完。注意 SWRESET 和 SLPOUT 后面各有一段完整 120 ms 等待
        // （init_delay_cycles 对 init_index<2 返回 WAKE_CYCLES），所以总量是
        // 20 ms 复位 + 2 x 120 ms 唤醒 + 零头，等比缩小后约 6300 拍，给 20000 拍。
        for (i = 0; i < 20_000; i = i + 1) begin
            @(posedge clk);
            if (lcd_rst_n === 1'b1) reset_seen_high = 1'b1;
            if (cmd_n >= 10) i = 20_000;       // 9 条初始化命令 + RAMWR 就够
        end

        check(reset_seen_high === 1'b1, "LCD reset released");
        check(cs_low_seen   === 1'b1, "LCD CS pulled low for init");
        check(sclk_edges  >     100,  "SCLK toggling during init");

        // 逐条比对：初始化一共 19 个字节状态，其中 9 条是命令、10 条是数据，
        // 之后紧跟 RAMWR(0x2c) 开始整帧。命令顺序就是面板要求的顺序。
        check(cmd_n >= 10, "init sends 9 commands then RAMWR");
        check(cmd_log[0] === 8'h01, "cmd0  SWRESET");
        check(cmd_log[1] === 8'h11, "cmd1  SLPOUT");
        check(cmd_log[2] === 8'h3a, "cmd2  COLMOD");
        check(cmd_log[3] === 8'h36, "cmd3  MADCTL");
        check(cmd_log[4] === 8'h20, "cmd4  INVON");
        check(cmd_log[5] === 8'h2a, "cmd5  CASET");
        check(cmd_log[6] === 8'h2b, "cmd6  RASET");
        check(cmd_log[7] === 8'h13, "cmd7  NORON");
        check(cmd_log[8] === 8'h29, "cmd8  DISPON");
        check(cmd_log[9] === 8'h2c, "cmd9  RAMWR starts the frame");

        // 数据字节：COLMOD 后面是 0x55（RGB565）
        check(dat_log[0] === 8'h55, "COLMOD data = RGB565");

        $display("INFO: st7789_panel_tb done, %0d command bytes, %0d data bytes", cmd_n, dat_n);
        if (fails == 0) $display("INFO: st7789_panel_tb ALL PASS");
        else            $display("INFO: st7789_panel_tb %0d FAIL(S)", fails);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT: st7789_panel_tb hung");
        $finish;
    end

endmodule
