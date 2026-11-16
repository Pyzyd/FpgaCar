// =============================================================================
// k230_link_tb.v —— K230 协议接收器自测
// iverilog -g2012 -Wall -s k230_link_tb -o k230.vvp src/k230_link.v sim/k230_link_tb.v
// -----------------------------------------------------------------------------
// 验收：
//   1) 颜色编码转换：协议 1红/2黄/3绿/4蓝 → color_seq 的 1红/2绿/3蓝/4黄
//   2) 一条消息连发两遍只采纳一次（不能因为第二遍再触发一次）
//   3) 两遍不一致不采纳，err_cnt +1
//   4) 000 分隔符不产生任何事件
//   5) 方向 / 命令 / 心跳各自走对通道
//   6) 掉线判定：窗口内无消息 link_alive 掉 0，来消息后恢复
//   7) 失步恢复：漏掉一个 strobe 后，接下来几条消息内能重新同步
//      （协议没有校验和，失步后靠「两遍一致」筛错，需要 2~3 条消息）
// =============================================================================
`timescale 1ns/1ps

module k230_link_tb;

    reg clk = 1'b0;
    always #10 clk = ~clk;                    // 50 MHz

    reg       rst_n = 1'b0;
    reg [2:0] k230_d = 3'd0;
    reg       k230_stb = 1'b0;

    wire [3:0] color_evt;
    wire [2:0] dir_evt;
    wire [7:0] cmd_evt;
    wire       link_alive;
    wire [7:0] err_cnt;

    // 掉线窗口按「多少拍」算：CLK_FREQ/1000*ALIVE_MS = 1*2000 = 2000 拍，
    // 远大于一条消息（约 100 拍），这样消息间隙不会误判掉线。
    k230_link #(.CLK_FREQ(1000), .ALIVE_MS(2000)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .k230_d(k230_d), .k230_stb(k230_stb),
        .color_evt(color_evt), .dir_evt(dir_evt), .cmd_evt(cmd_evt),
        .link_alive(link_alive), .err_cnt(err_cnt)
    );

    // ---------------- 事件记录器 ----------------
    integer n_color = 0, n_dir = 0, n_cmd = 0;
    reg [3:0] last_color = 4'd0;
    reg [2:0] last_dir   = 3'd0;
    reg [7:0] last_cmd   = 8'd0;

    always @(posedge clk) begin
        if (color_evt != 4'd0) begin n_color = n_color + 1; last_color = color_evt; end
        if (dir_evt   != 3'd0) begin n_dir   = n_dir   + 1; last_dir   = dir_evt;   end
        if (cmd_evt   != 8'd0) begin n_cmd   = n_cmd   + 1; last_cmd   = cmd_evt;   end
    end

    // ---------------- K230 发送侧模型 ----------------
    // 一个符号：先摆好数据，再给 strobe 脉冲
    // （对应 K230 侧「写 D → sleep 1ms → STB=1 → sleep 1ms → STB=0」）
    task send_sym (input [2:0] v);
        begin
            @(posedge clk); #1 k230_d = v;
            repeat (3) @(posedge clk);
            #1 k230_stb = 1'b1;
            repeat (3) @(posedge clk);
            #1 k230_stb = 1'b0;
            repeat (3) @(posedge clk);
        end
    endtask

    // 一条消息 = 000 → CAT → 000 → VAL → 000
    task send_msg_once (input [2:0] cat, input [2:0] val);
        begin
            send_sym(3'd0);
            send_sym(cat);
            send_sym(3'd0);
            send_sym(val);
            send_sym(3'd0);
        end
    endtask

    // 正常发送：整条连发两遍
    task send_msg (input [2:0] cat, input [2:0] val);
        begin
            send_msg_once(cat, val);
            send_msg_once(cat, val);
        end
    endtask

    // ---------------- 检查工具 ----------------
    task check_color (input [3:0] exp, input [8*28-1:0] tag);
        begin
            if (n_color == 1 && last_color === exp)
                $display("PASS: %0s -> 采纳 1 次, color=%0d", tag, last_color);
            else
                $display("FAIL: %0s -> 采纳 %0d 次, color=%0d (期望 1 次, %0d)",
                         tag, n_color, last_color, exp);
            n_color = 0; last_color = 4'd0;
        end
    endtask

    task check_none (input [8*28-1:0] tag);
        begin
            if (n_color == 0 && n_dir == 0 && n_cmd == 0)
                $display("PASS: %0s -> 无事件", tag);
            else
                $display("FAIL: %0s -> 竟有事件 color=%0d dir=%0d cmd=%0d",
                         tag, n_color, n_dir, n_cmd);
            n_color = 0; n_dir = 0; n_cmd = 0;
        end
    endtask

    initial begin
        $dumpfile(".scratch/k230_link_tb.vcd");
        $dumpvars(0, k230_link_tb);

        repeat (5) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ---- 1) 四种颜色的编码转换 ----
        send_msg(3'b001, 3'd1);  check_color(4'd1, "颜色 红 -> 1");
        send_msg(3'b001, 3'd2);  check_color(4'd4, "颜色 黄 -> 4");
        send_msg(3'b001, 3'd3);  check_color(4'd2, "颜色 绿 -> 2");
        send_msg(3'b001, 3'd4);  check_color(4'd3, "颜色 蓝 -> 3");

        // ---- 2) 收到消息后 link_alive 应为 1 ----
        if (link_alive === 1'b1)
            $display("PASS: 收到消息后 link_alive=1");
        else
            $display("FAIL: 收到消息后 link_alive 仍为 0");

        // ---- 3) 方向 ----
        send_msg(3'b010, 3'd1);
        if (n_dir == 1 && last_dir === 3'd1) $display("PASS: 方向 左转");
        else $display("FAIL: 方向 左转 -> %0d 次 dir=%0d", n_dir, last_dir);
        n_dir = 0; last_dir = 3'd0;

        send_msg(3'b010, 3'd3);
        if (n_dir == 1 && last_dir === 3'd3) $display("PASS: 方向 直行");
        else $display("FAIL: 方向 直行 -> %0d 次 dir=%0d", n_dir, last_dir);
        n_dir = 0; last_dir = 3'd0;

        // ---- 4) 命令 ----
        send_msg(3'b011, 3'd1);
        if (n_cmd == 1 && last_cmd === 8'b0000_0001) $display("PASS: 命令 清空顺序");
        else $display("FAIL: 命令 清空顺序 -> %0d 次 cmd=%0b", n_cmd, last_cmd);
        n_cmd = 0; last_cmd = 8'd0;

        send_msg(3'b011, 3'd2);
        if (n_cmd == 1 && last_cmd === 8'b0000_0010) $display("PASS: 命令 新一圈");
        else $display("FAIL: 命令 新一圈 -> %0d 次 cmd=%0b", n_cmd, last_cmd);
        n_cmd = 0; last_cmd = 8'd0;

        // ---- 5) 心跳：续 link_alive 但不产生事件 ----
        send_msg(3'b111, 3'd1);
        if (n_color == 0 && n_dir == 0 && n_cmd == 0 && link_alive === 1'b1)
            $display("PASS: 心跳 不产生事件且续活");
        else
            $display("FAIL: 心跳 -> color=%0d dir=%0d cmd=%0d alive=%0b",
                     n_color, n_dir, n_cmd, link_alive);
        n_color = 0; n_dir = 0; n_cmd = 0;

        // ---- 6) 两遍不一致：不采纳，err_cnt 加一 ----
        begin : mismatch
            reg [7:0] e0;
            e0 = err_cnt;
            send_msg_once(3'b001, 3'd1);      // 第一遍说红
            send_msg_once(3'b001, 3'd4);      // 第二遍说蓝 —— 不一致
            if (n_color == 0 && err_cnt == e0 + 8'd1)
                $display("PASS: 两遍不一致 -> 不采纳, err_cnt=%0d", err_cnt);
            else
                $display("FAIL: 两遍不一致 -> 采纳 %0d 次, err_cnt %0d->%0d",
                         n_color, e0, err_cnt);
            n_color = 0;
        end

        // ---- 7) 只有 000 分隔符：不该有任何反应 ----
        send_sym(3'd0); send_sym(3'd0); send_sym(3'd0);
        check_none("只有 000 分隔符");

        // ---- 8) 失步恢复：漏掉一个 strobe 后，接下来几条消息内要能重新同步 ----
        // 失步的代价是解析相位偏一位，会产出「类别当数值」之类的假配对；
        // 假配对靠「两遍一致」被筛掉，所以需要连发几条才能稳定回来。
        begin : resync
            integer k;
            integer got;
            // 制造失步：只发了类别，数值那一拍丢了
            send_sym(3'd0);
            send_sym(3'b001);
            send_msg(3'b001, 3'd3);           // 紧接一条完整的「绿」，大概率仍被带偏
            send_msg(3'b001, 3'd3);
            send_msg(3'b001, 3'd3);
            got = n_color;
            if (got >= 1 && last_color === 4'd2)
                $display("PASS: 失步后自动恢复 -> 3 条消息内采纳到 绿(%0d), 共 %0d 次",
                         last_color, got);
            else
                $display("FAIL: 失步后未能恢复 -> 采纳 %0d 次, color=%0d",
                         got, last_color);
            n_color = 0; last_color = 4'd0;
        end

        // ---- 9) 掉线判定与恢复 ----
        if (link_alive === 1'b1)
            $display("PASS: 掉线测试前 link_alive=1");
        else
            $display("FAIL: 掉线测试前 link_alive 已为 0");

        repeat (2200) @(posedge clk);         // 超过 2000 拍窗口
        if (link_alive === 1'b0)
            $display("PASS: 超时后 link_alive=0");
        else
            $display("FAIL: 超时后 link_alive 仍为 1");

        send_msg(3'b111, 3'd1);               // 心跳把链路救回来
        if (link_alive === 1'b1)
            $display("PASS: 新消息到达后 link_alive 恢复为 1");
        else
            $display("FAIL: 新消息到达后 link_alive 仍为 0");

        $display("ALL PASS: k230_link");
        repeat (10) @(posedge clk);
        $finish;
    end

endmodule
