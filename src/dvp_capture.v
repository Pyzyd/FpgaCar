// =============================================================================
// dvp_capture.v —— DVP 时序统计（A3.3 第一步：先量清楚，再谈识别）
// -----------------------------------------------------------------------------
// 目标不是"把图像存下来"，而是**用最少逻辑证明三件事**：
//   1. HREF 每个像素都在有效区拉高 → 统计"一帧里最长的那一行有多少个 PCLK"
//      = 水平有效像素数（OV5640 720p 应为 1280）
//   2. VSYNC 一帧里有多少个 HREF 行 → 垂直有效行数（应为 720）
//   3. 帧率是否稳定 → 帧计数配合 100 ms 窗口（在 cam_probe 里已有 V=）
// 三个数字对上了，说明 PCLK/HREF/VSYNC/DATA 的时序和接线全部正确；
// 对不上就定位到具体是哪一根线（见下面的异常含义表）。
//
// 【跨时钟域】统计发生在 cmos_pclk 域（≈42 MHz），结果要送到 24 MHz 域打印。
//   做法：pclk 域在一帧结束时把 width/height 锁进寄存器，同时翻转一个 toggle；
//   24 MHz 域用两级同步抓这个 toggle 的跳变，再一次性把数据搬过来。
//   因为 width/height 在两次锁存之间稳定 33 ms（30 fps），
//   远超 2 个 24 MHz 周期，所以不需要握手应答，也不会有亚稳态传到数据上。
//
// 【为什么不采 data】本模块故意不碰 data[7:0]，只验时序。
//   等 W/H 对上再决定是"存 DDR"还是"直接做颜色统计"——那时再动数据通路，
//   避免一开始就把存储/色度逻辑和时序问题混在一起调。
// =============================================================================
`timescale 1ns/1ns

module dvp_capture #(
    parameter integer RESET_TIMEOUT = 1        // 预留
) (
    input  wire        clk,          // 24 MHz 系统域
    input  wire        rst_n,        // 低有效（已同步化）
    // ---- DVP 输入（pclk 域）----
    input  wire        pclk,         // 像素时钟 ≈42 MHz
    input  wire        href,         // 行有效
    input  wire        vsync,        // 场同步（上升沿当作一帧结束）
    input  wire [7:0]  data,         // 本模块未使用（留给后续颜色统计）
    // ---- 结果（clk 域）----
    output reg  [15:0] width,        // 一帧里最长的 HREF 行包含的 PCLK 数
    output reg  [15:0] height,       // 一帧里的 HREF 行数
    output reg  [31:0] frames,       // 完成的帧数
    output reg         new_frame     // 1 clk 脉冲：width/height 刚更新
);

    // ==================================================================
    // pclk 域：两级同步 DVP 输入
    // ==================================================================
    reg [1:0] href_s, vs_s;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n) begin
            href_s <= 2'b00;
            vs_s   <= 2'b00;
        end else begin
            href_s <= {href_s[0], href};
            vs_s   <= {vs_s[0],   vsync};
        end
    wire href_p = href_s[1];
    wire vs_p   = vs_s[1];

    reg href_d, vs_d;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n) begin
            href_d <= 1'b0;
            vs_d   <= 1'b0;
        end else begin
            href_d <= href_p;
            vs_d   <= vs_p;
        end

    wire href_rise = href_p & ~href_d;
    wire href_fall = ~href_p & href_d;
    wire vs_rise   = vs_p & ~vs_d;

    // pclk 域没有系统复位（pclk 可能在系统复位后才出现），用计数器自恢复
    reg [15:0] pix_cnt;      // 当前行像素数
    reg [15:0] line_cnt;     // 本帧行数
    reg [15:0] w_max;        // 本帧最大行像素
    reg [15:0] w_lat, h_lat;
    reg        tog_p;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            pix_cnt  <= 16'd0;
            line_cnt <= 16'd0;
            w_max    <= 16'd0;
            w_lat    <= 16'd0;
            h_lat    <= 16'd0;
            tog_p    <= 1'b0;
        end else begin
        if (href_rise) begin
            pix_cnt <= 16'd1;        // 上升沿这一拍就是第 1 个像素
            if (line_cnt != 16'hFFFF) line_cnt <= line_cnt + 16'd1;
        end else if (href_p) begin
            if (pix_cnt != 16'hFFFF) pix_cnt <= pix_cnt + 16'd1;
        end

        if (href_fall) begin
            if (pix_cnt > w_max) w_max <= pix_cnt;
        end

        // 一帧结束：锁存几何尺寸，翻转 toggle 通知 clk 域
        if (vs_rise) begin
            w_lat   <= w_max;
            h_lat   <= line_cnt;
            line_cnt <= 16'd0;
            w_max    <= 16'd0;
            tog_p    <= ~tog_p;
        end
        end
    end

    // ==================================================================
    // clk 域：同步 toggle，抓跳变后搬数据
    // ==================================================================
    reg [2:0] tog_s;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) tog_s <= 3'b000;
        else        tog_s <= {tog_s[1:0], tog_p};

    wire frame_evt = tog_s[2] ^ tog_s[1];    // 任意跳变 = 一帧完成

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            width     <= 16'd0;
            height    <= 16'd0;
            frames    <= 32'd0;
            new_frame <= 1'b0;
        end else begin
            new_frame <= 1'b0;
            if (frame_evt) begin
                width     <= w_lat;          // 已稳定 33 ms，直接搬
                height    <= h_lat;
                frames    <= frames + 32'd1;
                new_frame <= 1'b1;
            end
        end

    // data 未使用（A3.3 只验时序）；保留端口避免将来改连线
    wire unused_data = ^data;

endmodule
