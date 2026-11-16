// =============================================================================
// uart_report.v —— 调试串口：把"距离 + 循迹状态 + 障碍 + 状态机 + 里程"打成两行
// -----------------------------------------------------------------------------
// 每来一个 dist_valid 脉冲（hc_sr04 每 60 ms 一帧）打两行，格式固定：
//
//     D=123cm T=00011000 P=+02 O=0 M=01          (35 字节)
//     L=00000123 R=00000123 VL=0005 VR=0005      (39 字节)
//
//   D=xxxcm : 超声波距离；--- 表示无回波/超量程
//   T=      : 8 路循迹探头，bit7..bit0 对应 track[7]..track[0]，1=压线
//   P=+02   : 加权质心位置，-16..+16，正=线在右
//   O=      : 1=前方有障碍（超声波近距 或 任一路红外触发）
//   M=nn    : 状态机状态（00 IDLE 01 RUN 02 LOST 03 SEARCH 04 STOP，两位十进制）
//   L=/R=   : 左右编码器累计里程，8 位十六进制二补码（标定每米脉冲数用）
//   VL=/VR= : 左右速度，每 50 ms 窗口净步数，4 位十六进制二补码
//
// 【为什么里程用十六进制】编码器计数是 32 位有符号，十进制要套 8 次 div10，
// 组合逻辑代价比信息价值大；解析时按行首字母分流，主机侧再换算即可。
// 【为什么加 M=】此前串口只能看到"车不动了"，分不清是 IDLE 没起跑、SEARCH
// 原地找线、还是 STOP 永久停车 —— 这三种情况现场处置完全不同。
//
// 115200 波特下两行约 6.5 ms，而一帧 60 ms，永远发得完，不需要队列。
// REPORT_EN=0 时整行静音（UART 保持空闲高），正式跑车可关掉省电/防干扰。
// =============================================================================
`timescale 1ns/1ns

module uart_report #(
    parameter integer CLK_FREQ  = 24_000_000,
    parameter integer BAUD      = 115_200,
    parameter integer REPORT_EN = 1          // 0 = 不输出
) (
    input  wire        clk,
    input  wire        rst_n,      // 低有效（已同步化）
    input  wire [15:0] dist_cm,    // 距离，16'hFFFF = 无效
    input  wire        dist_valid, // 1 clk 脉冲：dist_cm 已更新，触发本行
    input  wire [7:0]  line,       // 循迹压线位图
    input  wire signed [4:0] pos,  // 线位置
    input  wire        obstacle,   // 障碍标志
    input  wire [2:0]  state,      // 状态机状态（M=）
    input  wire [31:0] enc_l,      // 左编码器累计（二补码）
    input  wire [31:0] enc_r,      // 右编码器累计（二补码）
    input  wire signed [15:0] spd_l,  // 左速度（每窗口净步数）
    input  wire signed [15:0] spd_r,  // 右速度
    output wire        tx
);

    localparam integer MSG_LEN  = 35;   // 第一行：D=/T=/P=/O=/M=
    localparam integer MSG2_LEN = 39;   // 第二行：L=/R=/VL=/VR=

    // ------------------------------------------------------------------
    // 无符号除以 10（移位-减法，10 次迭代，纯组合）
    // ------------------------------------------------------------------
    function [7:0] div10u;
        input [9:0] x;
        integer i;
        reg [9:0] q;
        reg [9:0] r;
        begin
            q = 10'd0;
            r = 10'd0;
            for (i = 9; i >= 0; i = i - 1) begin
                r = {r[8:0], x[i]};
                q = q << 1;
                if (r >= 10) begin
                    r = r - 10;
                    q = q + 1;
                end
            end
            div10u = q[7:0];
        end
    endfunction

    // ------------------------------------------------------------------
    // 半字节转 ASCII（0-9 / A-F）
    // ------------------------------------------------------------------
    function [7:0] hexd;
        input [3:0] n;
        begin
            hexd = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
        end
    endfunction

    // ------------------------------------------------------------------
    // UART 发送器
    // ------------------------------------------------------------------
    reg [7:0] tx_data;
    reg       tx_start;
    wire      tx_busy;
    wire      tx_line;

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .data(tx_data), .start(tx_start), .tx(tx_line), .busy(tx_busy)
    );

    assign tx = REPORT_EN ? tx_line : 1'b1;

    // ------------------------------------------------------------------
    // 报文组装
    // ------------------------------------------------------------------
    reg  [7:0]  msg  [0:MSG_LEN-1];
    reg  [7:0]  msg2 [0:MSG2_LEN-1];
    reg  [6:0]  idx;        // 7 位：MSG_LEN=35，6 位够用，但保持 7 位与历史一致
    reg  [6:0]  idx2;       // 第二行游标（0..39）

    reg  [9:0]  v10;         // 距离（0..999）
    reg         bad;         // 距离无效
    reg  [7:0]  ln;          // 锁存的循迹位图
    reg  signed [4:0] pz;    // 锁存的位置
    reg         obst;        // 锁存的障碍标志
    reg  [2:0]  st;          // 锁存的状态
    reg  [31:0] el, er;      // 锁存的编码器里程
    reg  signed [15:0] sl, sr;  // 锁存的速度

    wire        bad_now = (dist_cm > 16'd999);
    wire [9:0]  v_now   = bad_now ? 10'd999 : dist_cm[9:0];

    // 距离十进制
    wire [7:0]  d_t  = div10u(v10);                 // v10/10  (0..99)
    wire [7:0]  d_h  = div10u({2'b00, d_t[7:0]});   // v10/100 (0..9)
    wire [7:0]  d_tt = d_t - d_h * 8'd10;
    wire [7:0]  d_uu = v10 - d_t * 8'd10;

    // 位置十进制（绝对值 0..16，两位）
    wire [4:0]  p_mag = pz[4] ? (~pz + 5'd1) : pz;
    wire [7:0]  p_t   = div10u({5'd0, p_mag});
    wire [7:0]  p_tt  = p_t;
    wire [7:0]  p_uu  = {3'd0, p_mag} - p_t * 8'd10;

    // 状态两位十进制（0..99，当前只用到 0..4）
    wire [7:0]  m_t   = div10u({2'b00, 5'd0, st});
    wire [7:0]  m_uu  = {5'd0, st} - m_t * 8'd10;

    localparam [2:0] R_IDLE  = 3'd0,
                     R_LOAD  = 3'd1,
                     R_SEND  = 3'd2,
                     R_WAIT  = 3'd3,
                     R_SEND2 = 3'd4,   // 第二行（里程/速度）
                     R_WAIT2 = 3'd5;

    reg [2:0] rstate;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate   <= R_IDLE;
            tx_start <= 1'b0;
            tx_data  <= 8'h00;
            idx      <= 7'd0;
            v10      <= 10'd0;
            bad      <= 1'b1;
            ln       <= 8'h00;
            pz       <= 5'sd0;
            obst     <= 1'b0;
            st       <= 3'd0;
            el       <= 32'd0;
            er       <= 32'd0;
            sl       <= 16'sd0;
            sr       <= 16'sd0;
            idx2     <= 7'd0;
        end else begin
            tx_start <= 1'b0;

            case (rstate)
            R_IDLE: begin
                idx <= 7'd0;
                if (REPORT_EN != 0 && dist_valid) rstate <= R_LOAD;
            end

            // 锁存本次快照（msg[] 由组合逻辑按这些寄存器生成）
            R_LOAD: begin
                bad  <= bad_now;
                v10  <= v_now;
                ln   <= line;
                pz   <= pos;
                obst <= obstacle;
                st   <= state;
                el   <= enc_l;
                er   <= enc_r;
                sl   <= spd_l;
                sr   <= spd_r;
                idx2 <= 7'd0;
                rstate <= R_SEND;
            end

            R_SEND: begin
                if (idx == MSG_LEN) begin
                    idx2   <= 7'd0;
                    rstate <= R_SEND2;        // 第一行发完，接着发里程/速度
                end else if (!tx_busy && !tx_start) begin
                    tx_data  <= msg[idx];
                    tx_start <= 1'b1;
                    idx      <= idx + 7'd1;
                    rstate   <= R_WAIT;
                end
            end

            // uart_tx 采到 start 后下一拍才抬 busy，这里等它确认，避免同一字节发两次
            R_WAIT: begin
                if (tx_busy) rstate <= R_SEND;
            end

            R_SEND2: begin
                if (idx2 == MSG2_LEN) begin
                    rstate <= R_IDLE;
                end else if (!tx_busy && !tx_start) begin
                    tx_data  <= msg2[idx2];
                    tx_start <= 1'b1;
                    idx2     <= idx2 + 7'd1;
                    rstate   <= R_WAIT2;
                end
            end

            R_WAIT2: begin
                if (tx_busy) rstate <= R_SEND2;
            end

            default: rstate <= R_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 第一行：D=123cm T=00011000 P=+02 O=0 M=01 CR LF
    // ------------------------------------------------------------------
    always @(*) begin
        msg[0]  = 8'h44;                                   // 'D'
        msg[1]  = 8'h3D;                                   // '='
        msg[2]  = bad ? 8'h2D : (8'h30 + d_h[3:0]);        // 百位 / '-'
        msg[3]  = bad ? 8'h2D : (8'h30 + d_tt[3:0]);
        msg[4]  = bad ? 8'h2D : (8'h30 + d_uu[3:0]);
        msg[5]  = 8'h63;                                   // 'c'
        msg[6]  = 8'h6D;                                   // 'm'
        msg[7]  = 8'h20;                                   // ' '
        msg[8]  = 8'h54;                                   // 'T'
        msg[9]  = 8'h3D;                                   // '='
        msg[10] = ln[7] ? 8'h31 : 8'h30;                   // 探头 7（最右）
        msg[11] = ln[6] ? 8'h31 : 8'h30;
        msg[12] = ln[5] ? 8'h31 : 8'h30;
        msg[13] = ln[4] ? 8'h31 : 8'h30;
        msg[14] = ln[3] ? 8'h31 : 8'h30;
        msg[15] = ln[2] ? 8'h31 : 8'h30;
        msg[16] = ln[1] ? 8'h31 : 8'h30;
        msg[17] = ln[0] ? 8'h31 : 8'h30;                   // 探头 0（最左）
        msg[18] = 8'h20;                                   // ' '
        msg[19] = 8'h50;                                   // 'P'
        msg[20] = 8'h3D;                                   // '='
        msg[21] = pz[4] ? 8'h2D : 8'h2B;                   // '-' / '+'
        msg[22] = 8'h30 + p_tt[3:0];
        msg[23] = 8'h30 + p_uu[3:0];
        msg[24] = 8'h20;                                   // ' '
        msg[25] = 8'h4F;                                   // 'O'
        msg[26] = 8'h3D;                                   // '='
        msg[27] = obst ? 8'h31 : 8'h30;
        msg[28] = 8'h20;                                   // ' '
        msg[29] = 8'h4D;                                   // 'M'
        msg[30] = 8'h3D;                                   // '='
        msg[31] = 8'h30 + m_t[3:0];
        msg[32] = 8'h30 + m_uu[3:0];
        msg[33] = 8'h0D;                                   // CR
        msg[34] = 8'h0A;                                   // LF
    end

    // ------------------------------------------------------------------
    // 第二行：L=00000123 R=00000123 VL=0005 VR=0005 CR LF
    //   里程是 32 位二补码的十六进制（8 位），速度是 16 位的（4 位）。
    //   负值直接显示补码：要把 L=FFFFFFF0 读成 -16，主机侧按有符号解析即可。
    // ------------------------------------------------------------------
    always @(*) begin
        msg2[0]  = 8'h4C;                                  // 'L'
        msg2[1]  = 8'h3D;                                  // '='
        msg2[2]  = hexd(el[31:28]);
        msg2[3]  = hexd(el[27:24]);
        msg2[4]  = hexd(el[23:20]);
        msg2[5]  = hexd(el[19:16]);
        msg2[6]  = hexd(el[15:12]);
        msg2[7]  = hexd(el[11:8]);
        msg2[8]  = hexd(el[7:4]);
        msg2[9]  = hexd(el[3:0]);
        msg2[10] = 8'h20;
        msg2[11] = 8'h52;                                  // 'R'
        msg2[12] = 8'h3D;
        msg2[13] = hexd(er[31:28]);
        msg2[14] = hexd(er[27:24]);
        msg2[15] = hexd(er[23:20]);
        msg2[16] = hexd(er[19:16]);
        msg2[17] = hexd(er[15:12]);
        msg2[18] = hexd(er[11:8]);
        msg2[19] = hexd(er[7:4]);
        msg2[20] = hexd(er[3:0]);
        msg2[21] = 8'h20;
        msg2[22] = 8'h56;                                  // 'V'
        msg2[23] = 8'h4C;                                  // 'L'
        msg2[24] = 8'h3D;
        msg2[25] = hexd(sl[15:12]);
        msg2[26] = hexd(sl[11:8]);
        msg2[27] = hexd(sl[7:4]);
        msg2[28] = hexd(sl[3:0]);
        msg2[29] = 8'h20;
        msg2[30] = 8'h56;                                  // 'V'
        msg2[31] = 8'h52;                                  // 'R'
        msg2[32] = 8'h3D;
        msg2[33] = hexd(sr[15:12]);
        msg2[34] = hexd(sr[11:8]);
        msg2[35] = hexd(sr[7:4]);
        msg2[36] = hexd(sr[3:0]);
        msg2[37] = 8'h0D;
        msg2[38] = 8'h0A;
    end

endmodule
