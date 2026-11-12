// =============================================================================
// oled_driver_tb.v —— oled_driver 自测（含 SSD1306 行为级从机模型）
// iverilog -g2012 -Wall -s oled_driver_tb -o oled_driver_tb.vvp \
//          src/oled_font.v src/oled_driver.v sim/oled_driver_tb.v && vvp oled_driver_tb.vvp
// -----------------------------------------------------------------------------
// 验收：
//   1) 事务结构正确：首字节 = 0x78（0x3C<<1 | W），第二字节 = 控制字节 0x00/0x40
//   2) 初始化序列含 0xAE / 0x8D 0x14 / 0xAF，全程 ack_err = 0
//   3) 一帧 = 列窗命令 21 00 7F + 页窗命令 22 00 07 + 1024 字节数据
//   4) 显存内容 = 4 个 32x32 汉字横向排列（与 oled_font ROM 逐字节比对）
//   5) seq 变化后重画一帧，内容随之更新
//   6) SCL 频率符合参数（本 tb 用 4 MHz 缩短仿真时间）
//   7) 上电自检：第 1 帧整屏 0xFF（白闪）、第 2 帧整屏 0x00（转黑），
//      之后每帧在 page0/col0..7 带 8 字节存活标记（ALIVE_MARK=1）
//   8) 粘滞 nack_seen：正常运行期恒 0；注入地址失配后必须锁存为 1 且不再回落
//      （上板黑屏靠它在 LED[5] 上区分「屏没应答」与「总线通了但屏不亮」）
// =============================================================================
`timescale 1ns/1ps

module oled_driver_tb;

    localparam integer CLK_F   = 24_000_000;
    localparam integer SCL_HZ  = 4_000_000;      // 仿真用 4 MHz（DIV = 2）

    reg clk = 1'b0;
    always #20.8335 clk = ~clk;

    reg        rst_n     = 1'b0;
    reg        seq_valid = 1'b0;
    reg [2:0]  seq0 = 3'd1, seq1 = 3'd2, seq2 = 3'd3, seq3 = 3'd4;

    wire scl, sda_out, sda_oe, sda_in;
    wire busy, ack_err, frame_done, nack_seen;

    // 物理 SDA：主机与从机共用一条线，外部上拉
    wire sda_line;
    reg  slv_oe_r = 1'b0;
    assign sda_line = sda_oe ? sda_out : (slv_oe_r ? 1'b0 : 1'bz);
    pullup (sda_line);
    assign sda_in = sda_line;

    oled_driver #(
        .CLK_FREQ(CLK_F), .SCL_FREQ(SCL_HZ), .BOOT_MS(1),
        .FLASH_MS(1), .ALIVE_MARK(1)      // 仿真里白闪只保持 1 ms
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .seq_valid(seq_valid), .seq0(seq0), .seq1(seq1), .seq2(seq2), .seq3(seq3),
        .scl(scl), .sda_in(sda_in), .sda_out(sda_out), .sda_oe(sda_oe),
        .busy(busy), .ack_err(ack_err), .frame_done(frame_done),
        .nack_seen(nack_seen)
    );

    // 期望值参考：同一份字形 ROM
    reg  [8:0] eaddr;
    wire [7:0] eq;
    oled_font u_ref (.addr(eaddr), .q(eq));

    // ------------------------------------------------------------------
    // 从机模型：时钟采样 + 事件检测（比沿触发稳，避免 SCL/SDA 同拍改值的竞争）
    // ------------------------------------------------------------------
    reg s1 = 1'b1, s2 = 1'b1, d1 = 1'b1, d2 = 1'b1;
    always @(posedge clk) begin
        s1 <= scl;      s2 <= s1;
        d1 <= sda_line; d2 <= d1;
    end
    wire scl_hi   = s1 & s2;
    wire scl_rise = s1 & ~s2;
    wire scl_fall = ~s1 & s2;
    wire start_ev = scl_hi & ~d1 & d2;
    wire stop_ev  = scl_hi & d1 & ~d2;

    localparam [1:0] SL_IDLE = 2'd0, SL_BITS = 2'd1, SL_ACK = 2'd2;

    reg [1:0]  st      = SL_IDLE;
    reg [7:0]  rx      = 8'h00;
    reg [7:0]  ctrl    = 8'h00;
    reg        addr_ok = 1'b1;
    reg [6:0]  slv_addr = 7'h3C;   // 故障注入时可改，模拟「屏不应答」
    integer    bitn    = 0;
    integer    byten   = 0;
    integer    ncmd    = 0;
    integer    ndata   = 0;
    integer    ntxn    = 0;
    integer    nack    = 0;

    reg [7:0] cmd_log [0:255];
    reg [7:0] model_fb[0:1023];

    // slv_oe_r 由状态机在时钟上升沿驱动（见 always 块内的 ACK 处理）

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= SL_IDLE; bitn <= 0; byten <= 0;
        end else if (start_ev) begin
            st <= SL_BITS; bitn <= 0; byten <= 0; rx <= 8'h00; addr_ok <= 1'b1;
        end else if (stop_ev) begin
            st <= SL_IDLE; bitn <= 0; byten <= 0; ntxn <= ntxn + 1; slv_oe_r <= 1'b0;
        end else begin
            case (st)
            SL_BITS: begin
                if (scl_rise) begin
                    rx   <= {rx[6:0], d1};
                    bitn <= bitn + 1;
                end
                if (scl_fall && bitn == 8) begin
                    st <= SL_ACK;
                    slv_oe_r <= addr_ok;
                    if (byten == 0) begin
                        addr_ok <= (rx[7:1] == slv_addr) && (rx[0] == 1'b0);
                        if (!((rx[7:1] == slv_addr) && (rx[0] == 1'b0))) nack <= nack + 1;
                    end else if (byten == 1) begin
                        ctrl <= rx;
                        if (rx == 8'h40) ndata <= 0;   // 每次数据流从 0 开始
                    end else if (ctrl == 8'h40) begin
                        if (ndata < 1024) model_fb[ndata] <= rx;
                        ndata <= ndata + 1;
                    end else begin
                        if (ncmd < 256) cmd_log[ncmd] <= rx;
                        ncmd <= ncmd + 1;
                    end
                    byten <= byten + 1;
                end
            end
            SL_ACK: begin
                if (scl_fall) begin
                    st <= SL_BITS; bitn <= 0; rx <= 8'h00;
                    slv_oe_r <= 1'b0;
                end
            end
            default: st <= SL_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 期望显存内容
    // ------------------------------------------------------------------
    reg [7:0] exp_fb [0:1023];
    reg [2:0] cols   [0:3];
    integer   mi, mg, mc, ms, mcol, mism;
    integer   tw;                      // 故障注入阶段的超时计数

    task build_exp;
        integer i2, s2i, g2, c2, col2;
        begin
            for (i2 = 0; i2 < 1024; i2 = i2 + 1) exp_fb[i2] = 8'h00;
            for (i2 = 0; i2 < 8; i2 = i2 + 1) exp_fb[i2] = 8'hFF;   // 左上角 8x8 存活标记
            for (s2i = 0; s2i < 4; s2i = s2i + 1) begin
                col2 = cols[s2i];
                if (col2 != 0) begin
                    for (g2 = 0; g2 < 4; g2 = g2 + 1) begin
                        for (c2 = 0; c2 < 32; c2 = c2 + 1) begin
                            eaddr = (col2 - 1) * 128 + g2 * 32 + c2;
                            #1;
                            exp_fb[(g2 + 2) * 128 + s2i * 32 + c2] = eq;
                        end
                    end
                end
            end
        end
    endtask

    task check_fb (input [127:0] tag);
        begin
            mism = 0;
            for (mi = 0; mi < 1024; mi = mi + 1)
                if (model_fb[mi] !== exp_fb[mi]) begin
                    if (mism < 5)
                        $display("  MISMATCH fb[%0d] = %02h expect %02h", mi, model_fb[mi], exp_fb[mi]);
                    mism = mism + 1;
                end
            if (mism == 0) $display("PASS: %0s framebuffer matches expectation (1024 bytes)", tag);
            else           $display("FAIL: %0s framebuffer has %0d bad bytes", tag, mism);
        end
    endtask

    // ------------------------------------------------------------------
    // SCL 周期测量
    // ------------------------------------------------------------------
    time t_prev = 0, t_now = 0, t_period = 0;
    integer scl_edges = 0;
    always @(posedge scl) begin
        t_now = $time;
        if (scl_edges > 0) t_period = t_now - t_prev;
        t_prev = t_now;
        scl_edges = scl_edges + 1;
    end

    // ------------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------------
    integer i, found_ae, found_af, found_cp, found_21, found_22, ncmd_snapshot;

    initial begin
        for (i = 0; i < 1024; i = i + 1) model_fb[i] = 8'h00;
        for (i = 0; i < 256;  i = i + 1) cmd_log[i]  = 8'h00;

        #200 rst_n = 1'b1;

        // ---- 第 1 帧：红绿蓝黄 ----
        cols[0] = 3'd1; cols[1] = 3'd2; cols[2] = 3'd3; cols[3] = 3'd4;
        @(posedge clk); #1;
        seq0 = 3'd1; seq1 = 3'd2; seq2 = 3'd3; seq3 = 3'd4;
        seq_valid = 1'b1;
        @(posedge clk); #1;
        seq_valid = 1'b0;
        build_exp;

        // ---- 上电自检第 1 帧：整屏全白（0xFF）----
        // frame_done 是 1 clk 脉冲：必须等「下一个上升沿」，用 wait(电平) 会在
        // 脉冲还没撤掉的同一拍立刻返回，等于没等（第二帧起就串位了）。
        @(posedge frame_done);
        @(posedge clk);
        $display("INFO: white-flash frame done at %0t ns, transactions = %0d", $time, ntxn);
        mism = 0;
        for (mi = 0; mi < 1024; mi = mi + 1)
            if (model_fb[mi] !== 8'hFF) begin
                if (mism < 5) $display("  MISMATCH fb[%0d] = %02h expect FF", mi, model_fb[mi]);
                mism = mism + 1;
            end
        if (mism == 0) $display("PASS: power-on self-test frame is all-white (1024 bytes FF)");
        else           $display("FAIL: white frame has %0d non-FF bytes", mism);

        // ---- 上电自检第 2 帧：整屏转黑（0x00）----
        // frame_done 是 1 clk 脉冲：必须等「下一个上升沿」，用 wait(电平) 会在
        // 脉冲还没撤掉的同一拍立刻返回，等于没等（第二帧起就串位了）。
        @(posedge frame_done);
        @(posedge clk);
        $display("INFO: black frame done at %0t ns", $time);
        mism = 0;
        for (mi = 0; mi < 1024; mi = mi + 1)
            if (model_fb[mi] !== 8'h00) begin
                if (mism < 5) $display("  MISMATCH fb[%0d] = %02h expect 00", mi, model_fb[mi]);
                mism = mism + 1;
            end
        if (mism == 0) $display("PASS: self-test clears screen to black (1024 bytes 00)");
        else           $display("FAIL: black frame has %0d non-zero bytes", mism);

        // ---- 第 1 帧内容：红绿蓝黄 ----
        // frame_done 是 1 clk 脉冲：必须等「下一个上升沿」，用 wait(电平) 会在
        // 脉冲还没撤掉的同一拍立刻返回，等于没等（第二帧起就串位了）。
        @(posedge frame_done);
        @(posedge clk);
        $display("INFO: frame 1 done at %0t ns, transactions = %0d", $time, ntxn);
        check_fb("frame1");
        if (ndata !== 1024) $display("FAIL: frame1 data bytes = %0d (expect 1024)", ndata);
        else                $display("PASS: frame1 pushed 1024 data bytes in one transaction");
        if (ack_err !== 1'b0) $display("FAIL: ack_err = 1 during frame1");
        else                  $display("PASS: no NACK during frame1");

        // 初始化命令抽查
        found_ae = 0; found_af = 0; found_cp = 0; found_21 = 0; found_22 = 0;
        for (i = 0; i < 256; i = i + 1) begin
            if (cmd_log[i] == 8'hAE) found_ae = 1;
            if (cmd_log[i] == 8'hAF) found_af = 1;
            if (cmd_log[i] == 8'h8D && cmd_log[i+1] == 8'h14) found_cp = 1;
            if (cmd_log[i] == 8'h21) found_21 = 1;
            if (cmd_log[i] == 8'h22) found_22 = 1;
        end
        if (found_ae && found_af && found_cp) $display("PASS: init sequence contains AE / 8D 14 / AF");
        else $display("FAIL: init sequence incomplete (AE=%0d AF=%0d CP=%0d)", found_ae, found_af, found_cp);
        if (found_21 && found_22) $display("PASS: page window commands 21 / 22 issued");
        else $display("FAIL: window commands missing (21=%0d 22=%0d)", found_21, found_22);

        if (t_period < (1_000_000_000 / SCL_HZ) * 0.95 ||
            t_period > (1_000_000_000 / SCL_HZ) * 1.05)
            $display("FAIL: SCL period = %0d ns (expect ~%0d ns)",
                     t_period, 1_000_000_000 / SCL_HZ);
        else
            $display("PASS: SCL period = %0d ns -> %.2f MHz",
                     t_period, 1000.0 / t_period);

        // ---- 第 2 帧：顺序改成 蓝黄红绿 ----
        cols[0] = 3'd3; cols[1] = 3'd4; cols[2] = 3'd1; cols[3] = 3'd2;
        @(posedge clk); #1;
        seq0 = 3'd3; seq1 = 3'd4; seq2 = 3'd1; seq3 = 3'd2;
        seq_valid = 1'b1;
        @(posedge clk); #1;
        seq_valid = 1'b0;
        build_exp;

        // frame_done 是 1 clk 脉冲：必须等「下一个上升沿」，用 wait(电平) 会在
        // 脉冲还没撤掉的同一拍立刻返回，等于没等（第二帧起就串位了）。
        @(posedge frame_done);
        @(posedge clk);
        $display("INFO: frame 2 done at %0t ns", $time);
        check_fb("frame2");

        // ---- 第 3 帧：只填 2 个槽（模拟只识别出两色，空槽应为空白）----
        cols[0] = 3'd2; cols[1] = 3'd4; cols[2] = 3'd0; cols[3] = 3'd0;
        @(posedge clk); #1;
        seq0 = 3'd2; seq1 = 3'd4; seq2 = 3'd0; seq3 = 3'd0;
        seq_valid = 1'b1;
        @(posedge clk); #1;
        seq_valid = 1'b0;
        build_exp;

        // frame_done 是 1 clk 脉冲：必须等「下一个上升沿」，用 wait(电平) 会在
        // 脉冲还没撤掉的同一拍立刻返回，等于没等（第二帧起就串位了）。
        @(posedge frame_done);
        @(posedge clk);
        check_fb("frame3 (2 slots)");

        if (nack !== 0) $display("FAIL: slave model saw %0d address NACKs", nack);
        else            $display("PASS: every transaction addressed 0x3C correctly");

        if (busy !== 1'b0) $display("FAIL: busy still high at end");
        else               $display("PASS: bus idle at end");

        // ---- 第 4 阶段：故障注入（从机地址不匹配）——粘滞 nack_seen 必须锁存 ----
        // 这一条是上板诊断路径的回归：黑屏时靠 nack_seen 区分「屏没应答」与
        // 「总线通了但屏不亮」，所以必须证明它真的会被置起来，而不只是恒 0。
        if (nack_seen !== 1'b0) $display("FAIL: nack_seen set before fault injection");
        else                    $display("PASS: nack_seen clear during healthy run");

        slv_addr = 7'h3D;              // 屏换地址 / 未接线 / 上拉缺失的表现
        @(posedge clk); #1;
        seq0 = 3'd3; seq1 = 3'd1;      // 改 seq 触发重画一帧
        seq_valid = 1'b1;
        @(posedge clk); #1;
        seq_valid = 1'b0;

        tw = 0;
        while (nack_seen !== 1'b1 && tw < 20000) begin
            @(posedge clk); tw = tw + 1;
        end
        if (nack_seen !== 1'b1)
            $display("FAIL: nack_seen never latched after address mismatch (%0d clk)", tw);
        else
            $display("PASS: nack_seen latched (sticky) after NACK, %0d clk", tw);

        $display("INFO: oled_driver_tb done");
        $finish;
    end

endmodule
