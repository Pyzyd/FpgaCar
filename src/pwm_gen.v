// =============================================================================
// pwm_gen.v —— 多通道 PWM 发生器（TB6612FNG 调速用）
// -----------------------------------------------------------------------------
// 功能：把 0~100 的占空比（0=停, 100=全速）变成 20 kHz PWM 波形。
//
// 设计取舍：
//   * 频率选 20 kHz：远超电机人耳可听抖动区（避啸叫），TB6612FNG PWM 输入
//     上限 100 kHz，余量充足；24 MHz / 20 kHz = 1200 计数，8 位分辨率内插值容易。
//   * 用 0~1200 计数、按 duty*12 线性展开，比 0~255/256 更能精确表达
//     duty=100 时满占空比（256 方案 255/256 永远缺一格）。
//   * 输出带 enable 门控：en=0 时恒 0，避免"duty 寄存器还有残值、电机就转"。
//
// 端口全部 24 MHz clk 域同步输入；duty/10bit 定点（0~1200），外部 PID 模块
// 直接写此数值即可（1 个 LSB ≈ 0.083% 占空比）。
// =============================================================================
`timescale 1ns/1ns

module pwm_gen #(
    parameter integer CLK_FREQ  = 24_000_000,   // 输入时钟 Hz
    parameter integer PWM_FREQ  = 20_000        // PWM 输出频率 Hz
) (
    input  wire        clk,        // 24 MHz
    input  wire        rst_n,      // 低有效（已同步化的系统复位）
    input  wire        en,         // 1=输出 PWM，0=强制低（安全）
    input  wire [10:0] duty,       // 0~[CLK_FREQ/PWM_FREQ]，线性占空比
    output wire        pwm         // PWM 输出（到 TB6612 xxPWM 脚）
);

    // 计数周期 = CLK_FREQ / PWM_FREQ = 1200（11 位正好覆盖）
    localparam integer CNT_MAX = CLK_FREQ / PWM_FREQ;   // 1200

    reg [10:0] cnt;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)                     cnt <= 11'd0;
        else if (cnt >= CNT_MAX - 1)    cnt <= 11'd0;
        else                            cnt <= cnt + 1'b1;

    // 占空比比较：cnt < duty 则输出高
    // duty >= CNT_MAX 视作 100% 直通（饱和保护，防止 PID 爆表后炸管）
    wire cmp = (cnt < duty) | (duty > CNT_MAX[10:0] - 1);

    assign pwm = en & cmp;

endmodule
