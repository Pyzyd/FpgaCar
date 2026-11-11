// =============================================================================
// color_detect.v —— RGB565 流式颜色识别（v2：饱和度优先）
// -----------------------------------------------------------------------------
// 【v1 为什么失败（2026-11-11 上板实测）】
// v1 的分类链是"先判黑/白、再比通道优势"，结果 Q 一直停在 5（白）：
// 摄像头对着的是整幅场景，白墙/亮桌面/纸背景占 90% 以上像素，
// "一帧里占比最大的颜色"永远是白或黑，色块那几百个像素被淹没。
//
// 【v2 的做法：中性色直接不计数】
//   1. 算饱和度 sat = max(R,G,B) - min(R,G,B)
//   2. sat < SAT_MIN 的像素（白/灰/黑/浅色背景）**一个都不计**
//   3. 剩下的只按"哪个通道最大"分门别类（黄单独判：R、G 都高且 B 低）
//   这样背景彻底被排除，只有真正鲜艳的东西才参与竞争 —— 正是"找色块"需要的语义。
//
// 【顺带加的格式自检】输出画面中心像素（第 360 行、第 640 个像素）的原始两个字节
// dbg_b0/dbg_b1，串口以 XY= 打出来。红纸在 RGB565 下应看到 B0≈F8、B1≈00；
// 若是 YUV422 则会看到 Y≈4C、U/V≈5A/F0 这种成对出现的值。
// 这是判定"到底是不是 RGB565"的唯一硬证据，比看 Q 猜可靠。
//
// 【RGB565 字节顺序】OV5640 在 8 位 DVP 上高字节先出：
//   第 1 个 PCLK： R[4:0] G[5:3]
//   第 2 个 PCLK： G[2:0] B[4:0]
// 在 pclk 域里 HREF/DATA/VSYNC 本来就是同步信号，**只需一级寄存器**，
// 绝不能给 HREF 单独做两级同步（会让字节奇偶整体反相，纯红被判成纯蓝）。
// =============================================================================
`timescale 1ns/1ns

module color_detect #(
    parameter [5:0]  SAT_MIN   = 6'd16,    // 饱和度门限：低于此值算中性色，不计数
    parameter [5:0]  YEL_RG    = 6'd30,    // 黄色要求 R、G 都超过此值
    parameter [5:0]  YEL_B_MAX = 6'd26,    // 且 B 低于此值
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
    output reg  [2:0]  color,        // 0=无色/中性 1=红 2=绿 3=蓝 4=黄
    output reg         new_color,    // 1 clk 脉冲：color 已更新（每帧一次）
    output reg  [7:0]  dbg_b0,       // 中心像素高字节（原样，用于确认格式）
    output reg  [7:0]  dbg_b1        // 中心像素低字节
);

    // ==================================================================
    // pclk 域：单级对齐
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
    // 字节组装
    // ==================================================================
    reg       hi_byte;
    reg [4:0] r5;
    reg [2:0] g_hi;

    wire        px_valid = href_p & hi_byte;        // 低字节那一拍：像素完整
    wire [5:0]  px_r     = {r5, 1'b0};
    wire [5:0]  px_g     = {g_hi, data_r[7:5]};
    wire [5:0]  px_b     = {data_r[4:0], 1'b0};

    // 7 位空间求 max/min/sat
    wire [6:0] r7  = {1'b0, px_r};
    wire [6:0] g7  = {1'b0, px_g};
    wire [6:0] b7  = {1'b0, px_b};

    wire [6:0] rg_max = (r7 > g7) ? r7 : g7;
    wire [6:0] mx     = (b7 > rg_max) ? b7 : rg_max;
    wire [6:0] rg_min = (r7 < g7) ? r7 : g7;
    wire [6:0] mn     = (b7 < rg_min) ? b7 : rg_min;
    wire [6:0] sat    = mx - mn;

    reg [2:0] cls;
    always @(*) begin
        if (sat < {1'b0, SAT_MIN})
            cls = 3'd0;                                  // 中性色（白/灰/黑/浅背景）
        else if (px_r > YEL_RG && px_g > YEL_RG && px_b < YEL_B_MAX)
            cls = 3'd4;                                  // 黄：R、G 都高且 B 低
        else if (mx == r7)
            cls = 3'd1;                                  // 红
        else if (mx == g7)
            cls = 3'd2;                                  // 绿
        else
            cls = 3'd3;                                  // 蓝
    end

    // ==================================================================
    // 帧内计数 + 中心像素采样
    // ==================================================================
    reg [19:0] cnt_r, cnt_g, cnt_b, cnt_y;
    reg [2:0]  col_lat;
    reg        tog_p;

    reg [11:0] pix_idx;         // 行内像素序号（0..2559）
    reg [10:0] line_idx;        // 帧内行号（0..719）
    reg        cap_pend;        // 已抓到高字节，等低字节

    localparam [11:0] CTR_PIX  = 12'd640;   // 1280 宽的中心
    localparam [10:0] CTR_LINE = 11'd360;   // 720 高的中心

    // 帧末主色：只在"有饱和色"的东西里选最大
    wire [19:0] max_all = (cnt_r > cnt_g) ? ((cnt_r > cnt_b) ? ((cnt_r > cnt_y) ? cnt_r : cnt_y)
                                                               : ((cnt_b > cnt_y) ? cnt_b : cnt_y))
                                          : ((cnt_g > cnt_b) ? ((cnt_g > cnt_y) ? cnt_g : cnt_y)
                                                             : ((cnt_b > cnt_y) ? cnt_b : cnt_y));

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            hi_byte  <= 1'b0;
            r5       <= 5'd0;
            g_hi     <= 3'd0;
            cnt_r    <= 20'd0;
            cnt_g    <= 20'd0;
            cnt_b    <= 20'd0;
            cnt_y    <= 20'd0;
            col_lat  <= 3'd0;
            tog_p    <= 1'b0;
            pix_idx  <= 12'd0;
            line_idx <= 11'd0;
            cap_pend <= 1'b0;
            dbg_b0   <= 8'h00;
            dbg_b1   <= 8'h00;
        end else begin
            // ---- 行列计数 ----
            if (!href_p) begin
                pix_idx  <= 12'd0;
                hi_byte  <= 1'b0;
                cap_pend <= 1'b0;
            end else begin
                if (!hi_byte) begin
                    r5      <= data_r[7:3];       // 高字节
                    g_hi    <= data_r[2:0];
                    hi_byte <= 1'b1;
                    if (line_idx == CTR_LINE && pix_idx == CTR_PIX) begin
                        dbg_b0   <= data_r;       // 中心像素高字节
                        cap_pend <= 1'b1;
                    end
                end else begin
                    hi_byte <= 1'b0;
                    pix_idx <= pix_idx + 12'd1;
                    if (cap_pend) begin
                        dbg_b1   <= data_r;       // 紧跟的低字节
                        cap_pend <= 1'b0;
                    end
                end
            end

            // ---- 分类计数 ----
            if (px_valid) begin
                case (cls)
                3'd1: cnt_r <= cnt_r + 20'd1;
                3'd2: cnt_g <= cnt_g + 20'd1;
                3'd3: cnt_b <= cnt_b + 20'd1;
                3'd4: cnt_y <= cnt_y + 20'd1;
                default: ;
                endcase
            end

            // ---- 帧边界 ----
            if (vs_rise) begin
                line_idx <= 11'd0;

                if (max_all < MIN_PIX)
                    col_lat <= 3'd0;
                else if (cnt_r == max_all)
                    col_lat <= 3'd1;
                else if (cnt_g == max_all)
                    col_lat <= 3'd2;
                else if (cnt_b == max_all)
                    col_lat <= 3'd3;
                else
                    col_lat <= 3'd4;

                cnt_r <= 20'd0;
                cnt_g <= 20'd0;
                cnt_b <= 20'd0;
                cnt_y <= 20'd0;
                tog_p <= ~tog_p;
            end else if (href_p && pix_idx == 12'd0 && !hi_byte) begin
                // 每行行首先进（用 pix_idx==0 且刚进入高字节的时机）
                line_idx <= line_idx + 11'd1;
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
