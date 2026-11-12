// =============================================================================
// frame_snap.v —— 缩略图抓帧 + UART 导出（用于离线调阈值 / 看构图）
// -----------------------------------------------------------------------------
// 【为什么需要它】color_detect 的阈值原来是盲调的：板子只回几个统计数
// （R/G/B/Y 计数、S、SB、LB），看不到"摄像头到底拍到了什么"。
// 有了它就能把一帧降采样成 GW×GH 的小图经串口发到 PC，存成 PNG 后
// 用 tools/tune_color.py 复现 RTL 的分类逻辑、网格搜索阈值，
// 调好的参数直接抄回 color_detect.v 的 parameter，不会出现"PC 与板子不一致"。
//
// 【为什么不做整帧】1280×720×2 B = 1.8 MB，115200 下要发 2.6 分钟，
// 还要 1.8 MB 存储（得动 DDR）。缩略图 40×30 = 1200 像素 = 2400 B，
// 发完 0.42 s，用分布式 RAM 就够。
//
// 【数据格式】每帧发 GH 行，每行：
//   'S' + GW×4 个 hex（每像素 RGB565，高字节在前）+ CR + LF
//
// 【时序要点】
//   1. 采样在 pclk 域、发送在 clk 域；fb 是分布式 RAM（pclk 写、组合读），
//      跨域只读地址，安全。
//   2. 发送期间 busy 拉高并同步回 pclk 域关掉写口，否则发到一半被下一帧覆盖，
//      会出现半新半旧的撕裂。
//   3. 上电等 FIRST_MS（默认 1500 ms，等 SCCB 配置 + AWB 稳定）再抓，
//      连续 NDUMP 次、间隔 GAP_MS，抓够后永久停手，不干扰常规输出。
// =============================================================================
`timescale 1ns/1ns

module frame_snap #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer BAUD     = 115_200,
    parameter integer GW       = 40,        // 横向格数（40 × 32 = 1280）
    parameter integer GH       = 30,        // 纵向格数（30 × 24 = 720）
    parameter integer PXS_LOG2 = 5,         // 每格横向 2^5 = 32 像素
    parameter integer STRIDE   = 24,        // 每格纵向 24 行
    parameter integer FIRST_MS = 1500,      // 上电先等多久
    parameter integer GAP_MS   = 1000,      // 两次抓帧间隔
    parameter integer NDUMP    = 3          // 抓几帧
) (
    input  wire        clk,          // 24 MHz
    input  wire        rst_n,
    // ---- DVP 输入（pclk 域）----
    input  wire        pclk,
    input  wire        href,
    input  wire        vsync,
    input  wire [7:0]  data,
    // ---- 结果 ----
    output wire        tx,           // 与 uart_report 分时复用同一根调试串口
    output wire        busy          // 抓帧/发送期间为 1，顶层用它压住常规输出
);

    localparam integer NW     = GW * GH;
    localparam integer MS_DIV = CLK_FREQ / 1000;

    // ==================================================================
    // pclk 域：采样
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

    reg href_d, vsync_d;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n) begin
            href_d  <= 1'b0;
            vsync_d <= 1'b0;
        end else begin
            href_d  <= href_r;
            vsync_d <= vsync_r;
        end

    wire href_rise = href_r & ~href_d;
    wire href_fall = ~href_r & href_d;
    wire vs_rise   = vsync_r & ~vsync_d;

    reg        hi_byte;
    reg [7:0]  b_hi;
    wire       px_done = href_r & hi_byte;        // 低字节那一拍：一像素完整

    reg [11:0] pix_idx;          // 行内像素序号
    reg [15:0] line_stride;      // 行计数，0..STRIDE-1
    reg        samp_line;        // 本行是否采样
    reg [15:0] gy;               // 已采样行号 0..GH-1

    reg [15:0] fb [0:NW-1];      // 分布式 RAM：pclk 写

    // 【存储器的推断方式很关键，这里踩了三个坑】
    //   1) 在时序块里过程化读（`pixbuf <= fb[cell_i]`）→ 整块被综合成触发器
    //      （FF 23443 / LUT4 43286，P&R 直接失败）。
    //   2) 改成组合读（`wire fb_q = fb[addr]`）→ 变成 logic memory（LUTRAM），
    //      但"读端口不同步"会被复制成两份（19200×2 bit），仍然吃 1.3 万 LUT。
    //   3) 最终方案：**同步读**（下面这个 always）→ 落到块 RAM，只占 5 个 4Kb 块。
    //      代价是读延迟 1 拍，用 S_LD 状态等 uart 发完上一字节，天然够了。
    reg  [11:0] rd_addr;
    reg  [15:0] fb_q;

    always @(posedge clk)
        fb_q <= fb[rd_addr];

    reg [1:0] busy_s;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n) busy_s <= 2'b00;
        else        busy_s <= {busy_s[0], busy};
    wire wr_ok = ~busy_s[1];

    wire [11:0] gx      = pix_idx >> PXS_LOG2;
    wire [22:0] cell_w  = gy * GW + gx;   // 乘积 23 位，加宽避免截断告警
    wire        hit_pix = px_done && samp_line && wr_ok &&
                          ((pix_idx & ((1 << PXS_LOG2) - 1)) == (1 << (PXS_LOG2 - 1)));

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            hi_byte     <= 1'b0;
            b_hi        <= 8'h00;
            pix_idx     <= 12'd0;
            line_stride <= 16'd0;
            samp_line   <= 1'b0;
            gy          <= 16'd0;
        end else begin
            // ---- 字节组装 ----
            if (!href_r) begin
                hi_byte <= 1'b0;
                pix_idx <= 12'd0;
            end else if (!hi_byte) begin
                b_hi    <= data_r;
                hi_byte <= 1'b1;
            end else begin
                hi_byte <= 1'b0;
                pix_idx <= pix_idx + 12'd1;
            end

            // ---- 中心像素写入 ----
            if (hit_pix && cell_w < NW)
                fb[cell_w] <= {b_hi, data_r};

            // ---- 行采样控制 ----
            if (vs_rise) begin
                line_stride <= 16'd0;
                samp_line   <= 1'b0;
                gy          <= 16'd0;
            end else if (href_rise) begin
                samp_line <= (line_stride == 16'd0);      // 每 STRIDE 行采一行
            end else if (href_fall) begin
                line_stride <= (line_stride >= STRIDE - 1) ? 16'd0 : line_stride + 16'd1;
                if (samp_line && gy < GH - 1)
                    gy <= gy + 16'd1;
            end
        end
    end

    // ==================================================================
    // clk 域：调度 + 发送
    // ==================================================================
    localparam [2:0] S_WAIT = 3'd0,
                     S_LS   = 3'd1,
                     S_PIX  = 3'd2,
                     S_CR   = 3'd3,
                     S_LF   = 3'd4,
                     S_GAP  = 3'd5,
                     S_LD   = 3'd6;    // 装载下一像素（组合读 → 寄存器，1 拍）

    reg [2:0]  st;
    reg [11:0] cell_i;
    reg [5:0]  col_i;         // 行内格号 0..GW-1
    reg [4:0]  line_i;
    reg [1:0]  nib_i;
    reg [15:0] pixbuf;
    reg        busy_r;
    reg [3:0]  dump_n;
    reg [15:0] wait_ms;
    reg [15:0] ms_in_st;

    reg        t_start;
    reg  [7:0] t_data;
    wire       t_busy;

    assign busy = busy_r;

    function [7:0] hexd;
        input [3:0] n;
        begin
            hexd = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
        end
    endfunction

    wire [3:0] nib = (nib_i == 2'd0) ? pixbuf[15:12] :
                     (nib_i == 2'd1) ? pixbuf[11:8]  :
                     (nib_i == 2'd2) ? pixbuf[7:4]   : pixbuf[3:0];

    // 1 ms 节拍
    reg [15:0] ms_div;
    wire       ms_tick = (ms_div >= MS_DIV - 1);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) ms_div <= 16'd0;
        else        ms_div <= ms_tick ? 16'd0 : ms_div + 16'd1;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            st        <= S_WAIT;
            cell_i    <= 12'd0;
            rd_addr   <= 12'd0;
            col_i     <= 6'd0;
            line_i    <= 5'd0;
            nib_i     <= 2'd0;
            pixbuf    <= 16'd0;
            t_start   <= 1'b0;
            t_data    <= 8'h00;
            busy_r    <= 1'b0;
            dump_n    <= 4'd0;
            wait_ms   <= FIRST_MS[15:0];
            ms_in_st  <= 16'd0;
        end else begin
            t_start <= 1'b0;

            case (st)
            S_WAIT: begin
                if (ms_tick) begin
                    if (ms_in_st + 16'd1 >= wait_ms) begin
                        ms_in_st <= 16'd0;
                        cell_i   <= 12'd0;
                        rd_addr  <= 12'd0;
                        col_i    <= 6'd0;
                        line_i   <= 5'd0;
                        nib_i    <= 2'd0;
                        busy_r   <= 1'b1;
                        st       <= S_LS;
                    end else begin
                        ms_in_st <= ms_in_st + 16'd1;
                    end
                end
            end

            S_LS: begin
                if (!t_busy && !t_start) begin
                    t_data  <= 8'h53;                     // 'S'
                    t_start <= 1'b1;
                    nib_i   <= 2'd0;
                    st      <= S_LD;
                end
            end

            S_LD: begin
                // 等上一字节发完（uart busy 约 200 个 clk），同步读的数据早已就位
                if (!t_busy && !t_start) begin
                    pixbuf <= fb_q;
                    st     <= S_PIX;
                end
            end

            S_PIX: begin
                if (!t_busy && !t_start) begin
                    t_data  <= hexd(nib);
                    t_start <= 1'b1;
                    if (nib_i != 2'd3) begin
                        nib_i <= nib_i + 2'd1;
                    end else begin
                        nib_i <= 2'd0;
                        if (col_i == GW - 1) begin
                            st    <= S_CR;                  // 一行结束
                            col_i <= 6'd0;
                        end else begin
                            col_i   <= col_i + 6'd1;
                            cell_i  <= cell_i + 12'd1;
                            rd_addr <= cell_i + 12'd1;
                            st      <= S_LD;
                        end
                    end
                end
            end

            S_CR: begin
                if (!t_busy && !t_start) begin
                    t_data  <= 8'h0D;
                    t_start <= 1'b1;
                    st      <= S_LF;
                end
            end

            S_LF: begin
                if (!t_busy && !t_start) begin
                    t_data  <= 8'h0A;
                    t_start <= 1'b1;
                    if (line_i == GH - 1) begin
                        busy_r  <= 1'b0;
                        dump_n  <= dump_n + 4'd1;
                        wait_ms <= (dump_n + 4'd1 >= NDUMP) ? 16'hFFFF : GAP_MS[15:0];
                        st      <= S_GAP;
                    end else begin
                        line_i  <= line_i + 5'd1;
                        cell_i  <= cell_i + 12'd1;      // 下一行第一格
                        rd_addr <= cell_i + 12'd1;
                        st      <= S_LS;
                    end
                end
            end

            S_GAP: begin
                if (dump_n >= NDUMP)
                    st <= S_GAP;                          // 抓够次数，永久停手
                else
                    st <= S_WAIT;
            end

            default: st <= S_WAIT;
            endcase
        end

    // ==================================================================
    // UART 发送器
    // ==================================================================
    uart_tx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (BAUD)
    ) u_tx (
        .clk   (clk),
        .rst_n (rst_n),
        .data  (t_data),
        .start (t_start),
        .busy  (t_busy),
        .tx    (tx)
    );

endmodule
