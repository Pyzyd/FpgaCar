// =============================================================================
// cam_sccb_cfg_tb.v —— cam_sccb_cfg 自测（LUT + SCCB 引擎跑完 252 条）
// iverilog -g2012 -Wall -s cam_sccb_cfg_tb -o cam_sccb_cfg_tb.vvp \
//   src/cam_sccb_cfg.v src/i2c_timing_ctrl_16bit.v src/I2C_OV5640_1280720_Config.v \
//   sim/cam_sccb_cfg_tb.v && vvp cam_sccb_cfg_tb.vvp
// -----------------------------------------------------------------------------
// 说明：这是"能不能把寄存器表发完"的通路测试，不模拟 OV5640 的应答细节。
//   sdat_in 固定为 1（无应答），因为官方引擎不检查 ACK，照样会走完 252 条。
//   真正的应答/寄存器读写要在板上用 V= / C= 判断。
// 为了仿真快，I2C_FREQ 参数放大 10 倍（2.4 MHz），实际工程用 100 kHz。
// 验收：
//   1) start=0 时引擎被按在复位，sclk 不翻转
//   2) start=1 后 sclk 出现大量脉冲（>1000 个上升沿）
//   3) 最终 done=1（252 条写完）
//   4) 写完后 sclk 回到空闲高
// =============================================================================
`timescale 1ns/1ps

module cam_sccb_cfg_tb;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    reg  start = 1'b0;
    always #20.8335 clk = ~clk;

    wire sclk, sdat_out, sdat_oe;
    wire done;
    reg  sdat_in = 1'b1;

    cam_sccb_cfg #(
        .CLK_FREQ(24_000_000),
        .I2C_FREQ(2_400_000),      // 10x 加速，仅仿真用
        .DEV_ADDR(8'h78)
    ) u_dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .sclk(sclk), .sdat_in(sdat_in), .sdat_out(sdat_out), .sdat_oe(sdat_oe),
        .done(done)
    );

    integer sclk_edges = 0;
    always @(posedge sclk) sclk_edges = sclk_edges + 1;

    initial begin
        #200 rst_n = 1'b1;

        // 1) start=0：引擎在复位，不应有 SCLK
        #2_000_000;                       // 2 ms
        if (sclk_edges > 2) $display("FAIL: sclk toggling before start (%0d edges)", sclk_edges);
        else                $display("PASS: engine held in reset before start");
        if (done !== 1'b0)  $display("FAIL: done set before start");
        else                $display("PASS: done=0 before start");

        // 2) start=1：等引擎跑完 252 条
        start = 1'b1;
        wait (done === 1'b1);
        #100_000;

        if (done !== 1'b1)        $display("FAIL: done never asserted");
        else                      $display("PASS: done=1 (LUT walked)");
        if (sclk_edges < 1000)    $display("FAIL: too few SCLK edges (%0d)", sclk_edges);
        else                      $display("PASS: SCLK edges = %0d", sclk_edges);
        if (sclk !== 1'b1)        $display("FAIL: sclk not idle high after done");
        else                      $display("PASS: sclk idle high after config");

        $display("INFO: cam_sccb_cfg_tb done at %0t", $time);
        $finish;
    end

    initial begin
        #400_000_000;                     // 400 ms 看门狗
        $display("TIMEOUT: cam_sccb_cfg_tb hung (done=%b edges=%0d)", done, sclk_edges);
        $finish;
    end

endmodule
