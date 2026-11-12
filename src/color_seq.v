// =============================================================================
// color_seq.v —— 颜色出现顺序记录（4 个槽，先到先得，自动去重）
// -----------------------------------------------------------------------------
// 细则 4.3.3 / 5.1：小车要在识别区读出「4 个色块出现的先后顺序」，并把顺序
// 持续显示在车载屏上供裁判拍照。color_detect 每帧只给一个「本帧占比最大的
// 颜色」（color + new_color 单拍脉冲），并不知道顺序；本模块就是那层记忆：
//
//   · 收到 new_color 且颜色非 0（0 = 中性/无色）时，若该颜色还没记过，
//     就填进下一个空槽 —— 槽号 = 出现次序，槽内容 = 颜色码。
//   · 4 个槽填满（cnt = 4）后不再接受新颜色，保证「先到先得、后面不覆盖」。
//   · 任一槽被写入时打一拍 seq_valid，oled_driver 据此重画。
//   · clr 清空重来（换一轮比赛/重新摆色块时用；当前顶层接常量 0）。
//
// 【为什么不用「每帧都写一次」】摄像头每帧都会给出 new_color，同一色块会被
// 反复报告上百次。若不去重，顺序会被同一个颜色淹掉（变成 红红红红）。
// 去重比较直接和 4 个槽比：空槽恒为 0，而 color_in 进到这里时已经非 0，
// 所以不会误判成重复。
// =============================================================================
`timescale 1ns/1ns

module color_seq (
    input  wire       clk,
    input  wire       rst_n,
    // ---- 来自 color_detect（clk 域）----
    input  wire [2:0] color_in,     // 0=无色 1=红 2=绿 3=蓝 4=黄
    input  wire       new_color,    // 1 clk 脉冲：本帧结果有效
    input  wire       clr,          // 1 = 清空重来
    // ---- 送给 oled_driver ----
    output reg  [2:0] seq0,         // 第 1 个出现的颜色（屏幕最左）
    output reg  [2:0] seq1,
    output reg  [2:0] seq2,
    output reg  [2:0] seq3,         // 第 4 个（屏幕最右）
    output reg  [2:0] cnt,          // 已记录个数 0..4
    output reg        seq_valid,    // 1 clk 脉冲：顺序有更新
    output wire       complete      // 4 个槽都填满
);

    assign complete = (cnt == 3'd4);

    // 空槽是 0，color_in 非 0 → 不会误判重复
    wire dup = (color_in == seq0) | (color_in == seq1) |
               (color_in == seq2) | (color_in == seq3);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seq0      <= 3'd0;
            seq1      <= 3'd0;
            seq2      <= 3'd0;
            seq3      <= 3'd0;
            cnt       <= 3'd0;
            seq_valid <= 1'b0;
        end else begin
            seq_valid <= 1'b0;

            if (clr) begin
                seq0 <= 3'd0;
                seq1 <= 3'd0;
                seq2 <= 3'd0;
                seq3 <= 3'd0;
                cnt  <= 3'd0;
            end else if (new_color && (color_in != 3'd0) && (cnt < 3'd4) && !dup) begin
                case (cnt)
                3'd0:    seq0 <= color_in;
                3'd1:    seq1 <= color_in;
                3'd2:    seq2 <= color_in;
                default: seq3 <= color_in;
                endcase
                cnt       <= cnt + 3'd1;
                seq_valid <= 1'b1;
            end
        end
    end

endmodule
