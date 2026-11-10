// =============================================================================
// i2c_master.v —— 字节级 I2C 主机（单次事务：写 1 字节 / 读 1 字节）
// -----------------------------------------------------------------------------
// 为什么是"字节级"而不是"全自动配置器"：OV5640 的 SCCB 配置、OLED 的初始化
// 命令、VL53L1X 的寄存器读写，都是"发几个字节 / 收几个字节"的组合。把它拆成
// 一个可靠的单字节事务引擎 + 上层的命令序列状态机，比写一个巨大的专用配置器
// 好复用、好调试（上板时用 UART 打一条 acK/NAK 就能定位问题）。
//
// 时序：SCL 由 3 个相位产生一个位周期
//   phase0 : SCL 低 —— 准备好 SDA（写）或释放 SDA（读）
//   phase1 : SCL 高 —— 从机采样（写）；主机在离开 phase1 时采样（读）
//   phase2 : SCL 低 —— 移位 / 进位到下一位
// 每相位 DIV = CLK_FREQ / (SCL_FREQ*3) 个时钟 → SCL 频率精确等于 SCL_FREQ。
// 24 MHz / 100 kHz 时 DIV=80，一位 = 240 clk = 10 us。
//
// 一次事务（start 脉冲触发）：
//   写：START → [addr|0] → ACK → [data] → ACK → STOP → done
//   读：START → [addr|1] → ACK → [data] → MACK → STOP → done
// 从机 NACK 不会中断流程（照样发完 STOP），只在 ack_err 上置 1
// ——OV5640 有些寄存器写入会 NAK，配置过程不能因此卡死。
//
// 【SDA 为什么是三根线】Efinix Titanium 顶层不允许 inout/1'bz（EFX-0410），
// 所以 sda_in / sda_out / sda_oe 三根分开，物理三态由 Interface Designer 里
// mode="inout" 的 GPIO 块合成。sda_oe=1 时驱动 sda_out，=0 时释放（靠上拉）。
// =============================================================================
`timescale 1ns/1ns

module i2c_master #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer SCL_FREQ = 100_000
) (
    input  wire       clk,        // 24 MHz
    input  wire       rst_n,      // 低有效（已同步化）
    // ---- 控制接口 ----
    input  wire       start,      // 1 clk 脉冲：发起一次事务（busy=1 期间忽略）
    input  wire [6:0] dev_addr,   // 7 位从机地址
    input  wire       rw,         // 0=写 1 字节, 1=读 1 字节
    input  wire [7:0] wr_data,    // 写模式下要发送的字节
    output reg  [7:0] rd_data,    // 读模式下收到的字节（done 时有效）
    output reg        ack_err,    // 事务中任一处收到 NACK（done 时有效）
    output reg        busy,       // 事务进行中
    output reg        done,       // 1 clk 脉冲：事务结束
    // ---- 物理层（三态拆线）----
    output reg        scl,
    input  wire       sda_in,
    output reg        sda_out,
    output reg        sda_oe
);

    // 一个相位多少个 clk（至少 1，防止参数写错导致 0 分频）
    localparam integer DIV_RAW = CLK_FREQ / (SCL_FREQ * 3);
    localparam integer DIV     = (DIV_RAW < 1) ? 1 : DIV_RAW;

    localparam [2:0] S_IDLE  = 3'd0,
                     S_START = 3'd1,
                     S_BYTE  = 3'd2,   // 主机发送一个字节（地址或数据）
                     S_RXBYT = 3'd3,   // 主机接收一个字节
                     S_ACK   = 3'd4,   // 主机接收从机应答
                     S_MACK  = 3'd5,   // 主机发送应答（读操作的最后一个字节）
                     S_STOP  = 3'd6;

    reg [2:0]  state;
    reg [1:0]  phase;
    reg [2:0]  bitc;          // 剩余位数-1
    reg [7:0]  shreg;         // 发送移位寄存器
    reg        is_read;
    reg        stage;         // 0=地址阶段 1=数据阶段

    // ---- SDA 输入两级同步（异步引脚）----
    reg [1:0] sda_sync;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) sda_sync <= 2'b11;
        else        sda_sync <= {sda_sync[0], sda_in};
    wire sda_q = sda_sync[1];

    // ---- 相位节拍 ----
    reg [15:0] div_cnt;
    reg        tick;          // 每 DIV 个 clk 一个脉冲
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

    // ------------------------------------------------------------------
    // 主状态机
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            phase   <= 2'd0;
            bitc    <= 3'd7;
            shreg   <= 8'h00;
            is_read <= 1'b0;
            stage   <= 1'b0;
            rd_data <= 8'h00;
            ack_err <= 1'b0;
            busy    <= 1'b0;
            done    <= 1'b0;
            scl     <= 1'b1;      // 总线空闲：SCL 高
            sda_out <= 1'b1;
            sda_oe  <= 1'b0;      // SDA 释放，靠外部上拉
        end else begin
            done <= 1'b0;

            case (state)
            // ---------------- 空闲 ----------------
            S_IDLE: begin
                scl     <= 1'b1;
                sda_oe  <= 1'b0;
                sda_out <= 1'b1;
                busy    <= 1'b0;
                phase   <= 2'd0;
                bitc    <= 3'd7;
                if (start) begin
                    busy    <= 1'b1;
                    ack_err <= 1'b0;
                    is_read <= rw;
                    stage   <= 1'b0;
                    shreg   <= {dev_addr, rw};
                    // START 条件：SCL 仍为高时把 SDA 拉低
                    sda_oe  <= 1'b1;
                    sda_out <= 1'b0;
                    state   <= S_START;
                end
            end

            // ---------------- START 建立 ----------------
            S_START: if (tick) begin
                if (phase == 2'd0) begin
                    phase <= 2'd1;              // 保持 t_HD_STA
                end else begin
                    scl   <= 1'b0;
                    phase <= 2'd0;
                    bitc  <= 3'd7;
                    state <= S_BYTE;
                end
            end

            // ---------------- 发送一个字节 ----------------
            S_BYTE: if (tick) begin
                case (phase)
                2'd0: begin
                    sda_oe  <= 1'b1;
                    sda_out <= shreg[7];
                    scl     <= 1'b0;
                    phase   <= 2'd1;
                end
                2'd1: begin
                    scl   <= 1'b1;              // 从机采样
                    phase <= 2'd2;
                end
                default: begin
                    scl   <= 1'b0;
                    shreg <= {shreg[6:0], 1'b0};
                    phase <= 2'd0;
                    if (bitc == 3'd0) begin
                        state <= S_ACK;
                    end else begin
                        bitc <= bitc - 3'd1;
                    end
                end
                endcase
            end

            // ---------------- 接收从机 ACK ----------------
            S_ACK: if (tick) begin
                case (phase)
                2'd0: begin
                    sda_oe <= 1'b0;             // 释放 SDA，交给从机
                    scl    <= 1'b0;
                    phase  <= 2'd1;
                end
                2'd1: begin
                    scl   <= 1'b1;
                    phase <= 2'd2;
                end
                default: begin
                    scl     <= 1'b0;
                    ack_err <= ack_err | sda_q; // 1 = NACK
                    phase   <= 2'd0;
                    bitc    <= 3'd7;
                    if (stage == 1'b0) begin
                        // 地址阶段结束，进入数据阶段
                        stage <= 1'b1;
                        if (is_read) begin
                            state <= S_RXBYT;
                        end else begin
                            shreg <= wr_data;
                            state <= S_BYTE;
                        end
                    end else begin
                        state <= S_STOP;
                    end
                end
                endcase
            end

            // ---------------- 接收一个字节 ----------------
            S_RXBYT: if (tick) begin
                case (phase)
                2'd0: begin
                    sda_oe <= 1'b0;
                    scl    <= 1'b0;
                    phase  <= 2'd1;
                end
                2'd1: begin
                    scl   <= 1'b1;
                    phase <= 2'd2;              // 离开 phase1 时采样
                end
                default: begin
                    scl   <= 1'b0;
                    shreg <= {shreg[6:0], sda_q};
                    phase <= 2'd0;
                    if (bitc == 3'd0) begin
                        rd_data <= {shreg[6:0], sda_q};
                        state   <= S_MACK;
                    end else begin
                        bitc <= bitc - 3'd1;
                    end
                end
                endcase
            end

            // ---------------- 主机发 ACK ----------------
            S_MACK: if (tick) begin
                case (phase)
                2'd0: begin
                    sda_oe  <= 1'b1;
                    sda_out <= 1'b0;            // ACK
                    scl     <= 1'b0;
                    phase   <= 2'd1;
                end
                2'd1: begin
                    scl   <= 1'b1;
                    phase <= 2'd2;
                end
                default: begin
                    scl   <= 1'b0;
                    phase <= 2'd0;
                    state <= S_STOP;
                end
                endcase
            end

            // ---------------- STOP ----------------
            S_STOP: if (tick) begin
                case (phase)
                2'd0: begin
                    sda_oe  <= 1'b1;
                    sda_out <= 1'b0;            // 确保 SDA 低
                    scl     <= 1'b0;
                    phase   <= 2'd1;
                end
                2'd1: begin
                    scl   <= 1'b1;              // 先抬高 SCL
                    phase <= 2'd2;
                end
                2'd2: begin
                    sda_oe <= 1'b0;             // 再释放 SDA → STOP 条件
                    phase  <= 2'd3;
                end
                default: begin
                    scl   <= 1'b1;
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                    phase <= 2'd0;
                end
                endcase
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
