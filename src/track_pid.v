// =============================================================================
// track_pid.v —— 循迹 PID（只用位置误差，不做全状态反馈）
// -----------------------------------------------------------------------------
// 【输入】track_line 的 pos：-7 最左 … 0 正中 … +7 最右（二补码）。
// 【输出】左右轮占空比差动：pos>0（线在右）→ 右转 → 左轮快、右轮慢。
//
// 【为什么要定点而不是浮点】FPGA 上没有浮点；这里全部用整数 + 移位：
//   corr = TRIM + pos*P_GAIN + (i_acc >> I_SHIFT) + d_term
//   d_term = 低通(pos - pos_d) * D_GAIN          （一阶 IIR，见下）
//   duty_l = BASE + corr,  duty_r = BASE - corr,  corr 限制在 ±BASE
// 这样 duty 永远落在 0..2*BASE，两轮都不会出现负占空比（反向由 car_fsm 负责）。
//
// 【2026-11-25 B 方案：D 项加低通 + corr 加变化率限制】
//   ① D 项原来直接对量化后的 pos（分辨率 1 格）做差分，1 格抖动就打
//      D_GAIN 计数，实际是"对传感器跳变做功"而不是对车的角速度做功。
//      现在先过一阶 IIR：d_filt += (d_raw - d_filt) >>> D_FILT_SHIFT，
//      内部按 Q(D_Q=2) 定点保存，保证能收敛到 0（直接对整数滤波会卡在 ±1
//      残差上，d_term 就会留下一个恒定的 D_GAIN 偏置）。
//      D_FILT_SHIFT=0 表示关闭滤波（退回旧行为）。
//   ② corr 每控制周期最多变化 SLEW_STEP 个计数：避免 pos 一跳就把差速从
//      0 拉到满量程（TB6612 电流尖峰 + 机械甩头）。代价是约 1~2 拍滞后。
//      SLEW_STEP=0 表示关闭。
//   ③ I_LIMIT 现在按"实际权限"来理解：积分输出上限 = I_LIMIT>>I_SHIFT。
//      顶层给 192/5 → 只有 ±6 计数，等于明确承认本环是「PD + TRIM 前馈」，
//      积分只吸收 1~2 格量化残差，不再假装能抵消 112 计数的轮速差。
//
// 【积分抗饱和】i_acc 在累加时直接钳位在 ±I_LIMIT，不在输出处钳位 ——
// 输出处钳位会让积分在饱和期间继续增长（经典 windup），倒车时"冲出去"。
//
// 【为什么丢线时保持而不是清零】丢线瞬间清 corr 会让车立刻回正直行，通常直接
// 冲出赛道；保持最后一刻的转向更接近人工操作，car_fsm 会在保持超时后进入找线。
//
// 【TRIM 前馈：为什么必须有】本车的两个电机/轮系效率不相等（实测右轮约只有
// 左轮的 0.55，见 PROJECT_PLAN §3.50）。差速车要跑直线，并不是"两轮占空比相等"，
// 而是"两轮线速度相等"，对 K_R≈0.55·K_L 就必须让右轮占空比高约 1.82 倍：
//   K_L·(BASE+c) = K_R·(BASE-c)  →  c = -BASE·(1-0.55)/(1+0.55) ≈ -140
// 这 140 的偏置原来想让积分自己去凑，但 I_LIMIT>>I_SHIFT 只有 20 的权限，
// 而且积分每拍只加 pos（±1 量级），要从 0 爬到 140 需要几千拍 —— 实际上永远
// 爬不上去。结果是控制器只能靠"故意把 pos 停在 -1"这种偏置去凑出 -120，
// C= 就僵在 -140 附近，pos 一跳到 -3 就变成 -380，工作点卡在悬崖边上。
// 把这段静态偏置做成前馈 TRIM，积分就只剩"补残差"的活，可以被清干净。
// 实车上板后如果发现直道仍朝一侧偏，就先调 TRIM（±40 以内），再动 P/D。
// =============================================================================
`timescale 1ns/1ns

module track_pid #(
    parameter integer CLK_FREQ   = 24_000_000,
    parameter integer TICK_MS    = 10,        // 控制周期（100 Hz）
    parameter integer DUTY_MAX   = 1200,      // = CLK_FREQ/PWM_FREQ
    parameter integer BASE_DUTY  = 600,       // 直行占空比默认值（50%）；顶层实际传
                                              // TRACK_BASE_DUTY=384（32%，2026-11-25 降速后），
                                              // 见 src/FpgaCar.v；单测 track_pid_tb 仍按默认 600 断言
    parameter integer P_GAIN     = 72,        // 比例：pos=7 → 504 计数（42% duty）
    parameter integer D_GAIN     = 40,        // 微分：pos 突变 1 格 → 40 计数
    parameter integer I_SHIFT    = 5,         // 积分右移（相当于 Ki = 1/32）
    parameter integer I_LIMIT    = 192,       // 积分累加上限（输出权限 = I_LIMIT>>I_SHIFT = ±6）
    parameter integer D_FILT_SHIFT = 2,       // D 项一阶低通系数：α=1/4；0 = 关闭
    parameter integer SLEW_STEP  = 64,        // corr 每控制周期最大变化量；0 = 关闭
    parameter integer TRIM       = 0           // 前馈偏置（抵消两轮效率差，见文件头）
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              en,              // 0 = 停机（输出 0、清积分）
    input  wire signed [4:0] pos,             // 线位置
    input  wire              on_line,         // 有压线探头
    input  wire              lost,            // 全丢线
    output reg  [10:0]       duty_l,
    output reg  [10:0]       duty_r,
    output reg  signed [10:0] corr            // 转向修正量（供串口/LED 观察）
);

    localparam integer TICK_CYC = (CLK_FREQ / 1000) * TICK_MS;

    // ---------------- 控制节拍 ----------------
    reg [31:0] tick_cnt;
    wire       tick = (tick_cnt >= TICK_CYC - 1);

    always @(posedge clk or negedge rst_n)
        if (!rst_n)      tick_cnt <= 32'd0;
        else if (tick)   tick_cnt <= 32'd0;
        else             tick_cnt <= tick_cnt + 32'd1;

    // ---------------- 误差寄存器 ----------------
    reg signed [4:0]  pos_d;
    reg signed [15:0] i_acc;
    reg signed [15:0] d_filt;      // D 项一阶低通状态，Q(D_Q) 定点
    reg               lost_d;      // 上一拍的丢线状态

    localparam integer D_Q = 2;    // d_filt 的小数位数（放大 4 倍，保证能收敛到 0）

    wire signed [15:0] err   = {{11{pos[4]}}, pos};

    // 【重新压线时屏蔽 D 项】track_line 在丢线期间把 pos 强制拉 0。如果这里仍按
    // 每拍更新 pos_d，丢线期间 pos_d 就会被拖到 0；重新压线那一拍 err_d 突变成
    // 5~7 格，D 项直接打出 200~280 计数（≈20% 占空比）的尖峰，车会猛甩一下。
    // 处理：丢线时冻结 pos_d（见下面的时序块），并在恢复后的第一拍把 D 项清零。
    wire signed [15:0] err_d = lost_d ? 16'sd0 :
                               (err - {{11{pos_d[4]}}, pos_d});

    // D 项一阶低通。注意必须先把 d_raw 放大 2^D_Q 倍再滤：
    // 直接对整数做 d += (raw-d)>>2 会卡在 ±1 残差上，d_term 就留下一个恒定的
    // D_GAIN 偏置（24 计数 ≈ 2% 占空比），比积分权限还大。
    wire signed [15:0] d_raw_q = err_d <<< D_Q;
    wire signed [15:0] d_next  = d_filt + ((d_raw_q - d_filt) >>> D_FILT_SHIFT);

    // 各项（全部 16 位有符号）
    //  f_term 是前馈偏置：整数赋给 16 位 signed wire 会自动符号扩展，
    //  TRIM=-140 得到 16'shFF74，与 p/i/d 直接相加即可。
    wire signed [15:0] f_term = TRIM;
    wire signed [15:0] p_term = err   * P_GAIN;
    wire signed [15:0] d_term = (d_filt * D_GAIN) >>> D_Q;   // 乘完再降回原量纲
    wire signed [15:0] i_term = i_acc >>> I_SHIFT;

    // 前馈放在钳位之前：这样 TRIM 占掉的那部分量程不会再被 ±BASE 削掉，
    // 单侧最大修正仍是 BASE（dl 最极端为 0，dr 最极端为 2*BASE）。
    wire signed [15:0] sum_raw = f_term + p_term + i_term + d_term;

    // 限幅到 ±BASE_DUTY：保证 duty_l/duty_r 落在 0..DUTY_MAX
    wire signed [15:0] lim_pos = BASE_DUTY;
    wire signed [15:0] lim_neg = -BASE_DUTY;
    wire signed [15:0] sum_lim = (sum_raw > lim_pos) ? lim_pos :
                                 (sum_raw < lim_neg) ? lim_neg : sum_raw;

    // 【变化率限制】corr 每拍最多朝目标挪 SLEW_STEP。基准是上一拍真正的下发值 corr，
    // 所以丢线保持期间(不下发)恢复后也会从这里继续，不会因为"攒了 20 拍"而跳变。
    // SLEW_STEP=0 时下级完全旁路（常量比较，综合成直连）。
    wire signed [15:0] slew_hi = corr + SLEW_STEP;
    wire signed [15:0] slew_lo = corr - SLEW_STEP;
    wire signed [15:0] sum_app = (SLEW_STEP == 0)     ? sum_lim :
                                 (sum_lim > slew_hi)  ? slew_hi :
                                 (sum_lim < slew_lo)  ? slew_lo : sum_lim;

    // 积分累加（钳位防 windup）
    wire signed [15:0] i_next = i_acc + err;
    wire signed [15:0] i_clamped = (i_next >  I_LIMIT) ?  I_LIMIT :
                                   (i_next < -I_LIMIT) ? -I_LIMIT : i_next;

    // 占空比合成（结果必在 0..DUTY_MAX，无需再钳位）
    wire signed [15:0] d_l = BASE_DUTY + sum_app;
    wire signed [15:0] d_r = BASE_DUTY - sum_app;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pos_d  <= 5'sd0;
            i_acc  <= 16'sd0;
            d_filt <= 16'sd0;
            lost_d <= 1'b0;
            duty_l <= 11'd0;
            duty_r <= 11'd0;
            corr   <= 11'sd0;
        end else if (!en) begin
            // 停机：输出清零、积分复位（避免下次启动带来残留转向）
            pos_d  <= pos;
            i_acc  <= 16'sd0;
            d_filt <= 16'sd0;      // D 低通状态也清：重启不许带着上一段的微分
            lost_d <= 1'b0;
            duty_l <= 11'd0;
            duty_r <= 11'd0;
            corr   <= 11'sd0;
        end else if (tick) begin
            lost_d <= lost;
            // 低通每拍都推进：丢线时 err_d 被屏蔽成 0，d_filt 自然朝 0 衰减，
            // 重新压线那一刻不会带着丢线前的微分值。
            d_filt <= d_next;

            if (lost) begin
                // 丢线：保持上一拍的转向量，冻结积分，pos_d 也一起冻结
                // （pos_d 若跟着被清零的 pos 走，重新压线时会打出 D 尖峰）
                duty_l <= duty_l;
                duty_r <= duty_r;
                corr   <= corr;
            end else begin
                pos_d <= pos;
                if (on_line)
                    i_acc <= i_clamped;
                duty_l <= d_l[10:0];
                duty_r <= d_r[10:0];
                corr   <= sum_app[10:0];
            end
        end
    end

endmodule
