// =============================================================================
// uart_tx.v —— 8N1 UART 发送器（参数化波特率）
// -----------------------------------------------------------------------------
// 8 数据位、无校验、1 停止位，LSB 先发。板上是 CH340N（Mini-USB 口），
// 默认 115200-8-N-1 即可被任何串口终端识别。
//
// 握手：start 给 1 个 clk 脉冲，data 在 start 那一拍必须有效；busy=1 期间忽略
// 新的 start（上层要么等 busy 落下，要么保证间隔够长）。
//
// 为什么不用资料包里现成的 uart_transfer.v：官方那份带 FIFO 和一堆无关信号，
// 依赖它自己的时钟分频模块；这里 40 行就能写清，且能与 24 MHz 严格对拍。
// =============================================================================
`timescale 1ns/1ns

module uart_tx #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer BAUD     = 115_200
) (
    input  wire       clk,
    input  wire       rst_n,     // 低有效（已同步化）
    input  wire [7:0] data,      // 待发字节（start 那一拍有效）
    input  wire       start,     // 1 clk 脉冲
    output reg        tx,        // 串行输出（空闲为高）
    output reg        busy       // 发送中
);

    localparam integer BAUD_DIV_RAW = CLK_FREQ / BAUD;
    localparam integer BAUD_DIV     = (BAUD_DIV_RAW < 1) ? 1 : BAUD_DIV_RAW;  // 24MHz/115200 = 208

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] bcnt;      // 位内计数 0..BAUD_DIV-1
    reg [2:0]  bitc;      // 已发数据位数
    reg [7:0]  sh;        // 移位寄存器，LSB 先出

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            bcnt  <= 16'd0;
            bitc  <= 3'd0;
            sh    <= 8'h00;
            tx    <= 1'b1;      // 空闲高
            busy  <= 1'b0;
        end else begin
            case (state)
            S_IDLE: begin
                tx   <= 1'b1;
                bcnt <= 16'd0;
                bitc <= 3'd0;
                if (start) begin
                    sh    <= data;
                    busy  <= 1'b1;
                    state <= S_START;
                end else begin
                    busy <= 1'b0;
                end
            end

            // 起始位：SCL... 不是，串口：低电平持续一个位宽
            S_START: begin
                tx <= 1'b0;
                if (bcnt >= BAUD_DIV - 1) begin
                    bcnt  <= 16'd0;
                    bitc  <= 3'd0;
                    state <= S_DATA;
                end else begin
                    bcnt <= bcnt + 16'd1;
                end
            end

            // 数据位：8 位，LSB 先出
            S_DATA: begin
                tx <= sh[0];
                if (bcnt >= BAUD_DIV - 1) begin
                    bcnt <= 16'd0;
                    sh   <= {1'b0, sh[7:1]};
                    if (bitc == 3'd7) state <= S_STOP;
                    else              bitc  <= bitc + 3'd1;
                end else begin
                    bcnt <= bcnt + 16'd1;
                end
            end

            // 停止位
            S_STOP: begin
                tx <= 1'b1;
                if (bcnt >= BAUD_DIV - 1) begin
                    bcnt  <= 16'd0;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end else begin
                    bcnt <= bcnt + 16'd1;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
