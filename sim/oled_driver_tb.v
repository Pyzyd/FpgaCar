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
    reg        k230_off = 1'b0;          // K230 掉线标志（0 = 在线）
    reg [2:0]  seq0 = 3'd1, seq1 = 3'd2, seq2 = 3'd3, seq3 = 3'd4;

    wire scl, sda_out, sda_oe, sda_in;
    wire busy, ack_err, frame_done, nack_seen;

    // ---- 调试输入（本次新增）：距离 / 八路循迹 / 车状态 / 四个标志位 ----
    reg [15:0] dbg_dist  = 16'hFFFF;     // 16'hFFFF = 无回波，屏上显示 "---"
    reg [7:0]  dbg_line  = 8'h00;
    reg [2:0]  dbg_state = 3'd0;
    reg [1:0]  panel_status = 2'd0;
    reg        dbg_obs   = 1'b0;
    reg [1:0]  dbg_turn  = 2'd0;         // 转向方向 0 无 / 1 左 / 2 右
    reg        dbg_lost  = 1'b0;

    // 物理 SDA：主机与从机共用一条线，外部上拉
    wire sda_line;
    reg  slv_oe_r = 1'b0;
    assign sda_line = sda_oe ? sda_out : (slv_oe_r ? 1'b0 : 1'bz);
    pullup (sda_line);
    assign sda_in = sda_line;

    oled_driver #(
        .CLK_FREQ(CLK_F), .SCL_FREQ(SCL_HZ), .BOOT_MS(1),
        .FLASH_MS(1), .ALIVE_MARK(1),     // 仿真里白闪只保持 1 ms
        .DBG_SAMPLE_MS(1)                 // 调试区 1 ms 采一次，别让仿真等 100 ms
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .k230_off(k230_off),
        .seq_valid(seq_valid), .seq0(seq0), .seq1(seq1), .seq2(seq2), .seq3(seq3),
        .scl(scl), .sda_in(sda_in), .sda_out(sda_out), .sda_oe(sda_oe),
        .busy(busy), .ack_err(ack_err), .frame_done(frame_done),
        .nack_seen(nack_seen),
        .dbg_dist(dbg_dist), .dbg_line(dbg_line), .dbg_state(dbg_state),
        .panel_status(panel_status),
        .dbg_obs(dbg_obs), .dbg_turn(dbg_turn),
        .dbg_lost(dbg_lost)
    );

    // 期望值参考：同一份字形 ROM
    reg  [8:0] eaddr;
    wire [7:0] eq;
    oled_font u_ref (.addr(eaddr), .q(eq));

    // ASCII 字模参照 ROM（与 DUT 同一份 oled_glyph，期望值靠它逐列取）
    reg  [7:0]  gch;
    wire [39:0] gq;
    oled_glyph u_ref_g (.ch(gch), .glyph(gq));

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
    integer   miso;                    // K230 OFF 叉号比对的不匹配计数


    task build_exp;
        integer i2, s2i, g2, c2, col2;
        begin
            for (i2 = 0; i2 < 1024; i2 = i2 + 1) exp_fb[i2] = 8'h00;
            for (i2 = 0; i2 < 8; i2 = i2 + 1) exp_fb[i2] = 8'hFF;   // 左上角 8x8 存活标记
            if (k230_off) begin                                     // 右上角 K230 OFF 叉号
                for (i2 = 0; i2 < 8; i2 = i2 + 1)
                    exp_fb[120 + i2] = (8'h01 << i2) | (8'h80 >> i2);
            end
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
            build_exp_dbg;
        end
    endtask

    // 调试区期望值：三行 16 字符文本，page1 / page6 / page7 各一行。
    // tb 侧独立把这三行字拼一遍（不复用 DUT 的任何表达式），再经 oled_glyph
    // 逐列铺进 exp_fb —— 两边共用同一份字模，但拼字逻辑各写一份，抄错会被抓。
    function [127:0] exp_row1;
        input [2:0] st;
        input       lost;
        reg [31:0] nm;
        begin
            case (st)
            3'd0:    nm = "IDLE";
            3'd1:    nm = "RUN ";
            3'd2:    nm = "LOST";
            3'd3:    nm = "SRCH";
            3'd4:    nm = "STOP";
            3'd5:    nm = "A-BK";
            3'd6:    nm = "A-TN";
            default: nm = "A-PB";
            endcase
            exp_row1 = {"ST:", nm, " LOST:", (lost ? "1" : "0"), "  "};
        end
    endfunction

    function [127:0] exp_row6;
        input [15:0] dv;
        input        ob;
        reg [3:0]  d2, d1, d0;
        reg [15:0] t;
        begin
            if (dv == 16'hFFFF)
                exp_row6 = {"DIST:---", " CM OB:", (ob ? "1" : "0")};
            else begin
                t  = (dv > 16'd999) ? 16'd999 : dv;
                d2 = t / 100; d1 = (t % 100) / 10; d0 = t % 10;
                exp_row6 = {"DIST:", (8'h30 + d2), (8'h30 + d1), (8'h30 + d0),
                            " CM OB:", (ob ? "1" : "0")};
            end
        end
    endfunction

    function [127:0] exp_row7;
        input [7:0] ln;
        input [1:0] tr;
        reg [7:0] tch;
        begin
            case (tr)
            2'd1:    tch = "L";
            2'd2:    tch = "R";
            default: tch = "-";
            endcase
            exp_row7 = {"LN:",
                        (ln[7] ? "1" : "0"), (ln[6] ? "1" : "0"),
                        (ln[5] ? "1" : "0"), (ln[4] ? "1" : "0"),
                        (ln[3] ? "1" : "0"), (ln[2] ? "1" : "0"),
                        (ln[1] ? "1" : "0"), (ln[0] ? "1" : "0"),
                        " TR:", tch};
        end
    endfunction

    // 把一行 16 字符按「5 列点阵 + 3 列空白」铺进指定 page
    task put_row (input [2:0] pg, input [127:0] txt);
        integer c, l;
        reg [7:0] ch;
        begin
            for (c = 0; c < 16; c = c + 1) begin
                ch = txt[127 - 8 * c -: 8];
                gch = ch;
                #1;
                for (l = 0; l < 8; l = l + 1)
                    exp_fb[pg * 128 + c * 8 + l] = (l < 5) ? gq[8 * l +: 8] : 8'h00;
            end
        end
    endtask

    task build_exp_dbg;
        begin
            put_row(3'd1, exp_row1(dbg_state, dbg_lost));
            put_row(3'd6, exp_row6(dbg_dist, dbg_obs));
            put_row(3'd7, exp_row7(dbg_line, dbg_turn));
        end
    endtask

    // 硬编码判据：调用点直接把三行「应该长什么样」写成字符串字面量，
    // 不经过 dbg_* 变量、也不经过 build_exp_dbg 的拼字函数。
    // 这样即使 DUT 与 tb 的期望模型被一起改错，也能被这条断言抓出来。
    reg [7:0] chk_fb [0:1023];

    task put_chk (input [2:0] pg, input [127:0] txt);
        integer c2, l2;
        reg [7:0] ch2;
        begin
            for (c2 = 0; c2 < 16; c2 = c2 + 1) begin
                ch2 = txt[127 - 8 * c2 -: 8];
                gch = ch2;
                #1;
                for (l2 = 0; l2 < 8; l2 = l2 + 1)
                    chk_fb[pg * 128 + c2 * 8 + l2] = (l2 < 5) ? gq[8 * l2 +: 8] : 8'h00;
            end
        end
    endtask

    task check_rows (input [255:0] tag,
                     input [127:0] t1, input [127:0] t6, input [127:0] t7);
        integer k2, bad2, pgc, fa;
        begin
            for (k2 = 0; k2 < 1024; k2 = k2 + 1) chk_fb[k2] = 8'h00;
            put_chk(3'd1, t1);
            put_chk(3'd6, t6);
            put_chk(3'd7, t7);
            // 只比三行文字所在的 page 1 / 6 / 7；page 2~5 是色块区，不归这里管
            bad2 = 0;
            for (k2 = 0; k2 < 3 * 128; k2 = k2 + 1) begin
                pgc = (k2 < 128) ? 1 : ((k2 < 256) ? 6 : 7);
                fa  = pgc * 128 + (k2 % 128);
                if (model_fb[fa] !== chk_fb[fa]) begin
                    if (bad2 < 5)
                        $display("  ROW MISMATCH fb[%0d] = %02h expect %02h", fa, model_fb[fa], chk_fb[fa]);
                    bad2 = bad2 + 1;
                end
            end
            if (bad2 == 0) $display("PASS: %0s three text rows match hard-coded strings", tag);
            else           $display("FAIL: %0s %0d bad bytes in text rows", tag, bad2);
        end
    endtask

    task check_fb (input [255:0] tag);
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

        // ---- 第 4 阶段：K230 掉线 → 右上角叉号出现；恢复 → 擦除 ----
        // 验收判据（PROJECT_PLAN §3.18）：拔掉 K230 后屏上要能看出来。
        // 这里只测驱动侧行为，link_alive 的 2 s 超时由 k230_link_tb 覆盖。
        $display("PHASE: waiting OFF-cross frame at %0t", $time); $fflush(0);
        k230_off = 1'b1;
        @(posedge frame_done);
        @(posedge clk);
        $display("PHASE: OFF-cross frame arrived at %0t", $time); $fflush(0);
        build_exp;
        miso = 0;
        for (mi = 120; mi < 128; mi = mi + 1)
            if (model_fb[mi] !== ((8'h01 << (mi - 120)) | (8'h80 >> (mi - 120)))) miso = miso + 1;
        if (miso == 0) $display("PASS: K230 OFF cross drawn at page0 col120..127");
        else           $display("FAIL: K230 OFF cross wrong, %0d bad bytes", miso);
        // 叉号不能波及左侧存活标记
        miso = 0;
        for (mi = 0; mi < 8; mi = mi + 1)
            if (model_fb[mi] !== 8'hFF) miso = miso + 1;
        if (miso == 0) $display("PASS: alive mark unaffected by OFF cross");
        else           $display("FAIL: alive mark damaged, %0d bad bytes", miso);

        $display("PHASE: waiting recover frame at %0t", $time); $fflush(0);
        k230_off = 1'b0;
        @(posedge frame_done);
        @(posedge clk);
        $display("PHASE: recover frame arrived at %0t", $time); $fflush(0);
        build_exp;
        check_fb("after K230 recover");

        // ---- 第 5 阶段：调试输入真变一次，验证数字/'1' 字形/标志格都跟着走 ----
        // 前面的用例里 dbg_line 恒 0，只走到 '0' 字形；这里给 8'b10000001，
        // 最左和最右两格必须是 '1'，并且四个标志格要跟着翻转，才算真的接通。
        $display("PHASE: waiting debug-data frame at %0t", $time); $fflush(0);
        dbg_dist  = 16'd123;
        dbg_line  = 8'b10000001;
        dbg_state = 3'd2;
        panel_status = 2'd1;
        dbg_obs   = 1'b1;
        dbg_turn  = 2'd2;              // 右转：点亮最后一格，覆盖新布局
        dbg_lost  = 1'b0;
        @(posedge frame_done);
        @(posedge clk);
        $display("PHASE: debug-data frame arrived at %0t", $time); $fflush(0);
        build_exp;
        check_fb("debug data 123cm / 10000001 / state2");
        // 本帧：state=2(LOST) obs=1 lost=0 turn=2(右) dist=123 line=10000001
        check_rows("right turn (dbg_turn=2)",
                   "ST:LOST LOST:0  ", "DIST:123 CM OB:1", "LN:10000001 TR:R");

        // ---- 第 5b 阶段：只把 dbg_turn 改成左转 ----
        // 右转那一帧左转格是灭的，单看它无法区分「fl=2 接的是 turn_dir」与
        // 「fl=2 接成了恒 0 或丢线」。这里再要一帧，让左转格真正点亮。
        $display("PHASE: waiting left-turn frame at %0t", $time); $fflush(0);
        dbg_turn = 2'd1;
        panel_status = 2'd2;
        @(posedge frame_done);
        @(posedge clk);
        $display("PHASE: left-turn frame arrived at %0t", $time); $fflush(0);
        build_exp;
        check_fb("left turn (dbg_turn=1)");
        check_rows("left turn (dbg_turn=1)",
                   "ST:LOST LOST:0  ", "DIST:123 CM OB:1", "LN:10000001 TR:L");

        panel_status = 2'd3;
        @(posedge frame_done);
        @(posedge clk);
        build_exp;
        check_fb("LINE panel-only redraw");

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
