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
    input  wire [7:0]  vs_cnt,     // 摄像头 VSYNC 计数（100 ms 窗口）
    input  wire        cam_done,   // SCCB 配置完成
    input  wire [15:0] cam_width,  // DVP 一行像素数
    input  wire [15:0] cam_height, // DVP 一帧行数
    input  wire [2:0]  cam_color,  // 主色：0中性 1红 2绿 3蓝 4黄
    input  wire [7:0]  cam_b0,     // 画面中心像素高字节（确认 RGB565/YUV 用）
    input  wire [7:0]  cam_b1,     // 画面中心像素低字节
    // ---- v4 帧统计遥测（第二行）----
    input  wire [19:0] cam_cnt_r,  // 本帧红/绿/蓝/黄像素数
    input  wire [19:0] cam_cnt_g,
    input  wire [19:0] cam_cnt_b,
    input  wire [19:0] cam_cnt_y,
    input  wire [6:0]  cam_sat,    // 本帧最大饱和度
    input  wire [7:0]  cam_sb0,    // 取到最大饱和度像素的两字节
    input  wire [7:0]  cam_sb1,
    input  wire [7:0]  cam_lb0,    // 本帧最亮像素的两字节
    input  wire [7:0]  cam_lb1,
    output wire        tx
);

    localparam integer MSG_LEN  = 64;   // 第一行：D=/T=/P=/O=/V=/C=/W=/H=/Q=/XY=
    localparam integer MSG2_LEN = 54;   // 第二行：R=/G=/B=/Y=/S=/SB=/LB=（全部十六进制）

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
    // 16 位无符号除以 10（W/H 是 0..9999，原来的 div10u 只有 10 位不够）
    // ------------------------------------------------------------------
    function [15:0] dv10;
        input [15:0] x;
        integer i;
        reg [15:0] q;
        reg [15:0] r;
        begin
            q = 16'd0;
            r = 16'd0;
            for (i = 15; i >= 0; i = i - 1) begin
                r = {r[14:0], x[i]};
                q = q << 1;
                if (r >= 16'd10) begin
                    r = r - 16'd10;
                    q = q + 16'd1;
                end
            end
            dv10 = q;
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
    reg  [6:0]  idx;        // 7 位：MSG_LEN=64，6 位（<=63）数不到 64，会无限循环（犯过两次）
    reg  [6:0]  idx2;       // 第二行游标（0..54）

    reg  [9:0]  v10;         // 距离（0..999）
    reg         bad;         // 距离无效
    reg  [7:0]  ln;          // 锁存的循迹位图
    reg  [7:0]  vs;          // 锁存的 VSYNC 计数
    reg         camd;        // 锁存的 SCCB 完成标志
    reg  [15:0] cw, ch;      // 锁存的摄像头宽/高
    reg  [2:0]  col;         // 锁存的主色
    reg  [7:0]  b0, b1;      // 锁存的中心像素两字节
    reg  signed [4:0] pz;    // 锁存的位置
    reg         obst;        // 锁存的障碍标志
    // v4 帧统计锁存（第二行用）
    reg [19:0]  cr, cg, cb_, cy;
    reg [6:0]   csat;
    reg [7:0]   csb0, csb1, clb0, clb1;

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

    // VSYNC 十进制（0..99，两位；Verilog-2001 不能对函数返回值直接取位，先落成 wire）
    wire [7:0]  v_t   = div10u({2'b00, vs});
    wire [7:0]  v_u   = vs - v_t * 8'd10;

    // W 四位 / H 三位
    wire [15:0] w1 = dv10(cw);
    wire [15:0] w2 = dv10(w1);
    wire [15:0] w3 = dv10(w2);
    wire [15:0] wd3 = w3;
    wire [15:0] wd2 = w2 - w3 * 16'd10;
    wire [15:0] wd1 = w1 - w2 * 16'd10;
    wire [15:0] wd0 = cw - w1 * 16'd10;

    wire [15:0] h1 = dv10(ch);
    wire [15:0] h2 = dv10(h1);
    wire [15:0] hd2 = h2;
    wire [15:0] hd1 = h1 - h2 * 16'd10;
    wire [15:0] hd0 = ch - h1 * 16'd10;

    wire [7:0]  b0h = hexd(b0[7:4]);
    wire [7:0]  b0l = hexd(b0[3:0]);
    wire [7:0]  b1h = hexd(b1[7:4]);
    wire [7:0]  b1l = hexd(b1[3:0]);

    localparam [2:0] R_IDLE  = 3'd0,
                     R_LOAD  = 3'd1,
                     R_SEND  = 3'd2,
                     R_WAIT  = 3'd3,
                     R_SEND2 = 3'd4,   // 第二行（帧统计）
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
            vs       <= 8'h00;
            camd     <= 1'b0;
            cw       <= 16'd0;
            ch       <= 16'd0;
            col      <= 3'd0;
            b0       <= 8'h00;
            b1       <= 8'h00;
            pz       <= 5'sd0;
            obst     <= 1'b0;
            idx2     <= 7'd0;
            cr       <= 20'd0;
            cg       <= 20'd0;
            cb_      <= 20'd0;
            cy       <= 20'd0;
            csat     <= 7'd0;
            csb0     <= 8'h00;
            csb1     <= 8'h00;
            clb0     <= 8'h00;
            clb1     <= 8'h00;
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
                vs   <= vs_cnt;
                camd <= cam_done;
                cw   <= cam_width;
                ch   <= cam_height;
                col  <= cam_color;
                b0   <= cam_b0;
                b1   <= cam_b1;
                pz   <= pos;
                obst <= obstacle;
                cr   <= cam_cnt_r;
                cg   <= cam_cnt_g;
                cb_  <= cam_cnt_b;
                cy   <= cam_cnt_y;
                csat <= cam_sat;
                csb0 <= cam_sb0;
                csb1 <= cam_sb1;
                clb0 <= cam_lb0;
                clb1 <= cam_lb1;
                idx2 <= 7'd0;
                rstate <= R_SEND;
            end

            R_SEND: begin
                if (idx == MSG_LEN) begin
                    idx2   <= 7'd0;
                    rstate <= R_SEND2;        // 第一行发完，接着发帧统计
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
        msg[28] = 8'h20;                                   // ' '
        msg[29] = 8'h56;                                   // 'V'
        msg[30] = 8'h3D;                                   // '='
        msg[31] = (vs > 8'd99) ? 8'h39 : (8'h30 + v_t[3:0]);   // 十位（>99 显示 9 饱和）
        msg[32] = (vs > 8'd99) ? 8'h39 : (8'h30 + v_u[3:0]);   // 个位
        msg[33] = 8'h20;                                   // ' '
        msg[34] = 8'h43;                                   // 'C'
        msg[35] = 8'h3D;                                   // '='
        msg[36] = camd ? 8'h31 : 8'h30;                    // SCCB 配置完成 = 1
        msg[37] = 8'h20;                                   // ' '
        msg[38] = 8'h57;                                   // 'W'
        msg[39] = 8'h3D;                                   // '='
        msg[40] = 8'h30 + wd3[3:0];
        msg[41] = 8'h30 + wd2[3:0];
        msg[42] = 8'h30 + wd1[3:0];
        msg[43] = 8'h30 + wd0[3:0];
        msg[44] = 8'h20;                                   // ' '
        msg[45] = 8'h48;                                   // 'H'
        msg[46] = 8'h3D;                                   // '='
        msg[47] = 8'h30 + hd2[3:0];
        msg[48] = 8'h30 + hd1[3:0];
        msg[49] = 8'h30 + hd0[3:0];
        msg[50] = 8'h20;                                   // ' '
        msg[51] = 8'h51;                                   // 'Q'
        msg[52] = 8'h3D;                                   // '='
        msg[53] = 8'h30 + {5'd0, col};                     // 主色代码 0~5
        msg[54] = 8'h20;                                   // ' '
        msg[55] = 8'h58;                                   // 'X'
        msg[56] = 8'h59;                                   // 'Y'
        msg[57] = 8'h3D;                                   // '='
        msg[58] = b0h;
        msg[59] = b0l;
        msg[60] = b1h;
        msg[61] = b1l;
        msg[62] = 8'h0D;                                   // CR
        msg[63] = 8'h0A;                                   // LF
    end

    // ------------------------------------------------------------------
    // 第二行：帧统计遥测（v4 调试用，定位 Q 恒为 0）
    //
    //   R=nnnnn G=nnnnn B=nnnnn Y=nnnnn S=nn SB=aabb LB=aabb CR LF
    //
    //   R/G/B/Y : 本帧被分类成红/绿/蓝/黄的像素个数（十六进制，5 位）
    //   S=nn    : 本帧出现过的最大饱和度（0..63）
    //   SB=aabb : 取到最大饱和度那个像素的原始两字节（高字节在前）
    //   LB=aabb : 本帧最亮（G 最大）像素的原始两字节
    //
    // 全用十六进制：计数可到 307200，十进制除法要多套 div10，没必要。
    // 解析时按行首字母分流：'D' 是第一行，'R' 是第二行。
    // ------------------------------------------------------------------
    always @(*) begin
        msg2[0]  = 8'h52;                                  // 'R'
        msg2[1]  = 8'h3D;                                  // '='
        msg2[2]  = hexd(cr[19:16]);
        msg2[3]  = hexd(cr[15:12]);
        msg2[4]  = hexd(cr[11:8]);
        msg2[5]  = hexd(cr[7:4]);
        msg2[6]  = hexd(cr[3:0]);
        msg2[7]  = 8'h20;
        msg2[8]  = 8'h47;                                  // 'G'
        msg2[9]  = 8'h3D;                                  // '='
        msg2[10] = hexd(cg[19:16]);
        msg2[11] = hexd(cg[15:12]);
        msg2[12] = hexd(cg[11:8]);
        msg2[13] = hexd(cg[7:4]);
        msg2[14] = hexd(cg[3:0]);
        msg2[15] = 8'h20;
        msg2[16] = 8'h42;                                  // 'B'
        msg2[17] = 8'h3D;                                  // '='
        msg2[18] = hexd(cb_[19:16]);
        msg2[19] = hexd(cb_[15:12]);
        msg2[20] = hexd(cb_[11:8]);
        msg2[21] = hexd(cb_[7:4]);
        msg2[22] = hexd(cb_[3:0]);
        msg2[23] = 8'h20;
        msg2[24] = 8'h59;                                  // 'Y'
        msg2[25] = 8'h3D;                                  // '='
        msg2[26] = hexd(cy[19:16]);
        msg2[27] = hexd(cy[15:12]);
        msg2[28] = hexd(cy[11:8]);
        msg2[29] = hexd(cy[7:4]);
        msg2[30] = hexd(cy[3:0]);
        msg2[31] = 8'h20;
        msg2[32] = 8'h53;                                  // 'S'
        msg2[33] = 8'h3D;                                  // '='
        msg2[34] = hexd({1'b0, csat[6:4]});
        msg2[35] = hexd(csat[3:0]);
        msg2[36] = 8'h20;
        msg2[37] = 8'h53;                                  // 'S'
        msg2[38] = 8'h42;                                  // 'B'
        msg2[39] = 8'h3D;                                  // '='
        msg2[40] = hexd(csb0[7:4]);
        msg2[41] = hexd(csb0[3:0]);
        msg2[42] = hexd(csb1[7:4]);
        msg2[43] = hexd(csb1[3:0]);
        msg2[44] = 8'h20;
        msg2[45] = 8'h4C;                                  // 'L'
        msg2[46] = 8'h42;                                  // 'B'
        msg2[47] = 8'h3D;                                  // '='
        msg2[48] = hexd(clb0[7:4]);
        msg2[49] = hexd(clb0[3:0]);
        msg2[50] = hexd(clb1[7:4]);
        msg2[51] = hexd(clb1[3:0]);
        msg2[52] = 8'h0D;                                  // CR
        msg2[53] = 8'h0A;                                  // LF
    end

endmodule
