// =============================================================================
// hc_sr04.v —— HC-SR04 超声波测距（Trig 触发 + Echo 脉宽计时）
// -----------------------------------------------------------------------------
// 工作方式（HC-SR04 手册时序）：
//   Trig 给 >=10 us 高脉冲 → 模块发 8 个 40 kHz 脉冲 → Echo 变高，
//   高电平持续时间 = 声波往返时间；距离(cm) = 高电平时长(us) / 58。
//
// 【为什么用乘法代替除 58】FPGA 里 16 位除以常数 58 综合出来的组合除法器又大又慢，
// 而 1/58 ≈ 1130/65536（误差 0.03%，4 m 处偏差 <0.15 cm），所以：
//   dist_cm = (echo_us * 1130) >> 16
// 一个 16x11 乘法器 = 1 个 DSP 块，一拍出结果。
//
// 【为什么 60 ms 测一次】HC-SR04 单次测量最长约 60 ms（量程 4 m），
// 上次的余波会影响下次，间隔必须大于量程时间；60 ms ≈ 16.7 Hz，对小车
// 循迹/避障的闭环完全够（车速 0.3 m/s 时 60 ms 走 1.8 cm）。
//
// 输出：
//   dist_cm  每次测量结束更新；无回波/超量程时为 16'hFFFF（上层判"无效"）
//   valid    1 clk 脉冲，表示 dist_cm 刚刚更新
// =============================================================================
`timescale 1ns/1ns

module hc_sr04 #(
    parameter integer CLK_FREQ        = 24_000_000,  // 输入时钟 Hz
    parameter integer PERIOD_US       = 60_000,      // 两次测量间隔 us
    parameter integer TRIG_US         = 15,          // Trig 脉宽 us（规格要求 >=10，留 50% 余量）
    parameter integer ECHO_WAIT_US    = 5_000,       // 触发后等 Echo 上升沿的上限 us
    parameter integer MEAS_MAX_US     = 25_000       // Echo 高电平上限 us（>4 m 视为超量程）
) (
    input  wire        clk,
    input  wire        rst_n,       // 低有效（已同步化）
    output reg         trig,        // 到 HC-SR04 Trig（3.3 V 可直接驱动 5 V 模块的输入）
    input  wire        echo,        // 来自 HC-SR04 Echo（5 V！必须两个电阻分压到 3.3 V）
    output reg  [15:0] dist_cm,     // 距离，cm；16'hFFFF = 无效
    output reg         valid        // 1 clk 脉冲
);

    // ---- 1 us 节拍 ----
    localparam integer US_DIV_RAW = CLK_FREQ / 1_000_000;
    localparam integer US_DIV     = (US_DIV_RAW < 1) ? 1 : US_DIV_RAW;   // 24 MHz -> 24

    reg [15:0] us_div;
    reg        us_tick;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            us_div  <= 16'd0;
            us_tick <= 1'b0;
        end else if (us_div >= US_DIV - 1) begin
            us_div  <= 16'd0;
            us_tick <= 1'b1;
        end else begin
            us_div  <= us_div + 16'd1;
            us_tick <= 1'b0;
        end

    // ---- Echo 两级同步（它来自模块，与 clk 完全异步）----
    reg [1:0] echo_sync;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) echo_sync <= 2'b00;
        else        echo_sync <= {echo_sync[0], echo};
    wire echo_q = echo_sync[1];

    localparam [2:0] S_PERIOD = 3'd0,   // 等测量间隔
                     S_TRIG   = 3'd1,   // 发 Trig 脉冲
                     S_WAIT   = 3'd2,   // 等 Echo 上升沿
                     S_MEAS   = 3'd3;   // 量 Echo 高电平宽度

    reg [2:0]  state;
    reg [17:0] period_cnt;
    reg [5:0]  trig_cnt;
    reg [17:0] wait_cnt;
    reg [17:0] echo_us;

    // ---- 距离换算：cm = round(us * 1130 / 65536) ----
    // 加 32768 做四舍五入，否则 1449 us 会截断成 24 cm 而不是 25 cm
    wire [31:0] dist_mul = {14'd0, echo_us} * 16'd1130 + 32'd32768;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_PERIOD;
            period_cnt <= 18'd0;
            trig_cnt   <= 6'd0;
            wait_cnt   <= 18'd0;
            echo_us    <= 18'd0;
            trig       <= 1'b0;
            dist_cm    <= 16'hFFFF;
            valid      <= 1'b0;
        end else begin
            valid <= 1'b0;

            case (state)
            // 等够 PERIOD_US 再发下一次触发
            S_PERIOD: begin
                trig <= 1'b0;
                if (period_cnt >= PERIOD_US - 1) begin
                    period_cnt <= 18'd0;
                    trig_cnt   <= 6'd0;
                    trig       <= 1'b1;             // 抬起 Trig
                    state      <= S_TRIG;
                end else begin
                    period_cnt <= period_cnt + 18'd1;
                end
            end

            // Trig 拉高保持 TRIG_US（>=10 us）
            S_TRIG: if (us_tick) begin
                if (trig_cnt >= TRIG_US - 1) begin
                    trig     <= 1'b0;
                    wait_cnt <= 18'd0;
                    state    <= S_WAIT;
                end else begin
                    trig_cnt <= trig_cnt + 6'd1;
                end
            end

            // 等 Echo 上升沿；超时 = 模块没接 / 无回波
            S_WAIT: if (us_tick) begin
                if (echo_q) begin
                    echo_us <= 18'd0;
                    state   <= S_MEAS;
                end else if (wait_cnt >= ECHO_WAIT_US) begin
                    dist_cm <= 16'hFFFF;
                    valid   <= 1'b1;
                    state   <= S_PERIOD;
                end else begin
                    wait_cnt <= wait_cnt + 18'd1;
                end
            end

            // 量 Echo 高电平宽度
            S_MEAS: if (us_tick) begin
                if (echo_q) begin
                    if (echo_us >= MEAS_MAX_US) begin   // 超量程
                        dist_cm <= 16'hFFFF;
                        valid   <= 1'b1;
                        state   <= S_PERIOD;
                    end else begin
                        echo_us <= echo_us + 18'd1;
                    end
                end else begin                          // Echo 下降 = 测量结束
                    dist_cm <= dist_mul[31:16];
                    valid   <= 1'b1;
                    state   <= S_PERIOD;
                end
            end

            default: state <= S_PERIOD;
            endcase
        end
    end

endmodule
