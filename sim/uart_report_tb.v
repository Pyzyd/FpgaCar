// =============================================================================
// uart_report_tb.v —— uart_report 自测（两行报文整体比对）
// iverilog -g2012 -Wall -s uart_report_tb -o _sim/urt.vvp \
//          src/uart_tx.v src/uart_report.v sim/uart_report_tb.v && vvp _sim/urt.vvp
// -----------------------------------------------------------------------------
// 每个 dist_valid 打两行，共 35 + 39 = 74 字节：
//   第 1 行 D=123cm T=00011000 P=+02 O=0 M=01 CR LF
//   第 2 行 L=0000007B R=FFFFFFF0 VL=0005 VR=FFF0 X=11100111 C=+036 DL=27C DR=234 CR LF
//   第 2 行共 71 字节：L=/R=(21) VL=/VR=(15) X=(10) C=(6) DL=(6) DR=(6) + 5 空格 + CR LF
// 验收：
//   1) 123cm / 中间两路 / pos=+2 / 无障碍 / RUN / 里程 123 与 -16
//   2) 无效距离 --- / 两端各一路 / pos=-7 / 有障碍 / STOP / 里程 0
//   3) 7cm / 全丢线 / pos=0 / IDLE / 里程 0x0000ABCD 与 -1 / 速度 1200 与 -1
//   4) 999cm / 全压线 / pos=+16 / 两位位置与三位距离的边界
//   5) pos=-16 的符号位与 "50cm" 前导零
// 【注意】期望串里不要写 \r\n 转义，直接用 set_exp 补 CR LF 两个字节，
//   避免模板串被还原成真实换行。
// =============================================================================
`timescale 1ns/1ps

module uart_report_tb;

    localparam real    BIT_NS   = 1.0e9 / 115200.0;
    localparam integer MSG_LEN  = 35;
    localparam integer MSG2_LEN = 75;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    always #20.8335 clk = ~clk;

    reg  [15:0] dist_cm = 16'd0;
    reg         dist_valid = 1'b0;
    reg  [7:0]  line = 8'h00;
    reg  [7:0]  raw  = 8'h00;
    reg  signed [4:0]  pos    = 5'sd0;
    reg  signed [10:0] corr   = 11'sd0;
    reg  [10:0]        duty_l = 11'd0;
    reg  [10:0]        duty_r = 11'd0;
    reg         wide = 1'b0;
    reg         obstacle = 1'b0;
    reg  [2:0]  state = 3'd0;
    reg  [31:0] enc_l = 32'd0;
    reg  [31:0] enc_r = 32'd0;
    reg  signed [15:0] spd_l = 16'sd0;
    reg  signed [15:0] spd_r = 16'sd0;
    wire        tx;

    uart_report #(.CLK_FREQ(24_000_000), .BAUD(115_200), .REPORT_EN(1)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .dist_cm(dist_cm), .dist_valid(dist_valid),
        .line(line), .raw(raw), .pos(pos),
        .corr(corr), .duty_l(duty_l), .duty_r(duty_r),
        .wide(wide),
        .obstacle(obstacle),
        .state(state), .enc_l(enc_l), .enc_r(enc_r),
        .spd_l(spd_l), .spd_r(spd_r),
        .tx(tx)
    );

    integer fails = 0;
    reg [7:0] exp [0:95];       // 模块级：set_exp 写、check_line 读，只此一份

    task rx_byte (output [7:0] b);
        integer k;
        begin
            @(negedge tx);                  // 起始位下降沿
            #(BIT_NS * 1.5);                // 到 bit0 中心
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = tx;
                if (k != 7) #(BIT_NS);
            end
            #(BIT_NS * 0.5);                // 停在停止位中间
        end
    endtask

    // 期望串正文（不含 CR LF）摊进 exp[0..n-1]，再在末尾补 CR LF
    task set_exp (input integer n, input [8*96-1:0] s);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                exp[i] = s[(n-1-i)*8 +: 8];   // Verilog 串右对齐：最左字符在高位
            exp[n]   = 8'h0D;
            exp[n+1] = 8'h0A;
        end
    endtask

    task check_line (input integer n, input [8*32-1:0] tag);
        integer i;
        reg [7:0] b;
        begin
            for (i = 0; i < n; i = i + 1) begin
                rx_byte(b);
                if (b !== exp[i]) begin
                    $display("FAIL: %0s byte %0d = %02h, expect %02h", tag, i, b, exp[i]);
                    fails = fails + 1;
                end
            end
        end
    endtask

    task fire;   // 打一拍 dist_valid，走完整两行
        begin
            @(posedge clk);
            dist_valid = 1'b1;
            @(posedge clk);
            dist_valid = 1'b0;
        end
    endtask

    initial begin
        #500;
        rst_n = 1'b1;
        #2000;

        // ---------- 用例 1：正常一帧 ----------
        dist_cm = 16'd123; line = 8'b00011000; pos = 5'sd2;
        raw = 8'b00011000; corr = 11'sd36; duty_l = 11'd636; duty_r = 11'd564;
        obstacle = 1'b0; state = 3'd1;
        enc_l = 32'd123; enc_r = 32'hFFFFFFF0;
        spd_l = 16'sd5;  spd_r = -16'sd16;
        fire;
        set_exp(MSG_LEN-2, "D=123cm T=00011000 P=+02 O=0 M=01");
        check_line(MSG_LEN, "L1 ");
        set_exp(MSG2_LEN-2, "L=0000007B R=FFFFFFF0 VL=0005 VR=FFF0 X=00011000 C=+036 DL=27C DR=234 W=0");
        check_line(MSG2_LEN, "L2 ");
        #5000;

        // ---------- 用例 2：无效距离 + 障碍 + 永久停车 ----------
        dist_cm = 16'hFFFF; line = 8'b10000001; pos = -5'sd7;
        raw = 8'b01111110; corr = -11'sd600; duty_l = 11'd0; duty_r = 11'd0;
        obstacle = 1'b1; state = 3'd4;
        enc_l = 32'd0; enc_r = 32'd0;
        spd_l = 16'sd0; spd_r = 16'sd0;
        fire;
        set_exp(MSG_LEN-2, "D=---cm T=10000001 P=-07 O=1 M=04");
        check_line(MSG_LEN, "L1b");
        set_exp(MSG2_LEN-2, "L=00000000 R=00000000 VL=0000 VR=0000 X=01111110 C=-600 DL=000 DR=000 W=0");
        check_line(MSG2_LEN, "L2b");
        #5000;

        // ---------- 用例 3：IDLE + 全丢线 + 负里程与负速度 ----------
        dist_cm = 16'd7; line = 8'h00; pos = 5'sd0;
        raw = 8'hFF; corr = 11'sd0; duty_l = 11'd1200; duty_r = 11'd1200;
        obstacle = 1'b0; state = 3'd0;
        enc_l = 32'h0000ABCD; enc_r = 32'hFFFFFFFF;
        spd_l = 16'sd1200;    spd_r = -16'sd1;
        fire;
        set_exp(MSG_LEN-2, "D=007cm T=00000000 P=+00 O=0 M=00");
        check_line(MSG_LEN, "L1c");
        set_exp(MSG2_LEN-2, "L=0000ABCD R=FFFFFFFF VL=04B0 VR=FFFF X=11111111 C=+000 DL=4B0 DR=4B0 W=0");
        check_line(MSG2_LEN, "L2c");
        #5000;

        // ---------- 用例 4：两位位置与三位距离的边界 ----------
        // 注意 5 位有符号的范围是 -16..+15，写 5'sd16 会被当成 -16
        dist_cm = 16'd999; line = 8'hFF; pos = 5'sd15;
        raw = 8'h00; corr = 11'sd600; duty_l = 11'd1200; duty_r = 11'd0;
        wide = 1'b1;                       // 八路全压 = 宽黑（影子），W= 应该出 1
        obstacle = 1'b0; state = 3'd3;
        enc_l = 32'h7FFFFFFF; enc_r = 32'h80000000;
        spd_l = 16'sd32767;   spd_r = -16'sd32768;
        fire;
        set_exp(MSG_LEN-2, "D=999cm T=11111111 P=+15 O=0 M=03");
        check_line(MSG_LEN, "L1d");
        set_exp(MSG2_LEN-2, "L=7FFFFFFF R=80000000 VL=7FFF VR=8000 X=00000000 C=+600 DL=4B0 DR=000 W=1");
        check_line(MSG2_LEN, "L2d");
        #5000;

        // ---------- 用例 5：pos=-16 与 "50cm" 前导零 ----------
        dist_cm = 16'd50; line = 8'b00000001; pos = -5'sd16;
        raw = 8'b11111110; corr = -11'sd16; duty_l = 11'd584; duty_r = 11'd616;
        wide = 1'b0;
        obstacle = 1'b0; state = 3'd2;
        enc_l = 32'd0; enc_r = 32'd0;
        spd_l = 16'sd0; spd_r = 16'sd0;
        fire;
        set_exp(MSG_LEN-2, "D=050cm T=00000001 P=-16 O=0 M=02");
        check_line(MSG_LEN, "L1e");
        set_exp(MSG2_LEN-2, "L=00000000 R=00000000 VL=0000 VR=0000 X=11111110 C=-016 DL=248 DR=268 W=0");
        check_line(MSG2_LEN, "L2e");

        if (fails == 0) $display("INFO: uart_report_tb ALL PASS");
        else            $display("INFO: uart_report_tb %0d FAIL(S)", fails);
        $finish;
    end

    // 超时兜底：5 帧共 370 字节，115200 下一帧（两行）约 6.5 ms
    initial begin
        #60_000_000;
        $display("TIMEOUT: uart_report_tb hung (rstate=%0d idx=%0d idx2=%0d)",
                 u_dut.rstate, u_dut.idx, u_dut.idx2);
        $finish;
    end

endmodule
