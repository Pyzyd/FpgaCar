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
    reg         rst_n = 1'b0;

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

    // 24 MHz -> 周期 41.667 ns
    always #20.833 clk = ~clk;

    // 上电复位保持 1 us 后释放
    initial begin
        rst_n = 1'b0;
        #1000 rst_n = 1'b1;
    end

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
    end

    // ---- 模拟 Interface Designer 的 inout GPIO 块 + 外部上拉 ----
    pullup(i2c_sda);
    assign i2c_sda    = i2c_sda_OE ? i2c_sda_OUT : 1'bz;
    assign i2c_sda_IN = i2c_sda;

    FpgaCar u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
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
        .uart_tx      (uart_tx)
    );

    // ------------------------------------------------------------------
    // 自检：上电安全性 + 循迹通道 + 心跳
    // 闭环已接入（PWM_BENCH_TEST=0）：上电先 IDLE 2 s，这段时间电机必须完全断电。
    // RUN 之后的行为由 car_fsm_tb / track_pid_tb 覆盖（否则本 tb 要跑 2 秒仿真）。
    // ------------------------------------------------------------------
    integer high_cnt, n;

    initial begin
        #2000;
        if (motor_stby !== 1'b0)  $display("FAIL: IDLE expects motor_stby=0, got %b", motor_stby);
        else                      $display("PASS: IDLE -> TB6612 standby (motors off)");
        if (ml_in1 !== 1'b0 || ml_in2 !== 1'b0) $display("FAIL: left motor driven during IDLE");
        else                                    $display("PASS: IDLE -> left motor undriven");
        if (i2c_sda_OE !== 1'b0)  $display("FAIL: I2C SDA should be released (OE=0)");
        if (i2c_scl !== 1'b1)     $display("FAIL: I2C SCL should idle high");
        if (u_dut.heartbeat === 24'd0) $display("FAIL: heartbeat counter not running");

        // 循迹通道要等消抖稳定（1 kHz x 4 次 = 4 ms）之后再看 LED
        #6_000_000;
        if (led[4:1] !== 4'hF)    $display("FAIL: LEDs[4:1] should be off (no line under sensors)");
        else                      $display("PASS: track channels settled, LEDs[4:1] off");
        if (u_dut.line_lost !== 1'b1) $display("FAIL: line_lost should be 1 when all white");
        else                          $display("PASS: line_lost=1 on all-white");

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
