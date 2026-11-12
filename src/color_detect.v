// =============================================================================
// color_detect.v —— RGB565 流式颜色识别（v3：相对判黄 + 帧内四色轮询）
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
//   这样背景彻底被排除，只有真正鲜艳的东西才参与竞争。
//
// 【v2 上板剩的问题（2026-11-12 实测：Q 只在 2/3 之间跳，从不出现 4）】
// 判黄是**绝对门限**（R>30 且 G>30 且 B<26，6 位空间，即 8 位 B<104）。
// 室内灯光下印刷黄块实测 B 落在 28~35（6 位），永远不满足 B<26；
// 而黄的 R、G 几乎相等，谁多一点点就被下面的 max 分支判成红或绿。
// 于是 color_seq 只收到红/绿/蓝三种颜色，第 4 个槽永远空着 ——
// 屏上只有 3 个色块，正是现场看到的现象。
//
// 【v3 的两处改动】
// 1. 判黄改成**相对判据**：不再看 B 的绝对值，而是看黄的固有特征 ——
//      R、G 互相接近（|R-G| <= YEL_DR），且都比 B 明显高（min(R,G) - B >= YEL_DB），
//      同时 min(R,G) 不低于 YEL_RG（避免暗部噪声算黄）。
//    光源偏暖 / 整幅画面被整体抬亮时这个判据依然成立，绝对门限则必然失效。
// 2. 帧末不再只报"占比最大的那一个颜色"，改成**帧内四色轮询**：
//    每帧从轮询指针 rr 开始，挑第一个计数 >= MIN_PIX 的颜色报出去，rr 后移一位。
//    四个色块同时摆在画面里时，v2 只会反复报最大的那个，其它颜色**永远轮不到**；
//    轮询保证每个达标颜色最多 4 帧（33 ms × 4 ≈ 130 ms）内必被报到一次。
//    上层 color_seq 本来就是"先到先得 + 去重"，多余的重复会被它滤掉。
//    （原设想是"左右半幅各自投票"，但半幅只是把"谁最大"换成"每半边谁最大"，
//      四块同时入画时仍会有颜色被饿死；轮询是从根上解决饿死问题。）
//
// 【顺带保留的格式自检】输出画面中心像素（第 360 行、第 640 个像素）的原始两个字节
// dbg_b0/dbg_b1，串口以 XY= 打出来。红纸在 RGB565 下应看到 B0≈F8、B1≈00；
// 若是 YUV422 则会看到 Y≈4C、U/V≈5A/F0 这种成对出现的值。
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
    parameter [5:0]  YEL_RG    = 6'd8,     // 黄：min(R,G) 至少这么大（太暗的不算黄）
                                           // 28→16→8 的两次下调都源于同一个现象：黄纸的阴影/背光像素
                                           // min(R,G) 只有 8~20，被这条"绝对亮度地板"踢出黄色分支，
                                           // 落到下面"绿最大"分支，导致 Y 和 G 同时达标、Q 在 4/2 之间轮询。
                                           // 中性色（白/灰/黑）早已被 SAT_MIN 先滤掉，这条只防"极暗无彩噪声"。
    parameter [5:0]  GRN_DR    = 6'd16,    // 绿：G 必须比 R 高出这么多才算绿
                                           // 光靠"G 是最大分量"不够：偏绿白平衡下黄纸像素常是
                                           // R=32 G=43（G 最大但只高 11），会被误判成绿。
                                           // 真绿 R=10 G=44（差 34）远超门槛，不会误伤。
    parameter [5:0]  YEL_DR    = 6'd24,    // 黄：|R-G| 不超过这么大（黄的 R≈G）
                                           // 实测偏绿白平衡下黄纸 R=32 G=43（|diff|=11~18），
                                           // 14 会把同一张黄纸劈成「一半黄一半绿」，故放宽到 24。
                                           // 真绿 R=10 G=44（|diff|=34）仍被判绿，不会误吞。
    parameter [5:0]  YEL_DB    = 6'd8,     // 黄：min(R,G) - B 至少这么大
                                           // 黄纸实测 min(R,G)=32、B=18，差值 14；旧值 12 只剩 2 的余量，
                                           // 偏暗的黄会滑到绿色，降到 8 留出余量（中性色已被 SAT_MIN 先滤掉）。
    parameter [19:0] MIN_PIX   = 20'd200,  // 少于这么多像素不认（滤掉小色斑）
    parameter [1:0]  DOM_SHIFT = 2'd2      // 主导色门限：计数不到"本帧最大色"的 1/4 就不算达标
                                           // 上板实测：黄纸铺满画面时黄 56707 px、残留绿 7960 px（阴影/边缘），
                                           // 7960 仍 > MIN_PIX，轮询会照样轮给绿，Q 就在 4/2 之间跳。
                                           // 有这道门限后残留绿（7%）被压掉，四色等面积场景（各 25%）仍全部达标。
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
    output reg  [7:0]  dbg_b1,       // 中心像素低字节
    // ---- 帧统计遥测（v4：只加观测，不改判定）----
    // 上板 Q 全 0 时，光看 Q 分不清「画面没颜色」还是「阈值/分类错了」，
    // 所以把每帧的四色计数、最大饱和度、最亮像素都送出来给串口第二行。
    output reg  [19:0] dbg_cnt_r,    // 本帧红/绿/蓝/黄像素数（原始值）
    output reg  [19:0] dbg_cnt_g,
    output reg  [19:0] dbg_cnt_b,
    output reg  [19:0] dbg_cnt_y,
    output reg  [6:0]  dbg_sat,      // 本帧见过的最大饱和度（0..63）
    output reg  [7:0]  dbg_sb0,      // 最大饱和度那个像素的原始两字节
    output reg  [7:0]  dbg_sb1,
    output reg  [7:0]  dbg_lb0,      // 本帧最亮（G 最大）像素的原始两字节
    output reg  [7:0]  dbg_lb1
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

    // ---- 相对判黄（v3）----
    wire [6:0] rg_diff   = (r7 > g7) ? (r7 - g7) : (g7 - r7);   // |R-G|
    wire [6:0] yel_b_lim = b7 + {1'b0, YEL_DB};                 // R/G 至少要比 B 高这么多
    wire       is_yel    = (rg_min  >= {1'b0, YEL_RG}) &&       // R、G 都够亮
                           (rg_diff <= {1'b0, YEL_DR}) &&       // 且互相接近
                           (rg_min  >= yel_b_lim);              // 且明显高于 B

    reg [2:0] cls;
    always @(*) begin
        if (sat < {1'b0, SAT_MIN})
            cls = 3'd0;                                  // 中性色（白/灰/黑/浅背景）
        else if (is_yel)
            cls = 3'd4;                                  // 黄：R≈G 且都明显高于 B
        else if (mx == r7)
            cls = 3'd1;                                  // 红
        else if (mx == g7)
            // G 虽是最大分量，但不够"绿"（如偏绿白平衡下的黄纸 R=32 G=43）
            // 就别硬塞进绿色 —— 记为中性，宁可漏计也不要造成假绿。
            cls = (g7 >= r7 + {1'b0, GRN_DR}) ? 3'd2 : 3'd0;
        else
            cls = 3'd3;                                  // 蓝
    end

    // ==================================================================
    // 帧内计数（四色）+ 帧末轮询 + 中心像素采样
    // ==================================================================
    reg [19:0] cnt_r, cnt_g, cnt_b, cnt_y;
    reg [1:0]  rr;              // 轮询起点：本帧先看哪个颜色（0=红 1=绿 2=蓝 3=黄）
    reg [2:0]  col_lat;
    reg        tog_p;

    // ---- v4 帧统计（pclk 域采集，vs_rise 时锁存到 lat_*，clk 域随 col_evt 搬走）----
    reg [19:0] lat_r, lat_g, lat_b, lat_y;
    reg [6:0]  lat_sat;
    reg [7:0]  lat_sb0, lat_sb1, lat_lb0, lat_lb1;
    reg [6:0]  sat_max, lum_max;         // 本帧最大饱和度 / 最大绿（近似亮度）
    reg [7:0]  sat_p0, sat_p1;           // 取到最大值那个像素的两个原始字节
    reg [7:0]  lum_p0, lum_p1;
    reg [7:0]  hb_val;                   // 当前像素的高字节（低字节拍上做统计用）

    reg [11:0] pix_idx;         // 行内像素序号（0..2559）
    reg [10:0] line_idx;        // 帧内行号（0..719）
    reg        cap_pend;        // 已抓到高字节，等低字节

    localparam [11:0] CTR_PIX  = 12'd640;   // 1280 宽的中心
    localparam [10:0] CTR_LINE = 11'd360;   // 720 高的中心

    // ---- 轮询选择：从 rr 开始，挑第一个计数达标的颜色 ----
    // elig 的位序固定为 {黄, 蓝, 绿, 红}；把它按 rr 做循环右移，
    // 移位后 er[0] 就是"从 rr 起第一个候选"，再按优先级取下标。
    // 主导色门限：先求本帧最大色计数，只有 >= 它的 1/(2^DOM_SHIFT) 才算达标。
    wire [19:0] mx_rg  = (cnt_r > cnt_g) ? cnt_r : cnt_g;
    wire [19:0] mx_by  = (cnt_b > cnt_y) ? cnt_b : cnt_y;
    wire [19:0] cnt_mx = (mx_rg > mx_by) ? mx_rg : mx_by;
    wire [19:0] dom_lim = cnt_mx >> DOM_SHIFT;

    wire [3:0] elig = {(cnt_y >= MIN_PIX) && (cnt_y >= dom_lim),
                       (cnt_b >= MIN_PIX) && (cnt_b >= dom_lim),
                       (cnt_g >= MIN_PIX) && (cnt_g >= dom_lim),
                       (cnt_r >= MIN_PIX) && (cnt_r >= dom_lim)};
    reg  [3:0] er;
    always @(*) begin
        case (rr)
        2'd0:    er = elig;
        2'd1:    er = {elig[0],    elig[3:1]};
        2'd2:    er = {elig[1:0],  elig[3:2]};
        default: er = {elig[2:0],  elig[3]};
        endcase
    end

    wire [1:0] sel_off = er[0] ? 2'd0 : (er[1] ? 2'd1 : (er[2] ? 2'd2 : 2'd3));
    wire       sel_ok  = |er;
    wire [1:0] sel     = (rr + sel_off) & 2'd3;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            hi_byte  <= 1'b0;
            r5       <= 5'd0;
            g_hi     <= 3'd0;
            cnt_r    <= 20'd0;
            cnt_g    <= 20'd0;
            cnt_b    <= 20'd0;
            cnt_y    <= 20'd0;
            lat_r    <= 20'd0;
            lat_g    <= 20'd0;
            lat_b    <= 20'd0;
            lat_y    <= 20'd0;
            lat_sat  <= 7'd0;
            lat_sb0  <= 8'h00;
            lat_sb1  <= 8'h00;
            lat_lb0  <= 8'h00;
            lat_lb1  <= 8'h00;
            sat_max  <= 7'd0;
            lum_max  <= 7'd0;
            sat_p0   <= 8'h00;
            sat_p1   <= 8'h00;
            lum_p0   <= 8'h00;
            lum_p1   <= 8'h00;
            hb_val   <= 8'h00;
            rr       <= 2'd0;
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
                    hb_val  <= data_r;        // 原样留一份，统计时和低字节配对送出
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

            // ---- 帧统计：这一帧到底有没有"鲜艳"和"明亮"的像素 ----
            // 两个原始字节一起送出，能直接看出是不是全画面对比度不够。
            if (px_valid) begin
                if (sat > sat_max) begin
                    sat_max <= sat;
                    sat_p0  <= hb_val;
                    sat_p1  <= data_r;
                end
                if (g7 > lum_max) begin
                    lum_max <= g7;
                    lum_p0  <= hb_val;
                    lum_p1  <= data_r;
                end
            end

            // ---- 帧边界：按轮询报一个颜色出去 ----
            if (vs_rise) begin
                line_idx <= 11'd0;

                col_lat <= sel_ok ? ({1'b0, sel} + 3'd1) : 3'd0;
                if (sel_ok) rr <= sel + 2'd1;     // 2 位自然回绕，下一帧从它后面开始

                // 先把统计量锁存到 lat_*（clk 域随后搬走），再清零本帧计数
                lat_r   <= cnt_r;
                lat_g   <= cnt_g;
                lat_b   <= cnt_b;
                lat_y   <= cnt_y;
                lat_sat <= sat_max;
                lat_sb0 <= sat_p0;
                lat_sb1 <= sat_p1;
                lat_lb0 <= lum_p0;
                lat_lb1 <= lum_p1;

                cnt_r   <= 20'd0;
                cnt_g   <= 20'd0;
                cnt_b   <= 20'd0;
                cnt_y   <= 20'd0;
                sat_max <= 7'd0;
                lum_max <= 7'd0;
                tog_p   <= ~tog_p;
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
                // 统计量在本帧内保持稳定（vs_rise 才更新），这里跟着 col_evt 整体搬过去
                dbg_cnt_r <= lat_r;
                dbg_cnt_g <= lat_g;
                dbg_cnt_b <= lat_b;
                dbg_cnt_y <= lat_y;
                dbg_sat   <= lat_sat;
                dbg_sb0   <= lat_sb0;
                dbg_sb1   <= lat_sb1;
                dbg_lb0   <= lat_lb0;
                dbg_lb1   <= lat_lb1;
            end
        end

endmodule
