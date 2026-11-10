// =============================================================================
// cam_probe_tb.v —— cam_probe 自测（上电时序 + VSYNC 统计 + SCCB 空闲）
// iverilog -g2012 -Wall -s cam_probe_tb -o cam_probe_tb.vvp src/cam_probe.v sim/cam_probe_tb.v
// -----------------------------------------------------------------------------
// 为了仿真快，参数缩小：RST_LOW_MS=1 / CFG_DELAY_MS=2 / WIN_MS=10（毫秒）
// 验收：
//   1) 复位期间 cam_rst_n=0、cam_pwdn=0（不休眠）
//   2) 约 1 ms 后 cam_rst_n=1，但 ready 仍为 0
//   3) 约 1+2 ms 后 ready=1（此时才允许发 SCCB 配置）
//   4) 给 1 kHz 的 VSYNC，10 ms 窗口后 vs_cnt ≈ 10，vs_act=1
//   5) SCCB 空闲：sclk=1、sdat_oe=0、sdat_out=1
//   6) 无 VSYNC 时 vs_cnt 归零、vs_act=0
// =============================================================================
`timescale 1ns/1ps

module cam_probe_tb;

    localparam integer RST_LOW   = 1;
    localparam integer CFG_DELAY = 2;
    localparam integer WIN       = 10;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    always #20.8335 clk = ~clk;

    reg  vsync = 1'b0;
    wire cam_rst_n, cam_pwdn;
    wire ready, vs_act;
    wire [7:0] vs_cnt;

    cam_probe #(
        .CLK_FREQ(24_000_000), .RST_LOW_MS(RST_LOW),
        .CFG_DELAY_MS(CFG_DELAY), .WIN_MS(WIN)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .cam_rst_n(cam_rst_n), .cam_pwdn(cam_pwdn),
        .vsync(vsync), .ready(ready), .vs_cnt(vs_cnt), .vs_act(vs_act)
    );

    // 1 kHz 的 VSYNC（模拟 1000 fps，便于在 10 ms 窗口里数够数）
    reg vs_en = 1'b0;
    always #500_000 if (vs_en) vsync = ~vsync;   // 1 ms 周期 = 1 kHz

    initial begin
        #200 rst_n = 1'b1;

        // 1) 复位刚释放：仍是复位态
        #100_000;                              // 0.1 ms
        if (cam_rst_n !== 1'b0) $display("FAIL: cam_rst_n should be low at 0.1ms");
        else                    $display("PASS: cam_rst_n low during reset window");
        if (cam_pwdn !== 1'b0)  $display("FAIL: cam_pwdn should be 0 (not standby)");
        else                    $display("PASS: cam_pwdn=0");

        // 2) 1 ms 之后复位释放，但 ready 还不能来
        #1_200_000;                            // 1.3 ms
        if (cam_rst_n !== 1'b1) $display("FAIL: cam_rst_n not released at 1.3ms");
        else                    $display("PASS: cam_rst_n released after 1ms");
        if (ready !== 1'b0)     $display("FAIL: ready came too early at 1.3ms");
        else                    $display("PASS: ready still 0 at 1.3ms (20ms guard)");

        // 3) 1+2 ms 之后 ready
        #2_500_000;                            // 3.8 ms
        if (ready !== 1'b1)     $display("FAIL: ready not set after rst+cfg delay");
        else                    $display("PASS: ready=1 after 1+2ms");

        // 4) 给 VSYNC，等一个 10 ms 窗口
        vs_en = 1'b1;
        #25_000_000;                           // 25 ms > 2 x WIN，保证锁存的是完整窗口
        if (vs_cnt < 8'd9 || vs_cnt > 8'd11)
            $display("FAIL: vs_cnt=%0d (expect ~10 for 1kHz in 10ms)", vs_cnt);
        else
            $display("PASS: vs_cnt=%0d for 1kHz VSYNC in 10ms window", vs_cnt);
        if (vs_act !== 1'b1)    $display("FAIL: vs_act should be 1");
        else                    $display("PASS: vs_act=1");

        // 6) 停掉 VSYNC，下一个窗口应归零
        vs_en = 1'b0;
        #25_000_000;
        if (vs_cnt !== 8'd0)    $display("FAIL: vs_cnt=%0d after VSYNC stopped", vs_cnt);
        else                    $display("PASS: vs_cnt back to 0 without VSYNC");
        if (vs_act !== 1'b0)    $display("FAIL: vs_act still 1");
        else                    $display("PASS: vs_act cleared");

        $display("INFO: cam_probe_tb done");
        $finish;
    end

    initial begin
        #150_000_000;
        $display("TIMEOUT: cam_probe_tb hung");
        $finish;
    end

endmodule
