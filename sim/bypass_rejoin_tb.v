`timescale 1ns/1ns

module bypass_rejoin_tb;
    localparam [2:0] RUN = 1, LOST = 2, SEARCH = 3, STOP = 4, TURN = 6, BYPASS = 7;
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
    wire [2:0] state;
    wire en, dir_l, dir_r;
    wire [2:0] fixed_state;
    wire fixed_en, fixed_dir_l, fixed_dir_r;
    wire [10:0] fixed_duty_l, fixed_duty_r;
    integer exit_ticks = 0, align_ticks = 0, return_ticks = 0;
    reg fixed_arc_error = 0;
    reg inside_bypass = 0;

    car_fsm #(
        .CLK_FREQ(1000), .START_MS(1), .LOST_HOLD_MS(2), .DIR_DEAD_MS(1),
        .AVOID_ROUTE_EN(1), .AVOID_BACK_MS(4), .AVOID_TURN_MS(6), .AVOID_PROBE_MS(6),
        .AVOID_TURN_IN_MS(TURN_IN_TICKS),
        .AVOID_OUT_MS(OUT_TICKS), .AVOID_ALIGN_MS(OUT_TICKS),
        .AVOID_PASS_MS(14), .AVOID_REJOIN_MS(20), .AVOID_LINE_MS(3), .AVOID_BLOCK_MS(5)
    ) dut (
        .clk(clk), .rst_n(rst_n), .on_line(on_line), .lost(lost), .obstacle(obstacle),
        .wide(wide), .pos(pos), .dir_evt(3'd0), .pid_l(11'd450), .pid_r(11'd450), .enc_l_step(1'b0), .enc_r_step(1'b0),
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
        .wide(wide), .pos(pos), .dir_evt(3'd0), .pid_l(11'd450), .pid_r(11'd450), .enc_l_step(1'b0), .enc_r_step(1'b0),
        .en(fixed_en), .dir_l(fixed_dir_l), .dir_r(fixed_dir_r),
        .duty_l(fixed_duty_l), .duty_r(fixed_duty_r), .state(fixed_state), .turn_dir()
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
    //   · 直线超越段两轮占空比相同。
    reg fixed_straight_error = 0;
    always @(negedge clk) begin
        if (!rst_n) begin
            exit_ticks <= 0;
            align_ticks <= 0;
            return_ticks <= 0;
            fixed_arc_error <= 0;
            fixed_straight_error <= 0;
        end else if (fixed_en && any_arc) begin
            if (fixed_out)     exit_ticks   <= exit_ticks + 1;
            if (fixed_align)   align_ticks  <= align_ticks + 1;
            if (fixed_turn_in) return_ticks <= return_ticks + 1;
            // 只在两轮真的出力时判占空比关系：换相死区/就绪前 duty 都是 0，
            // 那是"还没动"，不是"画弧却两轮等速"。
            if (!fixed_dir_l || !fixed_dir_r) fixed_arc_error <= 1;
            if ((fixed_duty_l != 0) && (fixed_duty_r != 0)) begin
                if (fixed_pass && (fixed_duty_l !== fixed_duty_r)) fixed_straight_error <= 1;
                if (!fixed_pass && (fixed_duty_l === fixed_duty_r)) fixed_arc_error <= 1;
            end
        end
    end

    always @(negedge clk)
        if (inside_bypass && (state == LOST || state == SEARCH)) begin
            $display("FAIL: bypass handed control to ordinary line search");
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

    task wait_drive(input [2:0] step);
        begin
            @(negedge clk);
            while (state != BYPASS || dut.bypass_step != step || !en)
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
        check(exit_ticks == OUT_TICKS && !fixed_arc_error, "fixed right starts with a timed outward arc");
        wait_drive(PASS_SIDE);
        check(dir_l && dir_r, "both wheels advance along the obstacle side");
        on_line = 1; lost = 0;
        repeat (2) @(negedge clk);
        check(state == BYPASS && dut.bypass_step == PASS_SIDE, "brief line alongside does not end bypass");
        on_line = 0; lost = 1;

        wait_drive(REJOIN);
        check(!fixed_arc_error, "every bypass step drives both wheels forward with unequal duty");
        check(!fixed_straight_error, "straight pass keeps both wheels at equal duty");
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
        repeat (4) @(negedge clk);
        check(state == RUN, "stable return line resumes normal tracking");

        begin_bypass(0);
        wait (state == BYPASS && dut.bypass_step == OUT);
        @(negedge clk);
        // 绕行期间不再用超声切电：方块必然处在阈值内（否则不会触发绕行），
        // 若继续据此断电，车会被自己的绕行对象冻住。这里改为确认仍在推进。
        check(en, "obstacle inside threshold does not freeze the detour");
        wait (state == STOP);
        @(negedge clk); obstacle = 0;
        repeat (5) @(negedge clk);
        check(state == STOP && !en, "persistent blockage latches stop without repeated attempts");

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
        wait (state == STOP);
        @(negedge clk);
        check(!en, "missing return line times out and stays stopped");
        finish_summary;
    end

    initial begin
        #8000;
        $display("TIMEOUT: bypass phase did not complete");
        $finish;
    end
endmodule
