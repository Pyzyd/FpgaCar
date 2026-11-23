// =============================================================================
// duty_shaper_floor_tb.v —— 地板与斜率限制（MIN_DUTY / SLEW_STEP 打开时）
//   5) MIN_DUTY=120：非零小值抬到 120，0 仍为 0
//   6) SLEW_STEP 生效：每 ms 变化量不超过 STEP，最终仍收敛到目标
// =============================================================================
`timescale 1ns/1ps

module duty_shaper_floor_tb;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20.8335 clk = ~clk;

    reg        en = 1'b1;
    reg        follow = 1'b0;     // 关掉差速缩放，单独看地板
    reg [10:0] dl_in = 11'd0, dr_in = 11'd0;
    wire [10:0] dl_out, dr_out;

    duty_shaper #(
        .CLK_FREQ   (48_000),
        .DUTY_MAX   (1200),
        .DIFF_SHIFT (0),          // 不缩放
        .MIN_DUTY   (120),
        .SLEW_STEP  (0)
    ) u_floor (
        .clk (clk), .rst_n (rst_n), .en (en), .follow (follow),
        .duty_l_in (dl_in), .duty_r_in (dr_in),
        .duty_l_out (dl_out), .duty_r_out (dr_out)
    );

    reg [10:0] dl2, dr2;
    duty_shaper #(
        .CLK_FREQ   (48_000),
        .DUTY_MAX   (1200),
        .DIFF_SHIFT (0),
        .MIN_DUTY   (0),
        .SLEW_STEP  (40)
    ) u_slew (
        .clk (clk), .rst_n (rst_n), .en (en), .follow (follow),
        .duty_l_in (dl_in), .duty_r_in (dr_in),
        .duty_l_out (dl2), .duty_r_out (dr2)
    );

    task wait_ms (input integer n);
        begin
            repeat (n * 48) @(posedge clk);
            #1;
        end
    endtask

    integer i;
    reg [10:0] prev2;
    reg slew_ok;

    initial begin
        #200 rst_n = 1'b1;

        // ---- 5) 地板：小非零值抬起 ----
        dl_in = 11'd30; dr_in = 11'd0;
        wait_ms(3);
        if (dl_out == 11'd120 && dr_out == 11'd0)
            $display("PASS: floor 30 -> %0d, and 0 stays 0", dl_out);
        else
            $display("FAIL: floor 30/0 -> %0d/%0d (expect 120/0)", dl_out, dr_out);

        // ---- 6) 斜率限制：单拍变化 <= 40，且能爬到位 ----
        dl_in = 11'd1000; dr_in = 11'd0;
        prev2 = dl2;
        slew_ok = 1'b1;
        for (i = 0; i < 40; i = i + 1) begin
            wait_ms(1);
            if (dl2 > prev2 + 11'd40) slew_ok = 1'b0;
            prev2 = dl2;
        end
        if (slew_ok && dl2 == 11'd1000)
            $display("PASS: slew limited (<=40/ms) and reached 1000");
        else
            $display("FAIL: slew_ok=%0d dl2=%0d (expect reach 1000, no step > 40)", slew_ok, dl2);

        $display("INFO: duty_shaper_floor_tb done");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TIMEOUT: duty_shaper_floor_tb hung");
        $finish;
    end

endmodule
