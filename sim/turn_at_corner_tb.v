`timescale 1ns/1ns

module turn_at_corner_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, on_line = 1, lost = 0, wide = 0;
    reg [2:0] dir_evt = 0;
    wire dir_l, dir_r;
    wire [1:0] turn_dir;

    car_fsm #(
        .CLK_FREQ(10000), .START_MS(2), .TURN_WAIT_FOR_CORNER(1),
        .TURN_REQUEST_MS(35), .TURN_MS(8), .DIR_DEAD_MS(1),
        .CORNER_WIDE_MS(15), .DEFAULT_TURN_LEFT(0), .LOST_HOLD_MS(5)
    ) dut (
        .clk(clk), .rst_n(rst_n), .on_line(on_line), .lost(lost),
        .wide(wide), .obstacle(1'b0), .pos(5'sd1), .dir_evt(dir_evt),
        .pid_l(11'd300), .pid_r(11'd300), .enc_l_step(1'b0), .enc_r_step(1'b0), .en(), .dir_l(dir_l),
        .dir_r(dir_r), .duty_l(), .duty_r(), .state(), .turn_dir(turn_dir)
    );

    // 第二个实例：DEFAULT_TURN_LEFT=1（打开拐角兜底），专门守 H1 ——
    // 牌驱动的找线旋转期间，车体自己扫出的宽黑不得把 corner_cnt 重新填满，
    // 否则下一次丢线时兜底会强制左转，把牌要求的右转反着执行。
    reg on_line2 = 1, lost2 = 0, wide2 = 0;
    reg [2:0] dir_evt2 = 0;
    wire dir_l2, dir_r2;
    wire [1:0] turn_dir2;

    car_fsm #(
        .CLK_FREQ(10000), .START_MS(2), .TURN_WAIT_FOR_CORNER(1),
        .TURN_REQUEST_MS(35), .TURN_MS(8), .DIR_DEAD_MS(1),
        .CORNER_WIDE_MS(15), .DEFAULT_TURN_LEFT(1), .LOST_HOLD_MS(5),
        .SEARCH_MS(20), .AVOID_EN(0)
    ) dut2 (
        .clk(clk), .rst_n(rst_n), .on_line(on_line2), .lost(lost2),
        .wide(wide2), .obstacle(1'b0), .pos(5'sd1), .dir_evt(dir_evt2),
        .pid_l(11'd300), .pid_r(11'd300), .enc_l_step(1'b0), .enc_r_step(1'b0), .en(), .dir_l(dir_l2),
        .dir_r(dir_r2), .duty_l(), .duty_r(), .state(), .turn_dir(turn_dir2)
    );

    task arrow2;
        input [2:0] value;
        begin
            dir_evt2 = value;
            @(negedge clk);
            dir_evt2 = 0;
        end
    endtask

    task tick;
        input integer ms;
        repeat (ms * 10) @(negedge clk);
    endtask

    task arrow;
        input [2:0] value;
        begin
            dir_evt = value;
            @(negedge clk);
            dir_evt = 0;
        end
    endtask

    initial begin
        tick(1);
        rst_n = 1;
        tick(4);
        arrow(1);
        tick(6);
        if (turn_dir != 0 || !dir_l || !dir_r) $fatal(1, "FAIL: early arrow steered on straight line");

        wide = 1;
        tick(3);
        if (turn_dir != 0 || !dir_l || !dir_r) $fatal(1, "FAIL: wide-only signal steered");
        wide = 0;
        on_line = 0;
        lost = 1;
        tick(4);
        if (turn_dir != 1 || dir_l || !dir_r) $fatal(1, "FAIL: latched left arrow was not used at corner");

        arrow(2);
        tick(1);
        if (turn_dir != 1 || dir_l || !dir_r) $fatal(1, "FAIL: second message interrupted active turn");
        $display("PASS: direction is latched, waits for corner, and stays fixed while turning");

        rst_n = 0;
        on_line = 1;
        lost = 0;
        tick(1);
        rst_n = 1;
        tick(4);
        arrow(1);
        tick(40);
        wide = 1;
        tick(3);
        wide = 0;
        on_line = 0;
        lost = 1;
        tick(8);
        if (!dir_l || dir_r || turn_dir != 2) $fatal(1, "FAIL: expired arrow overrode normal line search");
        $display("PASS: expired arrow does not affect line search");

        // ---- H1 回归：牌驱动转向后，找线期间自激宽黑不得改写牌的方向 ----
        rst_n = 0; tick(1); rst_n = 1; tick(4);
        arrow2(2);                          // 右转牌，等拐角
        tick(3);
        wide2 = 1; tick(3); wide2 = 0;      // 拐角宽黑
        on_line2 = 0; lost2 = 1; tick(8);   // 丢线 -> 消费牌 -> 右转找线
        if (!(dir_l2 === 1'b1 && dir_r2 === 1'b0 && turn_dir2 == 2'd2))
            $fatal(1, "FAIL: right card not honoured at corner");
        wide2 = 1; tick(3); wide2 = 0;      // 原地转时车体扫过线 = 自激宽黑
        on_line2 = 1; lost2 = 0; tick(6);   // 重新压线回 RUN
        on_line2 = 0; lost2 = 1; tick(8);   // 再次丢线：必须仍按牌右转
        if (!(dir_l2 === 1'b1 && dir_r2 === 1'b0 && turn_dir2 == 2'd2))
            $fatal(1, "FAIL: corner fallback overrode the right card");
        $display("PASS: self-induced wide during search cannot flip a card turn (H1)");
        $finish;
    end
endmodule
