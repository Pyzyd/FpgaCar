// =============================================================================
// car_fsm.v —— 整车状态机（起跑 / 循迹 / 丢线保持 / 原地找线 / 停车）
// -----------------------------------------------------------------------------
// 状态流转：
//
//   IDLE --(连续压线 START_MS)--> RUN --(丢线)--> LOST --(保持超时)--> SEARCH
//                              |                 |                   |
//                              |<--(重新压线)----+-------------------+
//                              |                                     |
//                              +--(障碍)--> BACK --> TURN --> PROBE -+
//                              |        (后退)   (原地转)  (试探前进) |
//                              |                            |        |
//                              |             (还有障碍 & 未超次数)--+
//                              |                            |
//                              |                     (无障碍) --> RUN
//                              |                (次数用尽) --> STOP
//                              +<--找线超时(SEARCH_FAIL_TO_IDLE=1)---+
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
    parameter integer START_MS      = 2000,   // 连续压线多久后起跑（留时间松手）
    parameter integer START_REQUIRE_LINE = 1, // 1 = 必须压线才起跑（安全锁）
    parameter integer LOST_HOLD_MS  = 300,    // 丢线先保持多久
    parameter integer SEARCH_MS     = 1500,   // 原地找线最长多久
    parameter integer SEARCH_DUTY   = 500,    // 找线时的占空比
    parameter integer SEARCH_FAIL_TO_IDLE = 1, // 找线超时后：1=回 IDLE 等重新压线，0=永久停车
    parameter integer DIR_DEAD_MS   = 10,     // 方向切换死区
    parameter integer TURN_MS       = 700,    // 交通牌强制转向持续时长
    parameter integer TURN_DUTY     = 700,    // 强制转向时的占空比
    parameter integer TURN_WAIT_FOR_CORNER = 0, // 1: 先存方向，宽黑后丢线才执行
    parameter integer TURN_REQUEST_MS = 12000,  // 转向牌等待岔口的上限
    // ---- 避障（BACK → TURN → PROBE 三段）----
    parameter integer AVOID_EN    = 1,      // 1 = 遇障碍执行避障；0 = 旧行为（原地停，障碍消失即走）
    parameter integer AVOID_BACK_MS = 400,  // 后退时长
    parameter integer AVOID_BACK_DUTY = 500,// 后退占空比
    parameter integer AVOID_TURN_MS = 600,  // 原地转时长
    parameter integer AVOID_TURN_DUTY = 600,// 原地转占空比
    parameter integer AVOID_PROBE_MS = 400, // 试探前进时长
    parameter integer AVOID_PROBE_DUTY = 450,// 试探前进占空比
    // 进 PROBE 后的静默观察窗：这段时间内不判 obstacle。
    // 为什么必须有：从 TURN 转进 PROBE 时障碍通常还在正前方（车还没动），
    // 若第一拍就判 obstacle，"试探前进"这一步只跑 1 ms 就被打回 BACK，
    // 3 轮配额瞬间耗尽 —— 避障退化成"原地左右各抖 600 ms 再停车"。
    parameter integer AVOID_PROBE_SETTLE_MS = 100,
    parameter integer AVOID_TRIES = 3,      // 最多连续尝试次数，用尽则停车等待
    parameter integer AVOID_ROUTE_EN = 0,  // 启用侧绕并定向回线；0 保留三段试探
    parameter integer AVOID_PASS_MS = 900, // 车头摆正后沿障碍侧边直行
    parameter integer AVOID_REJOIN_MS = 1200,
    parameter integer AVOID_REJOIN_DUTY = 400,
    parameter integer AVOID_LINE_MS = 20,  // 回线时黑线需稳定出现
    parameter integer AVOID_BLOCK_MS = 250,// 前方受阻先停，再等超声更新
    // ---- 拐角兜底（没有 K230 / 没识别到转向牌时怎么走）----
    // 1 = 判到"直角/菱形拐角"而没有任何转向牌事件时，一律向左转；
    // 0 = 退回旧行为（按最后看到线的方位转，线在左就左转、在右就右转）。
    parameter integer DEFAULT_TURN_LEFT = 1,
    // 宽黑（wide）出现后多久内仍算"拐角"。0 = 完全不做拐角判断。
    parameter integer CORNER_WIDE_MS = 500,

    // 转向指示（串口 S= / OLED 左转右转格）保持多久。
    // 不保持的话，一次转弯只有 1~2 ms 的脉冲，OLED 每 100 ms 才采一次样，
    // 基本抓不到；但一直保持又会让直道上也显示"正在左转"，反而看不懂。
    // 1500 ms 覆盖整个 S_SEARCH（SEARCH_MS=1500），之后自动熄灭。
    parameter integer TURN_DIR_HOLD_MS = 1500
) (
    input  wire              clk,
    input  wire              rst_n,
    // 感知
    input  wire              on_line,
    input  wire              lost,
    input  wire              obstacle,
    input  wire              wide,          // 1 = 当前宽黑（拐角/影子），拐角兜底用
    input  wire signed [4:0] pos,
input  wire [2:0]        dir_evt,        // 交通牌：0=无 1=左 2=右 3=直，单周期脉冲
    // 闭环输出
    input  wire [10:0]       pid_l,
    input  wire [10:0]       pid_r,
    // 执行
    output wire              en,              // 1 = 电机使能（同时接 TB6612 STBY）
    output reg               dir_l,           // 1 = 正转（车前进）
    output reg               dir_r,
    output reg  [10:0]       duty_l,
    output reg  [10:0]       duty_r,
    output reg  [2:0]        state,           // 观察用
    output reg  [1:0]        turn_dir         // 最近一次转向方向：0=无 1=左 2=右
);

    // 5/6/7 三个编码正好空着，避障直接占用，M= 字段（两位十进制）无需扩位。
    localparam [2:0] S_IDLE       = 3'd0,
                     S_RUN        = 3'd1,
                     S_LOST       = 3'd2,
                     S_SEARCH     = 3'd3,
                     S_STOP       = 3'd4,
                     S_AVOID_BACK = 3'd5,
                     S_AVOID_TURN = 3'd6,
                     S_AVOID_PROBE= 3'd7;

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

    // ---------------- 交通牌强制转向 ----------------
    reg        turning;             // 1 = 正在按交通牌转向
    reg [15:0] turn_cnt;            // 转向剩余 ms
    reg        turn_left;           // 1 = 左转（左轮后退、右轮前进）
    reg        turn_req;            // 已收到转向请求
    reg [15:0] turn_request_left;

    // ---------------- 拐角兜底（没有 K230 时的默认左转）----------------
    // 直角/菱形拐角在八路阵列上表现为"先宽黑、后全丢线"。宽黑出现后
    // CORNER_WIDE_MS 内丢线，就认为这是拐角而不是普通跑偏，此时若没有
    // 转向牌事件（K230 没装/没识别到），一律按 DEFAULT_TURN_LEFT 左转。
    // 不做这个区分的话，正常右弯跑偏丢线也会被强制左转，车会往反方向找线。
    reg  [15:0] corner_cnt;         // 距离上次宽黑还有多少 ms
    reg  [15:0] turn_dir_cnt;       // 转向指示还要亮多久（0 = 灭）
    wire turn_allowed = (TURN_WAIT_FOR_CORNER == 0) ||
                        (lost && !wide && (corner_cnt != 0) && (turn_request_left != 0));

    // ---------------- 方向死区 ----------------
    reg        dead;
    // 死区计时必须比 MS_DIV 宽：DEAD_CYC = MS_DIV * DIR_DEAD_MS，
    // 24 MHz + DIR_DEAD_MS=10 时是 240000，16 位放不下（上限 65535）。
    // 宽度不够的后果不是"死区变短"，而是 dead_cnt 永远追不上 DEAD_CYC-1，
    // dead 一旦置位就再也不清 → en 恒 0、duty 恒 0，车再也不动。
    // 测试台用 DIR_DEAD_MS=1（24000，刚好放得下）所以测不出这个错。
    reg [31:0] dead_cnt;
    reg        dir_l_des, dir_r_des;

    // ---------------- 避障 ----------------
    reg [3:0]  avoid_tries;         // 本次障碍已尝试几轮
    reg        avoid_left;          // 1 = 这次往左绕（按最后看到线的方位反着走）

    localparam [2:0] BY_OUT = 3'd0, BY_ALIGN = 3'd1, BY_PASS = 3'd2,
                     BY_TURN_IN = 3'd3, BY_REJOIN = 3'd4;
    reg [2:0] bypass_step;
    reg bypass_left_line;
    reg [15:0] bypass_line_cnt, bypass_block_cnt;
    wire bypass_active = (AVOID_ROUTE_EN != 0) && (state == S_AVOID_PROBE);
    wire bypass_forward = (bypass_step == BY_OUT || bypass_step == BY_PASS || bypass_step == BY_REJOIN);
    wire bypass_dir_l = bypass_forward || avoid_left;
    wire bypass_dir_r = bypass_forward || !avoid_left;
    wire bypass_blocked = bypass_forward && obstacle;
    wire bypass_dirs_ready = (dir_l == bypass_dir_l) && (dir_r == bypass_dir_r);
    wire bypass_has_line = on_line && !lost && !wide;
    wire [10:0] bypass_duty = !bypass_forward ? AVOID_TURN_DUTY[10:0] :
                             (bypass_step == BY_REJOIN ? AVOID_REJOIN_DUTY[10:0] : AVOID_PROBE_DUTY[10:0]);

    wire en_run = (state == S_RUN)   || (state == S_LOST)     || (state == S_SEARCH)
               || (state == S_AVOID_BACK) || (state == S_AVOID_TURN) || (state == S_AVOID_PROBE);
    assign en = en_run && !dead && (!bypass_active || (!bypass_blocked && bypass_dirs_ready));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            ms_cnt      <= 16'd0;
            final_stop  <= 1'b0;
            last_pos_neg <= 1'b0;
            dir_l       <= 1'b1;
            dir_r       <= 1'b1;
            dir_l_des   <= 1'b1;
            dir_r_des   <= 1'b1;
            duty_l      <= 11'd0;
            duty_r      <= 11'd0;
            dead        <= 1'b0;
            dead_cnt    <= 32'd0;
            turning     <= 1'b0;
            turn_cnt    <= 16'd0;
            turn_left   <= 1'b0;
            turn_req    <= 1'b0;
            turn_request_left <= 16'd0;
            avoid_tries <= 4'd0;
            avoid_left  <= 1'b0;
            bypass_step <= BY_OUT;
            bypass_left_line <= 1'b0;
            bypass_line_cnt <= 16'd0;
            bypass_block_cnt <= 16'd0;
            corner_cnt   <= 16'd0;
            turn_dir     <= 2'd0;
            turn_dir_cnt <= 16'd0;
        end else begin
            // ---- 记住线的方位 ----
            if (on_line && !lost) begin
                last_pos_neg <= pos[4];
            end

            // ---- 方向死区计数 ----
            if (dead) begin
                if (dead_cnt >= DEAD_CYC - 1) begin
                    dead      <= 1'b0;
                    dead_cnt  <= 32'd0;
                    dir_l     <= dir_l_des;
                    dir_r     <= dir_r_des;
                end else begin
                    dead_cnt <= dead_cnt + 32'd1;
                end
            end else if ((dir_l_des != dir_l) || (dir_r_des != dir_r)) begin
                dead     <= 1'b1;
                dead_cnt <= 32'd0;
                duty_l   <= 11'd0;      // 换相前先断电
                duty_r   <= 11'd0;
            end

            // ---- 交通牌事件锁存 ----
            // dir_evt 是单周期脉冲，而主状态机 1 ms 才走一步，直接在里面判会漏。
            // 前视联调模式在循迹确认岔口前只锁存方向，超时自动丢弃。
            if ((dir_evt == 3'd1 || dir_evt == 3'd2) &&
                ((TURN_WAIT_FOR_CORNER == 0) || !turning)) begin
                turn_req  <= 1'b1;
                turn_left <= dir_evt == 3'd1;
                turn_request_left <= TURN_REQUEST_MS[15:0];
                if (TURN_WAIT_FOR_CORNER == 0) begin
                    turn_dir <= (dir_evt == 3'd1) ? 2'd1 : 2'd2;
                    turn_dir_cnt <= TURN_DIR_HOLD_MS[15:0];
                end
            end else if (dir_evt == 3'd3) begin
                turn_req  <= 1'b0;
                turn_request_left <= 16'd0;
                turning   <= 1'b0;
                turn_cnt  <= 16'd0;
                turn_dir  <= 2'd0;      // 直行牌 = 取消转向，指示也一并灭掉
                turn_dir_cnt <= 16'd0;
                corner_cnt   <= 16'd0;  // 直行牌同时清拐角记忆，避免随后误触兜底
            end

            // ---- 主状态机（1 ms 步进）----
            if (ms_tick) begin
                if (!bypass_active) begin
                    bypass_step <= BY_OUT;
                    bypass_left_line <= 1'b0;
                    bypass_line_cnt <= 16'd0;
                    bypass_block_cnt <= 16'd0;
                end
                if ((TURN_WAIT_FOR_CORNER != 0) && turn_req && dir_evt == 3'd0) begin
                    if (turn_request_left != 0) turn_request_left <= turn_request_left - 16'd1;
                    if (turn_request_left <= 16'd1) turn_req <= 1'b0;
                end
                // ---- 拐角记忆 ----
                // 直角/菱形拐角会让八路同时压线（wide=1），随后整条线消失。
                // 记住"刚过拐角"这段时间，找线时才能区分"拐角"和"普通跑偏"。
                // 【必须 !turning】强制转向期间车是有意离开赛道的，车体扫过线/宽黑
                // 区域时 wide 会置位。若不加这个门控，转向结束回到找线时
                // corner_cnt 还没衰减完，拐角兜底会把刚按牌子做的转向反着执行一遍
                // （牌要求右转 → 兜底强制左转），直接违反"有牌就完全按牌走"。
                // 当前 USE_K230=0 时 turning 永远进不去，这条是接回 K230 后的保险。
                if ((AVOID_ROUTE_EN != 0) && (state >= S_AVOID_BACK)) begin
                    corner_cnt <= 16'd0;
                end else if (!turning && wide && CORNER_WIDE_MS > 0) begin
                    corner_cnt <= CORNER_WIDE_MS[15:0];
                end else if (corner_cnt != 16'd0) begin
                    corner_cnt <= corner_cnt - 16'd1;
                end

                // ---- 转向指示保持计时 ----
                // 到 0 那一拍把 turn_dir 清掉，屏上两格才不会常亮。
                if (turn_dir_cnt != 16'd0) begin
                    turn_dir_cnt <= turn_dir_cnt - 16'd1;
                    if (turn_dir_cnt == 16'd1) turn_dir <= 2'd0;
                end

                case (state)
                S_IDLE: begin
                    duty_l <= 11'd0;
                    duty_r <= 11'd0;
                    dir_l_des <= 1'b1;
                    dir_r_des <= 1'b1;
                    // 【起跑条件 / 安全锁】
                    //   START_REQUIRE_LINE=1（默认）时必须"连续压线 START_MS"才起跑，
                    //   相当于把"把车放到线上"当作钥匙。理由：电机接上以后，
                    //   旧的"上电计时到点就跑"会让车在桌面/箱子里自己窜出去；
                    //   没压线时这里会一直停着，绝不会自行启动。
                    //   =0 时退回旧行为（仅台架/专项测试用）。
                    if (START_REQUIRE_LINE != 0 && !(on_line && !lost)) begin
                        ms_cnt <= 16'd0;        // 一离线就重新计时，防止抖动蒙混起跑
                    end else if (ms_cnt >= START_MS - 1) begin
                        ms_cnt <= 16'd0;
                        state  <= S_RUN;
                    end else begin
                        ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                S_RUN: begin
                    if (turning) begin
                        // ---- 交通牌强制转向 ----
                        // 期间车道线会先被甩开（本来就是有意离开），所以忽略 lost，
                        // 否则一压离线就跳 S_LOST，转向走不完。障碍仍然优先停车。
                        dir_l_des <= turn_left ? 1'b0 : 1'b1;   // 左转：左轮后退
                        dir_r_des <= turn_left ? 1'b1 : 1'b0;   //       右轮前进
                        if (!dead) begin
                            duty_l <= TURN_DUTY[10:0];
                            duty_r <= TURN_DUTY[10:0];
                        end
                        turn_cnt <= turn_cnt - 16'd1;
                        if (turn_cnt <= 16'd1) begin
                            turning <= 1'b0;
                            ms_cnt  <= 16'd0;
                            // 转向正常结束时清掉拐角记忆：这 700 ms 里车轮扫过的
                            // 宽黑是"转向动作本身造成的"，不是赛道拐角特征。
                            corner_cnt <= 16'd0;
                        end
                        if (obstacle) begin
                            turning <= 1'b0;        // 撞上障碍就放弃这次转向
                            ms_cnt  <= 16'd0;
                            avoid_tries <= 4'd0;
                            // 往"线不在的那一侧"绕：线在右（!last_pos_neg）就往左绕
                            avoid_left  <= !last_pos_neg;
                            state   <= (AVOID_EN != 0) ? S_AVOID_BACK : S_STOP;
                        end
                    end else begin
                        dir_l_des <= 1'b1;
                        dir_r_des <= 1'b1;
                        if (!dead) begin
                            duty_l <= pid_l;
                            duty_r <= pid_r;
                        end
                        // 收到转向请求：转入强制转向
                        if (turn_req && turn_allowed &&
                            ((TURN_WAIT_FOR_CORNER == 0) || (!obstacle && dir_evt == 3'd0))) begin
                            turn_req <= 1'b0;
                            turn_request_left <= 16'd0;
                            turning  <= 1'b1;
                            turn_cnt <= TURN_MS[15:0];
                            turn_dir <= turn_left ? 2'd1 : 2'd2;
                            turn_dir_cnt <= TURN_DIR_HOLD_MS[15:0];
                            corner_cnt <= 16'd0;
                        end else if (obstacle) begin
                            ms_cnt <= 16'd0;
                            avoid_tries <= 4'd0;
                            avoid_left  <= !last_pos_neg;
                            state  <= (AVOID_EN != 0) ? S_AVOID_BACK : S_STOP;
                        end else if (lost) begin
                            ms_cnt <= 16'd0;
                            state  <= S_LOST;
                        end
                    end
                end

                S_LOST: begin
                    // 保持最后一刻的占空比与方向
                    duty_l <= pid_l;
                    duty_r <= pid_r;
                    if (!lost && on_line) begin
                        ms_cnt <= 16'd0;
                        state  <= S_RUN;
                    end else if (obstacle) begin
                        // 【盲区补漏】obstacle 原来只在 S_RUN 与 S_AVOID_PROBE 里检查。
                        // S_LOST 会按上一刻占空比继续前进 LOST_HOLD_MS(300 ms)，
                        // 按 0.4 m/s 约 10 cm —— 在 25 cm 阈值下完全来得及撞上去。
                        // 这里补上，与 S_RUN 走同一套避障入口。
                        ms_cnt <= 16'd0;
                        avoid_tries <= 4'd0;
                        avoid_left  <= !last_pos_neg;
                        state  <= (AVOID_EN != 0) ? S_AVOID_BACK : S_STOP;
                    end else if (ms_cnt >= LOST_HOLD_MS - 1 &&
                                 ((TURN_WAIT_FOR_CORNER == 0) || dir_evt == 3'd0)) begin
                        ms_cnt <= 16'd0;
                        // ---- 找线方向决策（三级优先级）----
                        // ① 有转向牌事件（K230 识别到左/右转）：完全按牌走。
                        // ② 刚过拐角（宽黑后 CORNER_WIDE_MS 内）且没有牌：
                        //    按 DEFAULT_TURN_LEFT 一律左转。这正是"没装 K230 /
                        //    没识别到牌"时的兜底，菱形那两段各触发一次。
                        // ③ 其余情况（普通跑偏丢线）：线在哪边就往哪边转，
                        //    否则正常赛道上一旦偏出去就会朝反方向找，越找越远。
                        if (turn_req && turn_allowed &&
                            ((TURN_WAIT_FOR_CORNER == 0) || dir_evt == 3'd0)) begin
                            turn_req  <= 1'b0;
                            turn_request_left <= 16'd0;
                            dir_l_des <= turn_left ? 1'b0 : 1'b1;
                            dir_r_des <= turn_left ? 1'b1 : 1'b0;
                            turn_dir  <= turn_left ? 2'd1 : 2'd2;
                            turn_dir_cnt <= TURN_DIR_HOLD_MS[15:0];
                            corner_cnt <= 16'd0;
                        end else if ((DEFAULT_TURN_LEFT != 0) && (corner_cnt != 16'd0) &&
                                     ((TURN_WAIT_FOR_CORNER == 0) || !wide)) begin
                            // 拐角兜底：默认左转（左轮后退、右轮前进）
                            dir_l_des <= 1'b0;
                            dir_r_des <= 1'b1;
                            turn_dir  <= 2'd1;
                            turn_dir_cnt <= TURN_DIR_HOLD_MS[15:0];
                            corner_cnt <= 16'd0;
                        end else begin
                            // 线在右边 → 向右转：左轮前进、右轮后退
                            dir_l_des <= ~last_pos_neg;
                            dir_r_des <=  last_pos_neg;
                            turn_dir  <= last_pos_neg ? 2'd1 : 2'd2;
                            turn_dir_cnt <= TURN_DIR_HOLD_MS[15:0];
                        end
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
                    end else if (obstacle) begin
                        // 【盲区补漏】原地图旋转找线期间完全不看障碍，而这段时间
                        // 车身一侧在反转、最长持续 SEARCH_MS(1.5 s)，贴着障碍转
                        // 很容易蹭上（细则 4.3.2 明确不得触碰）。同样转避障。
                        ms_cnt <= 16'd0;
                        avoid_tries <= 4'd0;
                        avoid_left  <= !last_pos_neg;
                        state  <= (AVOID_EN != 0) ? S_AVOID_BACK : S_STOP;
                    end else if (ms_cnt >= SEARCH_MS - 1) begin
                        ms_cnt <= 16'd0;
                        // 桌面/小场地反复测试时，永久停车只能断电才能解除，非常难用。
                        // SEARCH_FAIL_TO_IDLE=1 改成回 IDLE：把车放回线上等 2 s 就重新起跑。
                        // 正式比赛改回 0（找线失败即判负，不能无限重试）。
                        if (SEARCH_FAIL_TO_IDLE != 0) begin
                            state <= S_IDLE;
                        end else begin
                            final_stop <= 1'b1;
                            state      <= S_STOP;
                        end
                    end else begin
                        ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                S_STOP: begin
                    duty_l <= 11'd0;
                    duty_r <= 11'd0;
                    // 只有"障碍导致的停车"且障碍消失才恢复；找线超时的停车保持
                    // AVOID_EN=1 时障碍不再进这里（走 BACK/TURN/PROBE），
                    // 所以这条恢复路径只对 AVOID_EN=0 的老行为有效。
                    if (!final_stop && !obstacle) begin
                        ms_cnt <= 16'd0;
                        state  <= S_RUN;
                    end
                end

                // ----------------------------------------------------------
                // 避障：后退 → 原地转（绕开障碍）→ 试探前进
                //   三段都是定长动作，不看线（这时候线通常已经被让开或压不到）；
                //   试探完还有障碍就再来一轮，最多 AVOID_TRIES 轮；
                //   用尽后进 S_STOP 等障碍消失，避免顶死在墙角反复撞。
                // ----------------------------------------------------------
                S_AVOID_BACK: begin
                    // 后退：两轮同向反转
                    dir_l_des <= 1'b0;
                    dir_r_des <= 1'b0;
                    if (!dead) begin
                        duty_l <= AVOID_BACK_DUTY[10:0];
                        duty_r <= AVOID_BACK_DUTY[10:0];
                    end
                    if (ms_cnt >= AVOID_BACK_MS - 1) begin
                        ms_cnt <= 16'd0;
                        state  <= S_AVOID_TURN;
                    end else begin
                        ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                S_AVOID_TURN: begin
                    // 原地转：一侧前进、一侧后退。方向按 avoid_left 定。
                    dir_l_des <= avoid_left ? 1'b0 : 1'b1;  // 往左绕：左轮后退
                    dir_r_des <= avoid_left ? 1'b1 : 1'b0;
                    if (!dead) begin
                        duty_l <= AVOID_TURN_DUTY[10:0];
                        duty_r <= AVOID_TURN_DUTY[10:0];
                    end
                    if (ms_cnt >= AVOID_TURN_MS - 1) begin
                        ms_cnt <= 16'd0;
                        state  <= S_AVOID_PROBE;
                    end else begin
                        ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                S_AVOID_PROBE: begin
                    if (AVOID_ROUTE_EN != 0) begin
                        // 向外驶离 → 摆正 → 侧边超越 → 转向线内 → 低速回线。
                        // 这几段由避障控制，途中看到黑线也不能提前交回普通找线。
                        dir_l_des <= bypass_dir_l;
                        dir_r_des <= bypass_dir_r;
                        if (lost) bypass_left_line <= 1'b1;

                        if (bypass_blocked) begin
                            duty_l <= 11'd0;
                            duty_r <= 11'd0;
                            bypass_line_cnt <= 16'd0;
                            if (bypass_block_cnt >= AVOID_BLOCK_MS - 1) begin
                                final_stop <= 1'b1;
                                state <= S_STOP;
                            end else begin
                                bypass_block_cnt <= bypass_block_cnt + 16'd1;
                            end
                        end else if (!dead && bypass_dirs_ready) begin
                            bypass_block_cnt <= 16'd0;
                            duty_l <= bypass_duty;
                            duty_r <= bypass_duty;
                            ms_cnt <= ms_cnt + 16'd1;
                            case (bypass_step)
                                BY_OUT: if (ms_cnt >= AVOID_PROBE_MS - 1) begin
                                    ms_cnt <= 16'd0;
                                    bypass_step <= BY_ALIGN;
                                end
                                BY_ALIGN: if (ms_cnt >= AVOID_TURN_MS - 1) begin
                                    ms_cnt <= 16'd0;
                                    bypass_step <= BY_PASS;
                                end
                                BY_PASS: if (ms_cnt >= AVOID_PASS_MS - 1) begin
                                    ms_cnt <= 16'd0;
                                    if (bypass_left_line && lost) begin
                                        bypass_step <= BY_TURN_IN;
                                    end else begin
                                        final_stop <= 1'b1;
                                        state <= S_STOP;
                                    end
                                end
                                BY_TURN_IN: if (ms_cnt >= AVOID_TURN_MS - 1) begin
                                    ms_cnt <= 16'd0;
                                    bypass_step <= BY_REJOIN;
                                end
                                BY_REJOIN: begin
                                    if (bypass_has_line && bypass_line_cnt >= AVOID_LINE_MS - 1) begin
                                        ms_cnt <= 16'd0;
                                        state <= S_RUN;
                                    end else if (ms_cnt >= AVOID_REJOIN_MS - 1) begin
                                        final_stop <= 1'b1;
                                        state <= S_STOP;
                                    end else begin
                                        bypass_line_cnt <= bypass_has_line ? (bypass_line_cnt + 16'd1) : 16'd0;
                                    end
                                end
                                default: begin
                                    final_stop <= 1'b1;
                                    state <= S_STOP;
                                end
                            endcase
                        end
                    end else begin
                        // 传统试探段供原有调用方式使用。
                        dir_l_des <= 1'b1;
                        dir_r_des <= 1'b1;
                        if (!dead) begin
                            duty_l <= AVOID_PROBE_DUTY[10:0];
                            duty_r <= AVOID_PROBE_DUTY[10:0];
                        end
                        // 前 AVOID_PROBE_SETTLE_MS 不判障碍：刚转完身障碍还在正前方是
                        // 正常的，要等车真的往前探一段再判断"还堵着没"。
                        if (obstacle && (ms_cnt >= AVOID_PROBE_SETTLE_MS[15:0])) begin
                            // 还堵着：动作已经做完，再来一轮（或放弃）
                            ms_cnt <= 16'd0;
                            if (avoid_tries >= AVOID_TRIES - 1) begin
                                avoid_tries <= 4'd0;
                                state <= S_STOP;
                            end else begin
                                avoid_tries <= avoid_tries + 4'd1;
                                avoid_left  <= ~avoid_left;   // 换个方向再试
                                state <= S_AVOID_BACK;
                            end
                        end else if (ms_cnt >= AVOID_PROBE_MS - 1) begin
                            // 试探时间到。**不能无条件回 RUN**：绕行结束时车体朝向与线的
                            // 相对关系已经完全变了，按"线就在脚下"进 RUN 会用一份过期
                            // 的 pid 值瞎跑。压在线上才回 RUN，否则交给 S_LOST 找线。
                            ms_cnt      <= 16'd0;
                            avoid_tries <= 4'd0;
                            state       <= (!lost && on_line) ? S_RUN : S_LOST;
                        end else begin
                            ms_cnt <= ms_cnt + 16'd1;
                        end
                    end
                end

                default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
