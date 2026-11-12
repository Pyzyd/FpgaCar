// =============================================================================
// color_detect_tb.v —— color_detect v3 自测（按真实 DVP 时序造 RGB565 字节流）
// iverilog -g2012 -Wall -s color_detect_tb -o color_detect_tb.vvp \
//          src/color_detect.v sim/color_detect_tb.v && vvp color_detect_tb.vvp
// -----------------------------------------------------------------------------
// 【关键：时序模型】OV5640 在 PCLK **下降沿**改变数据，上升沿处数据稳定。
// 所以本 tb 一律在 negedge 更新 data/href/vsync，DUT 在 posedge 采样。
//
// 每帧默认 NPIX=256 像素（> MIN_PIX=200），VSYNC 上升沿表示"一帧结束"。
// 验收（v3 新增 6/7/8 三条，对应 2026-11-12 上板现象）：
//   1) 纯红/绿/蓝/黄 → 1/2/3/4          （v2 起就有）
//   2) 全黑 → 0                          （中性色不计）
//   3) 小色斑（各 64 < 200）→ 0          （MIN_PIX 生效）
//   4) 暖光下的黄 R=255 G=240 B=140 → 4  （B 抬到 6 位 34，v2 的 B<26 必失败）
//   5) 浅黄 R=250 G=250 B=180 → 4        （低饱和但仍是黄）
//   6) 一帧里四色各 256 像素 → 连续 4 帧必须把 1/2/3/4 全都报一遍（轮询不饿死）
//   7) 每帧都有 new_color 脉冲
// =============================================================================
`timescale 1ns/1ps

module color_detect_tb;

    localparam integer NPIX = 256;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    always #20.8335 clk = ~clk;        // 24 MHz

    reg  pclk = 1'b0;
    always #11.9 pclk = ~pclk;         // ≈42 MHz

    reg  href = 1'b0;
    reg  vsync = 1'b0;
    reg  [7:0] data = 8'h00;

    wire [2:0] color;
    wire       new_color;

    // v4 新增的遥测端口（只观测，本 tb 不比对，留着看波形）
    wire [19:0] dbg_cnt_r, dbg_cnt_g, dbg_cnt_b, dbg_cnt_y;
    wire [6:0]  dbg_sat;
    wire [7:0]  dbg_sb0, dbg_sb1, dbg_lb0, dbg_lb1;

    color_detect u_dut (
        .clk(clk), .rst_n(rst_n),
        .pclk(pclk), .href(href), .vsync(vsync), .data(data),
        .color(color), .new_color(new_color),
        .dbg_b0(), .dbg_b1(),
        .dbg_cnt_r(dbg_cnt_r), .dbg_cnt_g(dbg_cnt_g),
        .dbg_cnt_b(dbg_cnt_b), .dbg_cnt_y(dbg_cnt_y),
        .dbg_sat(dbg_sat),
        .dbg_sb0(dbg_sb0), .dbg_sb1(dbg_sb1),
        .dbg_lb0(dbg_lb0), .dbg_lb1(dbg_lb1)
    );

    integer nfr = 0;
    always @(posedge clk) if (rst_n && new_color) nfr = nfr + 1;

    integer fails = 0;

    // ---- 单个像素：先高字节后低字节，都在 negedge 更新 ----
    task px (input [4:0] r5, input [5:0] g6, input [4:0] b5);
        begin
            data = {r5, g6[5:3]};        // 高字节 R[4:0] G[5:3]
            @(negedge pclk);
            data = {g6[2:0], b5};        // 低字节 G[2:0] B[4:0]
            @(negedge pclk);
        end
    endtask

    task frame_end;
        begin
            href = 1'b0;
            repeat (2) @(negedge pclk);
            vsync = 1'b1;                    // 帧结束
            @(negedge pclk);
            vsync = 1'b0;
            repeat (3) @(negedge pclk);
        end
    endtask

    // 送 n 个同色像素，末尾给一个 VSYNC 上升沿结束本帧
    task send_frame (input [7:0] r, input [7:0] g, input [7:0] b, input integer n);
        reg [4:0] r5;
        reg [5:0] g6;
        reg [4:0] b5;
        integer i;
        begin
            r5 = r[7:3];
            g6 = g[7:2];
            b5 = b[7:3];

            @(negedge pclk);
            href = 1'b1;
            for (i = 0; i < n; i = i + 1) px(r5, g6, b5);
            frame_end;
        end
    endtask

    // 一帧里四段等长色带（红绿蓝黄各 n 个像素）
    task send_quad (input integer n);
        integer i;
        begin
            @(negedge pclk);
            href = 1'b1;
            for (i = 0; i < n; i = i + 1) px(5'd31, 6'd0,  5'd0);   // 红 (255,0,0)
            for (i = 0; i < n; i = i + 1) px(5'd0,  6'd63, 5'd0);   // 绿
            for (i = 0; i < n; i = i + 1) px(5'd0,  6'd0,  5'd31);  // 蓝
            for (i = 0; i < n; i = i + 1) px(5'd31, 6'd60, 5'd0);   // 黄
            frame_end;
        end
    endtask

    // 两段色带：主色 n1 个 + 次色 n2 个，用于验证主导色门限
    task send_two (input [7:0] r1, input [7:0] g1, input [7:0] b1, input integer n1,
                   input [7:0] r2, input [7:0] g2, input [7:0] b2, input integer n2);
        integer i;
        begin
            @(negedge pclk);
            href = 1'b1;
            for (i = 0; i < n1; i = i + 1) px(r1[7:3], g1[7:2], b1[7:3]);
            for (i = 0; i < n2; i = i + 1) px(r2[7:3], g2[7:2], b2[7:3]);
            frame_end;
        end
    endtask

    task check (input [2:0] exp, input [8*8-1:0] name);
        begin
            #3000;                           // 等跨域同步（24 MHz 几个周期）
            if (color !== exp) begin
                $display("FAIL: %0s -> color=%0d (expect %0d)", name, color, exp);
                fails = fails + 1;
            end else
                $display("PASS: %0s -> color=%0d", name, color);
        end
    endtask

    // 抓一帧的结果（不比对，用于轮询测试）
    task grab (output [2:0] c);
        begin
            #3000;
            c = color;
        end
    endtask

    reg [2:0] q0, q1, q2, q3;
    reg [4:0] seen;    // 下标 = 颜色码 1..4

    initial begin
        #400 rst_n = 1'b1;
        #400;

        send_frame(8'd255, 8'd0,   8'd0,   NPIX); check(3'd1, "red   ");
        send_frame(8'd0,   8'd255, 8'd0,   NPIX); check(3'd2, "green ");
        send_frame(8'd0,   8'd0,   8'd255, NPIX); check(3'd3, "blue  ");
        send_frame(8'd255, 8'd255, 8'd0,   NPIX); check(3'd4, "yellow");
        send_frame(8'd0,   8'd0,   8'd0,   NPIX); check(3'd0, "black ");

        // 小色斑：红 64 + 绿 64，都 < MIN_PIX=200
        send_frame(8'd255, 8'd0,   8'd0,   64);
        send_frame(8'd0,   8'd255, 8'd0,   64);
        check(3'd0, "sparse");

        // ---- v3 新增：暖光/浅黄，v2 的绝对门限必失败 ----
        send_frame(8'd255, 8'd240, 8'd140, NPIX); check(3'd4, "warmyel");
        send_frame(8'd250, 8'd250, 8'd180, NPIX); check(3'd4, "paleyel");

        // ---- v4 新增：按上板实测补两条"偏色"回归 ----
        // 板子实际白平衡偏绿，同一张黄纸中心像素 = R=32 G=43 B=18（6 位），
        // 即 8 位 R≈137 G≈173 B≈72。旧门限 YEL_DR=14 时 |R-G|=11 只是勉强过，
        // 光照稍变就滑到绿色，表现为 Q 在 2/4 之间跳 —— 这条用例锁死该行为。
        send_frame(8'd137, 8'd173, 8'd72,  NPIX); check(3'd4, "yelcast");

        // 真绿 R=42 G=177 B=42（6 位 10/44/10）：|R-G|=34 > YEL_DR=24，
        // 放宽黄门限后**不能**把它误吞成黄。
        send_frame(8'd42,  8'd177, 8'd42,  NPIX); check(3'd2, "truegrn");

        // 黄纸暗部：6 位 20/26/10（8 位 80/104/40）。旧 YEL_RG=28 会把它踢出黄色分支、
        // 落到"绿最大"分支导致 G 计数虚高 —— 这是 Q 在 4/2 之间轮询的真正来源。
        send_frame(8'd80,  8'd104, 8'd40,  NPIX); check(3'd4, "yeldsdw");

        // 黄纸更深一档的阴影：6 位 8/30/0（8 位 32/120/0）。
        // min(R,G)=8 正好卡在新 YEL_RG 上；旧值 16/28 会把它踢到绿色分支。
        send_frame(8'd32,  8'd120, 8'd0,   NPIX); check(3'd4, "yelsdw2");

        // 同样暗的真绿：6 位 4/30/4（8 位 16/120/16）。G 比 R 高 26 > GRN_DR=16，必须仍是绿。
        send_frame(8'd16,  8'd120, 8'd16,  NPIX); check(3'd2, "grnsdw2");

        // ---- v6 主导色门限：占本帧最大色的 1/5（v5 的"占总量 1/32"已废弃）----
        // 场景取自实测：黄纸 9000 px + 阴影/边缘残留绿 250 px，
        // 250*5 = 1250 < 9000，残留绿被压掉，连发 3 帧必须稳稳是 4。
        // （总量口径下 9250>>5=289 也压得住，但同一批实测里残留蓝占总量的比例
        //   够高就能帧帧入选 —— 总量口径没有绝对锚点，主色一暗门限就塌。）
        send_two(8'd137, 8'd173, 8'd72, 9000,  8'd42, 8'd177, 8'd42, 250);
        check(3'd4, "domyel1");
        send_two(8'd137, 8'd173, 8'd72, 9000,  8'd42, 8'd177, 8'd42, 250);
        check(3'd4, "domyel2");
        send_two(8'd137, 8'd173, 8'd72, 9000,  8'd42, 8'd177, 8'd42, 250);
        check(3'd4, "domyel3");

        // 反过来：绿铺满 + 残留黄 250 px，必须稳定是 2（门限双向对称）
        send_two(8'd42, 8'd177, 8'd42, 9000,  8'd137, 8'd173, 8'd72, 250);
        check(3'd2, "domgrn1");

        // ---- v6 核心动机：小块**真色**不能被一大块主色挤掉 ----
        // 黄 4000 + 绿 900：900*5 = 4500 >= 4000，绿占最大色的 22.5% > 1/5(20%)，
        // 既过 MIN_PIX 又过门限，必须在两帧内轮到一次
        // （从哪个颜色起轮由上一帧决定，故只查"都出现过"）。
        // 旧 1/4 口径（4000/4=1000 > 900）会永远只报黄，color_seq 就漏记这个绿块。
        // 20% 是实测选出的平衡点：y13 残留蓝占黄 max 16.5% 被压死，
        // y10 真实场景仍有 99.2% 的帧可轮（1/4 会掉到 93.9%）。
        seen = 5'b00000;
        send_two(8'd137, 8'd173, 8'd72, 4000,  8'd42, 8'd177, 8'd42, 900); grab(q0);
        send_two(8'd137, 8'd173, 8'd72, 4000,  8'd42, 8'd177, 8'd42, 900); grab(q1);
        if (q0 != 3'd0) seen[q0] = 1'b1;
        if (q1 != 3'd0) seen[q1] = 1'b1;
        $display("INFO: domrot results %0d %0d", q0, q1);
        if (seen[2] !== 1'b1 || seen[4] !== 1'b1) begin
            $display("FAIL: small real color starved by big block (seen=%b)", seen);
            fails = fails + 1;
        end else
            $display("PASS: small real color still rotate 2/4");

        // ---- v3 新增：四色同帧，连发 4 帧必须四色全到 ----
        seen = 5'b00000;
        send_quad(NPIX); grab(q0);
        send_quad(NPIX); grab(q1);
        send_quad(NPIX); grab(q2);
        send_quad(NPIX); grab(q3);
        if (q0 != 3'd0) seen[q0] = 1'b1;
        if (q1 != 3'd0) seen[q1] = 1'b1;
        if (q2 != 3'd0) seen[q2] = 1'b1;
        if (q3 != 3'd0) seen[q3] = 1'b1;
        $display("INFO: quad results %0d %0d %0d %0d", q0, q1, q2, q3);
        if (seen[1] !== 1'b1 || seen[2] !== 1'b1 || seen[3] !== 1'b1 || seen[4] !== 1'b1) begin
            $display("FAIL: quad round-robin missed colors (seen=%b)", seen);
            fails = fails + 1;
        end else
            $display("PASS: quad round-robin covers 1/2/3/4");


        // ---- v6b：大帧位宽回归（cnt*5 必须用 23 位）----
        // 单色上限 1280*720 = 921600，×5 = 4,608,000 > 2^22 = 4,194,304。
        // 若 cnt_*5 仍声明为 22 位，则 cnt > 838860 时乘积回绕（921600 会变成 413696），
        // 于是 cnt*5 反而 < cnt_mx，elig 全 0 → 整帧被判成"无色"。这帧 900000 px 专门锁死它。
        // （900000*5 = 4,500,000，22 位下回绕成 305,696，远小于 900000，必报 0。）
        send_frame(8'd255, 8'd255, 8'd0, 900000);
        #3000;    // 等 vs_rise 的锁存经 toggle 同步进 clk 域，否则读到的是上一帧的旧值
        $display("INFO: bigframe cnt_y=%0d", dbg_cnt_y);
        if (dbg_cnt_y < 20'd900000) begin
            $display("FAIL: bigframe cnt_y=%0d (expect 900000)", dbg_cnt_y);
            fails = fails + 1;
        end
        check(3'd4, "bigframe");

        if (nfr < 12) begin
            $display("FAIL: new_color pulses=%0d (expect >=12)", nfr);
            fails = fails + 1;
        end else
            $display("PASS: new_color pulses=%0d", nfr);

        if (fails == 0) $display("INFO: color_detect_tb ALL PASS");
        else            $display("INFO: color_detect_tb FAILURES=%0d", fails);
        $finish;
    end

    initial begin
        #200_000_000;   // v6b 大帧用例（900000 px ≈ 21.4 ms）需要更长预算
        $display("TIMEOUT: color_detect_tb hung");
        $finish;
    end

endmodule
