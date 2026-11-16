// =============================================================================
// k230_link.v —— K230 视觉结果接收器（3 位数据 + 1 根 strobe）
// -----------------------------------------------------------------------------
// 【为什么是它】颜色 20 + 交通牌 25 分改由 K230 承担（PROJECT_PLAN §3.18）。
// K230 是 Python 侧，只能跑「识别 + 往 GPIO 写几个 bit」，时序完全靠软件 sleep，
// 所以这里的设计目标不是跑得快，而是**丢一个 strobe 也能自己爬回同步**。
//
// 【帧格式】一条消息 = 两个符号，先「类别」后「数值」：
//     000 → CAT → 000 → VAL → 000        （整条连发两遍，两遍一致才采纳）
//   CAT=001 颜色  VAL=1红 2黄 3绿 4蓝
//   CAT=010 方向  VAL=1左 2右 3直
//   CAT=011 命令  VAL=1清空顺序 2新一圈
//   CAT=111 心跳  VAL 忽略（K230 空闲时定期发，用来续 link_alive）
//
// 【解析的核心：用间隔长度认符号，而不是用状态机奇偶交替】
// 先说为什么不用两状态机。天真的做法是「等类别 → 等数值 → 等类别」交替。
// 但协议里 000 只是分隔符，没有任何唯一帧头，于是相位一旦错一位（丢一个
// strobe 就会错），错位后的流**依然自洽**：它会把「数值」当类别、把下一个
// 「类别」当数值，凑出看起来很合理的假配对，然后永远错下去，只能靠复位救。
// 这个坑是仿真里实测到的（k230_link_tb 的「失步恢复」用例一开始直接 0 采纳）。
//
// 正确做法是利用帧结构里间隔长度的规律。把「非零符号」之间夹的 000 个数数出来：
//     同一帧内 CAT→VAL 之间：1 个 000
//     跨帧 VAL→CAT  之间：2 个 000（尾分隔 + 首分隔各一个）
// 也就是说间隔长度是 1,2,1,2… 交替 —— 而这个规律**与相位无关**，
// 错位不会破坏它。于是每次看到非零符号，就看它前面隔了几个 0：
//     间隔 == 1  → 它是「数值」，配给待着的那个类别
//     间隔 >= 2  → 它是「类别」，开一条新消息
// 丢一个符号只是让某个间隔变成 3，判定仍然成立（3>=2 当类别），
// 所以失步在**下一个符号**就自动修好，不需要复位、不需要超时。
//
// 【三重校验，挡住错位残留的假消息】
//   1) 类别必须落在 {001,010,011,111} 内，否则当垃圾丢掉；
//   2) 数值必须对该类别合法（颜色 1..4、方向 1..3、命令 1..2），否则丢弃并记错；
//   3) 连续两遍完全一致才采纳。三条叠起来，错位期间凑出的假配对几乎不可能通过。
//
// 【采样时刻】strobe 打两拍同步后取上升沿，在那一刻采 D[2:0]。
// K230 侧是「先写数据 → sleep 1 ms → 再拉 strobe」，数据早已稳住。
//
// 【★ 编码转换（务必看清，这里和协议表不一样）】
// 协议 VAL 的颜色顺序是 1红 2黄 3绿 4蓝，而 color_seq.v 的内部编码是
// 1红 2绿 3蓝 4黄。为了让 color_seq / oled_driver **一行都不用改**，
// 本模块在输出端就完成转换：
//     协议 1(红) → 1    协议 2(黄) → 4
//     协议 3(绿) → 2    协议 4(蓝) → 3
// 即 color_evt 的语义与 color_detect.v 的 cam_color 完全一致。
//
// 【link_alive / err_cnt】看到合法类别就续 2 s 窗口，超时置 0，顶层可在 OLED
// 上显示 "K230 OFF"（接线松了 / K230 没跑起来，是最常见的两种现场故障）。
// err_cnt 记「两遍不一致 / 数值非法 / 丢了数值」的累计次数，饱和到 255，
// 用来在 OLED 上显示链路质量，排查时很有用。
// =============================================================================
`timescale 1ns/1ns

module k230_link #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer ALIVE_MS = 2000        // 多久没消息就判链路掉线
) (
    input  wire        clk,
    input  wire        rst_n,                 // 低有效（已同步化）
    input  wire [2:0]  k230_d,                // 来自 K230 GPIO42/43/34
    input  wire        k230_stb,              // 来自 K230 GPIO35

    output reg  [3:0]  color_evt,             // 单周期脉冲：0=无 1=红 2=绿 3=蓝 4=黄
    output reg  [2:0]  dir_evt,               // 单周期脉冲：0=无 1=左 2=右 3=直
    output reg  [7:0]  cmd_evt,               // 单周期位图：bit0=清空顺序 bit1=新一圈
    output reg         link_alive,            // 2 s 内收到过合法消息
    output reg  [7:0]  err_cnt                // 协议异常计数（饱和到 255）
);

    // ------------------------------------------------------------------
    // 输入同步：两拍消除亚稳态。K230 的 GPIO 是异步的，必须同步后再用。
    // ------------------------------------------------------------------
    reg [2:0] d_s0, d_s1;
    reg       stb_s0, stb_s1;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            d_s0   <= 3'd0;  d_s1   <= 3'd0;
            stb_s0 <= 1'b0;  stb_s1 <= 1'b0;
        end else begin
            d_s0   <= k230_d;    d_s1   <= d_s0;
            stb_s0 <= k230_stb;  stb_s1 <= stb_s0;
        end

    wire stb_rise = stb_s0 & ~stb_s1;         // 上升沿：此刻采数据

    // ------------------------------------------------------------------
    // 解析状态
    // ------------------------------------------------------------------
    reg        cat_valid;                     // 手上是否有一条「只等数值」的类别
    reg [2:0]  cat_r;

    reg        prev_valid;                    // 上一条已成形消息（用于两遍比对）
    reg [2:0]  prev_cat, prev_val;

    reg [3:0]  gap_cnt;                       // 自上个非零符号以来过了几个 000
    reg        seen_nonzero;                  // 是否见过任何非零符号（决定首个符号怎么认）

    // 链路活性计时
    localparam integer ALIVE_RAW = CLK_FREQ / 1000 * ALIVE_MS;
    localparam integer ALIVE_MAX = (ALIVE_RAW < 1) ? 1 : ALIVE_RAW;
    reg [31:0] alive_cnt;

    // 颜色编码转换：协议序 → color_seq 序
    function [3:0] color_map;
        input [2:0] v;                        // 协议 VAL
        begin
            case (v)
                3'd1:    color_map = 4'd1;    // 红 → 红
                3'd2:    color_map = 4'd4;    // 黄 → 黄
                3'd3:    color_map = 4'd2;    // 绿 → 绿
                3'd4:    color_map = 4'd3;    // 蓝 → 蓝
                default: color_map = 4'd0;
            endcase
        end
    endfunction

    // 类别是否合法（000 是分隔符，{100,101,110} 是未定义码）
    function cat_ok;
        input [2:0] c;
        begin
            cat_ok = (c == 3'd1) || (c == 3'd2) || (c == 3'd3) || (c == 3'd7);
        end
    endfunction

    // 数值对该类别是否合法
    function val_ok;
        input [2:0] c;
        input [2:0] v;
        begin
            case (c)
                3'b001:  val_ok = (v >= 3'd1) && (v <= 3'd4);   // 颜色
                3'b010:  val_ok = (v >= 3'd1) && (v <= 3'd3);   // 方向
                3'b011:  val_ok = (v >= 3'd1) && (v <= 3'd2);   // 命令
                3'b111:  val_ok = 1'b1;                         // 心跳：数值随便
                default: val_ok = 1'b0;
            endcase
        end
    endfunction

    wire [3:0] gap_next = (gap_cnt == 4'hF) ? 4'hF : gap_cnt + 4'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cat_valid  <= 1'b0;
            cat_r      <= 3'd0;
            prev_valid <= 1'b0;
            prev_cat   <= 3'd0;
            prev_val   <= 3'd0;
            gap_cnt    <= 4'd0;
            seen_nonzero <= 1'b0;
            color_evt  <= 4'd0;
            dir_evt    <= 3'd0;
            cmd_evt    <= 8'd0;
            link_alive <= 1'b0;
            err_cnt    <= 8'd0;
            alive_cnt  <= 32'd0;
        end else begin
            // 事件默认拉低：它们都是单周期脉冲
            color_evt <= 4'd0;
            dir_evt   <= 3'd0;
            cmd_evt   <= 8'd0;

            // ---- 链路活性计时：收到合法类别就清零，超时判掉线 ----
            if (alive_cnt >= ALIVE_MAX - 1) begin
                alive_cnt  <= ALIVE_MAX;
                link_alive <= 1'b0;
            end else begin
                alive_cnt <= alive_cnt + 32'd1;
            end

            // ---- 符号解析（只在 strobe 上升沿动） ----
            if (stb_rise) begin
                if (d_s1 == 3'd0) begin
                    // 000 是分隔符：只累计间隔，不承载语义
                    gap_cnt <= gap_next;
                end else begin
                    gap_cnt      <= 4'd0;
                    seen_nonzero <= 1'b1;

                    // 用「前面隔了几个 0」判断这个符号的语义
                    //   首次出现：没有参照，按类别处理
                    //   间隔 == 1：同一帧内，这是数值
                    //   间隔 >= 2：跨帧了，这是新类别
                    if (!seen_nonzero || gap_cnt >= 4'd2) begin
                        // ---------------- 当作类别 ----------------
                        if (cat_valid) begin
                            // 上一条类别等数值没等到 —— 说明中途丢过 strobe
                            cat_valid <= 1'b0;
                            err_cnt   <= (err_cnt == 8'hFF) ? 8'hFF
                                                            : err_cnt + 8'd1;
                        end
                        if (cat_ok(d_s1)) begin
                            cat_r      <= d_s1;
                            cat_valid  <= 1'b1;
                            // 收到合法类别即认为 K230 在说话（心跳也走这里）
                            alive_cnt  <= 32'd0;
                            link_alive <= 1'b1;
                        end
                    end else begin
                        // ---------------- 当作数值 ----------------
                        if (!cat_valid) begin
                            // 没有配对的类别：错位残留，丢掉
                            err_cnt <= (err_cnt == 8'hFF) ? 8'hFF : err_cnt + 8'd1;
                        end else if (!val_ok(cat_r, d_s1)) begin
                            cat_valid <= 1'b0;
                            err_cnt   <= (err_cnt == 8'hFF) ? 8'hFF
                                                            : err_cnt + 8'd1;
                        end else begin
                            cat_valid <= 1'b0;

                            if (prev_valid && (cat_r == prev_cat) &&
                                              (d_s1  == prev_val)) begin
                                // ---- 连续两遍一致：采纳 ----
                                // 采纳后把这一对「消费掉」：同一条消息再发时要求
                                // 再来两遍，否则每一遍都会被当成新配对而反复采纳。
                                prev_valid <= 1'b0;

                                case (cat_r)
                                    3'b001: color_evt <= color_map(d_s1);
                                    3'b010: dir_evt   <= d_s1;
                                    3'b011: begin
                                        if (d_s1 == 3'd1)      cmd_evt <= 8'b0000_0001;
                                        else if (d_s1 == 3'd2) cmd_evt <= 8'b0000_0010;
                                    end
                                    3'b111: ;             // 心跳：只续 link_alive
                                    default: ;
                                endcase
                            end else begin
                                // ---- 不一致（或本轮第一条）：只记住，不采纳 ----
                                if (prev_valid)
                                    err_cnt <= (err_cnt == 8'hFF) ? 8'hFF
                                                                  : err_cnt + 8'd1;
                                prev_cat   <= cat_r;
                                prev_val   <= d_s1;
                                prev_valid <= 1'b1;
                            end
                        end
                    end
                end
            end
        end
    end

endmodule
