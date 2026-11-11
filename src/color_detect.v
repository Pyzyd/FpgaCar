// =============================================================================
// color_detect.v —— RGB565 流式颜色识别（颜色顺序 20 分的第一级）
// -----------------------------------------------------------------------------
// 核心思路：**不做帧缓存**。DVP 是逐像素流，颜色块识别只需要"统计一帧里
// 各颜色各占多少像素"，纯计数器就能算，不需要 DDR、不需要 BRAM。
// 1280x720 = 92 万像素/帧，5 个 20 位计数器足够。
//
// 【RGB565 字节顺序】OV5640 在 8 位 DVP 上"高字节先出"：
//   第 1 个 PCLK： R[4:0] G[5:3]   （高字节，锁存 r5 / g_hi）
//   第 2 个 PCLK： G[2:0] B[4:0]   （低字节，与上一拍拼成完整像素）
// 所以必须按 HREF 上升沿同步字节奇偶；否则整帧错位一个字节，
// 表现是"明明是红色却被判成别的颜色"。
//
// 【6 位色彩空间】R/B 是 5 位、G 是 6 位，为便于比较统一放大到 6 位：
//   R6 = {R[4:0],1'b0}  0..62 ；G6 = G[5:0] 0..63 ；B6 = {B[4:0],1'b0} 0..62
// 所有"通道差值"比较都在 7 位空间做，避免 6 位相加溢出（63+14=77 > 63）。
//
// 【分类规则】先看亮度（黑/白），再比通道优势（红/绿/蓝/黄）。
// 阈值是参数，上板后用串口 Q= 调：
//   纯红→Q=1，纯绿→Q=2，纯蓝→Q=3，黄→Q=4，白→Q=5，其他→Q=0。
// 若对着红/绿/蓝 结果都一样或都是 0，说明输出不是 RGB565（可能 YUV422），
// 那就得加 YUV→RGB 转换 —— 这是本模块第一个要验证的假设。
// =============================================================================
`timescale 1ns/1ns

module color_detect #(
    parameter [7:0] DARK_SUM   = 8'd36,    // R+G+B 之和低于此值算"黑"（最大值 187，必须 8 位）
    parameter [7:0] BRIGHT_SUM = 8'd150,   // 高于此值且三通道都够亮算"白"（原写 7 位会被截断成 22）
    parameter [5:0] WHITE_MIN  = 6'd34,    // 白色要求的最小通道值
    parameter [5:0] DOM_MARGIN = 6'd14,    // 领先多少才算"这个颜色"
    parameter [5:0] YEL_RG     = 6'd30,    // 黄色要求 R、G 都超过此值
    parameter [5:0] YEL_B_MAX  = 6'd26,    // 且 B 低于此值
    parameter [19:0] MIN_PIX   = 20'd200   // 少于这么多像素不认（滤掉小色斑）
) (
    input  wire        clk,          // 24 MHz 系统域
    input  wire        rst_n,
    // ---- DVP 输入（pclk 域）----
    input  wire        pclk,
    input  wire        href,
    input  wire        vsync,
    input  wire [7:0]  data,
    // ---- 结果（clk 域）----
    output reg  [2:0]  color,        // 0=其他 1=红 2=绿 3=蓝 4=黄 5=白
    output reg         new_color     // 1 clk 脉冲：color 已更新（每帧一次）
);

    // ==================================================================
    // pclk 域：单级对齐寄存
    // ------------------------------------------------------------------
    // 【为什么不做两级同步】HREF/DATA/VSYNC 本来就由摄像机的 PCLK 打出，
    // 在 pclk 域里它们是**同步信号**，只需要一级寄存器改善时序。
    // 之前给 HREF 做 2FF、data 不做，两者错开 2 拍，字节奇偶整体反相，
    // 表现就是"纯红被判成纯蓝"。
    // ==================================================================
    reg        href_r, vsync_r;
    reg [7:0]  data_r;

    always @(posedge pclk or negedge rst_n)
        if (!rst_n) begin
            href_r  <= 1'b0;
            vsync_r <= 1'b0;
            data_r  <= 8'h00;
        end else begin
            href_r  <= href;
            vsync_r <= vsync;
            data_r  <= data;
        end

    reg vsync_d;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n) vsync_d <= 1'b0;
        else        vsync_d <= vsync_r;

    wire href_p  = href_r;
    wire vs_rise = vsync_r & ~vsync_d;

    // ==================================================================
    // 字节组装：高字节锁进 r5/g_hi，低字节当拍拼出完整像素并分类
    // ==================================================================
    reg       hi_byte;
    reg [4:0] r5;
    reg [2:0] g_hi;

    // 本拍若在低字节，则这一组就是完整像素；否则无效
    wire        px_valid = href_p & hi_byte;        // 低字节那一拍：像素完整
    wire [5:0]  px_r     = {r5, 1'b0};              // 6 位
    wire [5:0]  px_g     = {g_hi, data_r[7:5]};         // 6 位
    wire [5:0]  px_b     = {data_r[4:0], 1'b0};         // 6 位

    // 7 位空间做比较
    wire [6:0] r7  = {1'b0, px_r};
    wire [6:0] g7  = {1'b0, px_g};
    wire [6:0] b7  = {1'b0, px_b};
    wire [6:0] mg  = {1'b0, DOM_MARGIN};
    wire [7:0] sum8 = {1'b0, r7} + {1'b0, g7} + {1'b0, b7};   // 0..187

    reg [2:0] cls;
    always @(*) begin
        if (sum8 < DARK_SUM)
            cls = 3'd0;                                        // 黑
        else if (sum8 > BRIGHT_SUM && px_r > WHITE_MIN &&
                 px_g > WHITE_MIN && px_b > WHITE_MIN)
            cls = 3'd5;                                        // 白
        else if (px_r > YEL_RG && px_g > YEL_RG && px_b < YEL_B_MAX)
            cls = 3'd4;                                        // 黄
        else if (r7 > g7 + mg && r7 > b7 + mg)
            cls = 3'd1;                                        // 红
        else if (g7 > r7 + mg && g7 > b7 + mg)
            cls = 3'd2;                                        // 绿
        else if (b7 > r7 + mg && b7 > g7 + mg)
            cls = 3'd3;                                        // 蓝
        else
            cls = 3'd0;                                        // 灰/杂色
    end

    // ==================================================================
    // 帧内计数 + 帧末选出主色
    // ==================================================================
    reg [19:0] cnt_r, cnt_g, cnt_b, cnt_y, cnt_w;
    reg [2:0]  col_lat;
    reg        tog_p;

    wire [19:0] max_col_cnt = (cnt_r > cnt_g) ? cnt_r : cnt_g;
    wire [19:0] max_col_y   = (cnt_y > cnt_w) ? cnt_y : cnt_w;
    wire [19:0] max_col_b   = (cnt_b > max_col_y) ? cnt_b : max_col_y;
    wire [19:0] max_all     = (max_col_cnt > max_col_b) ? max_col_cnt : max_col_b;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            hi_byte <= 1'b0;
            r5      <= 5'd0;
            g_hi    <= 3'd0;
            cnt_r   <= 20'd0;
            cnt_g   <= 20'd0;
            cnt_b   <= 20'd0;
            cnt_y   <= 20'd0;
            cnt_w   <= 20'd0;
            col_lat <= 3'd0;
            tog_p   <= 1'b0;
        end else begin
            // ---- 字节奇偶（d2 与 href_p 已对齐）----
            if (!href_p) begin
                hi_byte <= 1'b0;              // 行间：等下一个高字节
            end else if (!hi_byte) begin
                r5      <= data_r[7:3];           // 高字节：R[4:0] G[5:3]
                g_hi    <= data_r[2:0];
                hi_byte <= 1'b1;
            end else begin
                hi_byte <= 1'b0;              // 低字节：下一拍回到高字节
            end

            // ---- 像素分类计数（在低字节那一拍，用拼好的像素）----
            if (px_valid) begin
                case (cls)
                3'd1: cnt_r <= cnt_r + 20'd1;
                3'd2: cnt_g <= cnt_g + 20'd1;
                3'd3: cnt_b <= cnt_b + 20'd1;
                3'd4: cnt_y <= cnt_y + 20'd1;
                3'd5: cnt_w <= cnt_w + 20'd1;
                default: ;
                endcase
            end

            // ---- 帧末：主色判定 ----
            if (vs_rise) begin
                if (max_all < MIN_PIX)
                    col_lat <= 3'd0;
                else if (cnt_w == max_all)
                    col_lat <= 3'd5;
                else if (cnt_y == max_all)
                    col_lat <= 3'd4;
                else if (cnt_r == max_all)
                    col_lat <= 3'd1;
                else if (cnt_g == max_all)
                    col_lat <= 3'd2;
                else
                    col_lat <= 3'd3;

                cnt_r <= 20'd0;
                cnt_g <= 20'd0;
                cnt_b <= 20'd0;
                cnt_y <= 20'd0;
                cnt_w <= 20'd0;
                tog_p <= ~tog_p;
            end
        end
    end

    // ==================================================================
    // clk 域：同步 toggle 后搬颜色码
    // ==================================================================
    reg [2:0] tog_s;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) tog_s <= 3'b000;
        else        tog_s <= {tog_s[1:0], tog_p};

    wire col_evt = tog_s[2] ^ tog_s[1];

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            color     <= 3'd0;
            new_color <= 1'b0;
        end else begin
            new_color <= 1'b0;
            if (col_evt) begin
                color     <= col_lat;
                new_color <= 1'b1;
            end
        end

endmodule
