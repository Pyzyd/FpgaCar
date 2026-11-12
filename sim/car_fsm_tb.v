// =============================================================================
// car_fsm_tb.v —— 整车状态机自测
// 参数全部缩到 1~2 ms。验收点：
//   1) 复位后 IDLE，en=0（电机不转，安全）
//   2) START_MS 后进 RUN，en=1，两轮正转，duty 直接跟 pid
//   3) 丢线 → LOST（保持 duty），保持超时 → SEARCH（原地转，方向按最后线位）
//   4) 重新压线 → 回 RUN
//   5) 障碍 → STOP 且 en=0；障碍消失 → 自动恢复 RUN
//   6) 找线超时 → STOP 且永久保持（obstacle 清零也不恢复）
//
// 注意：每个 check 的字符串不能超过 31 字符（Verilog 任务端口位宽会截断，只留尾部）。
// =============================================================================
`timescale 1ns/1ps

module car_fsm_tb;

    localparam [2:0] S_IDLE = 3'd0, S_RUN = 3'd1, S_LOST = 3'd2,
                     S_SEARCH = 3'd3, S_STOP = 3'd4;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20.8335 clk = ~clk;

    reg               on_line = 1'b1;      // 一开始就压线（否则上电即触发丢线流程）
    reg               lost = 1'b0;
    reg               obstacle = 1'b0;
    reg signed [4:0]  pos = 5'sd0;
    reg [10:0]        pid_l = 11'd700;
    reg [10:0]        pid_r = 11'd500;

    wire              en;
    wire              dir_l, dir_r;
    wire [10:0]       duty_l, duty_r;
    wire [2:0]        state;

    car_fsm #(
        .CLK_FREQ     (24_000_000),
        .START_MS     (1),
        .LOST_HOLD_MS (1),
        .SEARCH_MS    (10),                    // 拉长到 10 ms，留出观察 SEARCH 的时间窗
        .SEARCH_DUTY  (500),
        .DIR_DEAD_MS  (1)
    ) u_dut (
        .clk (clk), .rst_n (rst_n),
        .on_line (on_line), .lost (lost), .obstacle (obstacle), .pos (pos),
        .pid_l (pid_l), .pid_r (pid_r),
        .en (en), .dir_l (dir_l), .dir_r (dir_r),
        .duty_l (duty_l), .duty_r (duty_r), .state (state)
    );

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

    initial begin
        #300 rst_n = 1'b1;
        wait_us(100);                      // 0.1 ms：还没到 START_MS

        // ---- 1) IDLE ----
        chk(state == S_IDLE && en === 1'b0, "IDLE, motor off");

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

        if (fails == 0) $display("INFO: car_fsm_tb ALL PASS");
        else            $display("INFO: car_fsm_tb %0d FAIL(S)", fails);
        $finish;
    end

    initial begin
        #200_000_000;                      // 200 ms：整个用例约 30 ms
        $display("TIMEOUT: car_fsm_tb hung (state=%0d)", state);
        $finish;
    end

endmodule
