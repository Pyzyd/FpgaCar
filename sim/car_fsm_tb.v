// =============================================================================
// car_fsm_tb.v —— 整车状态机自测
// 参数全部缩到 1~2 ms。验收点：
//   1) 复位后 IDLE，en=0（电机不转，安全）
//   2) START_MS 后进 RUN，en=1，两轮正转，duty 直接跟 pid
//   3) 丢线 → LOST（保持 duty），保持超时 → SEARCH（原地转，方向按最后线位）
//   4) 重新压线 → 回 RUN
//   5) 障碍 → STOP 且 en=0；障碍消失 → 自动恢复 RUN
//   6) 找线超时 → STOP 且永久保持（obstacle 清零也不恢复）
//   7) SEARCH_FAIL_TO_IDLE=1 的实例：同一激励下回 IDLE，放回线上能重新起跑
//   8) DIR_DEAD_MS=3 的实例：死区计时能走完，en/duty 恢复（防计数器位宽不足）
//   9) AVOID_EN=1 的实例：障碍 -> BACK(倒) -> TURN(原地转) -> PROBE(慢进) -> RUN
//  10) 试探仍被挡 -> 重试并换转向
//  11) 重试次数用尽 -> STOP；障碍消失后自动回 RUN
//
// 注意：每个 check 的字符串不能超过 31 字符（Verilog 任务端口位宽会截断，只留尾部）。
// =============================================================================
`timescale 1ns/1ps

module car_fsm_tb;

    localparam [2:0] S_IDLE = 3'd0, S_RUN = 3'd1, S_LOST = 3'd2,
                     S_SEARCH = 3'd3, S_STOP = 3'd4,
                     S_AVOID_BACK = 3'd5, S_AVOID_TURN = 3'd6, S_AVOID_PROBE = 3'd7;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20.8335 clk = ~clk;

    reg               on_line = 1'b0;      // 一开始不压线：先验安全锁，再手动压线起跑
    reg               lost = 1'b0;
    reg               obstacle = 1'b0;
    reg               wide = 1'b0;         // 宽黑标志（默认 0：不触发拐角兜底）
    reg signed [4:0]  pos = 5'sd0;
    reg [10:0]        pid_l = 11'd700;
    reg [10:0]        pid_r = 11'd500;

    wire              en;
    wire              dir_l, dir_r;
    wire [10:0]       duty_l, duty_r;
    wire [2:0]        state;
    wire [1:0]        td, td2, td3, td4;

    car_fsm #(
        .CLK_FREQ     (24_000_000),
        .START_MS     (1),
        .START_REQUIRE_LINE (1),
        .LOST_HOLD_MS (1),
        .SEARCH_MS    (10),                    // 拉长到 10 ms，留出观察 SEARCH 的时间窗
        .SEARCH_DUTY  (500),
        .SEARCH_FAIL_TO_IDLE (0),              // 比赛行为：找线超时永久停车
        .DIR_DEAD_MS  (1),
        .AVOID_EN     (0)                       // 老实例保持"障碍 -> STOP"的旧语义
    ) u_dut (
        .clk (clk), .rst_n (rst_n),
        .on_line (on_line), .lost (lost), .obstacle (obstacle), .pos (pos),
        .wide (wide),
        .dir_evt (3'd0),                // 本实例不测转向牌；悬空会在仿真里变成 X
        .pid_l (pid_l), .pid_r (pid_r),
        .en (en), .dir_l (dir_l), .dir_r (dir_r),
        .duty_l (duty_l), .duty_r (duty_r), .state (state), .turn_dir (td)
    );

    // 第二个实例：桌面反复测试用的行为 —— 找线超时回 IDLE 而不是永久停车。
    // 与 u_dut 共用同一组激励，只有这一个参数不同，便于逐拍对照两种收敛方式。
    wire              en2, dir_l2, dir_r2;
    wire [10:0]       duty_l2, duty_r2;
    wire [2:0]        state2;

    car_fsm #(
        .CLK_FREQ     (24_000_000),
        .START_MS     (1),
        .START_REQUIRE_LINE (1),
        .LOST_HOLD_MS (1),
        .SEARCH_MS    (10),
        .SEARCH_DUTY  (500),
        .SEARCH_FAIL_TO_IDLE (1),              // 桌面行为：找线超时回 IDLE，可重新起跑
        .DIR_DEAD_MS  (1),
        .AVOID_EN     (0)
    ) u_dut2 (
        .clk (clk), .rst_n (rst_n),
        .on_line (on_line), .lost (lost), .obstacle (obstacle), .pos (pos),
        .wide (wide),
        .dir_evt (3'd0),
        .pid_l (pid_l), .pid_r (pid_r),
        .en (en2), .dir_l (dir_l2), .dir_r (dir_r2),
        .duty_l (duty_l2), .duty_r (duty_r2), .state (state2), .turn_dir (td2)
    );

    // 第三个实例：DIR_DEAD_MS 用真实值 3 ms（DEAD_CYC = 24000*3 = 72000 > 16 位上限）。
    // 专门盯死区计数器位宽：宽度不够时 dead 永远清不掉，en 恒 0、duty 恒 0。
    wire              en3, dir_l3, dir_r3;
    wire [10:0]       duty_l3, duty_r3;
    wire [2:0]        state3;

    car_fsm #(
        .CLK_FREQ     (24_000_000),
        .START_MS     (1),
        .START_REQUIRE_LINE (1),
        .LOST_HOLD_MS (1),
        .SEARCH_MS    (10),
        .SEARCH_DUTY  (500),
        .SEARCH_FAIL_TO_IDLE (1),              // 回 IDLE，用例 8 才能重新起跑到 SEARCH
        .DIR_DEAD_MS  (3),
        .AVOID_EN     (0)
    ) u_dut3 (
        .clk (clk), .rst_n (rst_n),
        .on_line (on_line), .lost (lost), .obstacle (obstacle), .pos (pos),
        .wide (wide),
        .dir_evt (3'd0),
        .pid_l (pid_l), .pid_r (pid_r),
        .en (en3), .dir_l (dir_l3), .dir_r (dir_r3),
        .duty_l (duty_l3), .duty_r (duty_r3), .state (state3), .turn_dir (td3)
    );

    // 第四个实例：开避障三段。用自己的激励，避免被前面用例（永久停车等）干扰。
    reg               on4 = 1'b0;
    reg               lost4 = 1'b0;
    reg               obs4 = 1'b0;
    wire              en4, dir_l4, dir_r4;
    wire [10:0]       duty_l4, duty_r4;
    wire [2:0]        state4;
    localparam integer AVOID_TEST_DEAD_MS = 3, AVOID_TEST_MOVE_MS = 8;
    // 包含方向请求、完整死区、PWM 装载和轮询对齐的余量。
    localparam integer AVOID_STAGE_TIMEOUT_US = 1000 * (AVOID_TEST_MOVE_MS + AVOID_TEST_DEAD_MS + 3);
    localparam integer AVOID_RETRY_TIMEOUT_US = 2 * AVOID_STAGE_TIMEOUT_US;

    car_fsm #(
        .CLK_FREQ     (24_000_000),
        .START_MS     (1),
        .START_REQUIRE_LINE (1),
        .LOST_HOLD_MS (1),
        .SEARCH_MS    (10),
        .SEARCH_DUTY  (500),
        .SEARCH_FAIL_TO_IDLE (1),
        .DIR_DEAD_MS  (AVOID_TEST_DEAD_MS),
        .AVOID_EN     (1),
        .AVOID_BACK_MS   (AVOID_TEST_MOVE_MS),
        .AVOID_BACK_DUTY (400),
        .AVOID_TURN_MS   (AVOID_TEST_MOVE_MS),
        .AVOID_TURN_DUTY (400),
        .AVOID_PROBE_MS  (AVOID_TEST_MOVE_MS),
        .AVOID_PROBE_DUTY(350),
        .AVOID_PROBE_SETTLE_MS (2),             // 静默窗 2 ms，用例 10/11 才能看到试探段
        .AVOID_TRIES  (2)
    ) u_dut4 (
        .clk (clk), .rst_n (rst_n),
        .on_line (on4), .lost (lost4), .obstacle (obs4), .pos (5'sd0),
        .wide (1'b0), .dir_evt (3'd0),
        .pid_l (11'd700), .pid_r (11'd500),
        .en (en4), .dir_l (dir_l4), .dir_r (dir_r4),
        .duty_l (duty_l4), .duty_r (duty_r4), .state (state4), .turn_dir (td4)
    );

    // 第五个实例：拐角兜底。没有 K230 时应"宽黑后丢线 -> 一律左转"。
    // 用自己的激励，且故意把 pos 设成 +3（线在右、正常跑偏会右转），
    // 这样才能证明是兜底生效而不是碰巧走了原逻辑。
    reg               on5 = 1'b0;
    reg               lost5 = 1'b0;
    reg               wide5 = 1'b0;
    reg signed [4:0]  pos5 = 5'sd0;
    wire              en5, dir_l5, dir_r5;
    wire [10:0]       duty_l5, duty_r5;
    wire [2:0]        state5;
    wire [1:0]        td5;

    car_fsm #(
        .CLK_FREQ     (24_000_000),
        .START_MS     (1),
        .START_REQUIRE_LINE (1),
        .LOST_HOLD_MS (1),
        .SEARCH_MS    (10),
        .SEARCH_DUTY  (500),
        .SEARCH_FAIL_TO_IDLE (1),
        .DIR_DEAD_MS  (3),                     // 死区 > 1 拍，断言前要等它走完
        .AVOID_EN     (0),
        .DEFAULT_TURN_LEFT (1),
        .CORNER_WIDE_MS    (500),
        .TURN_DIR_HOLD_MS  (20)                // 20 ms 后指示自动熄灭，便于在仿真里验证
    ) u_dut5 (
        .clk (clk), .rst_n (rst_n),
        .on_line (on5), .lost (lost5), .obstacle (1'b0), .wide (wide5), .pos (pos5),
        .dir_evt (3'd0),
        .pid_l (11'd700), .pid_r (11'd500),
        .en (en5), .dir_l (dir_l5), .dir_r (dir_r5),
        .duty_l (duty_l5), .duty_r (duty_r5), .state (state5), .turn_dir (td5)
    );

    // 第六个实例：专门盯本轮补的三处逻辑 ——
    //   ① S_LOST 期间遇障碍要立刻转避障（原来会继续前进 300 ms）
    //   ② S_SEARCH 期间遇障碍同样要转避障（原来贴着障碍原地转 1.5 s）
    //   ③ PROBE 结束后不在线上应转 S_LOST，而不是无条件回 RUN
    // 用独立激励，避免被前面用例留下的状态干扰。
    reg               on6 = 1'b0;
    reg               lost6 = 1'b0;
    reg               obs6 = 1'b0;
    wire              en6, dir_l6, dir_r6;
    wire [10:0]       duty_l6, duty_r6;
    wire [2:0]        state6;
    wire [1:0]        td6;

    car_fsm #(
        .CLK_FREQ     (24_000_000),
        .START_MS     (1),
        .START_REQUIRE_LINE (1),
        .LOST_HOLD_MS (200),                   // 拉长到 200 ms：必须在 LOST 里就转避障，
                                               // 否则会先超时进 SEARCH 再绕回 BACK，
                                               // 那样测不出 S_LOST 这条分支
        .SEARCH_MS    (10),
        .SEARCH_DUTY  (500),
        .SEARCH_FAIL_TO_IDLE (1),
        .DIR_DEAD_MS  (1),
        .AVOID_EN     (1),
        .AVOID_BACK_MS   (8),
        .AVOID_BACK_DUTY (400),
        .AVOID_TURN_MS   (8),
        .AVOID_TURN_DUTY (400),
        .AVOID_PROBE_MS  (20),                 // 试探段拉长到 20 ms，便于观察静默窗
        .AVOID_PROBE_DUTY(350),
        .AVOID_PROBE_SETTLE_MS (5),            // 前 5 ms 不判障碍
        .AVOID_TRIES  (3),
        .DEFAULT_TURN_LEFT (0)                 // 本实例不测拐角兜底
    ) u_dut6 (
        .clk (clk), .rst_n (rst_n),
        .on_line (on6), .lost (lost6), .obstacle (obs6), .wide (1'b0), .pos (5'sd0),
        .dir_evt (3'd0),
        .pid_l (11'd700), .pid_r (11'd500),
        .en (en6), .dir_l (dir_l6), .dir_r (dir_r6),
        .duty_l (duty_l6), .duty_r (duty_r6), .state (state6), .turn_dir (td6)
    );

    // 第七个实例：转向牌（dir_evt）路径。此前 6 个实例一次都没驱动过 dir_evt，
    // 导致 car_fsm 里整块交通牌逻辑（事件锁存 / turning 段 / 按牌找线）零覆盖。
    // 参数刻意调短：TURN_MS=20 ms、TURN_DIR_HOLD_MS=50 ms，方便在仿真里观察。
    // DEFAULT_TURN_LEFT=1 + CORNER_WIDE_MS=500 同时开着，用来回归
    // "转向期间产生的宽黑不能污染拐角记忆、否则把牌的方向反过来"。
    reg  [2:0]        dir_evt7 = 3'd0;
    reg               on7 = 1'b0;
    reg               lost7 = 1'b0;
    reg               wide7 = 1'b0;
    reg signed [4:0]  pos7 = 5'sd0;
    wire              en7, dir_l7, dir_r7;
    wire [10:0]       duty_l7, duty_r7;
    wire [2:0]        state7;
    wire [1:0]        td7;

    car_fsm #(
        .CLK_FREQ          (24_000_000),
        .START_MS          (1),
        .START_REQUIRE_LINE (1),
        .LOST_HOLD_MS      (2),                // 很短：进 LOST 后马上到决策点
        .SEARCH_MS         (10),
        .SEARCH_DUTY       (500),
        .SEARCH_FAIL_TO_IDLE (1),
        .DIR_DEAD_MS       (1),
        .TURN_MS           (20),
        .TURN_DUTY         (400),
        .AVOID_EN          (0),
        .DEFAULT_TURN_LEFT (1),
        .CORNER_WIDE_MS    (500),
        .TURN_DIR_HOLD_MS  (50)
    ) u_dut7 (
        .clk (clk), .rst_n (rst_n),
        .on_line (on7), .lost (lost7), .obstacle (1'b0), .wide (wide7), .pos (pos7),
        .dir_evt (dir_evt7),
        .pid_l (11'd700), .pid_r (11'd500),
        .en (en7), .dir_l (dir_l7), .dir_r (dir_r7),
        .duty_l (duty_l7), .duty_r (duty_r7), .state (state7), .turn_dir (td7)
    );

    task wait_state5 (input [2:0] want, input integer timeout_us);
        integer n;
        begin
            n = 0;
            while (state5 !== want && n < timeout_us) begin
                wait_us(100);
                n = n + 100;
            end
            #1;
        end
    endtask

    task wait_us (input integer n);
        begin
            repeat (n * 24) @(posedge clk);      // 24 clk = 1 us
            #1;
        end
    endtask

    integer fails = 0;

    task chk6 (input integer cond, input [8*28-1:0] msg);
        begin
            if (cond) $display("PASS: %0s", msg);
            else begin
                $display("FAIL: %0s | st6=%0d en6=%b dir6=%b%b d6=%0d/%0d",
                         msg, state6, en6, dir_l6, dir_r6, duty_l6, duty_r6);
                fails = fails + 1;
            end
        end
    endtask

    task wait_state6 (input [2:0] want, input integer timeout_us);
        integer n;
        begin
            n = 0;
            while (state6 !== want && n < timeout_us) begin
                wait_us(100);
                n = n + 100;
            end
            #1;
        end
    endtask

    task chk7 (input integer cond, input [8*28-1:0] msg);
        begin
            if (cond) $display("PASS: %0s", msg);
            else begin
                $display("FAIL: %0s | st7=%0d dir7=%b%b d7=%0d/%0d td7=%0d",
                         msg, state7, dir_l7, dir_r7, duty_l7, duty_r7, td7);
                fails = fails + 1;
            end
        end
    endtask

    task wait_state7 (input [2:0] want, input integer timeout_us);
        integer n;
        begin
            n = 0;
            while (state7 !== want && n < timeout_us) begin
                wait_us(100);
                n = n + 100;
            end
            #1;
        end
    endtask

    task chk (input integer cond, input [8*28-1:0] msg);
        begin
            if (cond) $display("PASS: %0s", msg);
            else begin
                $display("FAIL: %0s | st=%0d en=%b dir=%b%b d=%0d/%0d",
                         msg, state, en, dir_l, dir_r, duty_l, duty_r);
                fails = fails + 1;
            end
        end
    endtask

    // 轮询等状态4到位（避障段被障碍打断时可能只停留一拍，定长延时不可靠）
    task wait_state4 (input [2:0] want, input integer timeout_us);
        integer n;
        begin
            n = 0;
            while (state4 !== want && n < timeout_us) begin
                wait_us(100);
                n = n + 100;
            end
            #1;
        end
    endtask

    // 等待动作实际使能，且两轮的方向、占空比都符合本段要求。
    task wait_avoid (input dl_want, input dr_want, input [10:0] d_want,
                     input integer timeout_us);
        integer n;
        begin
            n = 0;
            while ((en4 !== 1'b1 || dir_l4 !== dl_want || dir_r4 !== dr_want ||
                    duty_l4 != d_want || duty_r4 != d_want) && n < timeout_us) begin
                wait_us(100);
                n = n + 100;
            end
            wait_us(200);
        end
    endtask

    task chk5 (input integer cond, input [8*28-1:0] msg);
        begin
            if (cond) $display("PASS: %0s", msg);
            else begin
                $display("FAIL: %0s | st5=%0d dir5=%b%b td5=%0d",
                         msg, state5, dir_l5, dir_r5, td5);
                fails = fails + 1;
            end
        end
    endtask

    task chk4 (input integer cond, input [8*28-1:0] msg);
        begin
            if (cond) $display("PASS: %0s", msg);
            else begin
                $display("FAIL: %0s | st4=%0d en4=%b dir4=%b%b d4=%0d/%0d",
                         msg, state4, en4, dir_l4, dir_r4, duty_l4, duty_r4);
                fails = fails + 1;
            end
        end
    endtask

    initial begin
        #300 rst_n = 1'b1;
        wait_us(100);                      // 0.1 ms：还没到 START_MS

        // ---- 1) IDLE ----
        chk(state == S_IDLE && en === 1'b0, "IDLE, motor off");

        // ---- 1b) 安全锁：不压线就永不起跑 ----
        // START_REQUIRE_LINE=1 时，"连续压线 START_MS"才算数；这里故意让它
        // 空等 5 ms（远超 START_MS=1 ms），必须还停在 IDLE、电机断电。
        wait_us(5000);
        chk(state == S_IDLE && en === 1'b0, "no line -> stays IDLE");
        chk(duty_l == 11'd0 && duty_r == 11'd0, "no line -> duty 0");

        // ---- 2) 压线起跑 ----
        on_line = 1'b1;
        // 进 RUN 是在 1 ms 那一拍发生的，而 duty 要等到下一个 ms 节拍才装载，
        // 所以必须等到 2 ms 之后再检查（1.3 ms 时 duty 还是 0）
        wait_us(2600);                     // 2.6 ms：已过 START_MS 且 duty 已装载
        chk(state == S_RUN && en === 1'b1, "RUN, motor on");
        chk(dir_l === 1'b1 && dir_r === 1'b1, "RUN both wheels forward");
        chk(duty_l == pid_l && duty_r == pid_r, "RUN duty = pid");

        // ---- 3) 丢线 → LOST ----
        pos = 5'sd3;                       // 最后看到线在右边
        wait_us(1500);                     // 先让 last_pos 记住 pos=+3
        lost = 1'b1; on_line = 1'b0;
        wait_us(1500);              // 等下一个 ms 节拍完成状态切换
        chk(state == S_LOST, "lost -> LOST (hold)");
        chk(duty_l == pid_l && duty_r == pid_r, "LOST holds duty");
        chk(en === 1'b1, "LOST keeps motor on");

        // ---- LOST 超时 → SEARCH ----
        wait_us(3500);              // 等 ms 节拍 + 方向死区
        chk(state == S_SEARCH, "lost timeout -> SEARCH");
        chk(dir_l === 1'b1 && dir_r === 1'b0, "SEARCH turns to right");
        chk(duty_l == 11'd500 && duty_r == 11'd500, "SEARCH duty = 500");

        // ---- 4) 重新压线 → RUN ----
        lost = 1'b0; on_line = 1'b1; pos = 5'sd0;
        wait_us(3500);              // 等 ms 节拍 + 方向死区
        chk(state == S_RUN, "line back -> RUN");
        chk(dir_l === 1'b1 && dir_r === 1'b1, "RUN forward again");

        // ---- 5) 障碍 → STOP → 恢复 ----
        obstacle = 1'b1;
        wait_us(1500);
        chk(state == S_STOP && en === 1'b0, "obstacle -> STOP, motor off");
        obstacle = 1'b0;
        wait_us(3500);              // 等 ms 节拍 + 方向死区
        chk(state == S_RUN && en === 1'b1, "obstacle gone -> RUN");

        // ---- 6) 找线超时 → 永久停车 ----
        lost = 1'b1; on_line = 1'b0;
        wait_us(20000);                    // > LOST_HOLD(1) + SEARCH_MS(10)
        chk(state == S_STOP && en === 1'b0, "search timeout -> STOP");
        obstacle = 1'b0; lost = 1'b1;
        wait_us(3000);
        chk(state == S_STOP && en === 1'b0, "final stop latched");

        // ---- 7) 同一激励下 SEARCH_FAIL_TO_IDLE=1 的实例应回到 IDLE ----
        chk(state2 == S_IDLE, "fail-to-idle: back to IDLE");
        chk(en2 === 1'b0, "fail-to-idle: motor off in IDLE");
        // 放回线上，应能重新起跑（不需要断电）
        lost = 1'b0; on_line = 1'b1; pos = 5'sd0;
        wait_us(3500);
        chk(state2 == S_RUN, "fail-to-idle: restarts on line");
        chk(state == S_STOP, "final-stop DUT stays stopped");

        // ---- 8) 死区计数器位宽：DIR_DEAD_MS=3 时 dead 必须能清掉 ----
        // 进 SEARCH 会换相（dir 1,1 -> 1,0），触发 3 ms 死区。旧代码 dead_cnt 只有
        // 16 位，永远追不上 72000，dead 卡死 -> en 恒 0、duty 恒 0（实车表现为
        // M=01 却不走）。等 4 ms 后必须恢复输出。
        on_line = 1'b0; lost = 1'b1;
        wait_us(2500);                     // LOST_HOLD(1) + 节拍
        chk(state3 == S_SEARCH, "dead test: in SEARCH");
        wait_us(4000);                     // > DIR_DEAD_MS(3)
        chk(en3 === 1'b1, "dead zone clears (en)");
        chk(duty_l3 == 11'd500 && duty_r3 == 11'd500, "dead zone clears (duty)");

        // ---- 9) 避障三段：障碍 -> BACK -> TURN -> PROBE -> RUN ----
        // 两个坑：
        // 换向和 PWM 装载结束后才计入每段时长。用轮询捕捉各段，
        // 重试时也给前一段余下动作和试探静默窗留出时间。
        lost4 = 1'b0; on4 = 1'b1;
        wait_state4(S_RUN, 5000);
        chk4(state4 == S_RUN && en4 === 1'b1, "avoid: in RUN");

        obs4 = 1'b1;
        wait_state4(S_AVOID_BACK, 2000);
        chk4(state4 == S_AVOID_BACK, "avoid: obstacle -> BACK");
        wait_avoid(1'b0, 1'b0, 11'd400, 9000);
        chk4(dir_l4 === 1'b0 && dir_r4 === 1'b0, "avoid: BACK both reverse");
        chk4(duty_l4 == 11'd400 && duty_r4 == 11'd400, "avoid: BACK duty 400");

        wait_state4(S_AVOID_TURN, AVOID_STAGE_TIMEOUT_US);
        chk4(state4 == S_AVOID_TURN, "avoid: BACK -> TURN");
        wait_avoid(1'b0, 1'b1, 11'd400, 9000);
        chk4(dir_l4 === 1'b0 && dir_r4 === 1'b1, "avoid: TURN left wheel back");
        chk4(duty_l4 == 11'd400 && duty_r4 == 11'd400, "avoid: TURN duty 400");

        obs4 = 1'b0;                       // 转完把障碍拿开，试探应成功
        wait_state4(S_AVOID_PROBE, AVOID_STAGE_TIMEOUT_US);
        chk4(state4 == S_AVOID_PROBE, "avoid: TURN -> PROBE");
        wait_avoid(1'b1, 1'b1, 11'd350, 9000);
        chk4(dir_l4 === 1'b1 && dir_r4 === 1'b1, "avoid: PROBE forward");
        chk4(duty_l4 == 11'd350 && duty_r4 == 11'd350, "avoid: PROBE duty 350");

        wait_state4(S_RUN, AVOID_STAGE_TIMEOUT_US);
        chk4(state4 == S_RUN, "avoid: PROBE -> RUN");

        // ---- 10) 试探仍被挡 -> 重来一轮，第二次转向与第一次相反 ----
        obs4 = 1'b1;
        wait_state4(S_AVOID_BACK, 2000);
        chk4(state4 == S_AVOID_BACK, "retry: BACK again");

        wait_state4(S_AVOID_TURN, AVOID_STAGE_TIMEOUT_US);
        chk4(state4 == S_AVOID_TURN, "retry: TURN again");
        wait_avoid(1'b0, 1'b1, 11'd400, 9000);
        chk4(dir_l4 === 1'b0 && dir_r4 === 1'b1, "retry: TURN same side");

        // 第一轮试探被挡后会翻向，回到 BACK 再来一遍
        wait_state4(S_AVOID_BACK, AVOID_RETRY_TIMEOUT_US);
        chk4(state4 == S_AVOID_BACK, "retry: flip -> BACK");

        wait_state4(S_AVOID_TURN, AVOID_STAGE_TIMEOUT_US);
        chk4(state4 == S_AVOID_TURN, "retry: TURN after flip");
        wait_avoid(1'b1, 1'b0, 11'd400, 9000);
        chk4(dir_l4 === 1'b1 && dir_r4 === 1'b0, "retry: TURN flips side");

        // ---- 11) 次数用尽 -> STOP；障碍消失后自动回 RUN ----
        // AVOID_TRIES=2：这一轮 PROBE 仍被挡即放弃。
        wait_state4(S_STOP, AVOID_RETRY_TIMEOUT_US);
        chk4(state4 == S_STOP && en4 === 1'b0, "retry2: tries used -> STOP");

        obs4 = 1'b0;
        wait_state4(S_RUN, 8000);
        wait_us(4000);
        chk4(state4 == S_RUN && en4 === 1'b1, "avoid: obstacle gone -> RUN");

        // ---- 12) 拐角兜底：宽黑之后丢线、且没有转向牌 -> 一律左转 ----
        // 故意把 pos 设成 +3（线在右侧）：若走原逻辑应右转，只有兜底生效才会左转。
        lost5 = 1'b0; on5 = 1'b1; pos5 = 5'sd3;
        wait_us(3000);
        chk5(state5 == S_RUN, "corner: in RUN");
        wide5 = 1'b1;                      // 宽黑 = 拐角特征
        wait_us(2000);
        wide5 = 1'b0;
        lost5 = 1'b1; on5 = 1'b0;          // 拐角之后线消失
        wait_state5(S_SEARCH, 20000);
        wait_us(4000);                     // 等方向死区走完
        chk5(state5 == S_SEARCH, "corner: in SEARCH");
        chk5(dir_l5 === 1'b0 && dir_r5 === 1'b1, "corner: forced LEFT");
        chk5(td5 == 2'd1, "corner: S=1 left");

        // ---- 13) 普通跑偏（没有宽黑）仍按"线在哪边往哪边转" ----
        // 这一条是兜底的边界：不能因为加了默认左转，就让正常右弯跑偏也左转。
        lost5 = 1'b0; on5 = 1'b1; pos5 = 5'sd3;
        wait_state5(S_RUN, 20000);
        wait_us(3000);
        lost5 = 1'b1; on5 = 1'b0;
        wait_state5(S_SEARCH, 20000);
        wait_us(4000);
        chk5(dir_l5 === 1'b1 && dir_r5 === 1'b0, "normal: turn to line side");
        chk5(td5 == 2'd2, "normal: S=2 right");

        // ---- 14) 转向指示必须自动熄灭 ----
        // turn_dir 若只置位不清零，OLED 上"左转/右转"两格会一直亮着，
        // 直道上也显示正在转弯，四标志格就失去意义了。
        chk5(td5 == 2'd2, "hold: still lit right after turn");
        wait_us(30000);                    // > TURN_DIR_HOLD_MS(20)
        chk5(td5 == 2'd0, "hold: indicator clears");

        // ---- 15) S_LOST 期间遇障碍：必须立刻转避障，不能继续盲目前进 ----
        // 旧代码 obstacle 只在 S_RUN 与 PROBE 判，S_LOST 会按上一刻占空比
        // 继续前进 LOST_HOLD_MS，25 cm 阈值下完全来得及撞上去。
        lost6 = 1'b0; on6 = 1'b1; obs6 = 1'b0;
        wait_state6(S_RUN, 20000);
        wait_us(3000);
        lost6 = 1'b1; on6 = 1'b0;              // 丢线，进 S_LOST（LOST_HOLD_MS=5）
        wait_state6(S_LOST, 20000);
        chk6(state6 == S_LOST, "lost: in LOST");
        obs6 = 1'b1;                            // 丢线还保持期间突然出现障碍
        // 只等 60 ms：远小于 LOST_HOLD_MS(200)。若障碍分支没生效，车会一直
        // 停在 LOST 直到 200 ms 超时，这条断言就会失败 —— 区分度就在这里。
        wait_state6(S_AVOID_BACK, 60000);
        chk6(state6 == S_AVOID_BACK, "lost+obs -> BACK fast");
        // 换相死区会短暂把 en 拉低，等死区走完再查电机是否上电
        wait_us(6000);
        chk6(en6 === 1'b1, "lost+obs: motor on");

        // ---- 16) S_SEARCH 期间遇障碍：同样必须转避障 ----
        // 原地图旋转找线最长 1.5 s，贴着障碍转很容易蹭上（细则 4.3.2 禁触碰）。
        // 注意不能让它"自然"走到 SEARCH：避障走完车不在线上，会先进 S_LOST，
        // 而 LOST_HOLD_MS=5 太短、不容易在 LOST 里命中；这里先回线上重新起跑，
        // 再直接把 on6 拉低，让 LOST->SEARCH 这条路干净可控。
        obs6 = 1'b0;
        on6 = 1'b1; lost6 = 1'b0;
        wait_state6(S_RUN, 40000);
        wait_us(3000);
        on6 = 1'b0; lost6 = 1'b1;              // 丢线
        wait_state6(S_LOST, 30000);
        wait_state6(S_SEARCH, 400000);         // 等 LOST_HOLD_MS(200) 超时后自动进 SEARCH
        chk6(state6 == S_SEARCH, "search: in SEARCH");
        obs6 = 1'b1;
        wait_state6(S_AVOID_BACK, 20000);
        chk6(state6 == S_AVOID_BACK, "search+obs -> BACK");

        // ---- 17) PROBE 结束不在线上 -> 转 S_LOST（不是无条件回 RUN）----
        // 绕行结束时车体朝向与线的相对关系已经全变了，按"线就在脚下"进 RUN
        // 会用一份过期的 pid 值瞎跑。这里让整个避障过程都没有线。
        obs6 = 1'b0; lost6 = 1'b1; on6 = 1'b0;
        wait_state6(S_AVOID_PROBE, 40000);
        chk6(state6 == S_AVOID_PROBE, "probe: reached PROBE");
        wait_state6(S_LOST, 40000);
        chk6(state6 == S_LOST, "probe done offline -> LOST");
        chk6(state6 !== S_RUN, "probe done offline != RUN");

        // ---- 18) PROBE 静默窗：刚进试探段时障碍仍在，不能第一拍就打回 BACK ----
        // 从 TURN 转进 PROBE 时障碍通常还在正前方（车还没动）。如果一进 PROBE
        // 就判 obstacle，试探只跑 1 ms 就被打回，3 轮配额瞬间烧光，避障退化成
        // "原地左右各抖 600 ms 再停车"。这里断言它在静默窗内确实留在 PROBE。
        lost6 = 1'b0; on6 = 1'b1; obs6 = 1'b0;
        wait_state6(S_RUN, 40000);
        wait_us(3000);
        obs6 = 1'b1;                            // 全程保持障碍
        wait_state6(S_AVOID_PROBE, 60000);
        chk6(state6 == S_AVOID_PROBE, "settle: reached PROBE");
        wait_us(3000);                          // < AVOID_PROBE_SETTLE_MS(5)
        chk6(state6 == S_AVOID_PROBE, "settle: stays in PROBE");
        // 静默窗过后仍被挡，才应该回 BACK 再来一轮
        wait_state6(S_AVOID_BACK, 40000);
        chk6(state6 == S_AVOID_BACK, "settle: then bounces BACK");

        // 收回到线上一路跑回去，给后面的用例一个干净起点
        obs6 = 1'b0; lost6 = 1'b0; on6 = 1'b1;
        wait_state6(S_RUN, 60000);
        chk6(state6 == S_RUN, "recovered on line");

        // ---- 19) 转向牌：dir_evt=1 -> 左转（左轮后退、右轮前进）----
        // 这块逻辑此前零覆盖：六个旧实例一次都没驱动过 dir_evt。
        on7 = 1'b1; lost7 = 1'b0; pos7 = 5'sd0;
        wait_state7(S_RUN, 40000);
        chk7(state7 == S_RUN, "card: in RUN");
        dir_evt7 = 3'd1;
        wait_us(2000);
        dir_evt7 = 3'd0;
        wait_us(3000);                          // 死区 1 ms + 装载
        chk7(dir_l7 === 1'b0 && dir_r7 === 1'b1, "card1: LEFT wheels");
        chk7(duty_l7 == 11'd400 && duty_r7 == 11'd400, "card1: duty 400");
        chk7(td7 == 2'd1, "card1: S=1 left");
        wait_state7(S_RUN, 40000);              // TURN_MS=20 ms 后自动结束
        chk7(state7 == S_RUN, "card1: turn ends");

        // ---- 20) 转向牌：dir_evt=2 -> 右转 ----
        dir_evt7 = 3'd2;
        wait_us(2000);
        dir_evt7 = 3'd0;
        wait_us(3000);
        chk7(dir_l7 === 1'b1 && dir_r7 === 1'b0, "card2: RIGHT wheels");
        chk7(td7 == 2'd2, "card2: S=2 right");
        wait_state7(S_RUN, 40000);
        chk7(state7 == S_RUN, "card2: turn ends");

        // ---- 21) 直行牌 dir_evt=3：取消转向，同时熄掉转向指示 ----
        dir_evt7 = 3'd1;
        wait_us(2000);
        dir_evt7 = 3'd0;
        wait_us(3000);
        chk7(td7 == 2'd1, "card3: turn indicated");
        dir_evt7 = 3'd3;
        wait_us(2000);
        dir_evt7 = 3'd0;
        wait_us(2000);
        chk7(td7 == 2'd0, "card3: straight clears S");
        wait_state7(S_RUN, 40000);

        // ---- 22) 【回归 corner_cnt 污染】转向期间扫过宽黑，转向后丢线，
        //          找线方向必须仍按牌走，不能被拐角兜底反成左转 ----
        // 这是真实失效链：强制转向 700 ms 期间车体有意离开赛道，必然扫过
        // 黑线/宽黑区域。若 corner_cnt 在那儿被填满，转向结束丢线时兜底
        // 就会强制左转，把刚按牌子做的右转覆盖掉。
        pos7 = 5'sd3;                           // 线在右 -> 正常找线应右转
        wait_us(3000);
        chk7(state7 == S_RUN, "card4: RUN before turn");
        dir_evt7 = 3'd2;                        // 牌子要求右转
        wait_us(2000);
        dir_evt7 = 3'd0;
        wait_us(2000);
        wide7 = 1'b1;                           // 转向中扫过宽黑
        wait_us(2000);
        wide7 = 1'b0;                           // 必须在转向结束前撤掉，
                                                // 否则转向结束后它自己会重新填 corner_cnt
        wait_state7(S_RUN, 40000);              // 转向结束
        lost7 = 1'b1; on7 = 1'b0;
        wait_state7(S_SEARCH, 40000);           // LOST_HOLD_MS=2，很快到决策点
        wait_us(3000);                          // 等方向死区
        chk7(state7 == S_SEARCH, "card4: in SEARCH");
        chk7(dir_l7 === 1'b1 && dir_r7 === 1'b0, "card4: still RIGHT");
        chk7(td7 == 2'd2, "card4: S=2 not flipped");

        if (fails == 0) $display("INFO: car_fsm_tb ALL PASS");
        else            $display("INFO: car_fsm_tb %0d FAIL(S)", fails);
        $finish;
    end

    initial begin
        #1_200_000_000;                    // 1.2 s：u_dut6 的 LOST_HOLD_MS=200 拉长了整体时长
        $display("TIMEOUT: car_fsm_tb hung (state=%0d)", state);
        $finish;
    end

endmodule
