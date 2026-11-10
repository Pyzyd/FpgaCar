// =============================================================================
// track_line.v —— 八路循迹采样 + 加权质心 + 丢线判定（YB-MUX04）
// -----------------------------------------------------------------------------
// 输入 track[7:0] 是 YB-MUX04 的 X1~X8 数字量（已经在底板 TXS0108E 上转成 3.3V，
// 进 FPGA 是 1.8V）。8 个探头按车头方向从左到右排开，间距约 10~12 mm，
// 1~2 cm 宽的黑色循迹线通常只压住 1~3 个探头。
//
// 【极性】不同厂家/不同电位器调法，输出可能是"压黑线=1"也可能是"压黑线=0"。
// 这里用参数 ACTIVE_HIGH 统一：
//   ACTIVE_HIGH = 1 : 原始高电平 = 压线
//   ACTIVE_HIGH = 0 : 原始低电平 = 压线（TCRT5000 + LM393 模块最常见）
// 上板时先看串口打的 T= 位串，白纸上推车让黑线从左侧走到右侧，
// 位串里那个"1"应该从 bit7 走到 bit0（或反过来），据此确定极性再改参数。
//
// 【位置编码】权重取 -7,-5,-3,-1,+1,+3,+5,+7（i*2-7），加权平均后得到 [-7,+7]：
//     +  表示线在车体右侧  → PID 应让车右转
//     -  表示线在车体左侧
//   用"加权平均"而不是"最中间那个探头"：线宽 1~3 个探头时输出连续，PID 不会阶梯跳变。
//   归一化用倒数查表（1024/n 再右移 10 位），不推断除法器。
//
// 【消抖】1 ms 采样一次，连续 4 次一致才认账。红外探头在黑白交界处会抖，
// 不消抖会让 PID 微分项炸掉。
// =============================================================================
`timescale 1ns/1ns

module track_line #(
    parameter integer CLK_FREQ    = 24_000_000,
    parameter integer SAMPLE_KHZ  = 1_000,     // 采样率（消抖节拍）
    parameter integer DEBOUNCE_N  = 4,         // 连续一致次数
    parameter         ACTIVE_HIGH = 0          // 1=高电平压线，0=低电平压线
) (
    input  wire        clk,
    input  wire        rst_n,      // 低有效（已同步化）
    input  wire [7:0]  track,      // 原始八路
    output reg  [7:0]  line,       // 极性统一后：1 = 该探头压线
    output reg  [3:0]  cnt,        // 压线探头个数 0~8
    output reg         on_line,    // cnt > 0
    output reg         lost,       // cnt == 0（全丢线：该减速/找线）
    output reg  signed [4:0] pos   // 线位置，-7 最左 … 0 正中 … +7 最右（二补码）
);

    // ------------------------------------------------------------------
    // 采样节拍
    // ------------------------------------------------------------------
    localparam integer TICK_RAW = CLK_FREQ / (SAMPLE_KHZ * 1000);
    localparam integer TICK     = (TICK_RAW < 1) ? 1 : TICK_RAW;   // 24 MHz/1 kHz = 24000

    reg [15:0] tick_cnt;
    reg        tick;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            tick_cnt <= 16'd0;
            tick     <= 1'b0;
        end else if (tick_cnt >= TICK - 1) begin
            tick_cnt <= 16'd0;
            tick     <= 1'b1;
        end else begin
            tick_cnt <= tick_cnt + 16'd1;
            tick     <= 1'b0;
        end

    // ------------------------------------------------------------------
    // 八路异步输入同步 + 消抖（连续 DEBOUNCE_N 次一致才更新）
    // ------------------------------------------------------------------
    reg [7:0] trk_s1, trk_s2;          // 两级同步
    reg [7:0] dbuf [0:3];              // 最近 4 次采样
    reg [7:0] trk_stable;              // 消抖后原始电平

    integer k;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            trk_s1     <= 8'h00;
            trk_s2     <= 8'h00;
            trk_stable <= 8'h00;
            for (k = 0; k < 4; k = k + 1) dbuf[k] <= 8'h00;
        end else begin
            trk_s1 <= track;
            trk_s2 <= trk_s1;
            if (tick) begin
                for (k = 3; k > 0; k = k - 1) dbuf[k] <= dbuf[k-1];
                dbuf[0] <= trk_s2;
                // 4 次采样全部相同才认
                if (dbuf[0] == trk_s2 && dbuf[1] == trk_s2 &&
                    dbuf[2] == trk_s2 && dbuf[3] == trk_s2)
                    trk_stable <= trk_s2;
            end
        end

    // ------------------------------------------------------------------
    // 极性统一 + 加权质心
    // ------------------------------------------------------------------
    always @(*) begin
        line = ACTIVE_HIGH ? trk_stable : ~trk_stable;
    end

    // 权重：i=0..7 -> -7,-5,-3,-1,+1,+3,+5,+7
    // 左边(0..3)幅值 7,5,3,1；右边(4..7)幅值 1,3,5,7
    wire [4:0] mag_left  = (line[0] ? 5'd7 : 5'd0) + (line[1] ? 5'd5 : 5'd0)
                         + (line[2] ? 5'd3 : 5'd0) + (line[3] ? 5'd1 : 5'd0);
    wire [4:0] mag_right = (line[4] ? 5'd1 : 5'd0) + (line[5] ? 5'd3 : 5'd0)
                         + (line[6] ? 5'd5 : 5'd0) + (line[7] ? 5'd7 : 5'd0);

    wire [4:0] cnt_w = (line[0]?5'd1:5'd0) + (line[1]?5'd1:5'd0)
                     + (line[2]?5'd1:5'd0) + (line[3]?5'd1:5'd0)
                     + (line[4]?5'd1:5'd0) + (line[5]?5'd1:5'd0)
                     + (line[6]?5'd1:5'd0) + (line[7]?5'd1:5'd0);

    // 有符号和：右正左负，范围 -16..+16
    wire signed [5:0] wsum = $signed({1'b0, mag_right}) - $signed({1'b0, mag_left});

    // |wsum|
    wire [5:0] wabs = wsum[5] ? (~wsum + 6'd1) : wsum;

    // 1024/n 倒数表（n = 1..8），归一化用，避免除法器
    reg [10:0] recip;
    always @(*) begin
        case (cnt_w)
            5'd1: recip = 11'd1024;
            5'd2: recip = 11'd512;
            5'd3: recip = 11'd341;
            5'd4: recip = 11'd256;
            5'd5: recip = 11'd204;
            5'd6: recip = 11'd170;
            5'd7: recip = 11'd146;
            5'd8: recip = 11'd128;
            default: recip = 11'd0;
        endcase
    end

    // pos = |wsum| * (1024/n) >> 10  ，再补符号
    // 加 512 做四舍五入：否则 (5+3+1)/3=3 会被截断成 2，PID 会有系统性偏置
    wire [16:0] prod = wabs * recip + 17'd512;
    wire [6:0]  pmag = prod >> 10;             // 0..16

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            cnt     <= 4'd0;
            on_line <= 1'b0;
            lost    <= 1'b1;
            pos     <= 5'sd0;
        end else begin
            cnt     <= cnt_w[3:0];
            on_line <= (cnt_w != 5'd0);
            lost    <= (cnt_w == 5'd0);
            if (cnt_w == 5'd0)
                pos <= 5'sd0;                   // 丢线时位置输出 0，由 lost 标志决定策略
            else if (wsum[5])
                pos <= -$signed({1'b0, pmag[4:0]});   // 左负
            else
                pos <=  $signed({1'b0, pmag[4:0]});   // 右正
        end

endmodule
