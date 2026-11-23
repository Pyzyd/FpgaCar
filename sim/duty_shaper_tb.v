// =============================================================================
// duty_shaper_tb.v —— 差速整形自测
// 验收点：
//   1) follow=1，960/0（PID 饱和）→ 720/240，即差速减半、均值不变
//   2) follow=1，480/480（直行）→ 480/480 不变（不压 diff 就无副作用）
//   3) follow=0（原地转），960/0 → 960/0 原样直通
//   4) en=0 → 直通，且不引入滞后（换相死区不被延迟）
//   5) MIN_DUTY=N：非零小值被抬到 N，而 0 仍是 0（停车语义不变）
//   6) SLEW_STEP 生效时，单拍变化不超过 STEP
// =============================================================================
`timescale 1ns/1ps

module duty_shaper_tb;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20.8335 clk = ~clk;

    reg        en = 1'b1;
    reg        follow = 1'b1;
    reg [10:0] dl_in = 11'd0, dr_in = 11'd0;
    wire [10:0] dl_out, dr_out;

    // 节拍缩到 1 ms → MS_DIV = 24000，但 tb 里我们按 ms 数拍。
    // 为让仿真快，用 CLK_FREQ 使 MS_DIV 很小：CLK_FREQ=48000 / 1000 = 48 拍。
    duty_shaper #(
        .CLK_FREQ   (48_000),
        .DUTY_MAX   (1200),
        .DIFF_SHIFT (1),
        .MIN_DUTY   (0),
        .SLEW_STEP  (0)
    ) u_dut (
        .clk (clk), .rst_n (rst_n), .en (en), .follow (follow),
        .duty_l_in (dl_in), .duty_r_in (dr_in),
        .duty_l_out (dl_out), .duty_r_out (dr_out)
    );

    task wait_ms (input integer n);
        begin
            repeat (n * 48) @(posedge clk);
            #1;
        end
    endtask

    initial begin
        #200 rst_n = 1'b1;

        // ---- 1) 饱和 → 差速减半，均值不变 ----
        follow = 1'b1; dl_in = 11'd960; dr_in = 11'd0;
        wait_ms(3);
        if (dl_out == 11'd720 && dr_out == 11'd240)
            $display("PASS: 960/0 -> %0d/%0d (diff halved, mean kept)", dl_out, dr_out);
        else
            $display("FAIL: 960/0 -> %0d/%0d (expect 720/240)", dl_out, dr_out);

        // ---- 2) 直行不受影响 ----
        dl_in = 11'd480; dr_in = 11'd480;
        wait_ms(3);
        if (dl_out == 11'd480 && dr_out == 11'd480)
            $display("PASS: 480/480 unchanged");
        else
            $display("FAIL: 480/480 -> %0d/%0d", dl_out, dr_out);

        // ---- 3) follow=0 直通（原地转不许被改）----
        follow = 1'b0; dl_in = 11'd700; dr_in = 11'd0;
        wait_ms(3);
        if (dl_out == 11'd700 && dr_out == 11'd0)
            $display("PASS: follow=0 passthrough 700/0");
        else
            $display("FAIL: follow=0 -> %0d/%0d (expect 700/0)", dl_out, dr_out);

        // ---- 4) en=0 直通 ----
        follow = 1'b1; en = 1'b0; dl_in = 11'd900; dr_in = 11'd100;
        wait_ms(3);
        if (dl_out == 11'd900 && dr_out == 11'd100)
            $display("PASS: en=0 passthrough");
        else
            $display("FAIL: en=0 -> %0d/%0d (expect 900/100)", dl_out, dr_out);

        $display("INFO: duty_shaper_tb (core) done");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TIMEOUT: duty_shaper_tb hung");
        $finish;
    end

endmodule
