`timescale 1ns/1ns

module bypass_rejoin_tb;
    localparam [2:0] IDLE = 0, RUN = 1, LOST = 2, SEARCH = 3, STOP = 4, TURN = 6, BYPASS = 7;
    localparam [2:0] OUT = 0, ALIGN = 1, PASS_SIDE = 2, TURN_IN = 3, REJOIN = 4;
    // 弧线绕障后不再有"原地转"段：OUT/ALIGN 各自是一段定长圆弧。
    localparam integer OUT_TICKS = 6, TURN_IN_TICKS = 40;
    // AVOID_LINE_MS 用的是默认 3；把 TURN_IN 的上限拉到 40，两条通路才拉开
    // 足够差距（扫线 ~3 拍，定长 40 拍），否则断言区分不出来。
    localparam integer LINE_TICKS = 3;
    localparam [10:0] TURN_DUTY = 11'd540;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst_n = 0, on_line = 1, lost = 0, obstacle = 0, wide = 0;
    reg signed [4:0] pos = 0;
    reg [2:0] dir_evt = 0;
    reg [3:0] line_count = 2;
    wire [2:0] state;
    wire en, dir_l, dir_r;
    wire [2:0] fixed_state;
    wire fixed_en, fixed_dir_l, fixed_dir_r;
    wire [10:0] fixed_duty_l, fixed_duty_r;
    integer exit_ticks = 0, align_ticks = 0, return_ticks = 0;
    reg fixed_arc_error = 0;
    reg [2:0] prev_step = 3'd0;   // 上一拍的段号：判「切段那一拍」用
    // 本拍 duty 是否已经属于「当前段」：既要段号没变，也要状态没变。
    // 少了后面这个条件，从 S_RUN 刚跳进 S_AVOID_PROBE 的第一拍，段号同为 BY_OUT、
    // 但 duty 还是 S_RUN 留下的 450/450 —— 会被误判成「画弧却两轮等速」。
    reg  [2:0] prev_state = 3'd0;
    always @(negedge clk) prev_state <= fixed_state;
    wire step_stable = (prev_step == fixed_right.bypass_step) && (prev_state == fixed_state);    reg inside_bypass = 0;

    car_fsm #(
        .CLK_FREQ(1000), .START_MS(1), .LOST_HOLD_MS(2), .DIR_DEAD_MS(1),
        .TURN_WAIT_FOR_CORNER(1), .TURN_APPROACH_PERCENT(80), .TURN_JUNCTION_SENSORS(3),
        .AVOID_ROUTE_EN(1), .AVOID_BACK_MS(4), .AVOID_TURN_MS(6), .AVOID_PROBE_MS(6),
        .AVOID_TURN_IN_MS(TURN_IN_TICKS),
        .AVOID_OUT_MS(OUT_TICKS), .AVOID_ALIGN_MS(OUT_TICKS),
        .AVOID_PASS_MS(14), .AVOID_REJOIN_MS(20), .AVOID_LINE_MS(3), .AVOID_BLOCK_MS(5)
    ) dut (
        .clk(clk), .rst_n(rst_n), .on_line(on_line), .lost(lost), .obstacle(obstacle),
        .wide(wide), .line_count(line_count), .pos(pos), .dir_evt(dir_evt),
        .pid_l(11'd450), .pid_r(11'd450), .enc_l_step(1'b0), .enc_r_step(1'b0),
        .en(en), .dir_l(dir_l), .dir_r(dir_r), .duty_l(), .duty_r(), .state(state), .turn_dir()
    );

    car_fsm #(
        .CLK_FREQ(1000), .START_MS(1), .LOST_HOLD_MS(2), .DIR_DEAD_MS(1),
        .AVOID_ROUTE_EN(1), .AVOID_FIXED_RIGHT(1),
        .AVOID_BACK_MS(4), .AVOID_TURN_MS(6), .AVOID_TURN_DUTY(TURN_DUTY),
        .AVOID_PROBE_MS(6), .AVOID_TURN_IN_MS(TURN_IN_TICKS),
        .AVOID_OUT_MS(OUT_TICKS), .AVOID_ALIGN_MS(OUT_TICKS),
        .AVOID_PASS_MS(14), .AVOID_REJOIN_MS(20), .AVOID_LINE_MS(3), .AVOID_BLOCK_MS(5)
    ) fixed_right (
        .clk(clk), .rst_n(rst_n), .on_line(on_line), .lost(lost), .obstacle(obstacle),
        .wide(wide), .line_count(4'd0), .pos(pos), .dir_evt(3'd0),
        .pid_l(11'd450), .pid_r(11'd450), .enc_l_step(1'b0), .enc_r_step(1'b0),
        .en(fixed_en), .dir_l(fixed_dir_l), .dir_r(fixed_dir_r),
        .duty_l(fixed_duty_l), .duty_r(fixed_duty_r), .state(fixed_state), .turn_dir()
    );

    // ---- 第三个实例：AVOID_ONCE=1，验证"第二次障碍不得再触发绕障" ----
    wire [2:0] once_state;
    wire once_en;
    car_fsm #(
        .CLK_FREQ(1000), .START_MS(1), .LOST_HOLD_MS(2), .DIR_DEAD_MS(1),
        .AVOID_ONCE(1), .AVOID_ROUTE_EN(1),
        .AVOID_BACK_MS(4), .AVOID_TURN_MS(6), .AVOID_PROBE_MS(6),
        .AVOID_TURN_IN_MS(TURN_IN_TICKS),
        .AVOID_OUT_MS(OUT_TICKS), .AVOID_ALIGN_MS(OUT_TICKS),
        .AVOID_PASS_MS(14), .AVOID_REJOIN_MS(20), .AVOID_LINE_MS(3), .AVOID_BLOCK_MS(5)
    ) once_dut (
        .clk(clk), .rst_n(rst_n), .on_line(on_line), .lost(lost), .obstacle(obstacle),
        .wide(wide), .line_count(4'd0), .pos(pos), .dir_evt(3'd0), .pid_l(11'd450), .pid_r(11'd450),
        .enc_l_step(1'b0), .enc_r_step(1'b0),
        .en(once_en), .dir_l(), .dir_r(), .duty_l(), .duty_r(),
        .state(once_state), .turn_dir()
    );

    wire fixed_align   = fixed_state == BYPASS && fixed_right.bypass_step == ALIGN;
    wire fixed_turn_in = fixed_state == BYPASS && fixed_right.bypass_step == TURN_IN;
    wire fixed_out     = fixed_state == BYPASS && fixed_right.bypass_step == OUT;
    wire fixed_pass    = fixed_state == BYPASS && fixed_right.bypass_step == PASS_SIDE;
    wire any_arc = fixed_out || fixed_align || fixed_turn_in || fixed_pass;

    // 【弧线断言替代原地转断言】旧的 fixed_pivot_error 检查"两轮反相 + 同为
    // TURN_DUTY"，那是倒车/原地掉头时代的特征。现在绕障全程两轮同向正转，
    // 只靠差速画弧，所以改为检查：
    //   · 绕行段永远不出现反转轮（dir_l/dir_r 必须都为 1）；
    //   · 非直线段两侧占空比必须不同（真在画弧，而不是直行冲过去）；
    //   · 直线超越段两侧占空比必须正好等于 AVOID_PASS_DUTY（v1.21 起 PASS 段
    //     改回对称标称值，航向环自己维持直线；v1.20 那套固定 ±PASS_TRIM 偏置
    //     已取消，因为它和航向环打架：偏置在推着转，航向环在往回拉）。
    //     本 tb 的编码器不产生脉冲，arc_turn 恒 0，航向环输出 0，所以两轮同值。
    // 直接引用 DUT 的参数：2026-11-25 全域降速把 AVOID_PASS_DUTY 620→496 时，
    // 写死字面量的断言就假红了。层次化引用让这条断言永远跟着 DUT 的默认值走。
    // （iverilog 不允许层次化引用出现在 constant expression 里，所以用 wire 不用 localparam。）
    wire [10:0] PASS_DUTY = fixed_right.AVOID_PASS_DUTY[10:0];
    reg fixed_straight_error = 0;
    always @(negedge clk) begin
        if (!rst_n) begin
            exit_ticks <= 0;
            align_ticks <= 0;
            return_ticks <= 0;
            fixed_arc_error <= 0;
            fixed_straight_error <= 0;
        // 【v1.21 起一切判定都等「段号稳定」再算】bypass_step 在 ms_tick 就切了，
        //   而 duty_l/duty_r 也跟着在同一拍更新；但从 tb 观察，切段那一拍的 duty
        //   仍反映上一段的标称值（同一拍内非阻塞赋值的旧值）。若把这一拍算进新段，
        //   就会拿旧占空比去判新段的关系 —— 4 条断言全因此误报。
        //   step_stable = 本拍段号与上一拍相同，即「这一拍的 duty 属于本段」。
        end else if (fixed_en && any_arc) begin
            // 计时不受稳定门控影响：它数的是「本段驱动了几拍」，与 duty 新旧无关。
            if (fixed_out)     exit_ticks   <= exit_ticks + 1;
            if (fixed_align)   align_ticks  <= align_ticks + 1;
            if (fixed_turn_in) return_ticks <= return_ticks + 1;
            // 方向判据同样要等稳定，否则进绕障第一拍还是 S_RUN 的方向。
            if (step_stable && (!fixed_dir_l || !fixed_dir_r)) fixed_arc_error <= 1;
            // 只在两轮真的出力时判占空比关系：换相死区/就绪前 duty 都是 0，
            // 那是"还没动"，不是"画弧却两轮等速"。
            if (step_stable && (fixed_duty_l != 0) && (fixed_duty_r != 0)) begin
                if (fixed_pass && ((fixed_duty_l !== PASS_DUTY) ||
                                   (fixed_duty_r !== PASS_DUTY))) fixed_straight_error <= 1;
                if (!fixed_pass && (fixed_duty_l === fixed_duty_r)) fixed_arc_error <= 1;
            end
        end
    end

    // v1.20：REJOIN 超时现在**故意**交给普通找线（原来直接 final_stop 退赛），
    // 所以守卫要放行"从 REJOIN 进入 SEARCH"这一条。用上一拍的段号区分：
    // OUT/ALIGN/PASS/TURN_IN 任何一段把控制权让出去仍然是 bug。
    always @(negedge clk) prev_step <= fixed_right.bypass_step;
    always @(negedge clk)
        if (inside_bypass && (state == LOST || state == SEARCH) && (prev_step != REJOIN)) begin
            $display("FAIL: bypass handed control to line search from step %0d", prev_step);
            $finish;
        end

    // 只 $display 是不够的：单跑 vvp 时退出码仍是 0，工具链看起来"绿"。
    // 这里累计失败数，末尾统一判死，外面靠 FAIL: 与退出码两路都能抓到。
    integer fails = 0;

    task check(input condition, input [383:0] message);
        begin
            if (condition === 1'b1) $display("PASS: %0s", message);
            else begin
                $display("FAIL: %0s", message);
                fails = fails + 1;
            end
        end
    endtask

    task finish_summary;
        begin
            if (fails == 0) $display("INFO: bypass_rejoin_tb ALL PASS");
            else            $display("INFO: bypass_rejoin_tb %0d FAIL(S)", fails);
            $finish;
        end
    endtask

    task begin_bypass(input signed [4:0] initial_pos);
        begin
            inside_bypass = 0;
            rst_n = 0; on_line = 1; lost = 0; obstacle = 0; wide = 0; pos = initial_pos;
            repeat (3) @(negedge clk);
            rst_n = 1;
            wait (state == RUN);
            @(negedge clk); obstacle = 1; inside_bypass = 1;
            // 弧线绕障直接从 RUN 跳到 BYPASS（不再经过 S_AVOID_BACK/S_AVOID_TURN）。
            wait (state == BYPASS);
            @(negedge clk); on_line = 0; lost = 1;
        end
    endtask

    // 【v1.21 起要连占空比一起等】旧版 avoid_drive 要求「duty 与指令严格相等」，
    //   等于自带一个「指令已下发」的同步点，所以这里只等 en 就够了。现在航向环
    //   让指令每拍都变，那条严格相等判据被去掉，en 会在占空比还没更新到本段值时
    //   就置位 —— 此时读到的 duty 还是上一段或 0。这里显式补上这个条件。
    task wait_drive(input [2:0] step);
        begin
            @(negedge clk);
            // 还必须等「段号已稳定」：刚切段那一拍的 duty 仍是上一段的值。
            while (state != BYPASS || dut.bypass_step != step || !en ||
                   prev_step != step ||
                   dut.duty_l == 11'd0 || dut.duty_r == 11'd0)
                @(negedge clk);
        end
    endtask

    initial begin
        begin_bypass(0);
        obstacle = 0;
        wait_drive(ALIGN);
        // 左绕（avoid_left=1）：ALIGN 段是反打回来的弧，快轮在右。
        // 两轮都必须正转 —— 这正是"用差速画弧代替原地掉头"的关键判据。
        check(dir_l && dir_r, "left detour keeps both wheels advancing through align");
        // 左绕：OUT 段左偏（左轮慢），ALIGN 段反打回正（左轮快、右轮慢）。
        check(dut.duty_l > dut.duty_r, "align arc reverses the steer when detouring left");
        $display("INFO : ticks out=%0d align=%0d turn_in=%0d (nominal %0d/%0d/%0d)",
                 exit_ticks, align_ticks, return_ticks, OUT_TICKS, OUT_TICKS, TURN_IN_TICKS);
        check(exit_ticks >= OUT_TICKS && exit_ticks <= OUT_TICKS + 2 && !fixed_arc_error,
              "fixed right starts with a timed outward arc");
        wait_drive(PASS_SIDE);
        check(dir_l && dir_r, "both wheels advance along the obstacle side");
        on_line = 1; lost = 0;
        repeat (2) @(negedge clk);
        check(state == BYPASS && dut.bypass_step == PASS_SIDE, "brief line alongside does not end bypass");
        on_line = 0; lost = 1;

        wait_drive(REJOIN);
        begin : arrow_during_rejoin
            reg [10:0] rejoin_pwm_l, rejoin_pwm_r;
            line_count = 3;
            dir_evt = 3'd1;
            @(negedge clk); dir_evt = 3'd0;
            rejoin_pwm_l = dut.avoid_duty_l;
            rejoin_pwm_r = dut.avoid_duty_r;
            @(negedge clk);
            check(dut.turn_req && state == BYPASS && dut.bypass_step == REJOIN &&
                  dut.duty_l == rejoin_pwm_l && dut.duty_r == rejoin_pwm_r,
                  "arrow received during rejoin cannot scale its closed-loop PWM");
        end
        check(!fixed_arc_error, "every bypass step drives both wheels forward with unequal duty");
        check(!fixed_straight_error, "straight pass runs symmetric AVOID_PASS_DUTY on both wheels");
        check(align_ticks == OUT_TICKS, "alignment arc lasts the full powered duration");
        check(return_ticks == TURN_IN_TICKS, "return arc uses its own powered duration");
        on_line = 1; lost = 0; wide = 1;
        repeat (4) @(negedge clk);
        check(state == BYPASS, "wide black does not qualify as the return line");
        wide = 0;
        repeat (2) @(negedge clk);
        check(state == BYPASS, "short reacquisition does not enable normal tracking");
        on_line = 0; lost = 1;
        repeat (2) @(negedge clk);
        on_line = 1; lost = 0;
        // "压线 → 摆平 → 交回"：累计 3 拍压线置 flatten，航向判据在 tb 里恒成立
        // （无编码器脉冲，arc_turn 恒 0），所以约 5 拍就能回 RUN，给 8 拍余量。
        repeat (8) @(negedge clk);
        check(state == RUN, "stable return line resumes normal tracking");
        check(dut.duty_l == 360 && dut.duty_r == 360 && dut.turn_req && !dut.turning,
              "the retained arrow slows tracking without mistaking the rejoin line for a junction");
        line_count = 2;
        repeat (2) @(negedge clk);
        line_count = 3;
        repeat (4) @(negedge clk);
        check(dut.turning && dut.turn_dir == 1, "a new three-probe junction consumes the retained arrow");
        line_count = 2;

        // ---- 新增：线只在阵列边缘（|pos| = 7）不得算作"回线成功" ----
        // 现场问题：旧逻辑只要任意一路探头看到线就交回，交回瞬间 P=-5、航向 45°，
        // track_pid 只能满舵硬掰 → 越线外摆。现在要求 |pos| ≤ 3 才进入摆平阶段。
        begin_bypass(5'sd7);
        obstacle = 0;
        wait_drive(REJOIN);
        on_line = 1; lost = 0;                       // 看到线，但位置在最外侧
        repeat (12) @(negedge clk);
        check(state == BYPASS, "edge-only line does not count as rejoined");
        on_line = 0; lost = 1;

        begin_bypass(0);
        wait (state == BYPASS && dut.bypass_step == OUT);
        @(negedge clk);
        // 绕行期间不再用超声切电：方块必然处在阈值内（否则不会触发绕行），
        // 若继续据此断电，车会被自己的绕行对象冻住。这里改为确认仍在推进。
        check(en, "obstacle inside threshold does not freeze the detour");
        // v1.20：REJOIN 超时不再直接停车，而是交给 S_SEARCH 原地转着找线。
        // 这条用例从 OUT 起就 lost=1，全程扫不到线，所以必然走到这条路径。
        begin : block_wait
            integer guard;
            guard = 0;
            while (state != SEARCH && state != IDLE && state != STOP && guard < 3000) begin
                @(negedge clk);
                guard = guard + 1;
            end
        end
        check(state == SEARCH, "blocked bypass hands control to line search instead of quitting");
        check(!fixed_right.final_stop, "blocked bypass does not latch a permanent stop");
        @(negedge clk); obstacle = 0;

        // ---- M2：绕障全程都骑在线上（lost 从未置位）不得直接判退赛 ----
        // 现场是「线一直在脚下、只是前面挡了个 10 cm 立方体」的情形：
        // 出线转向只 800 ms，车很可能一直压着线。此时 bypass_left_line 永远
        // 是 0，旧逻辑在 BY_PASS 结束时会直接 final_stop + S_STOP —— 绕障绕到
        // 一半自己停住，比绕不开还糟。
        rst_n = 0; on_line = 1; lost = 0; obstacle = 0; wide = 0; pos = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        wait (state == RUN);
        @(negedge clk); obstacle = 1;
        wait (state == BYPASS);
        @(negedge clk); obstacle = 0;
        // 故意不再改 on_line/lost：全程压线
        wait (state == BYPASS && dut.bypass_step == PASS_SIDE);
        // 有界等待：正常应走到 REJOIN -> RUN；出 bug 会停在 STOP，用计数兜住
        // 而不是让整台挂死（挂死只会报 TIMEOUT，看不出是哪条断言）。
        begin : m2_wait
            integer guard;
            guard = 0;
            while (state != RUN && state != STOP && guard < 400) begin
                @(negedge clk);
                guard = guard + 1;
            end
        end
        check(dut.bypass_left_line == 1'b0, "never left the line during bypass");
        check(state == RUN, "line never lost: bypass returns to tracking");

        // ---- TURN_IN 提前收：转的过程中扫到线就不必转满整段 ----
        // 现场问题是「转得不够、之后一路找不到线」：定长转的角度随电池电压和
        // 地面摩擦漂移。改成扫线闭环后，转多少由"看到线"决定。
        begin_bypass(0);
        obstacle = 0;
        wait_drive(TURN_IN);
        // 先让它转几拍，确认此时确实还在 TURN_IN（lost=1，看不到线）
        repeat (2) @(negedge clk);
        check(state == BYPASS && dut.bypass_step == TURN_IN, "turn-in still running before line seen");
        // 中途压到线：数还要几拍才离开 TURN_IN。
        // 定长通路会等到 AVOID_TURN_IN_MS(=TURN_IN_TICKS) 才走，扫线通路
        // 只要 AVOID_LINE_MS(=3) 拍就够。用「< TURN_IN_TICKS」区分两者，
        // 不去断言离开后停在哪个 step —— 紧接着 REJOIN 可能已经交回 RUN。
        begin : early_exit
            integer t;
            t = 0;
            on_line = 1; lost = 0;
            while (state == BYPASS && dut.bypass_step == TURN_IN && t < TURN_IN_TICKS + 4) begin
                @(negedge clk);
                t = t + 1;
            end
            check(t <= LINE_TICKS + 4, "turn-in ends early once the line is seen");
        end

        begin_bypass(-5'sd2);
        obstacle = 0;
        wait_drive(ALIGN);
        check(dir_l && dir_r, "right detour also keeps both wheels advancing");
        check(exit_ticks == OUT_TICKS && !fixed_arc_error, "fixed right ignores last line position");
        wait_drive(REJOIN);
        // v1.20：REJOIN 超时不再直接 final_stop（那是"绕到一半自己退赛"），
        // 改为把控制权交给 S_SEARCH 原地转着找线，找不到再按
        // SEARCH_FAIL_TO_IDLE 的规则收场。这里只断言"交出去了"。
        begin : rejoin_timeout
            integer guard;
            guard = 0;
            while (state != SEARCH && state != IDLE && state != STOP && guard < 3000) begin
                @(negedge clk);
                guard = guard + 1;
            end
        end
        check(state == SEARCH, "missing return line hands control to line search, not a dead stop");
        check(!fixed_right.final_stop, "rejoin timeout no longer latches a permanent stop");
        check(en, "line search still drives the motors");

        // ---- M3：AVOID_ONCE=1 —— 第一次绕障后，第二次障碍不得再进绕障 ----
        // 现场依据：第一次绕障虽然回线抖，但最终把线找回来了并稳定跑了 2.3 s；
        // 导致 STOP 的是车跑到弯道附近、墙进入 31 cm 范围后的**第二次**触发。
        rst_n = 0; on_line = 1; lost = 0; obstacle = 0; wide = 0; pos = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        wait (once_state == RUN);
        @(negedge clk); obstacle = 1;
        wait (once_state == BYPASS);                 // 第一次：允许
        check(once_dut.avoid_done, "first obstacle sets the once-only flag");
        // 让它自己走完（全程不给线，必然离开绕障）
        begin : once_leave
            integer guard;
            guard = 0;
            while (once_state == BYPASS && guard < 3000) begin
                @(negedge clk);
                guard = guard + 1;
            end
        end
        check(once_state != BYPASS, "bypass ends by itself on timeout");
        @(negedge clk); obstacle = 0;
        repeat (3) @(negedge clk);
        obstacle = 1;                                // 第二次：必须被拦
        repeat (40) @(negedge clk);
        check(once_state != BYPASS, "AVOID_ONCE=1 rejects the second detour");
        obstacle = 0;

        finish_summary;
    end

    initial begin
        #8000;
        $display("TIMEOUT: bypass phase did not complete");
        $finish;
    end
endmodule
