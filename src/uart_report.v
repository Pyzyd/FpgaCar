// =============================================================================
// uart_report.v —— 调试串口：把"距离 + 循迹状态 + 障碍 + 状态机 + 里程"打成两行
// -----------------------------------------------------------------------------
// 每来一个 dist_valid 脉冲（hc_sr04 每 60 ms 一帧）打两行，格式固定：
//
//     D=123cm T=00011000 P=+02 O=0 M=01          (35 字节)
//     L=00000123 R=00000123 VL=0005 VR=0005 ...  (79 字节，含 W= 与 S=)
//
//   D=xxxcm : 超声波距离；--- 表示无回波/超量程
//   T=      : 8 路循迹探头，bit7..bit0 对应 track[7]..track[0]，1=压线
//   P=+02   : 加权质心位置，-16..+16，正=线在右
//   O=      : 1=前方有障碍（默认只看超声波近距；红外由顶层 USE_IR 开关决定是否取或）
//   M=nn    : 状态机状态（00 IDLE 01 RUN 02 LOST 03 SEARCH 04 STOP
//             05 AVOID_BACK 06 AVOID_TURN 07 AVOID_PROBE，两位十进制）
//   L=/R=   : 左右编码器累计里程，8 位十六进制二补码（标定每米脉冲数用）
//   VL=/VR= : 左右速度，每 50 ms 窗口净步数，4 位十六进制二补码
//   X=      : 循迹消抖后的**原始电平**（未经 ACTIVE_HIGH 取反），bit7..bit0
//             = X8..X1。T= 已经过极性统一，极性设反时只会看到"全压线"，
//             而"全压线"与"模块真在报全黑"在 T= 上无法区分 —— X= 就是那面镜子。
//   C=±nnn  : track_pid 的转向修正量（corr，±BASE_DUTY 内）。
//             只看 T=/P= 无法判断 PID 到底在做什么；调 P/D 时必须看这一项。
//   DL=/DR= : 实际下发的左右占空比，3 位十六进制（0..4B0=1200）。
//             **这是速度环之后的最终值**，被三处依次改写，逐层排查：
//               1) track_pid  : BASE+corr / BASE-corr，BASE=TRACK_BASE_DUTY
//                               （src/FpgaCar.v:170，当前 480=0x1E0，40%）
//               2) car_fsm    : LOST 保持 / SEARCH / TURN / 避障分段会覆盖它
//               3) speed_pid  : 左右轮同步闭环，最多再叠 ±SYNC_MAX(180)
//             所以"DL 不等于 480+C"是正常的。要判断是哪一层，看 M=（状态机）
//             和 VL=/VR=（编码器有没有脉冲：都为 0 说明速度环已自动直通，
//             此时 DL=BASE+C、DR=BASE-C 严格成立）。
//   W=      : 宽黑标志。1 = 这一拍被判成"压线太宽"（影子/整片黑），
//             track_line 不采信它的位置并保持上一拍 pos；持续超过 WIDE_MS
//             会降级成丢线（此时 T= 仍然有多个 1，但 M 会走 02 LOST）。
//             这是夜里被自己影子/灯影骗到时唯一能一眼看出来的字段。
//   S=      : 最近一次转向方向：0 无 / 1 左 / 2 右。找线只有 1.5 s，光看车往
//             哪开分不清是"拐角兜底左转"还是"按原逻辑右转"，这一项能一眼分开。
//             没装 K230 时过拐角应恒为 1（见 PROJECT_PLAN §3.31）。
//
// 【为什么里程用十六进制】编码器计数是 32 位有符号，十进制要套 8 次 div10，
// 组合逻辑代价比信息价值大；解析时按行首字母分流，主机侧再换算即可。
// 【为什么加 M=】此前串口只能看到"车不动了"，分不清是 IDLE 没起跑、SEARCH
// 原地找线、还是 STOP 永久停车 —— 这三种情况现场处置完全不同。
//
// 115200 波特下 10 位/字节：35 + 79 = 114 字节约 9.9 ms，而一帧 60 ms，
// 永远发得完，不需要队列。
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
    input  wire [7:0]  line,       // 循迹压线位图（已极性统一）
    input  wire [7:0]  raw,        // 循迹原始电平（未取反）
    input  wire signed [4:0] pos,  // 线位置
    input  wire signed [10:0] corr,     // PID 修正量（C=）
    input  wire [10:0] duty_l,          // 实际下发占空比左（DL=）
    input  wire [10:0] duty_r,          // 实际下发占空比右（DR=）
    input  wire        wide,       // 宽黑标志（影子防护，W=）
    input  wire [1:0]  turn_dir,   // 最近一次转向方向（0 无 / 1 左 / 2 右，S=）
    input  wire        obstacle,   // 障碍标志
    input  wire [2:0]  state,      // 状态机状态（M=）
    input  wire [31:0] enc_l,      // 左编码器累计（二补码）
    input  wire [31:0] enc_r,      // 右编码器累计（二补码）
    input  wire signed [15:0] spd_l,  // 左速度（每窗口净步数）
    input  wire signed [15:0] spd_r,  // 右速度
    output wire        tx
);

    localparam integer MSG_LEN  = 35;   // 第一行：D=/T=/P=/O=/M=
    localparam integer MSG2_LEN = 79;   // 第二行：L=/R=/VL=/VR=/X=/C=/DL=/DR=/W=/S=

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
    reg  [6:0]  idx2;       // 第二行游标（0..MSG2_LEN-1，当前 0..78）

    reg  [9:0]  v10;         // 距离（0..999）
    reg         bad;         // 距离无效
    reg  [7:0]  ln;          // 锁存的循迹位图（已极性统一）
    reg  [7:0]  rx_raw;      // 锁存的循迹原始电平
    reg  signed [10:0] cr;   // 锁存的 PID 修正量
    reg  [10:0] dl, dr;      // 锁存的实际占空比
    reg  signed [4:0] pz;    // 锁存的位置
    reg         wid;         // 锁存的宽黑标志
    reg  [1:0]  td;          // 锁存的转向方向（S=）
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

    // 修正量十进制（绝对值 0..600 → 3 位），带符号
    wire [10:0] c_mag = cr[10] ? (~cr + 11'd1) : cr;
    wire [7:0]  c_t   = div10u(c_mag[9:0]);              // |corr|/10
    wire [7:0]  c_h   = div10u({2'b00, c_t});            // |corr|/100
    wire [7:0]  c_tt  = c_t - c_h * 8'd10;
    wire [7:0]  c_uu  = c_mag - c_t * 8'd10;             // |corr|<=600，个位

    // 状态两位十进制（0..99，当前只用到 0..7）
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
            rx_raw   <= 8'h00;
            cr       <= 11'sd0;
            dl       <= 11'd0;
            dr       <= 11'd0;
            pz       <= 5'sd0;
            wid      <= 1'b0;
            td       <= 2'd0;
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
                rx_raw <= raw;
                cr   <= corr;
                dl   <= duty_l;
                dr   <= duty_r;
                pz   <= pos;
                wid  <= wide;
                td   <= turn_dir;
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
    // 第二行：L=00000123 R=00000123 VL=0005 VR=0005 X=11111111 C=+000 DL=258 DR=258 CR LF
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
        // ---- X= 原始电平（bit7..bit0 = X8..X1）----
        msg2[37] = 8'h20;                                  // ' '
        msg2[38] = 8'h58;                                  // 'X'
        msg2[39] = 8'h3D;
        msg2[40] = rx_raw[7] ? 8'h31 : 8'h30;
        msg2[41] = rx_raw[6] ? 8'h31 : 8'h30;
        msg2[42] = rx_raw[5] ? 8'h31 : 8'h30;
        msg2[43] = rx_raw[4] ? 8'h31 : 8'h30;
        msg2[44] = rx_raw[3] ? 8'h31 : 8'h30;
        msg2[45] = rx_raw[2] ? 8'h31 : 8'h30;
        msg2[46] = rx_raw[1] ? 8'h31 : 8'h30;
        msg2[47] = rx_raw[0] ? 8'h31 : 8'h30;
        // ---- C= 修正量，带符号三位十进制 ----
        msg2[48] = 8'h20;
        msg2[49] = 8'h43;                                  // 'C'
        msg2[50] = 8'h3D;
        msg2[51] = cr[10] ? 8'h2D : 8'h2B;                 // '-' / '+'
        msg2[52] = 8'h30 + c_h[3:0];
        msg2[53] = 8'h30 + c_tt[3:0];
        msg2[54] = 8'h30 + c_uu[3:0];
        // ---- DL= / DR= 实际占空比，3 位十六进制 ----
        msg2[55] = 8'h20;
        msg2[56] = 8'h44;                                  // 'D'
        msg2[57] = 8'h4C;                                  // 'L'
        msg2[58] = 8'h3D;
        msg2[59] = hexd({2'b00, dl[10:8]});
        msg2[60] = hexd(dl[7:4]);
        msg2[61] = hexd(dl[3:0]);
        msg2[62] = 8'h20;
        msg2[63] = 8'h44;                                  // 'D'
        msg2[64] = 8'h52;                                  // 'R'
        msg2[65] = 8'h3D;
        msg2[66] = hexd({2'b00, dr[10:8]});
        msg2[67] = hexd(dr[7:4]);
        msg2[68] = hexd(dr[3:0]);
        // ---- W= 宽黑标志 ----
        msg2[69] = 8'h20;
        msg2[70] = 8'h57;                                  // 'W'
        msg2[71] = 8'h3D;
        msg2[72] = wid ? 8'h31 : 8'h30;
        // ---- S= 最近一次转向方向（0 无 / 1 左 / 2 右）----
        msg2[73] = 8'h20;
        msg2[74] = 8'h53;                                  // 'S'
        msg2[75] = 8'h3D;
        msg2[76] = (td == 2'd0) ? 8'h30 : ((td == 2'd1) ? 8'h31 : 8'h32);
        msg2[77] = 8'h0D;
        msg2[78] = 8'h0A;
    end

endmodule
