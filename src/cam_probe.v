// =============================================================================
// cam_probe.v —— 摄像头上电时序 + 链路探测（A3.1）
// -----------------------------------------------------------------------------
// 本模块只做三件事，**不碰 SCCB 配置**（那是 A3.2）：
//   1. 按 OV5640 要求的上电时序放复位：
//         pwdn = 0（不待机）
//         rst_n 拉低 ≥ 1 ms  →  拉高  →  再等 ≥ 20 ms  →  ready=1
//      太快的后果：传感器内部稳压/时钟没稳，后面 SCCB 写进去也不生效，
//      表现为"配置了半天没反应"，是最常见的坑。
//   2. 把 SCCB 两脚置为总线空闲（SCLK=1、SDAT 释放靠外部上拉）。A3.2 接上
//      sccb 引擎后由引擎驱动，本模块就只留 ready。
//   3. 统计 VSYNC 上升沿个数（100 ms 窗口）：
//      OV5640 只要 XCLK 在跑、复位正确，**即使一条寄存器都没配**也会输出默认
//      帧（VSYNC/HREF/PCLK 都有）。所以 V>0 是"XCLK、接线、复位都对"的独立
//      证据，与 SCCB 通不通完全解耦 —— 这是把故障域切开的关键一步。
//
// 为什么 PCLK 不在这里量：PCLK 约 42 MHz，比 24 MHz 系统时钟还快，用 clk 域
// 采样会漏沿、量不准。PCLK 的测量放到 A3.3 的 pclk 域采集模块里做（那边本来
// 就有一个 pclk 域计数器，配握手跨域即可）。
// =============================================================================
`timescale 1ns/1ns

module cam_probe #(
    parameter integer CLK_FREQ     = 24_000_000,
    parameter integer RST_LOW_MS   = 1,      // rst_n 保持低电平的时间
    parameter integer CFG_DELAY_MS = 20,     // 复位释放后等多久才允许配置
    parameter integer WIN_MS       = 100      // VSYNC 统计窗口
) (
    input  wire        clk,
    input  wire        rst_n,        // 系统复位（已同步化）
    // ---- 到传感器的控制脚 ----
    output reg         cam_rst_n,    // CMOS_CTL2（GPIOL_04）
    output reg         cam_pwdn,     // CMOS_CTL3（GPIOL_N_00）
    output wire        sccb_sclk,    // CMOS_SCLK（GPIOL_09）
    input  wire        sccb_sdat_in, // CMOS_SDAT（GPIOR_13）回读
    output wire        sccb_sdat_out,
    output wire        sccb_sdat_oe,
    // ---- 从传感器来的探测信号 ----
    input  wire        vsync,        // CMOS_VSYNC
    // ---- 结果 ----
    output reg         ready,        // 上电时序完成，可以开始 SCCB 配置
    output reg  [7:0]  vs_cnt,       // 每 WIN_MS 个 VSYNC 上升沿数（饱和 255）
    output reg         vs_act        // 本次窗口内见过 VSYNC（有帧输出）
);

    // ------------------------------------------------------------------
    // 1 ms 节拍（多个毫秒计数器共用）
    // ------------------------------------------------------------------
    localparam integer MS_DIV_RAW = CLK_FREQ / 1_000;
    localparam integer MS_DIV     = (MS_DIV_RAW < 1) ? 1 : MS_DIV_RAW;   // 24 MHz -> 24000

    reg [15:0] ms_div;
    reg        ms_tick;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            ms_div  <= 16'd0;
            ms_tick <= 1'b0;
        end else if (ms_div >= MS_DIV - 1) begin
            ms_div  <= 16'd0;
            ms_tick <= 1'b1;
        end else begin
            ms_div  <= ms_div + 16'd1;
            ms_tick <= 1'b0;
        end

    // ------------------------------------------------------------------
    // 上电时序：rst_n 低 RST_LOW_MS 毫秒 -> 高 -> 再等 CFG_DELAY_MS 毫秒
    // ------------------------------------------------------------------
    reg [15:0] ms_cnt;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            ms_cnt    <= 16'd0;
            cam_rst_n <= 1'b0;
            cam_pwdn  <= 1'b0;      // 0 = 不休眠
            ready     <= 1'b0;
        end else begin
            cam_pwdn <= 1'b0;
            if (ms_tick) begin
                if (ms_cnt < RST_LOW_MS + CFG_DELAY_MS) begin
                    ms_cnt <= ms_cnt + 16'd1;
                end
                // 第 RST_LOW_MS 个毫秒到点后释放复位
                if (ms_cnt >= RST_LOW_MS - 1)
                    cam_rst_n <= 1'b1;
                if (ms_cnt >= RST_LOW_MS + CFG_DELAY_MS - 1)
                    ready <= 1'b1;
            end
        end

    // ------------------------------------------------------------------
    // SCCB 空闲：SCLK 高、SDAT 释放（外部 4.7k 上拉为高）
    // A3.2 接入 sccb 引擎后，这三根线改由引擎驱动。
    // ------------------------------------------------------------------
    assign sccb_sclk     = 1'b1;
    assign sccb_sdat_out = 1'b1;
    assign sccb_sdat_oe  = 1'b0;
    // sccb_sdat_in 目前未被使用（A3.2 读回寄存器时才需要），综合会报 unused 警告，忽略即可

    // ------------------------------------------------------------------
    // VSYNC 统计：两级同步 + 上升沿计数，每 WIN_MS 毫秒锁存一次
    // ------------------------------------------------------------------
    reg [1:0] vs_sync;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) vs_sync <= 2'b00;
        else        vs_sync <= {vs_sync[0], vsync};
    wire vs_q = vs_sync[1];

    reg        vs_d;
    reg [15:0] vs_acc;
    reg [15:0] win_cnt;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            vs_d    <= 1'b0;
            vs_acc  <= 16'd0;
            win_cnt <= 16'd0;
            vs_cnt  <= 8'd0;
            vs_act  <= 1'b0;
        end else begin
            vs_d <= vs_q;

            // 上升沿计数（饱和在 65535，正常 30 fps 下 100 ms 只有 3 个）
            if (vs_q && !vs_d && vs_acc != 16'hFFFF)
                vs_acc <= vs_acc + 16'd1;

            // 窗口
            if (ms_tick) begin
                if (win_cnt >= WIN_MS - 1) begin
                    win_cnt <= 16'd0;
                    vs_cnt  <= (vs_acc > 16'd255) ? 8'd255 : vs_acc[7:0];
                    vs_act  <= (vs_acc != 16'd0);
                    vs_acc  <= 16'd0;
                end else begin
                    win_cnt <= win_cnt + 16'd1;
                end
            end
        end

endmodule
