// =============================================================================
// FpgaCar_tb.v —— 顶层骨架的最小 testbench
// -----------------------------------------------------------------------------
// 【重要】这个文件只用于仿真，不要通过 Efinity 的
//   Edit Project -> Design -> Import Design & Constraint Files
// 导入工程（否则会被当成设计文件一起综合，tutorial 第 5 页第 16 步明确要求删掉 tb）。
// 跑 RTL 仿真用命令：efx_run.bat --flow rtlsim FpgaCar.xml
// 或用 ModelSim / iVerilog 手动编译 src/FpgaCar.v + 本文件。
//
// 【I2C 双向口怎么仿真】顶层把 SDA 拆成了 _IN/_OUT/_OE 三个端口（Efinix 标准写法），
// 物理 inout 由 Interface Designer 的 mode="inout" GPIO 块生成。testbench 里用
// 一个带 pullup 的 wire + 条件驱动把这个物理块的行为补出来：
//   assign i2c_sda    = i2c_sda_OE ? i2c_sda_OUT : 1'bz;
//   assign i2c_sda_IN = i2c_sda;
// 三态只出现在 tb 里（tb 不参与综合），所以不会触发 EFX-0410。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module FpgaCar_tb;

    reg         clk   = 1'b0;
    reg         key_start_n = 1'b1, key_stop_n = 1'b1;

    reg  [7:0]  track;
    wire        hc_trig;
    reg         hc_echo;
    reg         ir_l, ir_r;         // E18-D80NK：NPN 低有效，空闲=1
    wire        i2c_scl;
    wire        i2c_sda;            // 物理 SDA（外部 4.7k 上拉）
    wire        i2c_sda_IN;
    wire        i2c_sda_OUT;
    wire        i2c_sda_OE;
    reg         cmos_pclk;
    reg         cmos_href;
    reg         cmos_vsync;
    reg  [7:0]  cmos_data;
    wire        cmos_sclk;
    reg         cmos_sdat_IN;
    wire        cmos_sdat_OUT;
    wire        cmos_sdat_OE;
    wire        cmos_ctl1;
    wire        cmos_rst_n;
    wire        cmos_pwdn;
    wire        ml_in1, ml_in2, ml_pwm;
    wire        mr_in1, mr_in2, mr_pwm;
    wire        motor_stby;
    reg         enc_la, enc_lb, enc_ra, enc_rb;
    wire [5:0]  led;                // LED0~LED5（LED6/7 球让给 CMOS_D0/D1）
    reg         uart_rx;
    wire        uart_tx;
    wire        lcd_sclk, lcd_mosi, lcd_dc, lcd_rst_n, lcd_cs_n;
    reg  [2:0]  k230_d;             // K230 并行数据，未接模块时保持 0
    reg         k230_stb;           // K230 选通，空闲为低

    // 24 MHz -> 周期 41.667 ns
    always #20.833 clk = ~clk;

    // 输入空闲值
    initial begin
        track      = 8'hFF;                 // 全白（不压线），ACTIVE_HIGH=0 时 line=0
        hc_echo    = 1'b0;
        cmos_pclk  = 1'b0;
        cmos_href  = 1'b0;
        cmos_vsync = 1'b0;
        cmos_data  = 8'h00;
        enc_la     = 1'b0;  enc_lb = 1'b0;
        enc_ra     = 1'b0;  enc_rb = 1'b0;
        uart_rx    = 1'b1;                  // UART 空闲
        cmos_sdat_IN = 1'b1;                // SCCB 总线释放（外部上拉）
        ir_l       = 1'b1;  ir_r = 1'b1;     // 红外无遮挡
        k230_d     = 3'd0;                   // K230 未发数据
        k230_stb   = 1'b0;                   // 选通空闲
    end

    // ---- 模拟 Interface Designer 的 inout GPIO 块 + 外部上拉 ----
    pullup(i2c_sda);
    assign i2c_sda    = i2c_sda_OE ? i2c_sda_OUT : 1'bz;
    assign i2c_sda_IN = i2c_sda;

    FpgaCar u_dut (
        .clk          (clk),
        .key_start_n  (key_start_n),
        .key_stop_n   (key_stop_n),
        .track        (track),
        .hc_trig      (hc_trig),
        .hc_echo      (hc_echo),
        .ir_l         (ir_l),
        .ir_r         (ir_r),
        .i2c_scl      (i2c_scl),
        .i2c_sda_IN   (i2c_sda_IN),
        .i2c_sda_OUT  (i2c_sda_OUT),
        .i2c_sda_OE   (i2c_sda_OE),
        .cmos_pclk    (cmos_pclk),
        .cmos_href    (cmos_href),
        .cmos_vsync   (cmos_vsync),
        .cmos_data    (cmos_data),
        .cmos_sclk    (cmos_sclk),
        .cmos_sdat_IN (cmos_sdat_IN),
        .cmos_sdat_OUT(cmos_sdat_OUT),
        .cmos_sdat_OE (cmos_sdat_OE),
        .cmos_ctl1    (cmos_ctl1),
        .cmos_rst_n   (cmos_rst_n),
        .cmos_pwdn    (cmos_pwdn),
        .ml_in1       (ml_in1),
        .ml_in2       (ml_in2),
        .ml_pwm       (ml_pwm),
        .mr_in1       (mr_in1),
        .mr_in2       (mr_in2),
        .mr_pwm       (mr_pwm),
        .motor_stby   (motor_stby),
        .enc_la       (enc_la),
        .enc_lb       (enc_lb),
        .enc_ra       (enc_ra),
        .enc_rb       (enc_rb),
        .led          (led),
        .uart_rx      (uart_rx),
        .uart_tx      (uart_tx),
        .k230_d       (k230_d),
        .k230_stb     (k230_stb),
        .lcd_sclk     (lcd_sclk),
        .lcd_mosi     (lcd_mosi),
        .lcd_dc       (lcd_dc),
        .lcd_rst_n    (lcd_rst_n),
        .lcd_cs_n     (lcd_cs_n)
    );

    // ------------------------------------------------------------------
    // 自检：上电安全性 + 循迹通道 + 心跳
    // 上电进入待机，按键逻辑由 car_panel_tb 补充覆盖。
    // ------------------------------------------------------------------
    integer high_cnt, n;

    initial begin
        #2000;
        // 彩屏上电静态约束：面板要压 20 ms 复位再放，复位期间 CS 必须为高。
        // 完整的初始化序列与整帧发送由 sim/st7789_panel_tb.v 用小分频覆盖 ——
        // 那一段在本测试台的 24 MHz 真实时基下要跑 380 ms，会拖垮回归。
        if (u_dut.USE_LCD_PREVIEW) begin
            if (lcd_rst_n !== 1'b0)
                $display("FAIL: LCD reset should still be held 2 us after power-up");
            else if (lcd_cs_n !== 1'b1)
                $display("FAIL: LCD CS should sit high while reset is held");
            else
                $display("PASS: LCD held in reset with CS high right after power-up");
        end else begin
            if (lcd_cs_n !== 1'b1 || lcd_rst_n !== 1'b0 || lcd_sclk !== 1'b0)
                $display("FAIL: LCD pins should be idle when preview disabled");
            else $display("PASS: LCD pins idle (CS high, reset low, SCLK low)");
        end

        if (motor_stby !== 1'b0)  $display("FAIL: IDLE expects motor_stby=0, got %b", motor_stby);
        else                      $display("PASS: IDLE -> TB6612 standby (motors off)");
        if (ml_in1 !== 1'b0 || ml_in2 !== 1'b0) $display("FAIL: left motor driven during IDLE");
        else                                    $display("PASS: IDLE -> left motor undriven");
        if (i2c_sda_OE !== 1'b0)  $display("FAIL: I2C SDA should be released (OE=0)");
        if (i2c_scl !== 1'b1)     $display("FAIL: I2C SCL should idle high");
        if (u_dut.heartbeat === 24'd0) $display("FAIL: heartbeat counter not running");

        // 循迹通道要等消抖稳定（1 kHz x 4 次 = 4 ms）之后再看状态
        // 【LED 新映射】led = ~{heartbeat[23], car_state[2:0], obstacle, line_lost}
        //   led[5]=心跳  led[4:2]=状态机  led[1]=障碍  led[0]=丢线（低电平点亮）
        #6_000_000;
        if (u_dut.line_lost !== 1'b1) $display("FAIL: line_lost should be 1 when all white");
        else                          $display("PASS: line_lost=1 on all-white");
        // 低电平点亮：丢线 -> led[0]=0 点亮；无障碍 -> led[1]=1 熄灭
        if (led[0] !== 1'b0)      $display("FAIL: led[0] should be lit (0) when all-white");
        else                      $display("PASS: led[0] lit on line lost");
        if (led[1] !== 1'b1)      $display("FAIL: led[1] (obstacle) should be off when no obstacle");
        if (led[4:2] !== 3'b111)  $display("FAIL: led[4:2] should show IDLE(000) -> 3b111, got %b", led[4:2]);
        else                      $display("PASS: LEDs show IDLE + no obstacle + line lost");

        // 【摄像头】USE_CAMERA=0 但 USE_LCD_PREVIEW=1 时 SCCB 正在配 OV5640，
        // 此时 sclk/sdat_OE 本来就该动，不能再按"全部静默"断言。
        // 两条分支都要保证：输出是确定电平，不是 X（悬空）。
        if (u_dut.USE_LCD_PREVIEW) begin
            if (cmos_sclk === 1'bx)    $display("FAIL: cmos_sclk floating");
            if (cmos_sdat_OE === 1'bx) $display("FAIL: cmos_sdat_OE floating");
            if (cmos_ctl1 !== 1'b0 || cmos_rst_n !== 1'b0 || cmos_pwdn !== 1'b0)
                $display("FAIL: cmos CTL pins should all be 0");
            else $display("PASS: LCD preview on -> cmos outputs driven, CTL all 0");
        end else begin
            if (cmos_sclk !== 1'b0)   $display("FAIL: cmos_sclk should be 0 when camera disabled");
            if (cmos_sdat_OE !== 1'b0) $display("FAIL: cmos_sdat_OE should be 0 (bus released)");
            if (cmos_ctl1 !== 1'b0 || cmos_rst_n !== 1'b0 || cmos_pwdn !== 1'b0)
                $display("FAIL: cmos CTL pins should all be 0");
            else                      $display("PASS: camera disabled -> all cmos outputs deterministic");
        end
        // 预览模式下不出颜色事件（颜色仍由 K230 提供）
        if (u_dut.cam_color !== 3'd0 || u_dut.cam_color_evt !== 1'b0)
            $display("FAIL: cam_color should be neutral 0 with no event");

        // IDLE 期间 PWM 必须恒低（量一个完整 PWM 周期）
        high_cnt = 0;
        for (n = 0; n < 1200; n = n + 1) begin
            @(posedge clk);
            if (ml_pwm) high_cnt = high_cnt + 1;
        end
        if (high_cnt != 0)
            $display("FAIL: ml_pwm high for %0d/1200 during IDLE (expect 0)", high_cnt);
        else
            $display("PASS: ml_pwm idle low during IDLE (0/1200)");

        // 加速面板节拍，保留真顶层的循迹、状态机与电机门控。
        force u_dut.u_panel.ms_tick = 1'b1;
        @(negedge clk); track = 8'b11100111;
        #6_000_000;
        if (motor_stby === 1'b0) $display("PASS: on-line alone does not start the car");
        else $display("FAIL: on-line alone started the car");

        @(negedge clk); key_start_n = 1'b0;
        repeat (24) @(negedge clk);
        key_start_n = 1'b1;
        #2_000_000;
        if (motor_stby === 1'b1 && u_dut.panel_status == 2'd1)
            $display("PASS: K1 starts the on-line car");
        else $display("FAIL: K1 did not start the on-line car");

        @(negedge clk); force u_dut.k_color = 4'd2;
        @(negedge clk); release u_dut.k_color;
        key_stop_n = 1'b0;
        repeat (4) @(negedge clk);
        if ({motor_stby, ml_pwm, mr_pwm, ml_in1, ml_in2, mr_in1, mr_in2} === 7'd0 &&
            u_dut.panel_status == 2'd2 && u_dut.seq_cnt == 3'd1)
            $display("PASS: K2 immediately disables both motors and preserves color order");
        else $display("FAIL: K2 stop or color order retention failed");

        repeat (1002) @(negedge clk);
        if (motor_stby === 1'b0 && u_dut.panel_status == 2'd0 && u_dut.seq_cnt == 0)
            $display("PASS: K2 hold clears the color order while stopped");
        else $display("FAIL: K2 hold clear failed");
        release u_dut.u_panel.ms_tick;

        // 两类传感器同时触发时，低速版仍关闭避障。PWM 入口统一缩放。
        @(negedge clk);
        force u_dut.hc_near = 1'b1;
        ir_l = 1'b0;
        ir_r = 1'b0;
        force u_dut.shape_duty_l = 11'd500;
        force u_dut.shape_duty_r = 11'd700;
        @(negedge clk);
        if (u_dut.obstacle !== 1'b0 || u_dut.u_pwm_l.duty !== 11'd250 ||
            u_dut.u_pwm_r.duty !== 11'd350)
            $fatal(1, "FAIL: low speed profile obstacle mask or PWM scale");
        $display("PASS: low speed profile masks both sensors and halves PWM commands");
        release u_dut.hc_near;
        release u_dut.shape_duty_l;
        release u_dut.shape_duty_r;

        $display("INFO: FpgaCar smoke test done, heartbeat=%0d", u_dut.heartbeat);
        $finish;
    end

    // 看门狗
    initial begin
        #30_000_000;
        $display("TIMEOUT: FpgaCar_tb hung");
        $finish;
    end

endmodule
