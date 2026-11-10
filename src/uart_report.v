// =============================================================================
// uart_report.v —— 调试串口：把"距离 + 循迹状态 + 障碍"打成一行 ASCII
// -----------------------------------------------------------------------------
// 每来一个 dist_valid 脉冲（hc_sr04 每 60 ms 一帧）打一行，格式固定 30 字节：
//
//     D=123cm T=00011000 P=+02 O=0\r\n
//     ^距离   ^8 路压线  ^位置    ^障碍
//
//   D=xxxcm : 超声波距离；--- 表示无回波/超量程
//   T=      : 8 路循迹探头，bit7..bit0 对应 track[7]..track[0]，1=压线
//   P=+02   : 加权质心位置，-16..+16，正=线在右
//   O=      : 1=前方有障碍（超声波近距 或 任一路红外触发）
//
// 115200 波特下一行约 2.6 ms，而一帧 60 ms，永远发得完，不需要队列。
//
// 【十进制怎么来的】除法用移位-减法 div10u()，不实例化除法器 IP。
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
    output wire        tx
);

    localparam integer MSG_LEN = 30;

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
    reg  [7:0]  msg [0:MSG_LEN-1];
    reg  [4:0]  idx;

    reg  [9:0]  v10;         // 距离（0..999）
    reg         bad;         // 距离无效
    reg  [7:0]  ln;          // 锁存的循迹位图
    reg  signed [4:0] pz;    // 锁存的位置
    reg         obst;        // 锁存的障碍标志

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

    localparam [1:0] R_IDLE = 2'd0,
                     R_LOAD = 2'd1,
                     R_SEND = 2'd2,
                     R_WAIT = 2'd3;

    reg [1:0] rstate;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate   <= R_IDLE;
            tx_start <= 1'b0;
            tx_data  <= 8'h00;
            idx      <= 5'd0;
            v10      <= 10'd0;
            bad      <= 1'b1;
            ln       <= 8'h00;
            pz       <= 5'sd0;
            obst     <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            case (rstate)
            R_IDLE: begin
                idx <= 5'd0;
                if (REPORT_EN != 0 && dist_valid) rstate <= R_LOAD;
            end

            // 锁存本次快照（msg[] 由组合逻辑按这些寄存器生成）
            R_LOAD: begin
                bad  <= bad_now;
                v10  <= v_now;
                ln   <= line;
                pz   <= pos;
                obst <= obstacle;
                rstate <= R_SEND;
            end

            R_SEND: begin
                if (idx == MSG_LEN) begin
                    rstate <= R_IDLE;
                end else if (!tx_busy && !tx_start) begin
                    tx_data  <= msg[idx];
                    tx_start <= 1'b1;
                    idx      <= idx + 5'd1;
                    rstate   <= R_WAIT;
                end
            end

            // uart_tx 采到 start 后下一拍才抬 busy，这里等它确认，避免同一字节发两次
            R_WAIT: begin
                if (tx_busy) rstate <= R_SEND;
            end

            default: rstate <= R_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 拼 ASCII：D=123cm T=00011000 P=+02 O=0 CR LF
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
        msg[28] = 8'h0D;                                   // CR
        msg[29] = 8'h0A;                                   // LF
    end

endmodule
