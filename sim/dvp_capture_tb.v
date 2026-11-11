// =============================================================================
// dvp_capture_tb.v —— dvp_capture 自测（造 DVP 时序，验证 W/H/帧数）
// iverilog -g2012 -Wall -s dvp_capture_tb -o dvp_capture_tb.vvp src/dvp_capture.v sim/dvp_capture_tb.v
// -----------------------------------------------------------------------------
// 造的时序（参数缩小以便快速仿真）：
//   pclk 42 MHz，每帧 NPIX=5 个像素/行（HREF 高 5 拍），NLINE=4 行，
//   VSYNC 在帧之间给一个上升沿（当作帧结束）。
// 验收：
//   1) width  = 5
//   2) height = 4
//   3) frames 随帧累加（跑到 3 帧）
//   4) new_frame 是 1 个 clk 宽的脉冲，每帧一次
// =============================================================================
`timescale 1ns/1ps

module dvp_capture_tb;

    localparam integer NPIX  = 5;
    localparam integer NLINE = 4;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    always #20.8335 clk = ~clk;          // 24 MHz 系统域

    reg  pclk = 1'b0;
    always #11.9 pclk = ~pclk;           // ≈42 MHz

    reg  href = 1'b0;
    reg  vsync = 1'b0;
    reg  [7:0] data = 8'h00;

    wire [15:0] width, height;
    wire [31:0] frames;
    wire        new_frame;

    dvp_capture u_dut (
        .clk(clk), .rst_n(rst_n),
        .pclk(pclk), .href(href), .vsync(vsync), .data(data),
        .width(width), .height(height), .frames(frames), .new_frame(new_frame)
    );

    integer nf = 0;
    always @(posedge clk) if (rst_n && new_frame) nf = nf + 1;

    // 一帧：NLINE 行，每行 HREF 高 NPIX 拍，行间隔几拍低
    task one_frame;
        integer l, p;
        begin
            // 帧开始脉冲（VSYNC 一个上升沿 -> 上一帧结束）
            @(posedge pclk); vsync = 1'b1;
            @(posedge pclk); vsync = 1'b0;
            repeat (3) @(posedge pclk);

            for (l = 0; l < NLINE; l = l + 1) begin
                href = 1'b1;
                for (p = 0; p < NPIX; p = p + 1) begin
                    data = data + 8'h11;
                    @(posedge pclk);
                end
                href = 1'b0;
                repeat (4) @(posedge pclk);
            end
        end
    endtask

    initial begin
        #200 rst_n = 1'b1;
        #200;

        one_frame();
        one_frame();
        one_frame();

        // 让最后一帧的 VSYNC 上升沿把数据锁进去
        @(posedge pclk); vsync = 1'b1;
        @(posedge pclk); vsync = 1'b0;
        #2000;                            // 等跨域同步（几个 24 MHz 周期）

        if (width !== NPIX)
            $display("FAIL: width=%0d (expect %0d)", width, NPIX);
        else
            $display("PASS: width=%0d", width);

        if (height !== NLINE)
            $display("FAIL: height=%0d (expect %0d)", height, NLINE);
        else
            $display("PASS: height=%0d", height);

        if (frames < 32'd3)
            $display("FAIL: frames=%0d (expect >=3)", frames);
        else
            $display("PASS: frames=%0d", frames);

        if (nf < 3)
            $display("FAIL: new_frame pulses=%0d (expect >=3)", nf);
        else
            $display("PASS: new_frame pulses=%0d", nf);

        $display("INFO: dvp_capture_tb done");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT: dvp_capture_tb hung");
        $finish;
    end

endmodule
