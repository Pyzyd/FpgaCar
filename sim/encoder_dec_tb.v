// =============================================================================
// encoder_dec_tb.v —— encoder_dec 自测
// iverilog -g2012 -Wall -s encoder_dec_tb -o encoder_dec_tb.vvp src/encoder_dec.v sim/encoder_dec_tb.v && vvp encoder_dec_tb.vvp
// -----------------------------------------------------------------------------
// 4 倍频语义：每个格雷码跳变沿 = 1 个 count，一圈 N 线 = 4N counts。
// 本 tb 用"任务"计数：fwd_step 每次翻转 A、B 各一次 = 2 counts。
// 方向约定（与 RTL 查表一致）：B 相先翻 = 正转 +，A 相先翻 = 反转 -。
// 验收：1) fwd100 任务 → +200，且每个 count 有 1 个 step 脉冲，direction=1
//       2) 再 rev40 任务 → +120，direction=0
//       3) AB 同时翻（跳两相毛刺）被忽略，step 不产生
//       4) 复位清零
// =============================================================================
`timescale 1ns/1ns

module encoder_dec_tb;
    reg clk = 0, rst_n = 0;
    reg a = 0, b = 0;
    wire [31:0] position;
    wire        step;
    wire        direction;

    encoder_dec u_dut (
        .clk(clk), .rst_n(rst_n), .a(a), .b(b),
        .step(step), .direction(direction), .position(position)
    );

    always #21 clk = ~clk;   // ~24 MHz

    // 统计 step 脉冲个数（每个 count 应恰好 1 个）
    integer step_cnt = 0;
    always @(posedge clk) if (rst_n && step) step_cnt = step_cnt + 1;

    // 正转一格任务：B 先翻（+1 count），A 后翻（+1 count）→ 共 +2 counts
    task fwd_step;
        begin
            b = ~b; repeat (2) @(posedge clk);
            a = ~a; repeat (2) @(posedge clk);
        end
    endtask

    // 反转一格任务：A 先翻（-1），B 后翻（-1）→ 共 -2 counts
    task rev_step;
        begin
            a = ~a; repeat (2) @(posedge clk);
            b = ~b; repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        #100 rst_n = 1;
        #200;

        // 1) 正转 100 任务 = +200 counts
        repeat (100) fwd_step();
        repeat (3) @(posedge clk); #1;
        if (position !== 32'd200) $display("FAIL: fwd100 tasks, position=%0d (expect 200)", position);
        else                      $display("PASS: fwd100 tasks -> position=%0d", position);
        if (step_cnt !== 200)     $display("FAIL: fwd100 step pulses=%0d (expect 200)", step_cnt);
        else                      $display("PASS: fwd100 step pulses=%0d", step_cnt);
        if (direction !== 1'b1)   $display("FAIL: fwd100 direction=%b (expect 1)", direction);
        else                      $display("PASS: fwd100 direction=1");

        // 2) 反转 40 任务 = -80 counts → 120
        step_cnt = 0;
        repeat (40) rev_step();
        repeat (3) @(posedge clk); #1;
        if (position !== 32'd120) $display("FAIL: +rev40, position=%0d (expect 120)", position);
        else                      $display("PASS: fwd100-rev40 -> position=%0d", position);
        if (step_cnt !== 80)      $display("FAIL: rev40 step pulses=%0d (expect 80)", step_cnt);
        else                      $display("PASS: rev40 step pulses=%0d", step_cnt);
        if (direction !== 1'b0)   $display("FAIL: rev40 direction=%b (expect 0)", direction);
        else                      $display("PASS: rev40 direction=0");

        // 3) 毛刺：AB 同时翻转（跳两相）应被忽略，来回各一次
        step_cnt = 0;
        a = ~a; b = ~b; repeat (3) @(posedge clk); #1;
        a = ~a; b = ~b; repeat (3) @(posedge clk); #1;
        if (position !== 32'd120) $display("FAIL: glitch changed position=%0d (expect 120)", position);
        else                      $display("PASS: double-toggle glitch ignored");
        if (step_cnt !== 0)       $display("FAIL: glitch produced %0d step pulses", step_cnt);
        else                      $display("PASS: glitch produced no step pulse");

        // 4) 复位清零
        rst_n = 0; #100; rst_n = 1;
        #200;
        if (position !== 32'd0) $display("FAIL: reset position=%0d", position);
        else                    $display("PASS: reset clears position");

        $display("INFO: encoder_dec_tb done");
        $finish;
    end
endmodule
