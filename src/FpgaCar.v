// =============================================================================
// FpgaCar.v —— 第十四届"星火杯"赛题二 智能小车 / Ti60F225 顶层
// -----------------------------------------------------------------------------
// 器件  : Efinix Titanium Ti60F225 (C4)，Efinity 2026.1
// 时钟  : 24 MHz 有源晶振 -> GPIOL_11（3.3 V LVCMOS input）
//
// 【现场配置】K230 识别交通牌、色块和 P；OV5640 侧视找库并输出灰度取景。
//   原因：颜色识别改由 K230 经 3 线 GPIO 送结果（PROJECT_PLAN.md §3.18），
//   Ti60 侧暂时不需要 DVP 采集、SCCB 配置、帧统计、抓帧导出这一整条链路。
//   两个开关都置回 1'b1 即可完整恢复（RTL 一行不改，端口与管脚约束也不用动）。
//   【停用后省下的东西】u_color 1156 XLR、u_oled 10873 XLR（占顶层 72%）、
//   以及 I2C 总线与帧时序这两条最难调的调试线。
//
// 【管脚怎么分配】Titanium 的管脚不在 HDL 里写 LOC，全部在 Interface Designer 里分配：
//   - 可分配资源查 04_原理图&PIN TCL/Ti60_Board_引脚定义-20230703-V1.0.xlsx 的 "DC3-40" 页
//   - User_IO1 (GPIOL_P_02) / K1 启动，User_IO0 (GPIOL_N_02) / K2 停车，排针不外接
//   - 核心板第三个按键 K3 走 CRESET_N（Configuration 专用脚），RTL 碰不到，
//     按下等于整片重新配置并回到待机
//   - OV5640 走板上独立 DVP 排针，不占 DC3-40 的 36 个 User_IO
//   - 板上 6 个 LED / CH340N 串口是固定引脚，也不占 DC3-40
//   - 摄像头停用后 cmos_* 的管脚分配保持原样（只把输出打常量），
//     将来恢复时不用改 peri.xml
//
// 【I2C 双向口为什么是三根线】Efinity/Titanium 不允许顶层 inout 被 1'bz 驱动
//   （综合报错 "Signal driving output port 'xxx' is tristated" [EFX-0410]）。
//   正确做法是：HDL 里把双向 SDA 拆成 _IN / _OUT / _OE 三个独立端口，
//   由 Interface Designer 里一个 mode="inout" 的 GPIO 块（块名 i2c_sda）在物理
//   管脚上合成三态缓冲；SCL 由主机单向驱动，建 mode="output" 块即可。
//
// 【IO 电平】BL / BR / TL / TR bank = 3.3 V，其余 1.8 V（1A = 1.2 V）。
//   每个 User_IO 都过 TXS0108EPWR（VCCA=D1V8，VCCB=D3V3），所以 RTL 侧的
//   .peri 约束一律 LVCMOS18，写 3.3V 会直接跑不通。
//   HC-SR04 的 Echo 输出是 5 V，必须两个电阻分压到 3.3 V 才能进排针。
//
// 【首次下载预期状态】电机不转、LED[5] 慢闪、LED[4:2] 显示状态机状态；
//   串口按 D=/T=/P=/O=/M= 与 L=/R=/VL=/VR= 两行循环，是现场最快的观测手段。
// =============================================================================
`timescale 1ns/1ns

// 现场默认由 K230 发 P。台架把 PARKING_DEBUG 设为 1 时，K1 模拟收到 P。
module FpgaCar #(
    parameter PARKING_DEBUG = 1'b0
) (

    // ---------------- 时钟 / 板载按键 ----------------
    input  wire         clk,            // 24 MHz, GPIOL_11
    input  wire         key_start_n,    // K1 / KEY[0] / GPIOL_P_02，低有效
    input  wire         key_stop_n,     // K2 / KEY[1] / GPIOL_N_02，低有效

    // ---------------- 循迹 20 分：YB-MUX04 八路循迹 ----------------
    input  wire [7:0]   track,

    // ---------------- 避障 20 分：HC-SR04 ----------------
    output wire         hc_trig,        // 10 us 触发脉冲
    input  wire         hc_echo,        // 回波（5 V ！！必须两个电阻分压到 3.3 V）

    // ---------------- 避障 20 分：E18-D80NK 红外光电开关 ×2 ----------------
    // NPN 常开输出，检测到障碍时拉低（=0）；需外部 4.7k 上拉到 3.3 V。
    // 与 HC-SR04 做"或"融合：任一认为有障碍就减速/绕行，降低"触碰扣 10 分"的风险。
    // 【分左右的原因】绕行时要决定往哪边偏，二选一的融合信号做不到这一点。
    input  wire         ir_l,           // 左前端，User_IO26
    input  wire         ir_r,           // 右前端，User_IO27

    // ---------------- 公共 I2C 总线（当前空闲，见 USE_OLED）----------------
    output wire         i2c_scl,
    input  wire         i2c_sda_IN,
    output wire         i2c_sda_OUT,
    output wire         i2c_sda_OE,

    // ---------------- OV5640 DVP（当前停用，端口保留）----------------
    // 输入全部不参与运算；输出打常量，保证管脚行为确定（不是高阻）。
    input  wire         cmos_pclk,
    input  wire         cmos_href,
    input  wire         cmos_vsync,
    input  wire [7:0]   cmos_data,
    output wire         cmos_sclk,
    input  wire         cmos_sdat_IN,
    output wire         cmos_sdat_OUT,
    output wire         cmos_sdat_OE,
    // 三根 CTL：**必须全部驱动 0**（照抄官方 example_top.v:378-383 的实测值）。
    // 实测把 CTL2 给 1 会让传感器完全不出图。
    output wire         cmos_ctl1,      // GPIOR_15
    output wire         cmos_rst_n,     // CMOS_CTL2（GPIOL_04）
    output wire         cmos_pwdn,      // CMOS_CTL3（GPIOL_N_00）

    // ---------------- 运动执行：TB6612FNG（双路 H 桥）----------------
    output wire         ml_in1,
    output wire         ml_in2,
    output wire         ml_pwm,
    output wire         mr_in1,
    output wire         mr_in2,
    output wire         mr_pwm,
    output wire         motor_stby,     // 1=工作, 0=待机(电机禁止)

    // ---------------- 里程反馈：光电编码器 x2（AB 相）----------------
    // 必须光电式：细则 3.2.2 禁止非光电方式导航/识别
    input  wire         enc_la,
    input  wire         enc_lb,
    input  wire         enc_ra,
    input  wire         enc_rb,

    // ---------------- 视觉：K230 4 线并行口（见 PROJECT_PLAN §3.18）----------------
    // 固定线束见 docs/K230_GPIO_FIXED.md。P4外侧为3.3V，芯片侧为1.8V，经板载TXS0108转换。
    // K230输出电平须实测；若为1.8V，在固定线束上加1.8->3.3V转换，不能直接当作电平一致。
    // 未上电时必须靠外部 10 kΩ 下拉把线拉低，否则悬空乱触发（见计划里的风险表）。
    input  wire [2:0]   k230_d,         // D0=GPIO42 / D1=GPIO43 / D2=GPIO34
    input  wire         k230_stb,       // STB=GPIO35，上升沿采样 D[2:0]

    // ---------------- ST7789 彩屏（SPI，P4 排针 35/36/37/38/40）----------------
    // 与 OV5640 共用相机口：屏上显示的就是摄像头预览（灰度转 RGB565）。
    // 这五根在引脚分配表里一直预留，这里是首次真正例化。
    output wire         lcd_sclk,       // pin35 User_IO30 / GPIOL_N_17
    output wire         lcd_mosi,       // pin36 User_IO31 / GPIOL_P_17
    output wire         lcd_dc,         // pin37 User_IO32 / GPIOL_N_18
    output wire         lcd_rst_n,      // pin38 User_IO33 / GPIOL_P_18
    output wire         lcd_cs_n,       // pin40 User_IO35 / GPIOT_P_11

    // ---------------- 板载调试资源 ----------------
    output wire [5:0]   led,            // LED0~LED5，低电平点亮
    input  wire         uart_rx,        // GPIOT_N_16，Mini-USB 口 CH340N
    output wire         uart_tx         // GPIOT_P_16
);

    // ------------------------------------------------------------------
    // 【总开关】摄像头链路 / OLED 显示
    //   1'b1 = 启用，1'b0 = 停用。
    //   USE_OLED 与摄像头是两件事：K230 方案下 OLED 仍然要用（显示颜色顺序），
    //   只是它现在没有颜色可显示，先关掉省 10873 XLR。
    // ------------------------------------------------------------------
    localparam USE_CAMERA = 1'b0;
    localparam USE_OLED   = 1'b1;    // 2026-11-16 打开，测试 OLED 接线
    // K230 视觉链路：颜色事件的来源改由它提供（USE_CAMERA 才是 OV5640 那条路）。
    // 两者互斥地驱动同一组 cam_color/cam_color_evt 也可以，但没必要 ——
    // 赛场上 K230 是主方案，OV5640 只作退路，用一个开关明确二选一更不容易出错。
    // 前视联调分支：启用固定 K230 GPIO 线束，转向仍等待 Ti60 循迹确认。
    localparam USE_K230   = !PARKING_DEBUG;
    localparam USE_ULTRA  = !PARKING_DEBUG;

    // ------------------------------------------------------------------
    // 【彩屏预览开关】1'b1 = 相机画面送到 ST7789 屏上（灰度，320x240 横屏）
    //   - 与 USE_CAMERA 互斥：两者都要吃 OV5640 的 DVP 数据，同时开会争抢总线。
    //   - 与 USE_K230 不冲突：K230 走 GPIO 并行口，OV5640 走 DVP，互不相干。
    //   - 开着它时仍然不产生颜色事件（cam_color 打 0），方便单独看画面。
    // ------------------------------------------------------------------
    localparam USE_LCD_PREVIEW = 1'b1;

    // SPI 半周期（24 MHz 主时钟下的分频数）。SPI 时钟 = 24MHz / (2*N)：
    //   N=16 -> 750 kHz，整屏 1.6 s 一帧（bench 最初的值）
    //   N=4  -> 3 MHz，  整屏 0.41 s 一帧
    //   N=2  -> 6 MHz，  整屏 0.20 s 一帧（当前值）
    // 屏线拉长或出现花屏就把它改回 4 或 16，这是唯一需要现场试的参数。
    localparam integer LCD_SPI_HALF_CYCLES = 2;

    // ------------------------------------------------------------------
    // FPGA 配置后先保持内部复位几个周期，再随系统时钟释放。
    // ------------------------------------------------------------------
    reg [3:0] power_on = 4'b0000;
    wire      sys_rst_n = power_on[3];

    always @(posedge clk)
        power_on <= {power_on[2:0], 1'b1};

    // ------------------------------------------------------------------
    // 运动闭环（track_pid + car_fsm）接线
    // ------------------------------------------------------------------
    // 【台架开关】PWM_BENCH_TEST = 1 时绕过闭环：左轮 25% 常转，用于验证
    //   用来核对 PWM 和 TB6612 接线。两种模式都受 K1/K2 控制。
    localparam        PWM_BENCH_TEST = 1'b0;
    localparam [10:0] BENCH_DUTY     = 11'd300;     // 300/1200 = 25%

    // 【手动调参区】PWM 周期为 1200。循迹 P/D 初值和基础 PWM 来自 main 的实测版。
    localparam integer TRACK_P_GAIN             = 64;
    localparam integer TRACK_D_GAIN             = 24;
    localparam integer TRACK_TRIM               = 34;  // 正数增加左轮、降低右轮 PWM
    localparam [10:0]   TRACK_BASE_DUTY          = 384; // 正中时左右轮平均 PWM，32%
    localparam [6:0]    TRACK_SPEED_PERCENT      = 100; // 常规循迹倍率，384 已是 main 的降速值
    localparam [6:0]    PARK_AFTER_P_PERCENT     = 85;  // 相对调速后的常规循迹
    localparam [6:0]    PARK_AFTER_CORNER_PERCENT= 50;  // 相对调速后的常规循迹
    localparam [6:0]    POST_PARK_PERCENT        = 70;  // 出库后的循迹及终点直行倍率
    localparam integer START_BOX_MM             = 400; // 从 K1 起计，起步区内横边视为直行
    localparam [3:0]    FINISH_MIN_SENSORS       = 6;   // 终点横边至少压黑的探头数
    localparam integer FINISH_CONFIRM_MS        = 8;   // 横边连续确认时间
    localparam integer FINISH_MM                = 300; // 检出横边起再行驶的距离

    localparam integer FINISH_DRIVE_DUTY =
        TRACK_BASE_DUTY * TRACK_SPEED_PERCENT * POST_PARK_PERCENT / 10000;
    localparam integer FINISH_DRIVE_TRIM =
        TRACK_TRIM * $signed({1'b0, TRACK_SPEED_PERCENT}) *
        $signed({1'b0, POST_PARK_PERCENT}) / 10000;

    wire              ctrl_en;
    wire              ctrl_dir_l, ctrl_dir_r;
    wire [10:0]       ctrl_duty_l, ctrl_duty_r;
    wire [10:0]       pid_duty_l, pid_duty_r;
    wire signed [10:0] pid_corr;
    wire [2:0]        car_state;                     // 0 IDLE 1 RUN 2 LOST 3 SEARCH 4 STOP
    wire [1:0]        panel_status;
    wire              run_enable, clear_result;
    wire              parking_camera_ready, parking_frame_done, parking_corner, parking_pair;
    // {SCCB 配置完成, 见过 vsync, 采到过有效帧} —— 只给串口 CAM= 用，排查"屏不亮"
    wire [2:0]        cam_status;
    wire              parking_slow, parking_pair_seen, parking_brake, parking_stopped, parking_video_ready;
    wire              parking_owner, parking_done, parking_fault;
    wire              parking_motion_stopped, parking_forward_l, parking_forward_r;
    wire [1:0]        parking_reverse_fault;
    wire [2:0]        parking_status;
    wire              start_zone, start_box_override;
    wire              finish_driving, finish_braking, finish_stopped;
    wire [10:0]       finish_duty_l, finish_duty_r;
    wire              finish_owner = finish_driving || finish_braking;
    wire              motion_rst_n = sys_rst_n && run_enable;
    wire              tracking_rst_n = motion_rst_n && !parking_owner && !finish_owner;
    wire              approach_brake = parking_brake && !parking_done;
    wire [2:0]        reported_state = (panel_status == 2'd2 || parking_fault || finish_stopped) ? 3'd4 :
                                      finish_owner ? 3'd1 : parking_owner ? parking_status : car_state;

    // ------------------------------------------------------------------
    // 速度环（编码器闭环）
    //   SPEED_LOOP_EN = 0 → 完全直通，行为与加环之前一模一样；
    //   = 1 → car_fsm 给出的占空比先经 speed_pid 用编码器实测速度拉平两轮。
    //   编码器没接/没脉冲时 speed_pid 内部自动回退成直通（enc_ok=0），
    //   所以这一位开着也不影响"没有编码器"的降级调试路径。
    // ------------------------------------------------------------------
    // 【2026-11-24 关闭】实车数据证明这一层从加上去就没真正生效过，而且它的
    //   作用方向与差速转向直接冲突：
    //   · 实测循迹时的 |DL-DR| 中位 280，**没有任何一帧 ≤120**（run1 0/173、
    //     run2 0/80），而 v1.17 加的 SYNC_DIFF_MAX=120 只在 ≤120 时才放开 ——
    //     也就是说这一层名义上存在、实际上从来没算过。sum_lim 在 91% 的帧恒为 0。
    //   · 就算把门控放开也是错的：本车配平点是 DL=340/DR=620，那个点上两轮
    //     实测本来就等速、曲率≈0；同步环若强行把 spd 拉平，就会把这个「偏占空比
    //     换直行」的配平点当成误差去修正，等于禁止转弯。
    //   结论：轮速不等靠 track_pid 的前馈 TRIM 在前级解决，这一层不需要。
    //   保留整个模块与接线（以后要做得改成「按目标轮速差」而不是「按实测拉平」），
    //   只把开关置 0，行为与加环之前完全一致。
    localparam SPEED_LOOP_EN = 1'b0;

    wire [10:0]        spd_duty_l, spd_duty_r;
    // spd_sync / enc_ok 是这一层的观测量：
    //   DL=/DR= 已经改报环后的真实占空比，本层效果直接看这两个字段
    //   （DL=BASE+C-同步修正、DR=BASE-C+同步修正）。
    //   enc_ok=0 说明编码器没出脉冲、本层已自动回退成直通。
    wire signed [10:0] spd_sync;
    wire               enc_ok;
    wire [10:0]        loop_duty_l = SPEED_LOOP_EN ? spd_duty_l : ctrl_duty_l;
    wire [10:0]        loop_duty_r = SPEED_LOOP_EN ? spd_duty_r : ctrl_duty_r;

    // 整形器的 en 就是这个信号（停机/换相死区/非 RUN 时直通），
    // 所以必须在例化之前声明，否则 Verilog 会当成隐式 wire。
    wire        motor_en = motion_rst_n && !finish_stopped &&
                           (finish_owner || (parking_owner ? !parking_motion_stopped :
                            PWM_BENCH_TEST || ctrl_en || approach_brake));

    // ------------------------------------------------------------------
    // 差速幅度整形（duty_shaper）
    //   见 src/duty_shaper.v 顶部说明。一句话：track_pid 饱和时会把内侧轮压到
    //   占空比 0，等效于"绕车体中心原地转"（R = WHEEL_BASE_MM/2 = 80 mm），
    //   远超赛道弯半径；把差速压一半后内侧轮仍有 240，R≈240 mm，弯道动作幅度
    //   直接减半，而平均前进速度不变。
    //   只对循迹同向工况生效：原地转/找线/避障/停车一律直通，语义不变。
    // ------------------------------------------------------------------
    // 2026-11-23 实车+仿真结论：DIFF_SHIFT=1 是错的，本项目关闭。
    //   bench/corner_loop_sim2.py 与 bench/final_compare.py 的闭环仿真
    //   （8 路探头 + track_line + track_pid + 差速车体，R=400/300/250/200/175/160
    //   × 车速 0.35~0.80 mm/s-per-duty 共 24 组）：
    //     DIFF_SHIFT=1 → 8/24 失败，弯道横向误差平均 68.4 mm，最大 152.5 mm
    //                    （横向误差超过约 32 mm 线就跑出 77 mm 宽的探头阵列）
    //     DIFF_SHIFT=0 → 0/24 失败，平均 14.0 mm，最大 19.1 mm
    //   把差速压一半等于把可用转向曲率压一半，弯道反而跟不上；
    //   SHAPE_MIN_DUTY 地板（120~360）实测也不改善任何指标。
    //   保留本模块仅为将来做电机起转死区补偿，默认全程直通。
    localparam        DUTY_SHAPE_EN = 1'b0;   // 总开关（0=整级旁路）
    localparam integer SHAPE_DIFF_SHIFT = 0;  // 差速不缩放
    localparam integer SHAPE_MIN_DUTY   = 0;  // 低占空比地板（0=关闭，需实测死区）
    localparam integer SHAPE_SLEW_STEP  = 0;  // 斜率限制/ms（0=关闭，有相位滞后）

    // follow：正在循迹、两轮同向。S_RUN=1 / S_LOST=2（car_fsm.v:148-149）
    wire shape_follow = ((car_state == 3'd1) || (car_state == 3'd2)) &&
                        (ctrl_dir_l == ctrl_dir_r);

    wire [10:0] shape_duty_l, shape_duty_r;

    duty_shaper #(
        .CLK_FREQ   (24_000_000),
        .DUTY_MAX   (1200),
        .DIFF_SHIFT (SHAPE_DIFF_SHIFT),
        .MIN_DUTY   (SHAPE_MIN_DUTY),
        .SLEW_STEP  (SHAPE_SLEW_STEP)
    ) u_shaper (
        .clk        (clk),
        .rst_n      (sys_rst_n),
        .en         (motor_en),
        .follow     (shape_follow),
        .duty_l_in  (loop_duty_l),
        .duty_r_in  (loop_duty_r),
        .duty_l_out (shape_duty_l),
        .duty_r_out (shape_duty_r)
    );

    // 两轮同比缩放。避障沿用同学标定的独立 PWM，停车动作自行控制电机。
    function [10:0] pwm_percent;
        input [10:0] duty;
        input [6:0] percent;
        reg [17:0] product;
        begin
            product = duty * percent;
            pwm_percent = product / 18'd100;
        end
    endfunction

    wire [10:0] raw_track_duty_l = DUTY_SHAPE_EN ? shape_duty_l : loop_duty_l;
    wire [10:0] raw_track_duty_r = DUTY_SHAPE_EN ? shape_duty_r : loop_duty_r;
    wire [10:0] track_duty_l = pwm_percent(raw_track_duty_l, TRACK_SPEED_PERCENT);
    wire [10:0] track_duty_r = pwm_percent(raw_track_duty_r, TRACK_SPEED_PERCENT);
    wire avoid_active = car_state >= 3'd5;
    wire [10:0] approach_duty_l, approach_duty_r, parking_duty_l, parking_duty_r;
    wire [10:0] final_duty_l = finish_stopped ? 11'd0 : finish_owner ? finish_duty_l :
                              parking_owner ? parking_duty_l : avoid_active ? raw_track_duty_l :
                              parking_done ? pwm_percent(track_duty_l, POST_PARK_PERCENT) : approach_duty_l;
    wire [10:0] final_duty_r = finish_stopped ? 11'd0 : finish_owner ? finish_duty_r :
                              parking_owner ? parking_duty_r : avoid_active ? raw_track_duty_r :
                              parking_done ? pwm_percent(track_duty_r, POST_PARK_PERCENT) : approach_duty_r;

    // ------------------------------------------------------------------
    // 【接线补偿】2026-11-23 驱动轮从距车头 30 mm 后移到 75 mm 之后，电机
    // 的接法也跟着变了：左右两个通道对调，且每个电机的正反转都反了。
    //
    // 这两个错误只在这一层修，上层的「左轮/右轮」「前进/后退」语义一概不动。
    // 原因是上层语义一旦跟着翻，串口 DL=/DR=、OLED 四格、拐角方向判定、避障
    // 左右绕行会同时反过来，现场再出问题时就没法区分是接线错了还是控制错了。
    //
    // 两个开关互相独立，组合起来正好覆盖「哪个通道驱动哪个轮」×「正转是往前
    // 还是往后」四种情况。改机械时如果只动了一样，就只翻对应的那一个。
    //
    // 验证方法（架空车、手动让车上电但不跑循迹）：
    //   1) 给前进指令，两个轮子都应该朝车头方向转；反了就翻 MOTOR_INVERT。
    //   2) 给左转指令（左轮后退、右轮前进），车应该向左转；反了就翻 WHEEL_SWAP。
    // ------------------------------------------------------------------
    localparam WHEEL_SWAP   = 1'b1;   // 1 = 左右两个电机通道对调（ml_* 驱动右轮）
    localparam MOTOR_INVERT = 1'b1;   // 1 = 前进/后退取反（两个电机极性都反了）

    // 物理通道占空比：交换之后 ml_* 通道拿的是右轮的指令
    wire [10:0] ml_duty  = PWM_BENCH_TEST ? BENCH_DUTY : (WHEEL_SWAP ? final_duty_r : final_duty_l);
    wire [10:0] mr_duty  = PWM_BENCH_TEST ? BENCH_DUTY : (WHEEL_SWAP ? final_duty_l : final_duty_r);

    // 三根 CTL 恒 0（官方实测值），与 USE_CAMERA 无关：不驱动就是悬空
    assign cmos_ctl1  = 1'b0;
    assign cmos_rst_n = 1'b0;       // 不是复位！见端口处注释
    assign cmos_pwdn  = 1'b0;

    // ------------------------------------------------------------------
    // 子模块实例化：PWM 发生器（电机调速）
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // 编码器解码 + 测速
    //   position 现在有两个下游：串口的 L=/R=（标定每米脉冲数要用）
    //   和将来的入库里程闭环。speed 给 VL=/VR=，速度环接入前先用它看趋势。
    // ------------------------------------------------------------------
    wire [31:0] enc_l_pos, enc_r_pos;
    wire        enc_l_step, enc_r_step;
    wire        enc_l_dir,  enc_r_dir;
    wire signed [15:0] spd_l, spd_r;
    wire        spd_l_v, spd_r_v;

    // 【v1.17 修正：编码器必须跟着 WHEEL_SWAP 一起对调】
    //   v1.15 换接线时只翻了电机通道（ml_* 去驱动物理右轮），编码器还是照引脚
    //   直连，于是速度环拿「物理左轮」的读数去修「物理右轮」的占空比——修正
    //   方向正好相反，一装编码器就会正反馈发散（左轮看着快就越减，实际减的
    //   是右轮，差速被越推越大）。
    //
    //   修法放在接线层：逻辑左轮 = WHEEL_SWAP ? 物理右编码器 : 物理左编码器。
    //   这样 enc_l_pos / spd_l / enc_l_step 一开始就是「逻辑左轮」，下游的
    //   speed_pid、uart_report（L= / R= / VL= / VR=）全都不用动，串口报的
    //   L= 与 DL= 也自然对应同一个轮子。
    //
    //   注意 enc_l_step / enc_r_step 给 car_fsm 算 arc_diff / arc_sum 时取了
    //   绝对值（src/car_fsm.v:242-244），换不换对它都等价。
    wire enc_la_i = WHEEL_SWAP ? enc_ra : enc_la;
    wire enc_lb_i = WHEEL_SWAP ? enc_rb : enc_lb;
    wire enc_ra_i = WHEEL_SWAP ? enc_la : enc_ra;
    wire enc_rb_i = WHEEL_SWAP ? enc_lb : enc_rb;

    // 自动倒车复用独立动作版验证过的 10 us 编码器消抖，累计值的原始极性用于常规串口。
    encoder_dec #(.STABLE_TICKS(240)) u_enc_l (
        .clk       (clk),
        .rst_n     (sys_rst_n),
        .a         (enc_la_i),
        .b         (enc_lb_i),
        .step      (enc_l_step),
        .direction (enc_l_dir),
        .position  (enc_l_pos)
    );

    encoder_dec #(.STABLE_TICKS(240)) u_enc_r (
        .clk       (clk),
        .rst_n     (sys_rst_n),
        .a         (enc_ra_i),
        .b         (enc_rb_i),
        .step      (enc_r_step),
        .direction (enc_r_dir),
        .position  (enc_r_pos)
    );

    speed_meter #(
        .CLK_FREQ (24_000_000),
        .WIN_MS   (50)
    ) u_spd_l (
        .clk   (clk),
        .rst_n (sys_rst_n),
        .step  (enc_l_step),
        .dir   (enc_l_dir),
        .speed (spd_l),
        .valid (spd_l_v)
    );

    speed_meter #(
        .CLK_FREQ (24_000_000),
        .WIN_MS   (50)
    ) u_spd_r (
        .clk   (clk),
        .rst_n (sys_rst_n),
        .step  (enc_r_step),
        .dir   (enc_r_dir),
        .speed (spd_r),
        .valid (spd_r_v)
    );

    // ------------------------------------------------------------------
    // 速度环：放在测速模块之后，spd_l/spd_r/spd_*_v 必须先声明
    // ------------------------------------------------------------------
    speed_pid #(
        .DUTY_MAX     (1200),
        .K_SYNC       (12),
        .I_SYNC_SHIFT (4),
        .I_SYNC_LIMIT (400),
        .SYNC_MAX     (180),
        .NOENC_WIN    (20),
        .SYNC_DIFF_MAX(120)
    ) u_spd_pid (
        .clk        (clk),
        .rst_n      (motion_rst_n),
        .en         (ctrl_en),
        .spd_l      (spd_l),
        .spd_r      (spd_r),
        .valid_l    (spd_l_v),
        .valid_r    (spd_r_v),
        .dir_l      (ctrl_dir_l),
        .dir_r      (ctrl_dir_r),
        .duty_l_in  (ctrl_duty_l),
        .duty_r_in  (ctrl_duty_r),
        .duty_l_out (spd_duty_l),
        .duty_r_out (spd_duty_r),
        .sync_corr  (spd_sync),
        .enc_ok     (enc_ok)
    );


    // ------------------------------------------------------------------
    // 超声波测距（避障 20 分）
    // ------------------------------------------------------------------
    wire [15:0] dist_cm;
    wire        dist_valid;

    hc_sr04 u_ultra (
        .clk       (clk),
        .rst_n     (sys_rst_n && USE_ULTRA),
        .trig      (hc_trig),
        .echo      (hc_echo),
        .dist_cm   (dist_cm),
        .valid     (dist_valid)
    );

    // ------------------------------------------------------------------
    // 八路循迹采样 + 加权质心
    // ACTIVE_HIGH=0：TCRT5000 + LM393 模块的常见极性（压黑线输出低）。
    // ------------------------------------------------------------------
    wire [7:0]  line_bits;
    wire [7:0]  line_raw;      // 消抖后的原始电平（未按 ACTIVE_HIGH 取反）
    wire [3:0]  line_cnt;
    wire        line_on, line_lost;
    wire        line_wide;     // 宽黑判定（影子防护），串口 W= 字段显示
    wire signed [4:0] line_pos;
    assign start_box_override = start_zone && !parking_done && line_wide;
    wire steering_on_line = line_on || start_box_override;
    wire steering_lost = line_lost && !start_box_override;
    wire signed [4:0] steering_pos = start_box_override ? 5'sd0 : line_pos;

    track_line #(
        .CLK_FREQ    (24_000_000),
        .SAMPLE_KHZ  (1),          // 1 kHz = 1 ms 消抖节拍
        .DEBOUNCE_N  (4),
        .ACTIVE_HIGH (0)
    ) u_track (
        .clk     (clk),
        .rst_n   (sys_rst_n),
        .track   (track),
        .line    (line_bits),
        .raw     (line_raw),
        .cnt     (line_cnt),
        .on_line (line_on),
        .lost    (line_lost),
        .pos     (line_pos),
        .wide    (line_wide)
    );

    // ------------------------------------------------------------------
    // 障碍融合：超声波近距 或 任一路红外触发
    // 【绕行要用到的两个分量】ir_l / ir_r 单独留着：只知道"有障碍"没法决定
    //   往左还是往右偏，必须知道障碍压在哪一侧。
    // ------------------------------------------------------------------
    // 【触发距离 35 cm】v1.24c 由 28 cm 提前。几何核算（bench/hdg_profile_sim.py，
    // 按实测车长 20 cm / 含轮宽 18.5 cm / 轮距 16 cm）显示：触发越晚，出线弧
    // 留给车尾越过方块的距离越短。35 cm 触发 + AUTO_PASS 100 mm 时，若弧角仍
    // 是 70°，两轮等效率工况最小间隙掉到 0.0 mm（车体与方块相交）；把弧角同步
    // 提到 78° 后最小间隙回到 37.7 mm，六档效率全部安全。
    localparam [15:0] OBSTACLE_CM = 16'd35;    // 刹车/绕行阈值
    // 【滞回】释放距离要比触发距离大，否则车在阈值边缘会反复进出避障：
    // 超声波本身有 ±1 cm 抖动，车又刚好在动，单阈值必然抖。留 7 cm 死区，
    // 必须始终大于 OBSTACLE_CM，否则触发条件永远不满足、车直接撞上去。
    localparam [15:0] OBSTACLE_RELEASE_CM = 16'd42;
    // 【多帧确认】hc_sr04 单帧就可能因为地面反射/斜射丢回波给出一个假的近距，
    // 只判一帧会让车在路上被一个毛刺直接摁停或绕障。连续 N 帧都近才算真的近，
    // 连续 N 帧都远才算真的远。60 ms 一帧 → 3 帧约 180 ms，车速 0.3 m/s 时
    // 车已走 5.4 cm，仍在 28 cm 阈值的安全余量内。
    localparam [3:0]  OBSTACLE_CONFIRM_N = 4'd3;

    // 【总开关】红外避障（E18-D80NK）—— 现阶段不用，默认关闭。
    //   1'b0 = 不参与障碍判定（超声波单独决定 obstacle），接线与 RTL 全部保留；
    //   1'b1 = 超声波 或 任一路红外触发都算障碍。
    //   为什么默认关：E18-D80NK 要外接 10k 上拉到 D3V3 再经 1k/1.2k 分压（详见
    //   PROJECT_PLAN §3.21），没接模块时输入端要么悬空要么被内部上拉抬高，
    //   一旦电平判错就会凭空报障碍把车摁停 —— 现场最难查的一类故障。
    //   要启用：接好两路（含分压）后把这里改 1'b1 重新综合；只接一路也可以，
    //   另一路保持断开即可（未接那路若误报，把对应端口改接 D3V3 拉到「无遮挡」）。
    localparam USE_IR = 1'b0;

    // 【总开关】超声波避障参与障碍判定 —— 2026-11-18 恢复为 1（避障已实现）。
    //   1'b0 = hc_near 不参与 obstacle（O 恒 0，车不会因为前方 25 cm 内有墙被摁停），
    //          但 u_ultra 仍然例化运行，D= / 屏上距离继续可读，方便对照。
    //          只测循迹、不想被墙摁停时改成 0。
    //   1'b1 = 恢复超声波避障（原行为）。现在遇障碍不再原地干停，
    //          而是走 car_fsm 的 BACK → TURN → PROBE 三段绕行。
    // ---- 超声波多帧确认 + 滞回 ----
    reg  [1:0]  hc_near_cnt;     // 连续近帧数
    reg  [1:0]  hc_far_cnt;      // 连续远帧数
    reg         hc_near_lat;     // 锁存后的"近"标志

    wire hc_frame_ok   = dist_valid && (dist_cm != 16'hFFFF);
    wire hc_frame_near = hc_frame_ok && (dist_cm <= OBSTACLE_CM);
    wire hc_frame_far  = hc_frame_ok && (dist_cm >  OBSTACLE_RELEASE_CM);

    always @(posedge clk or negedge sys_rst_n)
        if (!sys_rst_n) begin
            hc_near_cnt <= 2'd0;
            hc_far_cnt  <= 2'd0;
            hc_near_lat <= 1'b0;
        end else if (hc_frame_ok) begin
            // 只有"有效回波"帧才动计数器：无回波（FFFF）整帧跳过，两个计数器
            // 都保持原值，既不算近也不算远。若改成 dist_valid 就把非近帧计数清零，
            // 空旷场地持续无回波会让 hc_far_cnt 一直加（掩盖真实近距）；反过来
            // 真实障碍偶丢一帧又要从头数 3 帧，确认被无谓推迟。
            hc_near_cnt <= hc_frame_near ? ((hc_near_cnt >= OBSTACLE_CONFIRM_N - 1)
                                            ? OBSTACLE_CONFIRM_N - 1 : hc_near_cnt + 2'd1) : 2'd0;
            hc_far_cnt  <= hc_frame_far  ? ((hc_far_cnt  >= OBSTACLE_CONFIRM_N - 1)
                                            ? OBSTACLE_CONFIRM_N - 1 : hc_far_cnt  + 2'd1) : 2'd0;
            if (hc_near_cnt >= OBSTACLE_CONFIRM_N - 1) hc_near_lat <= 1'b1;
            else if (hc_far_cnt >= OBSTACLE_CONFIRM_N - 1) hc_near_lat <= 1'b0;
        end

    wire hc_near  = hc_near_lat;
    wire ir_l_det = ~ir_l;                      // NPN 低有效
    wire ir_r_det = ~ir_r;
    // 注意：OLED 的四格已改成 障碍/丢线/左转/右转（红外模块已卸下），
    // 所以 ir_l_det / ir_r_det 现在只在 USE_IR=1 时参与 obstacle，没有观测出口。
    // 要排查红外接线只能用串口或示波器；重装红外时记得先把 USE_IR 改回 1。
    wire ir_det   = ir_l_det | ir_r_det;
    wire obstacle = (USE_ULTRA ? hc_near : 1'b0) | (USE_IR & ir_det);

    // ------------------------------------------------------------------
    // 运动闭环：track_pid（位置 PID）+ car_fsm（状态机）
    // ------------------------------------------------------------------
    // 【2026-11-24 v1.19 重新整定】P 120→80、D 220→30、新增 TRIM=-140。
    // 上一版 P120/D220 是纯仿真（理想连续传感器、左右轮完全对称）定的，实车
    // 跑出来是「线能跟上但一直在小幅甩」。两条串口实测数据（.scratch/run_track1.csv
    // 173 个 RUN 帧、run_track2.csv 80 个）给出了确定的因果：
    //
    //  1) 传感器是台阶量化的：8 路探头间距 11 mm、线半宽 6.5 mm，几何上「内侧两路
    //     同时压线」的窗口只有 2 mm，「只压一路」的窗口有 9 mm。实测 85% 的帧只
    //     压到 1 路，pos 只能取 ±1/±3/±5/±7（奇数占 89%），pos=0 几乎不出现。
    //     相邻探头切换 Δpos=±2，乘 D_GAIN=220 就是 440 计数 —— 单靠一次跳变就能
    //     顶满 ±480 的钳位，D 项在实车上完全被量化噪声主导（仿真里 pos 连续，
    //     所以没暴露这一点）。D 降到 30 后同一跳变只有 60 计数。
    //
    //  2) 真正的稳态误差来自左右轮效率不等：实测右轮约只有左轮 0.55（§3.50）。
    //     原来想靠积分自己凑出那 140 的偏置，但 I_LIMIT>>I_SHIFT 只有 20 的权限，
    //     且每拍只累加 pos（±1 量级），要爬几千拍才到 140 —— 实际永远爬不上去。
    //     证据：稳态帧的 i_term 恒等于 -20（100% 顶死），C= 就僵在 P*(-1)-20=-140。
    //     改成前馈 TRIM=-140 后，积分只补残差，工作点从悬崖边回到 0 附近。
    //
    // 扫描（bench/gain_final.py / bench/gain_trim_sens.py，K_L=0.30、K_R=0.165，
    // 复刻 RTL 的 pos 台阶量化 + P/D/I + ±BASE 钳位 + 20% 概率 pos±1 抖动；
    // R=4000/600/400/300/240/200/160 × 入弯偏差 ±15/±8/0 × 抖动开/关 × 2 种子
    // = 140 组）：
    //   P120 D220 TRIM=0    （旧） 0/140 失败，最差 10.1 mm，稳态横向误差 RMS 8.02
    //   P80  D30  TRIM=-140 ←本值  0/140 失败，最差  6.5 mm，稳态横向误差 RMS 0.95
    //   P80  D20  TRIM=-140       0/140 失败，最差  6.5 mm，RMS 0.97
    //   P96  D30  TRIM=-140       0/140 失败，最差  8.9 mm，RMS 0.82
    // 旧值那 8.02 mm 的 RMS 全是「右轮慢导致车一直斜着走」，新值是 0.95 mm。
    // TRIM 不需要精确：-120~-180 全部 0 失败，右轮比例 0.14~0.21 也全部 0 失败。
    //
    // 【上板后怎么调】直道仍朝一侧偏 → 先只动 TRIM（往偏差反方向加，步长 ±20）；
    // 弯道超调/切内 → 加 D（24→40）；跟线迟钝 → 加 P（64→80）。别再把 D 拉回 200。
    //
    // 【2026-11-25 全域降速 0.8×】P/D/I/TRIM 全部按 ×0.8 缩放。理由：这三个量
    //   输出的都是**占空比差**，而车画出的曲率 ≈ 占空比差 / 车速。车速 ×0.8 时
    //   占空比差同比例缩到 ×0.8，轨迹曲率才和降速前完全一样（每 mm 位置误差
    //   对应的修正曲率不变）——只降 BASE_DUTY 而不降增益，等于把转向放大 25%，
    //   弯道会变成"一顿一顿地打方向"。
    //   注意 track_pid 内部 corr 限幅是 ±BASE_DUTY，BASE 384 时自动变成 ±384。
    //   若现场发现低占空比下修正"打不动"（起转死区吃掉差分），优先把 P/D
    //   往回加（64/24 → 80/30），而不是加 BASE_DUTY。
    track_pid #(
        .CLK_FREQ  (24_000_000),
        .TICK_MS   (10),
        .DUTY_MAX  (1200),
        .BASE_DUTY (TRACK_BASE_DUTY),
        .P_GAIN    (TRACK_P_GAIN),
        .D_GAIN    (TRACK_D_GAIN),
        .I_SHIFT   (5),
        // 【B 方案】积分权限 = I_LIMIT>>I_SHIFT = 192>>5 = **±6 计数**。
        //   这不是"变小了"，而是把真实权限写明：本环实质是 PD + TRIM 前馈，
        //   112 计数的轮速差不该由积分去补（也补不动），积分只吸收 1~2 格量化残差。
        //   副作用是 windup 蓄水变浅（192 而非 640），饱和后回吐快。
        .I_LIMIT   (192),
        // D 项一阶低通（α=1/4）：D 现在对"滤波后的角速度"出力，而不是对传感器
        //   1 格跳变出力。0 = 关闭滤波（退回 2026-11-25 之前的行为）。
        .D_FILT_SHIFT (2),
        // corr 每 10 ms 最多变 64 计数（满量程 384 约 60 ms 到顶），压电流尖峰与甩头。
        .SLEW_STEP (64),
        // 【2026-11-25 现场实测重标：-112 → +34，符号翻转】
        //   依据：自制赛道跑 45 s 抓 124 帧 RUN，C= 的时间均值 +33.6、P= 均值 +2.37，
        //   两个独立算法给出同一个结论（mean(C)=+34；TRIM+P_mean*64 = -112+152 = +40）。
        //   稳态下 corr 的时间平均必然等于"让两轮等速"所需的物理差速 c*，所以
        //   TRIM 应当直接等于这个均值 —— 原来的 -140/-112 是按 v1.19 那次
        //   "右轮效率只有左轮 0.55"的测量给的，驱动轮后移到 75 mm、电机通道对调
        //   之后那个结论已经不成立：现在需要的是**左轮略快**（正修正）。
        //   偏差 146 计数 = 2.3 个 P 单位，正好等于现场看到的"偏右 1~2 个探头"，
        //   并且把右侧量程吃到只剩不到 1 格 → 右弯一进来就整排丢线（M=02）。
        //   改完的验收标准：直道 P= 均值回到 0±0.5、C= 均值 |·|≤10、不再频繁 M=02。
        .TRIM      (TRACK_TRIM)
    ) u_pid (
        .clk     (clk),
        .rst_n   (motion_rst_n),
        .en      (ctrl_en),
        .pos     (steering_pos),
        .on_line (line_on && !start_box_override),
        .lost    (steering_lost),
        .duty_l  (pid_duty_l),
        .duty_r  (pid_duty_r),
        .corr    (pid_corr)
    );

    // 方向事件来源（交通牌）：K230 提供，停用时恒 0
    // ------------------------------------------------------------------
    // K230 视觉链路（USE_K230 控制）
    //   协议见 PROJECT_PLAN §3.18：000 → CAT → 000 → VAL → 000，整条连发两遍。
    //   color_evt 的编码已在模块内转换过，与 cam_color 完全同构。
    //
    //   这些声明必须放在 car_fsm / oled_driver 例化之前：dir_evt_mux 与
    //   k230_off 在更靠前的位置就引用了它们（Verilog 不允许先用后声明）。
    // ------------------------------------------------------------------
    wire [3:0] k_color;                 // 1=红 2=绿 3=蓝 4=黄（与 cam_color 同语义）
    wire [2:0] k_dir;                   // 1=左 2=右 3=直
    wire [7:0] k_cmd;                   // bit0=清空顺序 bit1=新一圈 bit2=停车牌 P
    wire       k_alive;                 // 2 s 内收到过合法消息
    wire [7:0] k_err;                   // 协议异常计数，OLED 诊断用

    wire [2:0] dir_evt_mux = (USE_K230 && !parking_done) ? k_dir : 3'd0;
    wire [1:0] turn_dir;                                // 最近一次转向方向（0 无 1 左 2 右），串口 S= 用
    wire parking_request = PARKING_DEBUG || k_cmd[2];
    wire following_forward = car_state == 3'd1 && ctrl_en && ctrl_dir_l && ctrl_dir_r;

    // car_fsm 在入库交接期间复位，单次避障记录由顶层保留到本轮结束。
    reg avoided_this_run;
    always @(posedge clk or negedge sys_rst_n)
        if (!sys_rst_n) avoided_this_run <= 1'b0;
        else if (!run_enable) avoided_this_run <= 1'b0;
        else if (avoid_active) avoided_this_run <= 1'b1;
    wire route_obstacle = obstacle && !(parking_done && avoided_this_run);

    // 原始编码器前进为负，里程控制统一转换为前进为正。
    wire signed [31:0] park_pos_l = -$signed(enc_l_pos);
    wire signed [31:0] park_pos_r = -$signed(enc_r_pos);
    course_finish #(
        .START_BOX_MM(START_BOX_MM), .FINISH_MM(FINISH_MM),
        .CONFIRM_MS(FINISH_CONFIRM_MS), .DRIVE_DUTY(FINISH_DRIVE_DUTY),
        .DRIVE_TRIM(FINISH_DRIVE_TRIM)
    ) u_finish (
        .clk(clk), .rst_n(sys_rst_n), .run_enable(run_enable),
        .finish_armed(parking_done && following_forward),
        .wide_marker(line_wide && line_cnt >= FINISH_MIN_SENSORS),
        .position_l(park_pos_l), .position_r(park_pos_r), .start_zone(start_zone),
        .driving(finish_driving), .braking(finish_braking), .stopped(finish_stopped),
        .duty_l(finish_duty_l), .duty_r(finish_duty_r)
    );

    car_panel u_panel (
        .clk            (clk),
        .rst_n          (sys_rst_n),
        .key_start_n    (key_start_n),
        .key_stop_n     (key_stop_n),
        .line_ready     (steering_on_line && !steering_lost && (!PARKING_DEBUG || parking_video_ready)),
        .motion_stopped (finish_stopped || (!finish_owner && (parking_owner ? parking_motion_stopped :
                         !approach_brake && (car_state == 3'd4 || (car_state == 3'd0 && steering_lost))))),
        .run_enable     (run_enable),
        .clear_result   (clear_result),
        .status         (panel_status)
    );

    // ==================================================================
    // 【2026-11-25 全域降速到 0.8×】下面 car_fsm 的参数覆盖按同一规则缩放：
    //   占空比（速度量）→ ×0.8；纯时间参数 *_MS → ×1.25；角度/里程判据
    //   （ARC_DEG / PASS_MM / ENC 标定）不变；AVOID_MIN_DUTY、消抖与
    //   超声等待时间不缩放。细节见 src/car_fsm.v 参数区顶部说明。
    //   时间参数没跟着放大的话，降速后同样的 *_MS 只能走完原来 0.8 的距离，
    //   表现就是"每段都提前收、动作做一半"。
    // ==================================================================
    car_fsm #(
        .CLK_FREQ     (24_000_000),
        .START_MS     (1),           // K1 已确认；状态机再确认一次压线启动
        .LOST_HOLD_MS (375),         // 300→×1.25（保持同样的滑行距离）
        .SEARCH_MS    (1875),        // 1500→×1.25（转同样的角度）
        .SEARCH_DUTY  (400),         // 500→×0.8
        .SEARCH_FAIL_TO_IDLE (0),    // 找线失败后由按键面板锁停
        .DIR_DEAD_MS  (10),
        // 牌转向改成闭环：边转边看线，转开一段后线一压回来就提前收工。
        // 菱形锐角需要的转角比直角大得多，定长转不够就直接丢线；
        // 这里 1375 ms 只是上限（1100→×1.25），正常直角会自己提前结束。
        .TURN_MS        (1375),
        .TURN_MIN_MS    (313),    // 至少转这么久（250→×1.25）
        .TURN_LINE_MS   (20),     // 连续压线 20 ms 才算线已找回来（配合 4 ms 消抖，不缩放）
        // 转向牌从"看到牌"到"真的到岔口"的等待上限。默认 12000 太长：
        // 一旦锁存了一枚过期箭头，它会在整整 12 s 内压制拐角兜底，
        // 车遇到没有牌的真拐角也不会按 DEFAULT_TURN_LEFT 转（直接冲出去）。
        // 现场按 3 m 场地估：原 3 s 是按 ~0.4 m/s，降速后 3.75 s。
        .TURN_REQUEST_MS  (3750),
        .TURN_WAIT_FOR_CORNER (USE_K230),
        .TURN_DUTY    (560),         // 700→×0.8
        // 现场初值：先让车驶到障碍侧边，再摆正超越，最后低速斜切回线。
        .AVOID_EN         (1),
        // 【2026-11-25】只允许触发一次避障：实测第一次绕障虽然回线过程抖，
        //   但最终把线找回来了并稳定跑了 2.3 s；导致 STOP 的是车跑到弯道附近
        //   墙进入 31 cm 范围后的**第二次**触发。比赛只有一个方块，
        //   第二次触发没有正面价值。K1/复位后自动重新允许（见 car_fsm.v）。
        .AVOID_ONCE       (1),
        .AVOID_ROUTE_EN   (1),
        .AVOID_FIXED_RIGHT (1),
        .AVOID_BACK_MS    (500),     // 400→×1.25
        .AVOID_BACK_DUTY  (400),     // 500→×0.8
        .AVOID_TURN_MS    (1250),    // 1000→×1.25（右转出线和左转摆正各用这段时长）
        .AVOID_TURN_IN_MS (2000),    // 1600→×1.25；角度到位或扫到线都会提前结束
        .AVOID_TURN_DUTY  (496),     // 620→×0.8
        .AVOID_PROBE_MS   (3000),    // 2400→×1.25
        .AVOID_PROBE_DUTY (480),     // 600→×0.8
        // 【2026-11-25 重算】PASS 里程已改回 100 mm（原 360 mm），且车速降到 0.8×：
        //   100 mm 按降速后的慢端 0.16 mm/ms 约 625 ms。没有编码器时这条就是
        //   实际超越时长，必须按里程重算；编码器在线时它只是 ×4 上限的基数。
        //   若把 AVOID_PASS_MM 改回 360，这条同步改 2250。
        .AVOID_PASS_MS    (625),     // 沿障碍侧边直线超越（100 mm 的理论时长上限）
        .AVOID_REJOIN_MS  (6250),    // 5000→×1.25（回线更长，KR/KL=0.50 需约 5550 ms）
        .AVOID_REJOIN_DUTY (512),    // 回线段的差速（外侧快轮，640→×0.8）
        .AVOID_REJOIN_IN_DUTY (344), // 回线段的差速（内侧慢轮，430→×0.8）
        // ---- 弧线绕障（AVOID_ROUTE_EN=1 时生效）----
        // 全程两轮正转、只靠左右差速画弧，不出现倒车与原地掉头：
        //   细则 4.3.2 禁止"以大转弯形式绕开障碍"，而原地转的车尾摆幅最大。
        // 几何核算（车宽 18.5 cm、方块 10 cm、驱动轮距 16 cm）：
        //   单弧 60°、占空比 860/380 时横移约 20.7 cm（需 ≥14.25 cm），
        //   在 25 cm 触发距离下最小间隙约 4.5 cm，见 bench/avoid_sim6.py。
        // 【弧线段改成里程闭环】下面两条 ms 已不再是"定长"，而是编码器不
        // 出脉冲时的超时上限。真正的段切换由两轮计数差（转角）和计数和
        // （里程）决定：同样 60°，车速快慢、电池电压高低都走得一样。
        //   60° 对应计数差 2000（标定见下方三行参数）
        //
        // 【v1.16 修正：超时值必须等于"真的转过 60°"的时间，不能当成宽松上限】
        // 车上目前没有装编码器（本轮不采购）。没有脉冲 → arc_diff 恒 0 →
        // arc_diff_done 恒假 → 这三段永远走满超时。原来写 2500 ms 是按
        // "正常 300~500 ms 就够、给个宽松上限"想的，但没编码器时它就是
        // 唯一的实际时长：占空比 860/380 下 2500 ms 转 215°，BY_ALIGN 再
        // 反打 2500 ms 只往回 197°，车原地转一圈半还跑回起点后方
        // （仿真终点 y = -51 mm，理想是 +574 mm）。
        //
        // 取值为什么是 780/850 而不是理论 698/762：占空比到线速度的常数 K
        // 在仓库里有两套标定（duty 600 → 40 cm/s 与 → 30 cm/s，差 50%），
        // 而真实车速随电池/地面/轮胎在 18~46 cm/s 漂移，同一段 60° 弧所需
        // 时间从 1164 ms 到 436 ms，跨 2.7 倍，不存在单一正确值。
        // 两个方向的代价不对称：转少了横移不够会擦方块；转多了横移偏大，
        // 但 BY_TURN_IN 扫到线会提前结束，能自己拉回来。所以按慢端偏置，
        // 取 K=0.45~0.50 标定，覆盖 27~46 cm/s，整段最小间隙 ≥45.6 mm。
        // 现场若擦到方块（说明更慢），三条值同乘 698/实测所需ms。
        // 装了编码器后这三条退回"上限"语义，与车速无关，无需再调。
        .AVOID_OUT_MS     (975),     // 外摆弧真实时长（780→×1.25，降速后转同样 64°）
        //   【v1.23 ALIGN 上限 850→1100】弧角由 60° 加到 70° 后，右轮效率只有
        //   左轮 0.5 时摆正弧要 4148 ms，850×4=3400 会被超时截断，欠转的角度全丢。
        //   1100×4=4400 覆盖到 KR/KL=0.50 仍有 252 ms 余量。
        //   【2026-11-25 降速】1100→1375（×1.25），×4 后 5500 ms，覆盖同样的效率差。
        .AVOID_ALIGN_MS   (1375),    // 摆正弧超时上限（×4 后 5500 ms）
        // 标定：轮周长 / 轮距 / 每圈计数。换轮子或换编码器只改这三个。
        // 【v1.18 实测重标定】原来写 3840 计数/圈（按"20 线四倍频 80 × 减速 48"
        //   推算）、轮周长 232 mm —— 两个都是算出来的，从没量过。实测结果：
        //     每圈计数：手转左轮 5 圈，右轮全程 0 计数，左轮共 12662 →
        //       2532 计数/圈。转向过程自然分成三段 2522/7506/2634（比例 1:3:1），
        //       各自反推 2522/2502/2634，互相吻合 ±2.7%，所以这个数是可靠的。
        //       反推减速比只有 31.7:1，不是 48:1。
        //     轮周长：卡尺量轮径 67~68 mm（取 67.5）→ 212 mm，不是 232 mm。
        //   于是每毫米计数 实测 11.94、原假设 16.55，**高了 39%**。后果是
        //   里程闭环比真实走得远：60° 弧按 2772 计数差会转 83°（多 23°），
        //   BY_PASS 按 3310 计数会走 277 mm（多 77 mm）—— 这正是 v1.17 装上
        //   编码器后避障变差的原因：以前没脉冲靠 780 ms 超时（按时长标定，
        //   大致对），一有脉冲就按错误的尺子一直转到够数为止。
        .ENC_CNT_PER_REV  (2532),
        .WHEEL_CIRC_MM    (212),
        .WHEEL_BASE_MM    (160),
        // 【v1.25 78→64】上一轮是"加角度补车尾"（70→78）。本轮先把车推到位、延长 PASS
        // 让回拐远离方块，深度与间隙就能同时改善：78°/PASS100 → 横移 283 mm、间隙 70 mm；
        // 64°/PASS360 → 横移 200 mm、间隙 57.8 mm（bench/__final.py，35 cm 触发）。
        .AVOID_ARC_DEG    (64),      // 单弧目标转角（OUT / ALIGN 用）
        // 【v1.20 TURN_IN 也改成角度闭环】OUT/ALIGN 一直有计数差闭环（实测
        //   确实在 2000 计数差附近切换，−60°/+60° 达标），只有 TURN_IN 是
        //   "纯时间 + 扫线"：扫线要连续 20 ms 压到线，而车正在大幅转向途中
        //   几乎压不到，于是每次都跑满 1600 ms。run_avoid1 实测这 1600 ms
        //   转了 141°，目标是 60° —— 车头直接甩过，REJOIN 再也找不回线。
        //   【v1.22 由 90° 改回 60°】90° 几何上等于车头与赛道垂直，垂穿时只在
        //   一点压线，REJOIN 的 20 ms 连续压线判据几乎不可能满足，现场就是
        //   「转得过多、直接飞到平行赛道」。与 OUT 对称取 60° 形成标准 S 形回线。
        //   【v1.23 由 60° 改 70°】几何仿真（bench/hdg_profile_sim.py）里 60° 弧
        //   横移只有 140.9mm，而让开车体需要 NEED_LAT = 92.5（半宽）+ 50（方块
        //   半宽）= 142.5mm，恰好擦着方块过去（最小间隙 0.0mm）；70° 弧横移
        //   172mm，最小间隙升到 72mm。
        //   【v1.24 由 70° 改 40°】TURN_IN 目标角就是车切回原线时的航向角（REJOIN
        //   沿用同一目标继续斜切）。70° 等于以 70°~90° 姿态撞线、接近垂直穿越；
        //   track_pid 只有位置误差、没有航向状态，压一下就滑出去 → 「垂直赛道走过去」。
        //   几何仿真扫角：TURN_IN=40 时过线航向稳定在 39.9±0.4°（KR/KL 0.50~1.00
        //   六档全过）；最小间隙 72.1~105.2mm 只由 OUT 弧角决定，与 TURN_IN 无关。
                .AVOID_TURN_IN_ARC_DEG (40),  // 40° = 1333 计数差（浅角回线）
        // v1.26：REJOIN 不再沿用 TURN_IN 的 40°，单独给 15°。车仍持续向线收敛，
        //   但过线时航向只有约 15°，交回 track_pid 时不再需要硬掰 → 不冲过黑线。
        .AVOID_REJOIN_ARC_DEG (15),   // 15° = 500 计数差（贴线并入）
        //   【v1.23 由 200mm 改 500mm】200mm 时车身还没完全超越方块就开始回切，
        //   车尾扫到方块；500mm 让整车越过障碍后再回切，仿真最小间隙 72mm。
        // 【v1.25 100→360】100 mm 时车刚过方块中心就回拐，车尾角会扫到方块；360 mm 让
        // TURN_IN 起点落在方块后沿之后约 230 mm，这也是弧角能从 78° 降到 64° 的前提。
        .AVOID_PASS_MM    (100),     // BY_PASS 直线超越距离（每轮）
        // 【2026-11-25 降速】下面五对占空比全部 ×0.8。**两轮比值不变** ⇒ 弧半径
        //   与设计几何一致；只是走完同样弧角要更久，由上面各段 *_MS（已 ×1.25）
        //   和角度闭环兜住。内轮不要低于 AVOID_MIN_DUTY=120（起转门槛）。
        .AVOID_OUT_DUTY   (688),     // 860→×0.8
        .AVOID_OUT_IN_DUTY(304),     // 380→×0.8
        .AVOID_ALIGN_DUTY (672),     // 840→×0.8
        .AVOID_ALIGN_IN_DUTY (320),  // 400→×0.8
        // 【v1.24】AVOID_PASS_TRIM 已删除：v1.21 起 PASS 段两轮同取
        //   AVOID_PASS_DUTY，左右偏置由航向闭环 hdg_steer 实时给。
        .AVOID_PASS_DUTY  (496),     // 620→×0.8
        .AVOID_TURN_IN_DUTY (688),   // 860→×0.8
        .AVOID_TURN_IN_IN_DUTY (336),// 420→×0.8
        .AVOID_LINE_MS    (20),
        .AVOID_BLOCK_MS   (250),
        // 转向指示（串口 S= / OLED 左转右转格）保持 1500 ms 后自动熄灭。
        // 保持太短 OLED 每 100 ms 采样一次抓不到；太长直道上也显示"正在转弯"。
        .TURN_DIR_HOLD_MS (1500)
    ) u_car (
        .clk      (clk),
        .rst_n    (tracking_rst_n),
        .on_line  (steering_on_line),
        .lost     (steering_lost),
        .obstacle (route_obstacle),
        .wide     (line_wide && !start_box_override),
        .turn_dir (turn_dir),
        .pos      (steering_pos),
        .dir_evt  (dir_evt_mux),    // 交通牌方向：K230 提供，停用时恒 0
        .pid_l    (pid_duty_l),
        .pid_r    (pid_duty_r),
        .enc_l_step (enc_l_step),
        .enc_r_step (enc_r_step),
        .en       (ctrl_en),
        .dir_l    (ctrl_dir_l),
        .dir_r    (ctrl_dir_r),
        .duty_l   (ctrl_duty_l),
        .duty_r   (ctrl_duty_r),
        .state    (car_state)
    );

    // 停车控制器使能时，零占空比的车轮按独立动作版使用短路刹车。
    // 先按 WHEEL_SWAP 把逻辑轮的指令分配到物理通道（见 ml_duty 附近的接线补偿说明）
    wire logical_l_dir = finish_owner || (parking_owner ? parking_forward_l : ctrl_dir_l);
    wire logical_r_dir = finish_owner || (parking_owner ? parking_forward_r : ctrl_dir_r);
    wire ch_l_dir = WHEEL_SWAP ? logical_r_dir : logical_l_dir;
    wire ch_r_dir = WHEEL_SWAP ? logical_l_dir : logical_r_dir;
    // 再按 MOTOR_INVERT 取反极性。自测模式一律当「前进」，同样要跟着反。
    wire ch_l_fwd = (PWM_BENCH_TEST ? 1'b1 : ch_l_dir) ^ MOTOR_INVERT;
    wire ch_r_fwd = (PWM_BENCH_TEST ? 1'b1 : ch_r_dir) ^ MOTOR_INVERT;

    wire ch_l_brake = (approach_brake || parking_owner || finish_braking) && (ml_duty == 0);
    wire ch_r_brake = (approach_brake || parking_owner || finish_braking) && (mr_duty == 0);
    assign ml_in1     = motor_en & ( ch_l_fwd || ch_l_brake);
    assign ml_in2     = motor_en & (~ch_l_fwd || ch_l_brake);
    assign mr_in1     = motor_en & ( ch_r_fwd || ch_r_brake);
    assign mr_in2     = motor_en & (~ch_r_fwd || ch_r_brake);
    assign motor_stby = motor_en;

    // ------------------------------------------------------------------
    // 摄像头链路（USE_CAMERA 控制）
    //   启用：cam_probe → cam_sccb_cfg → dvp_capture → color_detect → frame_snap
    //   停用：cam_color / cam_color_evt 打常量，输出全部保持确定电平
    // ------------------------------------------------------------------
    wire [2:0] cam_color;
    wire       cam_color_evt;

    wire rep_tx;
    wire snap_tx, snap_busy;        // 停用时由 else 分支打常量
    reg [23:0] heartbeat;

    generate if (USE_LCD_PREVIEW) begin : g_parking
        wire snapshot_valid, snapshot_release;
        wire [15:0] scan_addr;
        wire [7:0] scan_gray;
        wire [9:0] center_x_sum;
        wire action_following;
        reg valid_frame_seen, rejoined;
        assign parking_video_ready = valid_frame_seen;
        assign parking_owner = parking_stopped && !rejoined;
        assign parking_done = rejoined;

        // 检测用独立缓冲，帧率不受 SPI 取景屏限制。
        ov5640_preview_frame #(.SAMPLE_LOG2(2), .ADDRESS_WIDTH(16)) garage_frame (
            .clk(clk), .rst_n(parking_camera_ready), .pclk(cmos_pclk),
            .href(cmos_href), .vsync(cmos_vsync), .data(cmos_data),
            .frame_release(snapshot_release), .frame_valid(snapshot_valid),
            .read_addr(scan_addr), .read_y(scan_gray)
        );
        garage_corner_scan corner_scan (
            .clk(clk), .rst_n(parking_camera_ready), .frame_valid(snapshot_valid),
            .read_y(scan_gray), .read_addr(scan_addr), .frame_release(snapshot_release),
            .frame_done(parking_frame_done), .corner_seen(parking_corner),
            .pair_valid(parking_pair), .center_x_sum(center_x_sum)
        );
        always @(posedge clk or negedge parking_camera_ready)
            if (!parking_camera_ready) valid_frame_seen <= 0;
            else if (parking_frame_done) valid_frame_seen <= 1;

        parking_approach #(
            .AFTER_P_PERCENT(PARK_AFTER_P_PERCENT), .AFTER_CORNER_PERCENT(PARK_AFTER_CORNER_PERCENT)
        ) approach (
            .clk(clk), .rst_n(sys_rst_n), .run_enable(run_enable && !rejoined),
            .parking_request(parking_request),
            .frame_done(parking_frame_done && following_forward && !start_box_override),
            .corner_seen(parking_corner), .pair_valid(parking_pair),
            .center_x_sum(center_x_sum), .track_duty_l(track_duty_l), .track_duty_r(track_duty_r),
            .duty_l(approach_duty_l), .duty_r(approach_duty_r),
            .slow(parking_slow), .pair_seen(parking_pair_seen),
            .brake(parking_brake), .stopped(parking_stopped)
        );

        // 归线后恢复原循迹，直到下一次 K1 才重新启用视觉停车。
        always @(posedge clk or negedge sys_rst_n)
            if (!sys_rst_n) rejoined <= 0;
            else if (!run_enable) rejoined <= 0;
            else if (action_following) rejoined <= 1;

        wire line_valid_for_parking = line_on && !line_lost && !line_wide;
        wire line_centered_for_parking =
            line_valid_for_parking && line_pos >= -5'sd1 && line_pos <= 5'sd1;
        parking_motion action (
            .clk(clk), .rst_n(sys_rst_n && (!run_enable || parking_stopped)),
            .run_enable(run_enable && parking_owner),
            .position_l(park_pos_l), .position_r(park_pos_r), .line_seen(line_on),
            .line_valid(line_valid_for_parking), .line_centered(line_centered_for_parking),
            .follow_duty_l(11'd0), .follow_duty_r(11'd0),
            .active(), .following(action_following), .stopped(parking_motion_stopped),
            .fault(parking_fault), .reverse_fault(parking_reverse_fault), .status(parking_status),
            .forward_l(parking_forward_l), .forward_r(parking_forward_r),
            .duty_l(parking_duty_l), .duty_r(parking_duty_r)
        );
    end else begin : g_no_parking
        assign {parking_frame_done, parking_corner, parking_pair, parking_video_ready,
                parking_slow, parking_pair_seen, parking_brake, parking_stopped} = 8'd0;
        assign {parking_owner, parking_done, parking_fault, parking_motion_stopped} = 4'd0;
        assign {parking_forward_l, parking_forward_r} = 2'b11;
        assign {parking_reverse_fault, parking_status} = 5'd0;
        assign {parking_duty_l, parking_duty_r} = 22'd0;
        assign approach_duty_l = track_duty_l;
        assign approach_duty_r = track_duty_r;
    end endgenerate

    generate
    if (USE_LCD_PREVIEW) begin : g_lcd
        // ----------------------------------------------------------------
        // 彩屏预览：cam_probe -> cam_sccb_cfg(VGA 全视场) -> 预览取样 -> ST7789
        //   采集侧：OV5640 640x480 RGB565，PCLK 下写满一帧约 26 ms
        //   显示侧：SPI 6 MHz 发 320x240 RGB565 约 210 ms，帧间另等 100 ms。
        //   两者用双缓冲 + request/ack 握手解耦，采集不必等屏发完。
        // ----------------------------------------------------------------
        wire        lcd_cam_ready;
        wire        lcd_cfg_done;
        wire        lcd_vs_act;
        wire [8:0]  pv_x, pv_y;
        wire [7:0]  pv_gray;
        wire        pv_frame_valid, pv_frame_release;
        wire        pv_used;

        // 160x120 取样点双倍放大铺满 320x240：屏幕坐标右移一位就是样本坐标
        wire pv_image_row = pv_y >= 9'd30 && pv_y < 9'd210;
        wire [8:0] pv_video_y = pv_y - 9'd30;
        wire [14:0] pv_sample_row = {7'b0, pv_video_y[8:1]};
        wire [14:0] pv_sample_addr = (pv_sample_row << 7) + (pv_sample_row << 5)
                                     + {7'b0, pv_x[8:1]};
        wire        lcd_capture_ready = sys_rst_n && lcd_cfg_done;
        assign parking_camera_ready = lcd_capture_ready;
        // CAM= 遥测：cfg_done / vs_act（每 100 ms 窗口内见过 vsync）/ 曾采到过帧
        reg cam_frame_seen;
        always @(posedge clk or negedge sys_rst_n)
            if (!sys_rst_n) cam_frame_seen <= 1'b0;
            else if (pv_frame_valid) cam_frame_seen <= 1'b1;
        assign cam_status = {lcd_cfg_done, lcd_vs_act, cam_frame_seen};
        wire park_guide = !parking_done && (pv_x == 154 || pv_x == 166);
        wire [15:0] park_status_color = (reported_state == 3'd4 ||
                                           (parking_owner && parking_status == 3'd1)) ? 16'hF800 :
                                        finish_owner ? 16'hFD20 :
                                        parking_owner ? 16'h001F : approach_brake ? 16'hF800 :
                                        parking_done ? 16'h07E0 :
                                        parking_pair_seen ? 16'h07FF :
                                        parking_slow ? 16'hFFE0 : 16'h0000;
        wire [15:0] pv_pixel = !pv_image_row ? park_status_color : park_guide ?
                               16'h07E0 : {pv_gray[7:3], pv_gray[7:2], pv_gray[7:3]};

        cam_probe #(
            .CLK_FREQ     (24_000_000),
            .RST_LOW_MS   (1),
            .CFG_DELAY_MS (20),
            .WIN_MS       (100)
        ) u_lcd_cam (
            .clk    (clk),
            .rst_n  (sys_rst_n),
            .vsync  (cmos_vsync),
            .ready  (lcd_cam_ready),
            .vs_cnt (),
            .vs_act (lcd_vs_act)
        );

        // FULL_FOV_VGA=1：把读取窗口从 720p 的纵向 250..1705 扩到 4:3 全阵列，
        // 输出 640x480。主工程原来那套 720p 参数由 g_cam 分支继续用，不受影响。
        cam_sccb_cfg #(
            .CLK_FREQ    (24_000_000),
            .I2C_FREQ    (100_000),
            .DEV_ADDR    (8'h78),
            .FULL_FOV_VGA(1'b0)
        ) u_lcd_sccb (
            .clk      (clk),
            .rst_n    (sys_rst_n),
            .start    (lcd_cam_ready),
            .sclk     (cmos_sclk),
            .sdat_in  (cmos_sdat_IN),
            .sdat_out (cmos_sdat_OUT),
            .sdat_oe  (cmos_sdat_OE),
            .done     (lcd_cfg_done)
        );

        ov5640_preview_frame #(
            .INPUT_WIDTH  (1280),
            .INPUT_HEIGHT (720),
            .SAMPLE_LOG2  (3)
        ) u_preview (
            .clk           (clk),
            .rst_n         (lcd_capture_ready),
            .pclk          (cmos_pclk),
            .href          (cmos_href),
            .vsync         (cmos_vsync),
            .data          (cmos_data),
            .frame_release (pv_frame_release),
            .frame_valid   (pv_frame_valid),
            .read_addr     (pv_image_row ? pv_sample_addr : 15'd0),
            .read_y        (pv_gray)
        );

        st7789_panel #(
            .CLK_HZ          (24_000_000),
            .SPI_HALF_CYCLES (LCD_SPI_HALF_CYCLES),
            .MADCTL          (8'h60),
            .INVERSION_CMD   (8'h20),
            .LANDSCAPE       (1'b1)
        ) u_lcd (
            .clk             (clk),
            .rst_n           (sys_rst_n),
            .preview_valid   (lcd_capture_ready && pv_frame_valid),
            .preview_pixel   (pv_pixel),
            .x               (pv_x),
            .y               (pv_y),
            .preview_used    (pv_used),
            .preview_release (pv_frame_release),
            .led             (),              // 屏驱动的板载指示灯不用，LED 由顶层统一给
            .lcd_rst_n       (lcd_rst_n),
            .lcd_cs_n        (lcd_cs_n),
            .lcd_sclk        (lcd_sclk),
            .lcd_mosi        (lcd_mosi),
            .lcd_dc          (lcd_dc)
        );

        // 预览模式下不出颜色事件：下游 color_seq 会一直空着，K230 仍然是颜色的来源
        assign cam_color     = 3'd0;
        assign cam_color_evt = 1'b0;
        assign snap_tx       = 1'b1;
        assign snap_busy     = 1'b0;
        assign uart_tx       = rep_tx;
    end else if (USE_CAMERA) begin : g_cam
        assign parking_camera_ready = 0;
        assign cam_status = 3'b000;   // 本分支没有取景链路
        wire        cam_ready;
        wire [7:0]  cam_vs_cnt;
        wire        cam_vs_act;
        wire        cam_cfg_done;
        wire [15:0] dvp_width, dvp_height;
        wire [31:0] dvp_frames;
        wire        dvp_new_frame;
        wire [7:0]  cam_dbg_b0, cam_dbg_b1;
        wire [19:0] cam_cnt_r, cam_cnt_g, cam_cnt_b, cam_cnt_y;
        wire [6:0]  cam_sat;
        wire [7:0]  cam_sb0, cam_sb1, cam_lb0, cam_lb1;

        cam_probe #(
            .CLK_FREQ     (24_000_000),
            .RST_LOW_MS   (1),
            .CFG_DELAY_MS (20),
            .WIN_MS       (100)
        ) u_cam (
            .clk    (clk),
            .rst_n  (sys_rst_n),
            .vsync  (cmos_vsync),
            .ready  (cam_ready),
            .vs_cnt (cam_vs_cnt),
            .vs_act (cam_vs_act)
        );

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

        color_detect u_color (
            .clk       (clk),
            .rst_n     (sys_rst_n),
            .pclk      (cmos_pclk),
            .href      (cmos_href),
            .vsync     (cmos_vsync),
            .data      (cmos_data),
            .color     (cam_color),
            .new_color (cam_color_evt),
            .dbg_b0    (cam_dbg_b0),
            .dbg_b1    (cam_dbg_b1),
            .dbg_cnt_r (cam_cnt_r),
            .dbg_cnt_g (cam_cnt_g),
            .dbg_cnt_b (cam_cnt_b),
            .dbg_cnt_y (cam_cnt_y),
            .dbg_sat   (cam_sat),
            .dbg_sb0   (cam_sb0),
            .dbg_sb1   (cam_sb1),
            .dbg_lb0   (cam_lb0),
            .dbg_lb1   (cam_lb1)
        );

        frame_snap #(
            .CLK_FREQ (24_000_000),
            .BAUD     (115_200),
            .GW       (40),
            .GH       (30),
            .PXS_LOG2 (5),
            .STRIDE   (24),
            .FIRST_MS (1500),
            .GAP_MS   (1000),
            .NDUMP    (3)
        ) u_snap (
            .clk   (clk),
            .rst_n (sys_rst_n),
            .pclk  (cmos_pclk),
            .href  (cmos_href),
            .vsync (cmos_vsync),
            .data  (cmos_data),
            .tx    (snap_tx),
            .busy  (snap_busy)
        );

        // 抓帧时给缩略图，平时给常规统计行（两路不能同时占线）
        assign uart_tx = snap_busy ? snap_tx : rep_tx;
    end else begin : g_no_cam
        assign parking_camera_ready = 0;
        assign cam_status = 3'b000;   // 本分支没有取景链路
        // 摄像头不吃数据：颜色结果恒为"中性、无事件"
        assign cam_color     = 3'd0;
        assign cam_color_evt = 1'b0;
        assign snap_tx       = 1'b1;
        assign snap_busy     = 1'b0;

        // SCCB 与 DVP 输出保持确定电平（SDA 释放，靠外部上拉）
        assign cmos_sclk     = 1'b0;
        assign cmos_sdat_OUT = 1'b0;
        assign cmos_sdat_OE  = 1'b0;

        assign uart_tx = rep_tx;
    end
    endgenerate

    // 不开预览时把屏的 5 根脚全部驱动成确定电平：CS 拉高（不选中）、RST 拉低（屏保持复位）。
    // 不能留空，否则综合认为端口无驱动。开着预览时这五根由 g_lcd 驱动。
    generate
    if (!USE_LCD_PREVIEW) begin : g_no_lcd
        assign lcd_sclk  = 1'b0;
        assign lcd_mosi  = 1'b0;
        assign lcd_dc    = 1'b0;
        assign lcd_rst_n = 1'b0;
        assign lcd_cs_n  = 1'b1;
    end
    endgenerate

    // ------------------------------------------------------------------
    // K230 视觉链路实例化；信号声明放在 car_fsm 之前（见文件前部）
    // ------------------------------------------------------------------
    generate
    if (USE_K230) begin : g_k230
        k230_link #(
            .CLK_FREQ (24_000_000),
            .ALIVE_MS (2000)
        ) u_k230 (
            .clk        (clk),
            .rst_n      (sys_rst_n),
            .k230_d     (k230_d),
            .k230_stb   (k230_stb),
            .color_evt  (k_color),
            .dir_evt    (k_dir),
            .cmd_evt    (k_cmd),
            .link_alive (k_alive),
            .err_cnt    (k_err)
        );
    end else begin : g_no_k230
        // 停用时四个输入都不参与运算，输出打常量保持确定电平
        assign k_color = 4'd0;
        assign k_dir   = 3'd0;
        assign k_cmd   = 8'd0;
        assign k_alive = 1'b0;
        assign k_err   = 8'd0;
    end
    endgenerate

    // 颜色事件统一成「3 位颜色 + 单拍脉冲」，K230 与 OV5640 共用同一个下游。
    // 两者都启用时按位或：两路都空闲时是 0，不会互相干扰。
    wire [2:0] color_in_mux = USE_K230   ? k_color[2:0] : cam_color;
    wire       color_evt_mux = USE_K230  ? (k_color != 4'd0)
                                          : cam_color_evt;

    // ------------------------------------------------------------------
    // 颜色顺序记录（A3.4 / 4.3.3）
    // 颜色来源由 USE_K230 选择：K230（主方案）或 OV5640（退路）。
    // 保留在 generate 之外：它让 color 事件始终有消费者，停用时不留孤立网。
    // ------------------------------------------------------------------
    wire [2:0] seq0, seq1, seq2, seq3;
    wire [2:0] seq_cnt;
    wire       seq_valid;
    wire       seq_full;

    color_seq #(.DEDUP_COLORS(!USE_K230)) u_seq (
        .clk       (clk),
        .rst_n     (sys_rst_n),
        .color_in  (color_in_mux),
        .new_color (color_evt_mux && run_enable),
        .clr       (clear_result),
        .seq0      (seq0),
        .seq1      (seq1),
        .seq2      (seq2),
        .seq3      (seq3),
        .cnt       (seq_cnt),
        .seq_valid (seq_valid),
        .complete  (seq_full)
    );

    // ------------------------------------------------------------------
    // 车载显示：0.96" SSD1306 OLED（USE_OLED 控制）
    // 停用时 I2C 总线整体让出：SCL 置高、SDA 释放，不影响外部器件。
    // 恢复时直接置 USE_OLED=1'b1，管脚约束与接线都不用动。
    // ------------------------------------------------------------------
    // K230 掉线标志：USE_K230=0 时整条链路不存在，不算「掉线」，永不画叉。
    wire k230_off = USE_K230 & ~k_alive;

    generate
    if (USE_OLED) begin : g_oled
        wire oled_busy, oled_ack_err, oled_frame_done, oled_nack_seen;

        oled_driver #(
            .CLK_FREQ   (24_000_000),
            .SCL_FREQ   (400_000),
            .DEV_ADDR   (7'h3C),
            .BOOT_MS    (20),
            .FLASH_MS   (600),
            .ALIVE_MARK (1),
            .OFF_MARK   (1)
        ) u_oled (
            .clk        (clk),
            .rst_n      (sys_rst_n),
            .k230_off   (k230_off),     // 右上角叉号：K230 掉线提示
            .seq_valid  (seq_valid),
            .seq0       (seq0),
            .seq1       (seq1),
            .seq2       (seq2),
            .seq3       (seq3),
            .scl        (i2c_scl),
            .sda_in     (i2c_sda_IN),
            .sda_out    (i2c_sda_OUT),
            .sda_oe     (i2c_sda_OE),
            .busy       (oled_busy),
            .ack_err    (oled_ack_err),
            .frame_done (oled_frame_done),
            .nack_seen  (oled_nack_seen),
            // ---- 屏幕调试区（page1 循迹条 / page6-7 距离+状态+标志）----
            .dbg_dist   (dist_cm),      // 16'hFFFF = 无回波，屏上显示 ---
            .dbg_line   (line_bits),    // bit0 = 车体最左 X1
            .dbg_state  (reported_state),
            .panel_status (panel_status),
            .dbg_obs    (obstacle),
            // 左/右红外模块已从车上卸下，原来的两格改显示转向方向 S
            .dbg_turn   (turn_dir),     // 0 无 / 1 左 / 2 右，与串口 S= 同源
            .dbg_lost   (line_lost)
        );
    end else begin : g_no_oled
        assign i2c_scl     = 1'b1;      // 空闲高
        assign i2c_sda_OUT = 1'b0;
        assign i2c_sda_OE  = 1'b0;      // 释放总线，靠外部 4.7k 上拉
    end
    endgenerate

    // ------------------------------------------------------------------
    // 调试串口：每测一次距离打两行（CH340N，115200-8-N-1）
    //   第 1 行  D=123cm T=00011000 P=+02 O=0 M=01
    //   第 2 行  L=00000123 R=00000123 VL=0005 VR=0005
    // M= 是状态机状态（00 IDLE 01 RUN 02 LOST 03 SEARCH 04 STOP
    //                 05 AVOID_BACK 06 AVOID_TURN 07 AVOID_PROBE）；
    // L=/R= 是左右编码器累计里程（二补码十六进制），标定每米脉冲数时用。
    // ------------------------------------------------------------------
    uart_report #(
        .CLK_FREQ  (24_000_000),
        .BAUD      (115_200),
        .REPORT_EN (1)
    ) u_dbg (
        .clk        (clk),
        .rst_n      (sys_rst_n),
        .dist_cm    (dist_cm),
        .dist_valid (PARKING_DEBUG ? heartbeat[20:0] == 0 : dist_valid),
        .line       (line_bits),
        .raw        (line_raw),
        .pos        (line_pos),
        .corr       (pid_corr),
        // DL=/DR= 必须报"真正送到 PWM 的占空比"。速度环接上以后
        // ctrl_duty_* 只是环前指令，环后还会被 spd_sync 修正；
        // 报环前值会让现场看到的占空比与车轮实际转动对不上。
        .duty_l     (final_duty_l),
        .duty_r     (final_duty_r),
        .wide       (line_wide),
        .turn_dir   (parking_fault ? parking_reverse_fault : turn_dir),
        .obstacle   (parking_fault || (!parking_owner && !finish_owner && obstacle)),
        .state      (reported_state),
        .enc_l      (enc_l_pos),
        .enc_r      (enc_r_pos),
        .spd_l      (spd_l),
        .spd_r      (spd_r),
        .cam_status (cam_status),
        .tx         (rep_tx)
    );

    // ------------------------------------------------------------------
    // 系统心跳（正式工程保留的诊断逻辑，不是演示代码）
    // 为什么必须有：Efinity 对"所有输出都是常量、所有输入悬空"的顶层会报
    //   ERROR : Post-synthesis netlist has only vcc and gnd nets because all
    //   logic is eliminated. Legal, but will cause router to crash. [VDB-9009]
    // ------------------------------------------------------------------
    always @(posedge clk or negedge sys_rst_n)
        if (!sys_rst_n) heartbeat <= 24'd0;
        else            heartbeat <= heartbeat + 1'b1;

    // ------------------------------------------------------------------
    // LED（6 个，低电平点亮）：摄像头与 OLED 停用后，这是板上唯一的现场指示
    //   LED[5]    心跳慢闪（2^23 / 24 MHz ≈ 0.35 s 半周期）
    //   LED[4:2]  状态机状态，二进制直读：001 RUN / 010 LOST / 011 SEARCH / 100 STOP
    //             车停着不动时先看这三个灯，一眼分出"没起跑"和"在找线"
    //   LED[1]    有障碍（超声近距或任一路红外）
    //   LED[0]    全丢线
    // ------------------------------------------------------------------
    assign led = ~{heartbeat[23], reported_state,
                   parking_owner ? parking_slow : obstacle, steering_lost};

endmodule
