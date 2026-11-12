// =============================================================================
// track_pid.v —— 循迹 PID（只用位置误差，不做全状态反馈）
// -----------------------------------------------------------------------------
// 【输入】track_line 的 pos：-7 最左 … 0 正中 … +7 最右（二补码）。
// 【输出】左右轮占空比差动：pos>0（线在右）→ 右转 → 左轮快、右轮慢。
//
// 【为什么要定点而不是浮点】FPGA 上没有浮点；这里全部用整数 + 移位：
//   corr = pos*P_GAIN + (i_acc >> I_SHIFT) + (pos-pos_d)*D_GAIN
//   duty_l = BASE + corr,  duty_r = BASE - corr,  corr 限制在 ±BASE
// 这样 duty 永远落在 0..2*BASE，两轮都不会出现负占空比（反向由 car_fsm 负责）。
//
// 【积分抗饱和】i_acc 在累加时直接钳位在 ±I_LIMIT，不在输出处钳位 ——
// 输出处钳位会让积分在饱和期间继续增长（经典 windup），倒车时"冲出去"。
//
// 【为什么丢线时保持而不是清零】丢线瞬间清 corr 会让车立刻回正直行，通常直接
// 冲出赛道；保持最后一刻的转向更接近人工操作，car_fsm 会在保持超时后进入找线。
// =============================================================================
`timescale 1ns/1ns

module track_pid #(
    parameter integer CLK_FREQ   = 24_000_000,
    parameter integer TICK_MS    = 10,        // 控制周期（100 Hz）
    parameter integer DUTY_MAX   = 1200,      // = CLK_FREQ/PWM_FREQ
    parameter integer BASE_DUTY  = 600,       // 直行占空比（50%）
    parameter integer P_GAIN     = 40,        // 比例：pos=7 → 280 计数（23% duty）
    parameter integer D_GAIN     = 24,        // 微分：pos 突变 1 格 → 24 计数
    parameter integer I_SHIFT    = 5,         // 积分右移（相当于 Ki = 1/32）
    parameter integer I_LIMIT    = 640         // 积分累加上限（抗饱和）
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

    wire signed [15:0] err   = {{11{pos[4]}}, pos};
    wire signed [15:0] err_d = err - {{11{pos_d[4]}}, pos_d};

    // 各项（全部 16 位有符号）
    wire signed [15:0] p_term = err   * P_GAIN;
    wire signed [15:0] d_term = err_d * D_GAIN;
    wire signed [15:0] i_term = i_acc >>> I_SHIFT;

    wire signed [15:0] sum_raw = p_term + i_term + d_term;

    // 限幅到 ±BASE_DUTY：保证 duty_l/duty_r 落在 0..DUTY_MAX
    wire signed [15:0] lim_pos = BASE_DUTY;
    wire signed [15:0] lim_neg = -BASE_DUTY;
    wire signed [15:0] sum_lim = (sum_raw > lim_pos) ? lim_pos :
                                 (sum_raw < lim_neg) ? lim_neg : sum_raw;

    // 积分累加（钳位防 windup）
    wire signed [15:0] i_next = i_acc + err;
    wire signed [15:0] i_clamped = (i_next >  I_LIMIT) ?  I_LIMIT :
                                   (i_next < -I_LIMIT) ? -I_LIMIT : i_next;

    // 占空比合成（结果必在 0..DUTY_MAX，无需再钳位）
    wire signed [15:0] d_l = BASE_DUTY + sum_lim;
    wire signed [15:0] d_r = BASE_DUTY - sum_lim;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pos_d  <= 5'sd0;
            i_acc  <= 16'sd0;
            duty_l <= 11'd0;
            duty_r <= 11'd0;
            corr   <= 11'sd0;
        end else if (!en) begin
            // 停机：输出清零、积分复位（避免下次启动带来残留转向）
            pos_d  <= pos;
            i_acc  <= 16'sd0;
            duty_l <= 11'd0;
            duty_r <= 11'd0;
            corr   <= 11'sd0;
        end else if (tick) begin
            pos_d <= pos;

            if (lost) begin
                // 丢线：保持上一拍的转向量，只把积分冻住
                duty_l <= duty_l;
                duty_r <= duty_r;
                corr   <= corr;
            end else begin
                if (on_line)
                    i_acc <= i_clamped;
                duty_l <= d_l[10:0];
                duty_r <= d_r[10:0];
                corr   <= sum_lim[10:0];
            end
        end
    end

endmodule
