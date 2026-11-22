// =============================================================================
// speed_pid.v —— 编码器速度闭环（左右轮同步修正）
// -----------------------------------------------------------------------------
// 【解决什么问题】track_pid 只输出占空比，占空比 → 轮速的换算随电池电压、
// 地面摩擦、电机个体差异漂移。两个电机同样的 600/1200，实际转速可以差一截，
// 车就必然画龙：位置环拼命纠偏，越纠越摆。这一层用编码器实测速度把两轮拉平。
//
// 【为什么是"同步"而不是"绝对速度"】绝对速度环需要一个 占空比→步/窗口 的
// 标定常数，标错就整体跑偏（快了/爬不动）。左右同步只依赖两个编码器的相对
// 读数，不需要标定，接上就是准的 —— 这一层先解决"画龙/摆头"。
//
// 【回退】编码器没接、线松、A/B 相接反导致没脉冲时：只要"有占空比指令但
// 两个窗口都没脉冲"持续 NOENC_WIN 个窗口，就自动置 enc_ok=0 并直通，
// 车退化成原来的开环行为，不会因为缺反馈而停摆。接好脉冲后自动恢复。
//
// 【只在同向时修正】两轮一个正转一个反转（原地转/找线）时速度差没有意义，
// 直接直通，避免把 car_fsm 的转向动作改坏。
// =============================================================================
`timescale 1ns/1ns

module speed_pid #(
    parameter integer DUTY_MAX      = 1200,  // = CLK_FREQ/PWM_FREQ
    parameter integer K_SYNC        = 12,    // 比例：速度差 1 步/窗口 → 12 计数占空比
    parameter integer I_SYNC_SHIFT  = 4,     // 积分右移（Ki = 1/16）
    parameter integer I_SYNC_LIMIT  = 400,   // 积分累加钳位（抗饱和）
    parameter integer SYNC_MAX      = 180,   // 单次修正上限（15% 占空比）
    parameter integer NOENC_WIN     = 20     // 连续多少个窗口没脉冲就判定编码器失效
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              en,             // 0 = 直通（停机/换相死区/非 RUN）
    input  wire signed [15:0] spd_l,         // 每窗口净步数（speed_meter 输出）
    input  wire signed [15:0] spd_r,
    input  wire              valid_l,        // 窗口结束脉冲
    input  wire              valid_r,
    input  wire              dir_l,          // 1=正转（与 pwm 方向脚同义）
    input  wire              dir_r,
    input  wire [10:0]       duty_l_in,      // 来自 car_fsm
    input  wire [10:0]       duty_r_in,
    output reg  [10:0]       duty_l_out,
    output reg  [10:0]       duty_r_out,
    output reg  signed [10:0] sync_corr,     // 本次修正量（正=左轮减速/右轮加速）
    output reg               enc_ok          // 1 = 编码器在出脉冲，闭环生效
);

    // ------------------------------------------------------------------
    // 编码器存活判定
    //   "有指令但两个窗口都数不到脉冲"才累加；车本来停着不算失效。
    // ------------------------------------------------------------------
    reg [15:0] silent_cnt;

    wire win_end  = valid_l | valid_r;
    wire moving   = (duty_l_in != 11'd0) || (duty_r_in != 11'd0);
    wire no_pulse = (spd_l == 16'sd0) && (spd_r == 16'sd0);

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            silent_cnt <= 16'd0;
            enc_ok     <= 1'b0;
        end else if (win_end) begin
            if (!moving || !no_pulse) begin
                silent_cnt <= 16'd0;
                // 数到脉冲就认为编码器有效；没有指令时保持上一次的判断
                if (moving) enc_ok <= 1'b1;
            end else if (silent_cnt >= NOENC_WIN - 1) begin
                silent_cnt <= 16'd0;
                enc_ok     <= 1'b0;
            end else begin
                silent_cnt <= silent_cnt + 16'd1;
            end
        end

    // ------------------------------------------------------------------
    // 同步 PI
    //   差速方向约定：两轮都正转时，左轮慢 = 车头左偏。
    //   左轮比右轮快（diff>0）→ 左轮减速、右轮加速 → 车头回正。
    // ------------------------------------------------------------------
    reg signed [31:0] i_acc;

    wire same_dir = (dir_l == dir_r);
    wire active   = en && enc_ok && same_dir;

    // 17 位有符号差，避免 ±32767 相减溢出
    wire signed [16:0] diff = $signed({spd_l[15], spd_l}) - $signed({spd_r[15], spd_r});

    wire signed [31:0] diff_ext = {{15{diff[16]}}, diff};          // 32 位扩展
    wire signed [31:0] p_term   = diff_ext * K_SYNC;               // 比例
    wire signed [31:0] i_term   = i_acc >>> I_SYNC_SHIFT;          // 积分
    wire signed [31:0] sum_raw  = p_term + i_term;

    wire signed [31:0] lim_pos  = SYNC_MAX;
    wire signed [31:0] lim_neg  = -SYNC_MAX;
    wire signed [31:0] sum_lim  = (sum_raw > lim_pos) ? lim_pos :
                                  (sum_raw < lim_neg) ? lim_neg : sum_raw;

    // 积分累加（只在本层生效时累加，钳位防 windup）
    wire signed [31:0] i_next    = i_acc + diff_ext;
    wire signed [31:0] i_clamped = (i_next >  I_SYNC_LIMIT) ?  I_SYNC_LIMIT :
                                   (i_next < -I_SYNC_LIMIT) ? -I_SYNC_LIMIT : i_next;

    // ------------------------------------------------------------------
    // 修正合成 + 限幅（结果必落 0..DUTY_MAX）
    // ------------------------------------------------------------------
    wire signed [31:0] d_l_raw = $signed({21'd0, duty_l_in}) - sum_lim;
    wire signed [31:0] d_r_raw = $signed({21'd0, duty_r_in}) + sum_lim;

    wire [10:0] d_l_clamped = (d_l_raw < 0)          ? 11'd0 :
                              (d_l_raw > DUTY_MAX)   ? DUTY_MAX[10:0] : d_l_raw[10:0];
    wire [10:0] d_r_clamped = (d_r_raw < 0)          ? 11'd0 :
                              (d_r_raw > DUTY_MAX)   ? DUTY_MAX[10:0] : d_r_raw[10:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_acc      <= 32'sd0;
            duty_l_out <= 11'd0;
            duty_r_out <= 11'd0;
            sync_corr  <= 11'sd0;
        end else if (!en) begin
            // 直通：积分清零，避免换相/停机后带着旧修正启动
            i_acc      <= 32'sd0;
            duty_l_out <= duty_l_in;
            duty_r_out <= duty_r_in;
            sync_corr  <= 11'sd0;
        end else if (win_end) begin
            if (active) begin
                i_acc      <= i_clamped;
                duty_l_out <= d_l_clamped;
                duty_r_out <= d_r_clamped;
                // 截到 11 位有符号，供串口/O LED 观察
                sync_corr  <= sum_lim[10:0];
            end else begin
                // 编码器失效或两轮反向：不修正，保持直通
                i_acc      <= 32'sd0;
                duty_l_out <= duty_l_in;
                duty_r_out <= duty_r_in;
                sync_corr  <= 11'sd0;
            end
        end else begin
            // 窗口之间保持上一拍的输出（避免 duty 抖动到 PWM 上）
            duty_l_out <= duty_l_out;
            duty_r_out <= duty_r_out;
        end
    end

endmodule
