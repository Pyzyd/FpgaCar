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

    car_fsm #(
        .CLK_FREQ     (24_000_000),
        .START_MS     (1),
        .START_REQUIRE_LINE (1),
        .LOST_HOLD_MS (1),
        .SEARCH_MS    (10),
        .SEARCH_DUTY  (500),
        .SEARCH_FAIL_TO_IDLE (1),
        .DIR_DEAD_MS  (3),                      // 3 ms 死区 > 1 拍，必须等它走完
        .AVOID_EN     (1),
        .AVOID_BACK_MS   (8),                   // 每段 8 ms，给死区留出余量
        .AVOID_BACK_DUTY (400),
        .AVOID_TURN_MS   (8),
        .AVOID_TURN_DUTY (400),
        .AVOID_PROBE_MS  (8),
        .AVOID_PROBE_DUTY(350),
        .AVOID_TRIES  (2)
    ) u_dut4 (
        .clk (clk), .rst_n (rst_n),
        .on_line (on4), .lost (lost4), .obstacle (obs4), .pos (5'sd0),
        .wide (1'b0),
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
        .CORNER_WIDE_MS    (500)
    ) u_dut5 (
        .clk (clk), .rst_n (rst_n),
        .on_line (on5), .lost (lost5), .obstacle (1'b0), .wide (wide5), .pos (pos5),
        .pid_l (11'd700), .pid_r (11'd500),
        .en (en5), .dir_l (dir_l5), .dir_r (dir_r5),
        .duty_l (duty_l5), .duty_r (duty_r5), .state (state5), .turn_dir (td5)
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

    // 轮询等"方向 + 双轮占空比"三者同时到位。
    // 不能只看 duty：进新一段时本段 duty 会先装载一次，随后换相死区把 duty
    // 压到 0 再放开，中间会出现"duty 已是新值、dir 还是旧值"的窗口。
    task wait_avoid (input dl_want, input dr_want, input [10:0] d_want,
                     input integer timeout_us);
        integer n;
        begin
            n = 0;
            while ((dir_l4 !== dl_want || dir_r4 !== dr_want ||
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
        //   a) 进新一段时先改 dir_*_des，换相死区（DIR_DEAD_MS=3 ms）会把
        //      dir/duty 压住 3 ms，断言方向/占空比必须等到 duty 真正装载；
        //   b) PROBE 期间若障碍仍在会立刻重试，PROBE 只停留约 1 ms。
        // 所以一律用 wait_state4 / wait_duty4 轮询，不用定长延时。
        lost4 = 1'b0; on4 = 1'b1;
        wait_state4(S_RUN, 5000);
        chk4(state4 == S_RUN && en4 === 1'b1, "avoid: in RUN");

        obs4 = 1'b1;
        wait_state4(S_AVOID_BACK, 2000);
        chk4(state4 == S_AVOID_BACK, "avoid: obstacle -> BACK");
        wait_avoid(1'b0, 1'b0, 11'd400, 9000);
        chk4(dir_l4 === 1'b0 && dir_r4 === 1'b0, "avoid: BACK both reverse");
        chk4(duty_l4 == 11'd400 && duty_r4 == 11'd400, "avoid: BACK duty 400");

        wait_state4(S_AVOID_TURN, 12000);
        chk4(state4 == S_AVOID_TURN, "avoid: BACK -> TURN");
        wait_avoid(1'b0, 1'b1, 11'd400, 9000);
        chk4(dir_l4 === 1'b0 && dir_r4 === 1'b1, "avoid: TURN left wheel back");
        chk4(duty_l4 == 11'd400 && duty_r4 == 11'd400, "avoid: TURN duty 400");

        obs4 = 1'b0;                       // 转完把障碍拿开，试探应成功
        wait_state4(S_AVOID_PROBE, 12000);
        chk4(state4 == S_AVOID_PROBE, "avoid: TURN -> PROBE");
        wait_avoid(1'b1, 1'b1, 11'd350, 9000);
        chk4(dir_l4 === 1'b1 && dir_r4 === 1'b1, "avoid: PROBE forward");
        chk4(duty_l4 == 11'd350 && duty_r4 == 11'd350, "avoid: PROBE duty 350");

        wait_state4(S_RUN, 12000);
        chk4(state4 == S_RUN, "avoid: PROBE -> RUN");

        // ---- 10) 试探仍被挡 -> 重来一轮，第二次转向与第一次相反 ----
        obs4 = 1'b1;
        wait_state4(S_AVOID_BACK, 2000);
        chk4(state4 == S_AVOID_BACK, "retry: BACK again");

        wait_state4(S_AVOID_TURN, 12000);
        chk4(state4 == S_AVOID_TURN, "retry: TURN again");
        wait_avoid(1'b0, 1'b1, 11'd400, 9000);
        chk4(dir_l4 === 1'b0 && dir_r4 === 1'b1, "retry: TURN same side");

        // 第一轮试探被挡后会翻向，回到 BACK 再来一遍
        wait_state4(S_AVOID_BACK, 12000);
        chk4(state4 == S_AVOID_BACK, "retry: flip -> BACK");

        wait_state4(S_AVOID_TURN, 12000);
        chk4(state4 == S_AVOID_TURN, "retry: TURN after flip");
        wait_avoid(1'b1, 1'b0, 11'd400, 9000);
        chk4(dir_l4 === 1'b1 && dir_r4 === 1'b0, "retry: TURN flips side");

        // ---- 11) 次数用尽 -> STOP；障碍消失后自动回 RUN ----
        // AVOID_TRIES=2：这一轮 PROBE 仍被挡即放弃。
        wait_state4(S_STOP, 20000);
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

        if (fails == 0) $display("INFO: car_fsm_tb ALL PASS");
        else            $display("INFO: car_fsm_tb %0d FAIL(S)", fails);
        $finish;
    end

    initial begin
        #600_000_000;                      // 600 ms：用例从约 30 ms 涨到约 130 ms
        $display("TIMEOUT: car_fsm_tb hung (state=%0d)", state);
        $finish;
    end

endmodule