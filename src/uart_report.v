// =============================================================================
// uart_report.v —— 把超声测距结果打成 ASCII 行发到调试串口
// -----------------------------------------------------------------------------
// 每次 dist_valid 脉冲发一行："D=123cm\r\n"（9 字节）。
// 115200 波特下一行约 0.78 ms，而 hc_sr04 每 60 ms 才出一帧，
// 所以永远发得完，不需要握手/队列。
//
// 【十进制怎么来的】FPGA 里除 10 用移位减法（div10u 函数，无除法器 IP）：
//   t = v / 10   (0..99)
//   h = t / 10   (0..9)
//   tt = t - h*10, u = v - t*10
// dist_cm > 999 时钳到 999；无效值（16'hFFFF）显示为 "---"。
//
// 这是整车保留的调试设施：比赛现场 5 分钟窗口内，串口打一行距离比用万用表
// 量管脚快得多；正式跑车时把 REPORT_EN 置 0 即可静音。
// =============================================================================
`timescale 1ns/1ns

module uart_report #(
    parameter integer CLK_FREQ  = 24_000_000,
    parameter integer BAUD      = 115_200,
    parameter integer REPORT_EN = 1          // 0 = 完全不输出（只留 UART 空闲高）
) (
    input  wire       clk,
    input  wire       rst_n,      // 低有效（已同步化）
    input  wire [15:0] dist_cm,   // 距离，16'hFFFF = 无效
    input  wire       dist_valid, // 1 clk 脉冲：dist_cm 已更新
    output wire       tx
);

    // ------------------------------------------------------------------
    // 无符号除以 10（移位-减法，10 次迭代，组合逻辑）
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
    reg  [7:0] msg [0:8];    // 9 字节
    reg  [3:0] idx;

    reg [9:0] v10;           // 钳位后的距离（0..999）
    reg       bad;           // 本次读数无效（超量程/无回波）

    wire       bad_now = (dist_cm > 16'd999);
    wire [9:0] v_now   = bad_now ? 10'd999 : dist_cm[9:0];

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
            idx      <= 4'd0;
        end else begin
            tx_start <= 1'b0;

            case (rstate)
            R_IDLE: begin
                idx <= 4'd0;
                if (REPORT_EN != 0 && dist_valid) rstate <= R_LOAD;
            end

            // 锁存本次读数（msg[] 由下面的组合逻辑按 v10/bad 生成）
            R_LOAD: begin
                bad    <= bad_now;
                v10    <= v_now;
                rstate <= R_SEND;
            end

            R_SEND: begin
                if (idx == 4'd9) begin
                    rstate <= R_IDLE;              // 9 字节全部已递交
                end else if (!tx_busy && !tx_start) begin
                    tx_data  <= msg[idx];
                    tx_start <= 1'b1;
                    idx      <= idx + 4'd1;
                    rstate   <= R_WAIT;            // 等 busy 抬起，避免同一字节发两次
                end
            end

            // uart_tx 采到 start 后下一拍才抬 busy，这里等它确认
            R_WAIT: begin
                if (tx_busy) rstate <= R_SEND;
            end

            default: rstate <= R_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 把 v10 拆成十进制并组装 msg[]（纯组合，R_LOAD 之后的 SEND 阶段使用）
    // ------------------------------------------------------------------
    wire [7:0] w_div10 = div10u(v10);              // v10/10  -> 0..99
    wire [7:0] w_h     = div10u({2'b00, w_div10[7:0]}); // /100 -> 0..9
    wire [7:0] w_tt    = w_div10 - w_h * 8'd10;    // 十位
    wire [7:0] w_uu    = v10 - w_div10 * 8'd10;    // 个位

    always @(*) begin
        msg[0] = 8'h44;                            // 'D'
        msg[1] = 8'h3D;                            // '='
        msg[2] = bad ? 8'h2D : (8'h30 + w_h[3:0]); // '-' 或 百位
        msg[3] = bad ? 8'h2D : (8'h30 + w_tt[3:0]);
        msg[4] = bad ? 8'h2D : (8'h30 + w_uu[3:0]);
        msg[5] = 8'h63;                            // 'c'
        msg[6] = 8'h6D;                            // 'm'
        msg[7] = 8'h0D;                            // CR
        msg[8] = 8'h0A;                            // LF
    end

endmodule
