// =============================================================================
// FpgaCar.v —— 第十四届"星火杯"赛题二 智能小车 / Ti60F225 顶层
// -----------------------------------------------------------------------------
// 器件  : Efinix Titanium Ti60F225 (C4)，Efinity 2026.1
// 时钟  : 24 MHz 有源晶振 -> GPIOL_11（3.3 V LVCMOS input）
//
// 【当前配置：OV5640 链路整体停用】见下面 USE_CAMERA / USE_OLED 两个开关。
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

module FpgaCar (

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
    localparam USE_K230   = 1'b1;

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

    wire              ctrl_en;
    wire              ctrl_dir_l, ctrl_dir_r;
    wire [10:0]       ctrl_duty_l, ctrl_duty_r;
    wire [10:0]       pid_duty_l, pid_duty_r;
    wire signed [10:0] pid_corr;
    wire [2:0]        car_state;                     // 0 IDLE 1 RUN 2 LOST 3 SEARCH 4 STOP
    wire [1:0]        panel_status;
    wire              run_enable, clear_result;
    wire              motion_rst_n = sys_rst_n && run_enable;
    wire [2:0]        reported_state = (panel_status == 2'd2) ? 3'd4 : car_state;

    wire        motor_en = motion_rst_n && (PWM_BENCH_TEST || ctrl_en);
    wire [10:0] ml_duty  = PWM_BENCH_TEST ? BENCH_DUTY : ctrl_duty_l;
    wire [10:0] mr_duty  = PWM_BENCH_TEST ? BENCH_DUTY : ctrl_duty_r;

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
    // 八路循迹采样 + 加权质心
    // ACTIVE_HIGH=0：TCRT5000 + LM393 模块的常见极性（压黑线输出低）。
    // ------------------------------------------------------------------
    wire [7:0]  line_bits;
    wire [7:0]  line_raw;      // 消抖后的原始电平（未按 ACTIVE_HIGH 取反）
    wire [3:0]  line_cnt;
    wire        line_on, line_lost;
    wire        line_wide;     // 宽黑判定（影子防护），串口 W= 字段显示
    wire signed [4:0] line_pos;

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
    localparam [15:0] OBSTACLE_CM = 16'd25;    // 刹车/绕行阈值，实测后调

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
    localparam USE_ULTRA = 1'b1;

    wire hc_near  = (dist_cm != 16'hFFFF) && (dist_cm <= OBSTACLE_CM);
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
    track_pid #(
        .CLK_FREQ  (24_000_000),
        .TICK_MS   (10),
        .DUTY_MAX  (1200),
        .BASE_DUTY (600),
        .P_GAIN    (72),
        .D_GAIN    (40),
        .I_SHIFT   (5),
        .I_LIMIT   (640)
    ) u_pid (
        .clk     (clk),
        .rst_n   (motion_rst_n),
        .en      (ctrl_en),
        .pos     (line_pos),
        .on_line (line_on),
        .lost    (line_lost),
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
    wire [7:0] k_cmd;                   // bit0=清空顺序 bit1=新一圈
    wire       k_alive;                 // 2 s 内收到过合法消息
    wire [7:0] k_err;                   // 协议异常计数，OLED 诊断用

    wire [2:0] dir_evt_mux = USE_K230 ? k_dir : 3'd0;   // K230 停用时恒 0，转向走 car_fsm 的拐角兜底
    wire [1:0] turn_dir;                                // 最近一次转向方向（0 无 1 左 2 右），串口 S= 用

    car_panel u_panel (
        .clk            (clk),
        .rst_n          (sys_rst_n),
        .key_start_n    (key_start_n),
        .key_stop_n     (key_stop_n),
        .line_ready     (line_on && !line_lost),
        .motion_stopped (car_state == 3'd4 || (car_state == 3'd0 && line_lost)),
        .run_enable     (run_enable),
        .clear_result   (clear_result),
        .status         (panel_status)
    );

    car_fsm #(
        .CLK_FREQ     (24_000_000),
        .START_MS     (1),           // K1 已确认；状态机再确认一次压线启动
        .LOST_HOLD_MS (300),
        .SEARCH_MS    (1500),
        .SEARCH_DUTY  (500),
        .SEARCH_FAIL_TO_IDLE (0),    // 找线失败后由按键面板锁停
        .DIR_DEAD_MS  (10),
        .TURN_MS      (700),
        .TURN_WAIT_FOR_CORNER (USE_K230),
        .TURN_DUTY    (700),
        // 现场初值：先让车驶到障碍侧边，再摆正超越，最后低速斜切回线。
        .AVOID_EN         (1),
        .AVOID_ROUTE_EN   (1),
        .AVOID_FIXED_RIGHT (1),
        .AVOID_BACK_MS    (400),
        .AVOID_BACK_DUTY  (500),
        .AVOID_TURN_MS    (600),
        .AVOID_TURN_DUTY  (600),
        .AVOID_PROBE_MS   (550),
        .AVOID_PROBE_DUTY (450),
        .AVOID_PASS_MS    (900),
        .AVOID_REJOIN_MS  (1200),
        .AVOID_REJOIN_DUTY (400),
        .AVOID_LINE_MS    (20),
        .AVOID_BLOCK_MS   (250),
        // 转向指示（串口 S= / OLED 左转右转格）保持 1500 ms 后自动熄灭。
        // 保持太短 OLED 每 100 ms 采样一次抓不到；太长直道上也显示"正在转弯"。
        .TURN_DIR_HOLD_MS (1500)
    ) u_car (
        .clk      (clk),
        .rst_n    (motion_rst_n),
        .on_line  (line_on),
        .lost     (line_lost),
        .obstacle (obstacle),
        .wide     (line_wide),
        .turn_dir (turn_dir),
        .pos      (line_pos),
        .dir_evt  (dir_evt_mux),    // 交通牌方向：K230 提供，停用时恒 0
        .pid_l    (pid_duty_l),
        .pid_r    (pid_duty_r),
        .en       (ctrl_en),
        .dir_l    (ctrl_dir_l),
        .dir_r    (ctrl_dir_r),
        .duty_l   (ctrl_duty_l),
        .duty_r   (ctrl_duty_r),
        .state    (car_state)
    );

    // TB6612 方向脚：使能时才驱动，且 IN1/IN2 永不同时为 1（否则短路刹车）
    assign ml_in1     = motor_en & (PWM_BENCH_TEST |  ctrl_dir_l);
    assign ml_in2     = motor_en & (~PWM_BENCH_TEST & ~ctrl_dir_l);
    assign mr_in1     = motor_en & (~PWM_BENCH_TEST &  ctrl_dir_r);
    assign mr_in2     = motor_en & (~PWM_BENCH_TEST & ~ctrl_dir_r);
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

    generate
    if (USE_CAMERA) begin : g_cam
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
        .dist_valid (dist_valid),
        .line       (line_bits),
        .raw        (line_raw),
        .pos        (line_pos),
        .corr       (pid_corr),
        .duty_l     (ctrl_duty_l),
        .duty_r     (ctrl_duty_r),
        .wide       (line_wide),
        .turn_dir   (turn_dir),
        .obstacle   (obstacle),
        .state      (reported_state),
        .enc_l      (enc_l_pos),
        .enc_r      (enc_r_pos),
        .spd_l      (spd_l),
        .spd_r      (spd_r),
        .tx         (rep_tx)
    );

    // ------------------------------------------------------------------
    // 系统心跳（正式工程保留的诊断逻辑，不是演示代码）
    // 为什么必须有：Efinity 对"所有输出都是常量、所有输入悬空"的顶层会报
    //   ERROR : Post-synthesis netlist has only vcc and gnd nets because all
    //   logic is eliminated. Legal, but will cause router to crash. [VDB-9009]
    // ------------------------------------------------------------------
    reg [23:0] heartbeat;

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
    assign led = ~{heartbeat[23], reported_state, obstacle, line_lost};

endmodule
