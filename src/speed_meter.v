// =============================================================================
// speed_meter.v —— 编码器测速（固定窗口内数脉冲）
// -----------------------------------------------------------------------------
// 【为什么不用"测周期"法】低速时测周期法要求很高的计时分辨率；而我们只需要
// 一个能进 PID 的粗速度量（分辨率 ±1 pulse/窗口），数脉冲法最简单、无除法。
//
// 【单位】speed = 每 WIN_MS 毫秒内的**净步数**（带方向）。20 线编码器、50 ms 窗口时：
//   100 mm/s 左右的小车大约每 50 ms 走 1~3 个脉冲 → 分辨率够做趋势判断。
//   要换成"步/秒"只需把 WIN_MS 改成 1000，或在上层乘 1000/WIN_MS。
// =============================================================================
`timescale 1ns/1ns

module speed_meter #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer WIN_MS   = 50          // 统计窗口（毫秒）
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              step,           // 编码器走一格（1 clk 脉冲）
    input  wire              dir,            // 1 = 正转
    output reg  signed [15:0] speed,         // 每窗口净步数
    output reg                valid          // 每窗口一个 clk 脉冲
);

    localparam integer WIN_CYC = (CLK_FREQ / 1000) * WIN_MS;

    reg [31:0]        cnt;
    reg signed [15:0] acc;

    wire signed [15:0] acc_inc = acc + 16'sd1;
    wire signed [15:0] acc_dec = acc - 16'sd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt   <= 32'd0;
            acc   <= 16'sd0;
            speed <= 16'sd0;
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;

            // 累加：正向加、反向减（饱和，不翻转）
            if (step) begin
                if (dir) acc <= (acc == 16'sh7FFF) ? acc : acc_inc;
                else     acc <= (acc == 16'sh8000) ? acc : acc_dec;
            end

            // 窗口结束：锁存并清零
            if (cnt >= WIN_CYC - 1) begin
                cnt   <= 32'd0;
                speed <= acc;
                acc   <= 16'sd0;
                valid <= 1'b1;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end

endmodule
