// =============================================================================
// car_fsm.v —— 整车状态机（起跑 / 循迹 / 丢线保持 / 原地找线 / 停车）
// -----------------------------------------------------------------------------
// 状态流转：
//
//   IDLE --(上电 START_MS)--> RUN --(丢线)--> LOST --(保持超时)--> SEARCH
//                              |                 |                   |
//                              |<--(重新压线)----+-------------------+
//                              |                                     |
//                              +--(障碍)--> STOP <--(找线超时)-------+
//                                            |
//                                        (障碍消失) --> RUN
//
// 【为什么要有 LOST 这一级】track_line 的 lost 会在线抖动/短暂离线的瞬间置位，
// 立刻进找线会让车原地抽搐。先保持最后一刻的转向 HOLD_MS，多数情况下线就回来了。
//
// 【找线方向】按最后一次看到线的位置决定（pos>0 说明线在右边 → 向右原地转），
// 比固定"往左找"稍好；且比左右来回扫更简单（不需要额外状态）。
//
// 【方向死区】【重要】TB6612 在 IN1/IN2 同时翻转时会短暂短路刹车，实测会有电流尖峰。
// 因此方向改变时先拉低 PWM（DIR_DEAD_MS），再换相；换相后也先低占空比。
// =============================================================================
`timescale 1ns/1ns

module car_fsm #(
    parameter integer CLK_FREQ      = 24_000_000,
    parameter integer START_MS      = 2000,   // 上电后等多久起跑（留时间把车放正）
    parameter integer LOST_HOLD_MS  = 300,    // 丢线先保持多久
    parameter integer SEARCH_MS     = 1500,   // 原地找线最长多久
    parameter integer SEARCH_DUTY   = 500,    // 找线时的占空比
    parameter integer DIR_DEAD_MS   = 10      // 方向切换死区
) (
    input  wire              clk,
    input  wire              rst_n,
    // 感知
    input  wire              on_line,
    input  wire              lost,
    input  wire              obstacle,
    input  wire signed [4:0] pos,
    // 闭环输出
    input  wire [10:0]       pid_l,
    input  wire [10:0]       pid_r,
    // 执行
    output wire              en,              // 1 = 电机使能（同时接 TB6612 STBY）
    output reg               dir_l,           // 1 = 正转（车前进）
    output reg               dir_r,
    output reg  [10:0]       duty_l,
    output reg  [10:0]       duty_r,
    output reg  [2:0]        state            // 观察用
);

    localparam [2:0] S_IDLE   = 3'd0,
                     S_RUN    = 3'd1,
                     S_LOST   = 3'd2,
                     S_SEARCH = 3'd3,
                     S_STOP   = 3'd4;

    localparam integer MS_DIV     = CLK_FREQ / 1000;
    localparam integer DEAD_CYC   = MS_DIV * DIR_DEAD_MS;

    // ---------------- 1 ms 节拍 ----------------
    reg [15:0] ms_div;
    wire       ms_tick = (ms_div >= MS_DIV - 1);

    always @(posedge clk or negedge rst_n)
        if (!rst_n)      ms_div <= 16'd0;
        else if (ms_tick) ms_div <= 16'd0;
        else             ms_div <= ms_div + 16'd1;

    reg [15:0] ms_cnt;

    // ---------------- 状态 ----------------
    reg        final_stop;          // 找线超时后的永久停车（只能靠复位解除）
    reg        last_pos_neg;        // 最后看到线时 pos<0（线在左）
    reg        saw_line;            // 是否曾经看到过线

    // ---------------- 方向死区 ----------------
    reg        dead;
    reg [15:0] dead_cnt;
    reg        dir_l_des, dir_r_des;

    wire en_run = (state == S_RUN) || (state == S_LOST) || (state == S_SEARCH);
    assign en   = en_run & ~dead;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            ms_cnt      <= 16'd0;
            final_stop  <= 1'b0;
            last_pos_neg <= 1'b0;
            saw_line    <= 1'b0;
            dir_l       <= 1'b1;
            dir_r       <= 1'b1;
            dir_l_des   <= 1'b1;
            dir_r_des   <= 1'b1;
            duty_l      <= 11'd0;
            duty_r      <= 11'd0;
            dead        <= 1'b0;
            dead_cnt    <= 16'd0;
        end else begin
            // ---- 记住线的方位 ----
            if (on_line && !lost) begin
                last_pos_neg <= pos[4];
                saw_line     <= 1'b1;
            end

            // ---- 方向死区计数 ----
            if (dead) begin
                if (dead_cnt >= DEAD_CYC - 1) begin
                    dead      <= 1'b0;
                    dead_cnt  <= 16'd0;
                    dir_l     <= dir_l_des;
                    dir_r     <= dir_r_des;
                end else begin
                    dead_cnt <= dead_cnt + 16'd1;
                end
            end else if ((dir_l_des != dir_l) || (dir_r_des != dir_r)) begin
                dead     <= 1'b1;
                dead_cnt <= 16'd0;
                duty_l   <= 11'd0;      // 换相前先断电
                duty_r   <= 11'd0;
            end

            // ---- 主状态机（1 ms 步进）----
            if (ms_tick) begin
                case (state)
                S_IDLE: begin
                    duty_l <= 11'd0;
                    duty_r <= 11'd0;
                    dir_l_des <= 1'b1;
                    dir_r_des <= 1'b1;
                    if (ms_cnt >= START_MS - 1) begin
                        ms_cnt <= 16'd0;
                        state  <= S_RUN;
                    end else begin
                        ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                S_RUN: begin
                    dir_l_des <= 1'b1;
                    dir_r_des <= 1'b1;
                    if (!dead) begin
                        duty_l <= pid_l;
                        duty_r <= pid_r;
                    end
                    if (obstacle) begin
                        ms_cnt <= 16'd0;
                        state  <= S_STOP;
                    end else if (lost) begin
                        ms_cnt <= 16'd0;
                        state  <= S_LOST;
                    end
                end

                S_LOST: begin
                    // 保持最后一刻的占空比与方向
                    duty_l <= pid_l;
                    duty_r <= pid_r;
                    if (!lost && on_line) begin
                        ms_cnt <= 16'd0;
                        state  <= S_RUN;
                    end else if (ms_cnt >= LOST_HOLD_MS - 1) begin
                        ms_cnt <= 16'd0;
                        // 线在右边 → 向右转：左轮前进、右轮后退
                        dir_l_des <= ~last_pos_neg;
                        dir_r_des <=  last_pos_neg;
                        duty_l    <= SEARCH_DUTY[10:0];
                        duty_r    <= SEARCH_DUTY[10:0];
                        state     <= S_SEARCH;
                    end else begin
                        ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                S_SEARCH: begin
                    if (!dead) begin
                        duty_l <= SEARCH_DUTY[10:0];
                        duty_r <= SEARCH_DUTY[10:0];
                    end
                    if (!lost && on_line) begin
                        ms_cnt <= 16'd0;
                        state  <= S_RUN;
                    end else if (ms_cnt >= SEARCH_MS - 1) begin
                        ms_cnt     <= 16'd0;
                        final_stop <= 1'b1;
                        state      <= S_STOP;
                    end else begin
                        ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                S_STOP: begin
                    duty_l <= 11'd0;
                    duty_r <= 11'd0;
                    // 只有"障碍导致的停车"且障碍消失才恢复；找线超时的停车保持
                    if (!final_stop && !obstacle) begin
                        ms_cnt <= 16'd0;
                        state  <= S_RUN;
                    end
                end

                default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
