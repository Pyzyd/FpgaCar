// =============================================================================
// oled_driver.v —— SSD1306 128x64 单色 OLED 驱动（I2C，7 位地址 0x3C）
// -----------------------------------------------------------------------------
// 为什么自带 I2C 引擎、不复用 src/i2c_master.v：
//   SSD1306 写显存是「[从机地址][控制字节 0x40][N 个显存字节]」在同一个
//   START-STOP 内完成；i2c_master 只有单字节事务，拆成 N 次会被屏当成 N 次
//   独立访问，每次的首字节都被解释成从机地址 → 花屏。i2c_master 已被 tb 验证
//   过，不动它，另写一个支持 3~1030 字节连发的引擎，相位时序与它逐行对应。
//
// 事务结构（一次 START-STOP 内）：
//   byte0 = {DEV_ADDR, 1'b0}         从机地址 + 写
//   byte1 = 0x40（数据流）/ 0x00（命令）  控制字节
//   byte2.. = payload（命令字节 或 显存字节）
//
// 显示内容（细则 4.3.3 / 5.1：颜色顺序必须在车载屏持续显示到裁判拍照）：
//   4 个 32x32 汉字「红/绿/蓝/黄」从左到右横排，纵向居中（行 16~47 = page 2~5）。
//   字形来自 oled_font.v（simhei 30px 生成）。槽位颜色码 1=红 2=绿 3=蓝 4=黄，
//   0 = 空槽（画空白，便于调试时只看前 n 个）。
//
// 刷新策略：颜色顺序变化时重画；另外每 2 s 无条件重推一次，防止上电毛刺或
//   总线干扰丢帧。一次全屏 = 列窗命令 + 页窗命令 + 1026 字节数据流。
//
// 上电自检（2026-11-12 增加，解决「屏本来就是黑的，看不出有没有启动」）：
//   ① 复位后整屏填 0xFF 推出去 -> 屏全白 FLASH_MS(默认 600 ms)，肉眼可见；
//   ② 计时到后整屏填 0x00 再推 -> 屏转黑；
//   ③ 之后正常渲染 4 个色块；ALIVE_MARK=1 时在 page 0 / col 0..7 画一个
//      8x8 实心方块常亮，作为「固件在跑、屏在线」的持续标志
//      （4 个色块都还空着时，屏上就只剩这个小方块，一眼能分辨死屏和活屏）。
//   判据：见到白闪 = 初始化 + 清屏 + 整屏推送 + 屏本体全通；
//         只剩左上角小方块 = 通，只是还没有颜色顺序要显示；
//         连白闪都没有 = 初始化 / 接线 / 地址问题（见 PROJECT_PLAN 3.16）。
//
// 【SDA 三根线】Efinix Titanium 顶层不允许 inout/1'bz（EFX-0410），
//   sda_in / sda_out / sda_oe 三根分开，物理三态由 Interface Designer 合成。
// =============================================================================
`timescale 1ns/1ns

module oled_driver #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer SCL_FREQ = 400_000,
    parameter [6:0]   DEV_ADDR = 7'h3C,
    parameter integer BOOT_MS  = 20,         // 上电后等屏内电荷泵稳定
    parameter integer FLASH_MS = 600,        // 上电全白自检保持时长（0 = 关闭）
    parameter integer ALIVE_MARK = 1         // 1 = 左上角常亮 8x8 存活标记
) (
    input  wire       clk,
    input  wire       rst_n,
    // ---- 颜色顺序输入 ----
    input  wire       seq_valid,   // 1 clk 脉冲：seq0~3 已更新
    input  wire [2:0] seq0,        // 第 1 个出现的颜色（最左）
    input  wire [2:0] seq1,
    input  wire [2:0] seq2,
    input  wire [2:0] seq3,        // 第 4 个（最右）
    // ---- I2C 物理层（三态拆线）----
    output reg        scl,
    input  wire       sda_in,
    output reg        sda_out,
    output reg        sda_oe,
    // ---- 状态观测 ----
    output wire       busy,        // 总线事务进行中
    output reg        ack_err,     // 最近一次事务有 NACK（每次事务开始清零）
    output reg        frame_done,  // 1 clk 脉冲：一整屏推完
    // 粘滞标志：复位后只要出现过一次 NACK 就置 1，且不再清零。
    // 用途：上板黑屏时区分「屏一次都没应答」（接线/地址/上拉）与
    //       「总线通了但屏没显示」（时序/对比度/电荷泵）——ack_err 每笔事务
    //       开始就清，靠它无法在串口上看到历史，所以单独锁存一份。
    output reg        nack_seen
);

    // ------------------------------------------------------------------
    // 相位节拍：1 bit = 3 相位，每相位 DIV 个 clk
    // ------------------------------------------------------------------
    localparam integer DIV_RAW = CLK_FREQ / (SCL_FREQ * 3);
    localparam integer DIV     = (DIV_RAW < 1) ? 1 : DIV_RAW;

    reg [15:0] div_cnt;
    reg        tick;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            div_cnt <= 16'd0;
            tick    <= 1'b0;
        end else if (div_cnt >= DIV - 1) begin
            div_cnt <= 16'd0;
            tick    <= 1'b1;
        end else begin
            div_cnt <= div_cnt + 16'd1;
            tick    <= 1'b0;
        end

    // SDA 输入两级同步（异步引脚）
    reg [1:0] sda_sync;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) sda_sync <= 2'b11;
        else        sda_sync <= {sda_sync[0], sda_in};
    wire sda_q = sda_sync[1];

    // ------------------------------------------------------------------
    // 显存 128x64 = 1024 字节（页格式：byte[page*128 + col]）
    // 写只在 S_CLEAR / S_RENDER，读只在发送时，两者不重叠 → 推断为块 RAM
    // ------------------------------------------------------------------
    reg [7:0] fb [0:1023];

    // ------------------------------------------------------------------
    // 汉字点阵 ROM（异步读）
    // ------------------------------------------------------------------
    reg  [2:0] cur_color;
    wire [8:0] font_addr;
    wire [7:0] font_q;
    oled_font u_font (.addr(font_addr), .q(font_q));

    // ------------------------------------------------------------------
    // 事务请求（调度器驱动，引擎在 E_IDLE 且 x_req 时锁存）
    // ------------------------------------------------------------------
    reg        x_req;
    reg        x_data;            // 1 = 显存数据流（控制字节 0x40），0 = 命令（0x00）
    reg [10:0] x_len;             // 总字节数（含地址字节与控制字节）
    reg [9:0]  x_base;            // 数据流起始显存地址
    reg [7:0]  x_b0, x_b1, x_b2;  // 命令事务的第 0~2 个命令字节

    // ------------------------------------------------------------------
    // I2C 字节引擎
    // ------------------------------------------------------------------
    localparam [2:0] E_IDLE = 3'd0, E_START = 3'd1, E_BYTE = 3'd2,
                     E_ACK  = 3'd3, E_STOP  = 3'd4;

    reg [2:0]  estate;
    reg [1:0]  ephase;
    reg [2:0]  ebit;
    reg [7:0]  shreg;
    reg [10:0] bytec;
    reg [10:0] bidx;          // 事务内字节序号：0=地址 1=控制 >=2=payload
    reg [9:0]  txa;           // payload 读地址（显存）
    reg        e_data;
    reg        e_done;
    reg        e_busy;
    reg        frame_pend;    // 当前挂起的事务是整屏数据流（决定 frame_done）
    reg [7:0]  tb0, tb1, tb2;

    // 下一字节在 ACK 终点装入 shreg（见 E_ACK 的 default 分支）：
    //   bidx = 0 → 控制字节；bidx = 1 → 第一个命令字节 / 第一个显存字节；
    //   其余按 bidx 递增取 tb1、tb2 或 fb[txa+1]。

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            estate  <= E_IDLE;
            ephase  <= 2'd0;
            ebit    <= 3'd7;
            shreg   <= 8'hFF;
            bytec   <= 11'd0;
            bidx    <= 11'd0;
            txa     <= 10'd0;
            e_data  <= 1'b0;
            tb0     <= 8'h00;
            tb1     <= 8'h00;
            tb2     <= 8'h00;
            e_busy  <= 1'b0;
            e_done  <= 1'b0;
            nack_seen <= 1'b0;      // 只在复位时清，运行中永不回落
            scl     <= 1'b1;
            sda_out <= 1'b1;
            sda_oe  <= 1'b0;
        end else begin
            e_done <= 1'b0;

            case (estate)
            // ---------------- 空闲：等请求 ----------------
            E_IDLE: begin
                scl     <= 1'b1;
                sda_oe  <= 1'b0;
                sda_out <= 1'b1;
                e_busy  <= 1'b0;
                ephase  <= 2'd0;
                ebit    <= 3'd7;
                if (x_req) begin
                    e_busy  <= 1'b1;
                    ack_err <= 1'b0;
                    e_data  <= x_data;
                    bytec   <= x_len;
                    bidx    <= 11'd0;
                    txa     <= x_base;
                    tb0     <= x_b0;
                    tb1     <= x_b1;
                    tb2     <= x_b2;
                    shreg   <= {DEV_ADDR, 1'b0};
                    sda_oe  <= 1'b1;
                    sda_out <= 1'b0;                     // START：SCL 高时拉低 SDA
                    estate  <= E_START;
                end
            end

            // ---------------- START 保持 ----------------
            E_START: if (tick) begin
                if (ephase == 2'd0) begin
                    ephase <= 2'd1;                      // 保持 t_HD_STA
                end else begin
                    scl    <= 1'b0;
                    ephase <= 2'd0;
                    ebit   <= 3'd7;
                    estate <= E_BYTE;
                end
            end

            // ---------------- 发送一个字节 ----------------
            E_BYTE: if (tick) begin
                case (ephase)
                2'd0: begin
                    sda_oe  <= 1'b1;
                    sda_out <= shreg[7];
                    scl     <= 1'b0;
                    ephase  <= 2'd1;
                end
                2'd1: begin
                    scl    <= 1'b1;                      // 从机采样
                    ephase <= 2'd2;
                end
                default: begin
                    scl    <= 1'b0;
                    shreg  <= {shreg[6:0], 1'b0};
                    ephase <= 2'd0;
                    if (ebit == 3'd0) estate <= E_ACK;
                    else              ebit   <= ebit - 3'd1;
                end
                endcase
            end

            // ---------------- 接收从机 ACK ----------------
            E_ACK: if (tick) begin
                case (ephase)
                2'd0: begin
                    sda_oe <= 1'b0;                      // 释放 SDA 给从机
                    scl    <= 1'b0;
                    ephase <= 2'd1;
                end
                2'd1: begin
                    scl    <= 1'b1;
                    ephase <= 2'd2;
                end
                default: begin
                    scl     <= 1'b0;
                    ack_err <= ack_err | sda_q;          // 1 = NACK
                    if (sda_q) nack_seen <= 1'b1;        // 粘滞：记「曾经没人应答」
                    ephase  <= 2'd0;
                    ebit    <= 3'd7;
                    bytec   <= bytec - 11'd1;
                    bidx    <= bidx + 11'd1;
                    if (bytec <= 11'd1) begin
                        estate <= E_STOP;
                    end else begin
                        // 装入下一字节
                        if (bidx == 11'd0)      shreg <= e_data ? 8'h40 : 8'h00;
                        else if (!e_data)       shreg <= (bidx == 11'd1) ? tb0 :
                                                        (bidx == 11'd2) ? tb1 : tb2;
                        else                    shreg <= (bidx == 11'd1) ? fb[txa]
                                                                       : fb[txa + 10'd1];
                        if (e_data && (bidx >= 11'd2)) txa <= txa + 10'd1;
                        estate <= E_BYTE;
                    end
                end
                endcase
            end

            // ---------------- STOP ----------------
            E_STOP: if (tick) begin
                case (ephase)
                2'd0: begin
                    sda_oe  <= 1'b1;
                    sda_out <= 1'b0;
                    scl     <= 1'b0;
                    ephase  <= 2'd1;
                end
                2'd1: begin
                    scl    <= 1'b1;                      // 先抬 SCL
                    ephase <= 2'd2;
                end
                2'd2: begin
                    sda_oe <= 1'b0;                      // 再释放 SDA → STOP
                    ephase <= 2'd3;
                end
                default: begin
                    scl    <= 1'b1;
                    e_busy <= 1'b0;
                    e_done <= 1'b1;
                    estate <= E_IDLE;
                    ephase <= 2'd0;
                end
                endcase
            end

            default: estate <= E_IDLE;
            endcase
        end
    end

    assign busy = e_busy;

    // ------------------------------------------------------------------
    // SSD1306 初始化命令表（地址/控制字节由引擎发，这里只列命令+参数）
    // ------------------------------------------------------------------
    reg [1:0] init_n;
    reg [7:0] init_b0, init_b1;
    reg [4:0] init_idx;
    always @(*) begin
        init_n  = 2'd1;
        init_b0 = 8'h00;
        init_b1 = 8'h00;
        case (init_idx)
        5'd0:  begin init_n = 2'd1; init_b0 = 8'hAE; end                  // display off
        5'd1:  begin init_n = 2'd2; init_b0 = 8'hD5; init_b1 = 8'h80; end // clock div
        5'd2:  begin init_n = 2'd2; init_b0 = 8'hA8; init_b1 = 8'h3F; end // multiplex 64
        5'd3:  begin init_n = 2'd2; init_b0 = 8'hD3; init_b1 = 8'h00; end // display offset 0
        5'd4:  begin init_n = 2'd1; init_b0 = 8'h40; end                  // start line 0
        5'd5:  begin init_n = 2'd2; init_b0 = 8'h8D; init_b1 = 8'h14; end // charge pump on
        5'd6:  begin init_n = 2'd2; init_b0 = 8'h20; init_b1 = 8'h00; end // horizontal addr
        5'd7:  begin init_n = 2'd1; init_b0 = 8'hA1; end                  // segment remap
        5'd8:  begin init_n = 2'd1; init_b0 = 8'hC8; end                  // COM scan dec
        5'd9:  begin init_n = 2'd2; init_b0 = 8'hDA; init_b1 = 8'h12; end // COM pins
        5'd10: begin init_n = 2'd2; init_b0 = 8'h81; init_b1 = 8'hCF; end // contrast
        5'd11: begin init_n = 2'd2; init_b0 = 8'hD9; init_b1 = 8'hF1; end // precharge
        5'd12: begin init_n = 2'd2; init_b0 = 8'hDB; init_b1 = 8'h40; end // VCOMH
        5'd13: begin init_n = 2'd1; init_b0 = 8'hA4; end                  // display from RAM
        5'd14: begin init_n = 2'd1; init_b0 = 8'hA6; end                  // normal (not inverse)
        5'd15: begin init_n = 2'd1; init_b0 = 8'h2E; end                  // deactivate scroll
        5'd16: begin init_n = 2'd1; init_b0 = 8'hAF; end                  // display on
        default: begin init_n = 2'd1; init_b0 = 8'h00; end
        endcase
    end
    localparam [4:0] INIT_LAST = 5'd16;

    // ------------------------------------------------------------------
    // 顶层调度
    // ------------------------------------------------------------------
    localparam [2:0] S_BOOT = 3'd0, S_INIT = 3'd1, S_CLEAR = 3'd2,
                     S_RENDER = 3'd3, S_PUSH = 3'd4, S_WAIT = 3'd5,
                     S_FLASH_WAIT = 3'd6, S_MARK = 3'd7;

    reg [2:0]  state;
    reg [20:0] boot_cnt;
    reg [25:0] refresh_cnt;
    reg        pend;          // 已发请求、等 e_done

    reg [2:0]  seq0_r, seq1_r, seq2_r, seq3_r;
    reg        dirty;

    reg [9:0]  clr;           // 清屏计数
    reg [7:0]  clr_val;       // 清屏填充值：白闪阶段 8'hFF，之后 8'h00
    reg        boot_flash;    // 1 = 仍在上电白闪阶段
    reg        need_render;   // 1 = 显存刚清完、还没画色块
    reg [25:0] flash_cnt;     // 白闪保持计时
    reg [3:0]  mk;            // 存活标记列计数 0..7
    reg [2:0]  rs;            // 渲染槽 0..3
    reg [1:0]  gp;            // 字形内 page 0..3
    reg [4:0]  rc;            // col 0..31
    reg [1:0]  pk;            // 推送步进：0=列窗 1=页窗 2=数据流

    // 当前槽颜色（供显存写入与 ROM 地址共用）
    always @(*) begin
        case (rs)
        3'd0:    cur_color = seq0_r;
        3'd1:    cur_color = seq1_r;
        3'd2:    cur_color = seq2_r;
        default: cur_color = seq3_r;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_BOOT;
            init_idx    <= 5'd0;
            boot_cnt    <= 21'd0;
            refresh_cnt <= 26'd0;
            pend        <= 1'b0;
            seq0_r      <= 3'd0;
            seq1_r      <= 3'd0;
            seq2_r      <= 3'd0;
            seq3_r      <= 3'd0;
            dirty       <= 1'b1;
            clr         <= 10'd0;
            clr_val     <= (FLASH_MS > 0) ? 8'hFF : 8'h00;
            boot_flash  <= (FLASH_MS > 0) ? 1'b1 : 1'b0;
            need_render <= 1'b1;
            flash_cnt   <= 26'd0;
            mk          <= 4'd0;
            rs          <= 3'd0;
            gp          <= 2'd0;
            rc          <= 5'd0;
            pk          <= 2'd0;
            frame_done  <= 1'b0;
            frame_pend  <= 1'b0;
            x_req       <= 1'b0;
            x_data      <= 1'b0;
            x_len       <= 11'd0;
            x_base      <= 10'd0;
            x_b0        <= 8'h00;
            x_b1        <= 8'h00;
            x_b2        <= 8'h00;
        end else begin
            x_req      <= 1'b0;
            frame_done <= 1'b0;

            // ---- 颜色顺序锁存 ----
            if (seq_valid) begin
                seq0_r      <= seq0;
                seq1_r      <= seq1;
                seq2_r      <= seq2;
                seq3_r      <= seq3;
                dirty       <= 1'b1;
                refresh_cnt <= 26'd0;
            end else if (refresh_cnt != 26'h3FFFFFF) begin
                refresh_cnt <= refresh_cnt + 26'd1;
            end

            // ---- 2 s 定时重推 ----
            if (refresh_cnt == CLK_FREQ * 2 - 1) begin
                refresh_cnt <= 26'd0;
                dirty       <= 1'b1;
            end

            // ---- 请求/完成握手 ----
            // frame_done 只对「整屏数据流」那一笔给脉冲（初始化命令不算），且放在
            // 全局而不是 S_WAIT 里：推完一屏后可能跳去白闪等待/渲染/空闲，都得报。
            if (pend && e_done) begin
                pend <= 1'b0;
                if (frame_pend) begin
                    frame_done <= 1'b1;
                    frame_pend <= 1'b0;
                end
            end

            case (state)
            // ---------------- 上电等待 ----------------
            S_BOOT: begin
                if (boot_cnt >= CLK_FREQ / 1000 * BOOT_MS) begin
                    boot_cnt <= 21'd0;
                    state    <= S_INIT;
                end else begin
                    boot_cnt <= boot_cnt + 21'd1;
                end
            end

            // ---------------- 初始化序列 ----------------
            S_INIT: begin
                if (!pend) begin
                    if (init_idx > INIT_LAST) begin
                        clr   <= 10'd0;
                        state <= S_CLEAR;
                    end else begin
                        x_req  <= 1'b1;
                        x_data <= 1'b0;
                        x_len  <= {9'd0, init_n} + 11'd2;   // 地址 + 控制 + 命令
                        x_b0   <= init_b0;
                        x_b1   <= init_b1;
                        x_b2   <= 8'h00;
                        pend   <= 1'b1;
                    end
                end else if (e_done) begin
                    init_idx <= init_idx + 5'd1;
                end
            end

            // ---------------- 清显存（page 0/1/6/7 永远不被渲染覆盖）----
            S_CLEAR: begin
                fb[clr] <= clr_val;
                if (clr == 10'h3FF) begin
                    rs          <= 3'd0;
                    gp          <= 2'd0;
                    rc          <= 5'd0;
                    pk          <= 2'd0;
                    mk          <= 4'd0;
                    need_render <= 1'b1;      // 显存是干净的，色块还没画
                    state       <= S_PUSH;    // 先把这一屏（白或黑）推出去
                end else begin
                    clr <= clr + 10'd1;
                end
            end

            // ---------------- 渲染：4 个槽的汉字写进显存 page 2~5 ----------------
            S_RENDER: begin
                if (rs <= 3'd3) begin
                    // page = gp + 2（2..5），必须扩到 3 位，否则 gp=3 时溢出回 page 1
                    fb[{(gp + 3'd2), 7'd0} + {rs, 5'd0} + {5'd0, rc}]
                        <= (cur_color == 3'd0) ? 8'h00 : font_q;
                    if (rc == 5'd31) begin
                        rc <= 5'd0;
                        if (gp == 2'd3) begin
                            gp <= 2'd0;
                            rs <= rs + 3'd1;
                        end else begin
                            gp <= gp + 2'd1;
                        end
                    end else begin
                        rc <= rc + 5'd1;
                    end
                end else begin
                    rs          <= 3'd0;
                    gp          <= 2'd0;
                    rc          <= 5'd0;
                    pk          <= 2'd0;
                    mk          <= 4'd0;
                    need_render <= 1'b0;      // 色块已写进显存
                    state       <= (ALIVE_MARK != 0) ? S_MARK : S_PUSH;
                end
            end

            // ---------------- 推送一整屏 ----------------
            S_PUSH: begin
                if (!pend) begin
                    case (pk)
                    2'd0: begin   // 列窗口 0..127 : 21 00 7F
                        x_req  <= 1'b1;
                        x_data <= 1'b0;
                        x_len  <= 11'd5;
                        x_b0   <= 8'h21;
                        x_b1   <= 8'h00;
                        x_b2   <= 8'h7F;
                        pend   <= 1'b1;
                        pk     <= 2'd1;
                    end
                    2'd1: begin   // 页窗口 0..7 : 22 00 07
                        x_req  <= 1'b1;
                        x_data <= 1'b0;
                        x_len  <= 11'd5;
                        x_b0   <= 8'h22;
                        x_b1   <= 8'h00;
                        x_b2   <= 8'h07;
                        pend   <= 1'b1;
                        pk     <= 2'd2;
                    end
                    default: begin // 1024 字节显存 + 地址 + 控制
                        x_req  <= 1'b1;
                        x_data <= 1'b1;
                        x_len  <= 11'd1026;
                        x_base <= 10'd0;
                        pend   <= 1'b1;
                        pk         <= 2'd0;
                        dirty      <= 1'b0;
                        frame_pend <= 1'b1;   // 这一笔推完 = 一屏推完
                        // 白闪那一屏推完先停住让肉眼看见；其余一律回 S_WAIT，
                        // 由 S_WAIT 在传输真正结束后（!pend）再去渲染。
                        // 不能在这里直接跳 S_RENDER：此刻 1026 字节还在推，
                        // 渲染会改掉还没发出的显存内容（仿真里表现为整屏
                        // 「一半黑一半色块」）。
                        if (boot_flash)
                            state <= S_FLASH_WAIT;
                        else
                            state <= S_WAIT;
                    end
                    endcase
                end
            end

            // ---------------- 上电白闪保持（肉眼可见「固件起来了」）----
            S_FLASH_WAIT: begin
                // 必须等这一屏真正推完（!pend）才开始计时：1026 字节 @400 kHz 约 26 ms，
                // 若边推边倒计时，计时一到就去清显存，会把还在读的 fb 改掉（仿真里
                // FLASH_MS=1 时表现为整屏只推出去一半）。
                if (pend) begin
                    flash_cnt <= 26'd0;
                end else if (flash_cnt >= FLASH_MS * (CLK_FREQ / 1000)) begin
                    flash_cnt  <= 26'd0;
                    boot_flash <= 1'b0;
                    clr_val    <= 8'h00;      // 下一遍把整屏清成全黑
                    clr        <= 10'd0;
                    state      <= S_CLEAR;
                end else begin
                    flash_cnt <= flash_cnt + 26'd1;
                end
            end

            // -------- 左上角存活标记：page 0, col 0..7 写 0xFF（8x8 实心）----
            S_MARK: begin
                if (mk <= 4'd7) begin
                    fb[{7'd0, mk[2:0]}] <= 8'hFF;
                    mk <= mk + 4'd1;
                end else begin
                    mk    <= 4'd0;
                    state <= S_PUSH;
                end
            end

            // ---------------- 空闲：等下一次刷新 ----------------
            S_WAIT: begin
                if (!pend && need_render) state <= S_RENDER;   // 先补画色块
                else if (dirty && !pend)  state <= S_RENDER;
            end

            default: state <= S_BOOT;
            endcase
        end
    end

    // 字形地址：(color-1)*128 + gp*32 + rc
    assign font_addr = ((cur_color - 3'd1) << 7) + (gp << 5) + rc;

endmodule
