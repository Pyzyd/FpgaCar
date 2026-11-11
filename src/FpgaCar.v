// =============================================================================
// FpgaCar.v —— 第十四届"星火杯"赛题二 智能小车 / Ti60F225 顶层【骨架】
// -----------------------------------------------------------------------------
// 这不是演示程序，是正式工程的顶层：先把整车 I/O 与模块划分定下来，
// 再逐个往 src/ 里填子模块（顺序见 ../PROJECT_PLAN.md）。
//
// 器件  : Efinix Titanium Ti60F225 (C4)，Efinity 2026.1
// 时钟  : 24 MHz 有源晶振 -> GPIOL_11（3.3 V LVCMOS input）
//
// 【为什么不用 PLL】骨架阶段不例化 Interface Designer 的 PLL 块，方便第一次编译；
//   后续做图像流水线 / Sapphire 软核需要高频时钟时，再去 Interface Designer 里
//   加 PLL 块，并把下面的 clk / rst_n 换成该块的输出端口名。参考写法见资料包
//   06-FPGA_HDL_Basic-2023.2/01_LED_8bit_Test/src/LED_8bit_Test.v：
//   顶层端口为 pll_inst1_CLKOUT0 / pll_inst1_LOCKED（名字必须与 PLL 块输出名一致）。
//
// 【管脚怎么分配】Titanium 的管脚不在 HDL 里写 LOC，全部在 Interface Designer 里分配：
//   - 可分配资源查 04_原理图&PIN TCL/Ti60_Board_引脚定义-20230703-V1.0.xlsx 的 "DC3-40" 页
//   - 避开 User_IO0 / User_IO1（与核心板复用、默认上拉）
//   - OV5640 走板上独立 DVP 排针，不占 DC3-40 的 36 个 User_IO
//   - 板上 8 个 LED / CH340N 串口是固定引脚，也不占 DC3-40
//   - 本顶层需占用 DC3-40 约 26 根 User_IO（36 根够用）
//   - LED 只用 LED0~LED5：LED6/LED7 的球（GPIOL_01/02）与 CMOS_D0/D1 复用，
//     官方 OV5640 工程同样只接 6 个 LED（led_o[5:0]）
//
// 【I2C 双向口为什么是三根线】Efinity/Titanium 不允许顶层 inout 被 1'bz 驱动
//   （综合报错 "Signal driving output port 'xxx' is tristated" [EFX-0410]）。
//   正确做法是：HDL 里把双向 SDA 拆成 _IN / _OUT / _OE 三个独立端口，
//   由 Interface Designer 里一个 mode="inout" 的 GPIO 块（块名 i2c_sda）在物理
//   管脚上合成三态缓冲；SCL 由主机单向驱动，建 mode="output" 块即可。
//   资料包 06-FPGA_HDL_Basic-2023.2/02-1_Ti60_OV5640_LCD-HDMI_1080P60 的
//   src/cmos_i2c/i2c_timing_ctrl_16bit.v (第 44-47、368-370 行) 与
//   Ti60_Demo.peri.xml (第 205-211 行) 就是这么写的。
//   注意：DC3-40 引出的 SCL/SDA 需要外部 4.7 kΩ 上拉到 3.3 V。
//
// 【IO 电平】BL / BR / TL / TR bank = 3.3 V，其余 1.8 V（1A = 1.2 V）。
//   HC-SR04 的 Echo 输出是 5 V，必须分压到 3.3 V 才能进 FPGA（两个电阻即可）。
//
// 【首次下载预期状态】电机不转、I2C 总线释放、LED[5] 约 0.7 s 慢闪、
//   LED[4:0] 显示循迹探头电平 —— 这是刻意的安全默认值：既有可见的
//   "位流已加载 / 时钟在跑"确认，又不会让小车乱跑。先用它验证
//   "导入源码 -> 综合 -> 布局布线 -> 生成位流 -> 下载"整条链路通，
//   再开始填下面的 TODO 子模块。
// =============================================================================
`timescale 1ns/1ns

module FpgaCar (

    // ---------------- 时钟 / 复位 ----------------
    input  wire         clk,            // 24 MHz, GPIOL_11
    input  wire         rst_n,          // 低有效复位（板上按键 / 上电复位）

    // ---------------- 循迹 20 分：YB-MUX04 八路循迹 ----------------
    // 板载 MCU，支持 Direct IO 数字量 / I2C / 串口三种输出；
    // 此处按 Direct IO 模式接 8 根数字量，也可改成复用 i2c_scl/i2c_sda
    input  wire [7:0]   track,

    // ---------------- 避障 20 分：HC-SR04 ----------------
    output wire         hc_trig,        // 10 us 触发脉冲
    input  wire         hc_echo,        // 回波（5 V ！！必须两个电阻分压到 3.3 V 再进排针）
                                        // 注：DC3-40 的 TXS0108E 的 B 侧绝对最大只有 4.6 V，
                                        // 5 V 直连属于超规格，别信"电平转换芯片能承受"的说法

    // ---------------- 避障 20 分：E18-D80NK 红外光电开关 ×2（冗余）----------------
    // NPN 常开输出，检测到障碍时拉低（=0）；需外部 4.7k 上拉到 3.3 V。
    // 与 HC-SR04 做"或"融合：任一认为有障碍就减速/绕行，降低"触碰扣 10 分"的风险。
    input  wire         ir_l,           // 左前端，User_IO26
    input  wire         ir_r,           // 右前端，User_IO27

    // ---------------- 公共 I2C 总线 ----------------
    // OV5640 SCCB(配置) / VL53L1X(冗余测距) / YB-MUX04(I2C模式) / OLED 共用；
    // I2C 主机在 FPGA 片内用 RTL 实现，见 PROJECT_PLAN.md。
    // 双向 SDA 用 Efinix 标准的 _IN/_OUT/_OE 三端口（见文件头说明），
    // 物理 inout 由 Interface Designer 的 mode="inout" GPIO 块 i2c_sda 生成。
    output wire         i2c_scl,        // 主机输出时钟（mode="output" 块）
    input  wire         i2c_sda_IN,     // 物理 SDA 引脚回读
    output wire         i2c_sda_OUT,    // 送向物理 SDA 引脚的数据
    output wire         i2c_sda_OE,     // 1=驱动总线(输出0)，0=释放(高阻靠上拉)

    // ---------------- 标识 25 + 颜色 20 分：OV5640 DVP ----------------
    // 板上独立 DVP 排针：CMOS_D0~D7 / PCLK_3V3 / HREF / VSYNC / XCLK / CTL0~3
    input  wire         cmos_pclk,
    input  wire         cmos_href,
    input  wire         cmos_vsync,
    input  wire [7:0]   cmos_data,
    // SCCB（配置 OV5640 用）：SCLK 单向输出；SDAT 物理是 inout，按 Efinix 规矩拆三根
    output wire         cmos_sclk,      // GPIOL_09，mode=output
    input  wire         cmos_sdat_IN,   // GPIOR_13 回读
    output wire         cmos_sdat_OUT,  // 送向 GPIOR_13
    output wire         cmos_sdat_OE,   // 1=驱动，0=释放靠外部上拉
    // 【为什么这里没有 cmos_xclk 端口】Efinix 的时钟输出不走 RTL：
    //   时钟树直接连到 interface block，clkout 型 GPIO 由 Interface Designer
    //   按 clock_name 取时钟网输出，RTL 里既没有这个端口也不能 assign。
    //   本工程在 FpgaCar.peri.xml 里建了 comp_gpio name="cmos_xclk"
    //   gpio_def="GPIOR_16" mode="clkout"，clock_name 指向系统 24 MHz 时钟。
    //   对照：官方 02-1_Ti60_OV5640 的 example_top.v 同样没有 cmos_xclk 端口。
    // 三根 CTL：**必须全部驱动 0**（照抄官方 example_top.v:378-383 的实测值）。
    // 名字沿用硬件接口表的 cmos_rst_n / cmos_pwdn，但电气上它们不是"高有效复位"：
    // 实测把 CTL2 给 1 会让传感器完全不出图（串口 V=00）。
    output wire         cmos_ctl1,      // GPIOR_15
    output wire         cmos_rst_n,     // CMOS_CTL2（GPIOL_04）
    output wire         cmos_pwdn,      // CMOS_CTL3（GPIOL_N_00）

    // ---------------- 运动执行：TB6612FNG（双路 H 桥）----------------
    // 一块 TB6612 带左右两个直流减速电机：IN1/IN2 定方向，PWM 定转速
    output wire         ml_in1,
    output wire         ml_in2,
    output wire         ml_pwm,
    output wire         mr_in1,
    output wire         mr_in2,
    output wire         mr_pwm,
    output wire         motor_stby,     // 1=工作, 0=待机(电机禁止)

    // ---------------- 里程反馈：光电编码器 x2（AB 相）----------------
    // 必须光电式：细则 3.2.2 禁止非光电方式导航/识别（磁/霍尔编码器有违规风险）
    input  wire         enc_la,
    input  wire         enc_lb,
    input  wire         enc_ra,
    input  wire         enc_rb,

    // ---------------- 车载显示：0.96" OLED ----------------
    // 若是 4 脚 I2C OLED：直接复用上面的 i2c_scl / i2c_sda，无需额外端口；
    // 若是 7 脚 SPI OLED：在此增加 oled_dc / oled_rst / oled_cs / oled_sck / oled_mosi。
    // 细则 4.3.3 / 5.1 要求颜色顺序在【车载显示屏持续显示】，口头报告不计分。

    // ---------------- 板载调试资源 ----------------
    // 【6 LED 而不是 8】板上 LED6/LED7 与 OV5640 的 CMOS_D0/D1 在 GPIOL_01/02
    //   共用同一个 BGA 球（04_原理图&PIN TCL xlsx「BANK 3.3」页 R4/R3 行），
    //   官方 02-1_Ti60_OV5640_LCD-HDMI_1080P60 就是只用 led_o[5:0]（Ti60_Demo.peri.xml
    //   第 510–526 行 bus led_o msb=5）。摄像头工程必须让 DVP 排针优先，所以这里 6 位。
    output wire [5:0]   led,            // LED0~LED5，低电平点亮；LED6/7 球让给 CMOS_D0/D1
    input  wire         uart_rx,        // GPIOT_N_16，Mini-USB 口 CH340N
    output wire         uart_tx         // GPIOT_P_16
);

    // ------------------------------------------------------------------
    // 复位同步化：异步有效、同步释放
    // ------------------------------------------------------------------
    reg [1:0] rst_sync;
    wire      sys_rst_n = rst_sync[1];

    always @(posedge clk or negedge rst_n)
        if (!rst_n) rst_sync <= 2'b00;
        else        rst_sync <= {rst_sync[0], 1'b1};

    // ------------------------------------------------------------------
    // 阶段 1 台架试车开关
    // ------------------------------------------------------------------
    // PWM_BENCH_TEST = 1 : 左轮以 25% 占空比持续正转、TB6612 STBY 放开
    //                      —— 用于验证"PWM 波形真的出来了、电机真的转"。
    //                      【上地跑车前必须改回 0】，否则上电即走。
    // PWM_BENCH_TEST = 0 : 电机完全待机（安全默认值），PWM 输出恒低。
    // car_fsm / track_pid 接入后，这两个 localparam 由闭环输出取代。
    localparam        PWM_BENCH_TEST = 1'b1;
    localparam [10:0] BENCH_DUTY     = 11'd300;     // 300/1200 = 25%

    assign ml_in1     = PWM_BENCH_TEST;   // 左轮正转方向
    assign ml_in2     = 1'b0;
    assign mr_in1     = 1'b0;             // 右轮不给方向 = 不动
    assign mr_in2     = 1'b0;
    assign motor_stby = PWM_BENCH_TEST;   // 1=TB6612 工作，0=待机

    // 三根 CTL 恒 0（官方实测值）；SCCB 由 cam_sccb_cfg 驱动（见下）
    assign cmos_ctl1  = 1'b0;
    assign cmos_rst_n = 1'b0;       // 不是复位！见端口处注释
    assign cmos_pwdn  = 1'b0;

    // ------------------------------------------------------------------
    // 子模块实例化：PWM 发生器（电机调速）+ 编码器解码（里程反馈）
    // 阶段 1 用台架常量驱动；car_fsm / track_pid 就绪后把 en/duty 换成闭环输出。
    // ------------------------------------------------------------------
    wire        motor_en = PWM_BENCH_TEST;      // TODO: 接 car_fsm 的使能
    wire [10:0] ml_duty  = PWM_BENCH_TEST ? BENCH_DUTY : 11'd0;  // TODO: 接 track_pid
    wire [10:0] mr_duty  = PWM_BENCH_TEST ? BENCH_DUTY : 11'd0;

    pwm_gen u_pwm_l (
        .clk   (clk),
        .rst_n (sys_rst_n),
        .en    (motor_en),
        .duty  (ml_duty),
        .pwm   (ml_pwm)
    );

    pwm_gen u_pwm_r (
        .clk   (clk),
        .rst_n (sys_rst_n),
        .en    (motor_en),
        .duty  (mr_duty),
        .pwm   (mr_pwm)
    );

    wire [31:0] enc_l_pos, enc_r_pos;
    wire        enc_l_step, enc_r_step;
    wire        enc_l_dir,  enc_r_dir;

    encoder_dec u_enc_l (
        .clk       (clk),
        .rst_n     (sys_rst_n),
        .a         (enc_la),
        .b         (enc_lb),
        .step      (enc_l_step),
        .direction (enc_l_dir),
        .position  (enc_l_pos)
    );

    encoder_dec u_enc_r (
        .clk       (clk),
        .rst_n     (sys_rst_n),
        .a         (enc_ra),
        .b         (enc_rb),
        .step      (enc_r_step),
        .direction (enc_r_dir),
        .position  (enc_r_pos)
    );

    // ------------------------------------------------------------------
    // 超声波测距（避障 20 分）
    // ------------------------------------------------------------------
    wire [15:0] dist_cm;
    wire        dist_valid;

    hc_sr04 u_ultra (
        .clk       (clk),
        .rst_n     (sys_rst_n),
        .trig      (hc_trig),
        .echo      (hc_echo),
        .dist_cm   (dist_cm),
        .valid     (dist_valid)
    );

    // ------------------------------------------------------------------
    // DVP 时序统计（A3.3）：在 pclk 域量每行像素/每帧行数，跨域送回
    // ------------------------------------------------------------------
    wire [15:0] dvp_width, dvp_height;
    wire [31:0] dvp_frames;
    wire        dvp_new_frame;

    dvp_capture u_dvp (
        .clk       (clk),
        .rst_n     (sys_rst_n),
        .pclk      (cmos_pclk),
        .href      (cmos_href),
        .vsync     (cmos_vsync),
        .data      (cmos_data),
        .width     (dvp_width),
        .height    (dvp_height),
        .frames    (dvp_frames),
        .new_frame (dvp_new_frame)
    );

    // ------------------------------------------------------------------
    // 颜色识别（A3.4）：流式统计，不需要帧缓存
    // ------------------------------------------------------------------
    wire [2:0] cam_color;
    wire       cam_color_evt;

    color_detect u_color (
        .clk       (clk),
        .rst_n     (sys_rst_n),
        .pclk      (cmos_pclk),
        .href      (cmos_href),
        .vsync     (cmos_vsync),
        .data      (cmos_data),
        .color     (cam_color),
        .new_color (cam_color_evt)
    );

    // ------------------------------------------------------------------
    // 调试串口：每测一次距离打一行 "D=xxxcm\r\n"（CH340N，115200-8-N-1）
    // 这是现场 5 分钟调试窗口里最省事的观测手段，比接示波器快。
    // ------------------------------------------------------------------
    // ------------------------------------------------------------------
    // 八路循迹采样 + 加权质心（循迹 20 分的第一级）
    // ACTIVE_HIGH=0：TCRT5000 + LM393 模块的常见极性（压黑线输出低）。
    // 接上 YB-MUX04 后看串口 T= 位串，若极性反了就把这里改成 1。
    // ------------------------------------------------------------------
    wire [7:0]  line_bits;
    wire [3:0]  line_cnt;
    wire        line_on, line_lost;
    wire signed [4:0] line_pos;

    track_line #(
        .CLK_FREQ    (24_000_000),
        .SAMPLE_KHZ  (1_000),
        .DEBOUNCE_N  (4),
        .ACTIVE_HIGH (0)
    ) u_track (
        .clk     (clk),
        .rst_n   (sys_rst_n),
        .track   (track),
        .line    (line_bits),
        .cnt     (line_cnt),
        .on_line (line_on),
        .lost    (line_lost),
        .pos     (line_pos)
    );

    // ------------------------------------------------------------------
    // 障碍融合：超声波近距 或 任一路红外触发
    // HC-SR04 每 60 ms 更新一次 dist_cm（一直保持上次值），这里直接拿来比较即可。
    // ------------------------------------------------------------------
    localparam [15:0] OBSTACLE_CM = 16'd25;    // 刹车/绕行阈值，实测后调

    wire hc_near  = (dist_cm != 16'hFFFF) && (dist_cm <= OBSTACLE_CM);
    wire ir_det   = ~ir_l | ~ir_r;              // NPN 低有效
    wire obstacle = hc_near | ir_det;

    // ------------------------------------------------------------------
    // 摄像头上电时序 + VSYNC 探测（A3.1）
    // 里程碑：串口 V>0 就说明 XCLK、DVP 接线、复位全对 —— 与 SCCB 无关。
    // ------------------------------------------------------------------
    wire        cam_ready;
    wire [7:0]  cam_vs_cnt;
    wire        cam_vs_act;

    cam_probe #(
        .CLK_FREQ     (24_000_000),
        .RST_LOW_MS   (1),
        .CFG_DELAY_MS (20),
        .WIN_MS       (100)
    ) u_cam (
        .clk           (clk),
        .rst_n         (sys_rst_n),
        .vsync         (cmos_vsync),
        .ready         (cam_ready),
        .vs_cnt        (cam_vs_cnt),
        .vs_act        (cam_vs_act)
    );

    // ------------------------------------------------------------------
    // OV5640 寄存器配置（A3.2）：cam_ready 之后才开始，252 条写完置 done
    // ------------------------------------------------------------------
    wire cam_cfg_done;

    cam_sccb_cfg #(
        .CLK_FREQ (24_000_000),
        .I2C_FREQ (100_000),
        .DEV_ADDR (8'h78)
    ) u_sccb (
        .clk      (clk),
        .rst_n    (sys_rst_n),
        .start    (cam_ready),
        .sclk     (cmos_sclk),
        .sdat_in  (cmos_sdat_IN),
        .sdat_out (cmos_sdat_OUT),
        .sdat_oe  (cmos_sdat_OE),
        .done     (cam_cfg_done)
    );

    // ------------------------------------------------------------------
    // 调试串口：每测一次距离打一行
    //   D=123cm T=00011000 P=+02 O=0 V=03\r\n
    // ------------------------------------------------------------------
    uart_report #(
        .CLK_FREQ  (24_000_000),
        .BAUD      (115_200),
        .REPORT_EN (1)
    ) u_dbg (
        .clk        (clk),
        .rst_n      (sys_rst_n),
        .dist_cm    (dist_cm),
        .dist_valid (dist_valid),
        .line       (line_bits),
        .pos        (line_pos),
        .obstacle   (obstacle),
        .vs_cnt     (cam_vs_cnt),
        .cam_done   (cam_cfg_done),
        .cam_width  (dvp_width),
        .cam_height (dvp_height),
        .cam_color  (cam_color),
        .tx         (uart_tx)
    );

    // ------------------------------------------------------------------
    // I2C 主机（OV5640 SCCB / OLED / VL53L1X 共用）
    // 当前 start 恒 0：总线保持释放状态（SCL 高、SDA 高阻靠外部上拉）。
    // sccb_cfg / oled_driver 接入后改为驱动 start/dev_addr/wr_data。
    // ------------------------------------------------------------------
    wire        i2c_busy;
    wire [7:0]  i2c_rd_data;
    wire        i2c_ack_err;

    i2c_master #(
        .CLK_FREQ (24_000_000),
        .SCL_FREQ (100_000)
    ) u_i2c (
        .clk      (clk),
        .rst_n    (sys_rst_n),
        .start    (1'b0),               // TODO: 接 sccb_cfg 的命令 FSM
        .dev_addr (7'h3C),              // OV5640 SCCB 写地址 0x78>>1
        .rw       (1'b0),
        .wr_data  (8'h00),
        .rd_data  (i2c_rd_data),
        .ack_err  (i2c_ack_err),
        .busy     (i2c_busy),
        .done     (),
        .scl      (i2c_scl),
        .sda_in   (i2c_sda_IN),
        .sda_out  (i2c_sda_OUT),
        .sda_oe   (i2c_sda_OE)
    );

    // ------------------------------------------------------------------
    // 系统心跳（正式工程保留的诊断逻辑，不是演示代码）
    // 为什么必须有：Efinity 对"所有输出都是常量、所有输入悬空"的顶层会报
    //   ERROR : Post-synthesis netlist has only vcc and gnd nets because all
    //   logic is eliminated. Legal, but will cause router to crash. [VDB-9009]
    // 纯常量骨架进不了布局布线。一个由 24 MHz 驱动的自由运行计数器既保住
    // 时钟网络与真实寄存器，也是最终整车上"位流已加载 / 时钟在跑"的指示灯，
    // 并能把 rst_n / sys_rst_n / track 真正接进逻辑，消除 unconnected 警告。
    // ------------------------------------------------------------------
    reg [23:0] heartbeat;

    always @(posedge clk or negedge rst_n)
        if (!rst_n)       heartbeat <= 24'd0;
        else if (!sys_rst_n) heartbeat <= 24'd0;
        else              heartbeat <= heartbeat + 1'b1;

    // LED[5] 慢闪（2^23 / 24 MHz ≈ 0.35 s 半周期），板上 LED 低电平点亮；
    // LED[4:1] 显示"极性统一、消抖之后"的循迹探头 3~0（1=压线 -> 灯亮），
    //          比直接显示原始 track 有用：极性改 ACTIVE_HIGH 后灯也跟着对；
    // LED[0]  丢线时常亮（提示"看不见线了"），否则显示"左右任一编码器是否在走"：
    //          两个里程计数第 22 位异或后与心跳相与，轮子一转就能看到闪，
    //          是"编码器接线对不对、AB 相有没有脉冲"最快的判断依据。
    //          【为什么用左右异或】enc_r_pos 目前没有下游使用，综合会把它整块优化掉、
    //          连 enc_ra/enc_rb 引脚一起删掉（VDB-8003）；异或让两路都留在网表里，
    //          PID 接入前也能上板验证右侧编码器。
    assign led = {heartbeat[23], ~line_bits[3:0],
                  line_lost ? 1'b0 : ((enc_l_pos[22] ^ enc_r_pos[22]) & heartbeat[22])};

    // ------------------------------------------------------------------
    // 待实现子模块（顺序见 PROJECT_PLAN.md 第 5 节）
    //   sccb_cfg      u_sccb  —— 用 u_i2c 把 OV5640 寄存器表写进去   ← 下一步
    //   dvp_capture   u_cam   —— DVP 8bit 采集，写 DDR3 帧缓存
    //   color_detect  u_color —— 红/绿/蓝/黄顺序识别
    //   sign_detect   u_sign  —— 左转/右转标识
    //   oled_driver   u_oled  —— 颜色顺序持续显示（裁判拍照）
    //   track_pid     u_track —— 用 track[7:0] + enc_*_step 做 PID
    //   car_fsm       u_fsm   —— 整机状态机（循迹/避障/入库/停稳）
    // 说明：enc_l_step / enc_r_step / enc_l_dir / enc_r_dir / i2c_busy /
    //   i2c_rd_data / i2c_ack_err 目前没有下游使用，综合会产生 unused 警告，
    //   这是"接口先留好、模块逐个接入"的正常中间状态，不影响位流生成。
    // ------------------------------------------------------------------

endmodule
