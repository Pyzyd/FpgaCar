// =============================================================================
// color_seq_tb.v —— 颜色顺序记录自测
// iverilog -g2012 -Wall -s color_seq_tb -o cs.vvp src/color_seq.v sim/color_seq_tb.v
// -----------------------------------------------------------------------------
// 验收：
//   1) 0（中性色）不计入顺序
//   2) 重复颜色只记一次，顺序保持「先到先得」
//   3) 4 个槽填满后 complete=1，之后再来新颜色也不覆盖
//   4) clr 能清空并重新开始
// =============================================================================
`timescale 1ns/1ps

module color_seq_tb;

    reg clk = 1'b0;
    always #10 clk = ~clk;          // 50 MHz，仅用于打拍

    reg       rst_n = 1'b0;
    reg [2:0] color_in = 3'd0;
    reg       new_color = 1'b0;
    reg       clr = 1'b0;

    wire [2:0] seq0, seq1, seq2, seq3, cnt;
    wire       seq_valid, complete;

    color_seq u_dut (
        .clk(clk), .rst_n(rst_n),
        .color_in(color_in), .new_color(new_color), .clr(clr),
        .seq0(seq0), .seq1(seq1), .seq2(seq2), .seq3(seq3),
        .cnt(cnt), .seq_valid(seq_valid), .complete(complete)
    );

    integer pulses = 0;
    always @(posedge clk) if (seq_valid) pulses = pulses + 1;

    task push (input [2:0] c);
        begin
            @(posedge clk); #1;
            color_in  = c;
            new_color = 1'b1;
            @(posedge clk); #1;
            new_color = 1'b0;
            color_in  = 3'd0;
            @(posedge clk); #1;
        end
    endtask

    task expect_seq (input [2:0] e0, input [2:0] e1, input [2:0] e2, input [2:0] e3,
                     input [2:0] ec, input [8*20-1:0] tag);
        begin
            if (seq0 === e0 && seq1 === e1 && seq2 === e2 && seq3 === e3 && cnt === ec)
                $display("PASS: %0s -> seq = %0d %0d %0d %0d (cnt=%0d)",
                         tag, seq0, seq1, seq2, seq3, cnt);
            else
                $display("FAIL: %0s -> seq = %0d %0d %0d %0d (cnt=%0d), expect %0d %0d %0d %0d (cnt=%0d)",
                         tag, seq0, seq1, seq2, seq3, cnt, e0, e1, e2, e3, ec);
        end
    endtask

    initial begin
        #100 rst_n = 1'b1;
        @(posedge clk); #1;

        // 0 = 中性色，必须被忽略
        push(3'd0);
        expect_seq(0, 0, 0, 0, 0, "ignore neutral");

        push(3'd1);                     // 红
        expect_seq(1, 0, 0, 0, 1, "red first");

        push(3'd3);                     // 蓝
        expect_seq(1, 3, 0, 0, 2, "blue second");

        push(3'd1);                     // 红（重复，丢弃）
        expect_seq(1, 3, 0, 0, 2, "duplicate red dropped");

        push(3'd2);                     // 绿
        push(3'd4);                     // 黄 -> 满
        expect_seq(1, 3, 2, 4, 4, "green/yellow fill");
        if (complete === 1'b1) $display("PASS: complete asserted after 4 colors");
        else                   $display("FAIL: complete = %0b after 4 colors", complete);

        push(3'd2);                     // 满了以后的重复/新颜色都不该动
        push(3'd3);
        expect_seq(1, 3, 2, 4, 4, "full list is frozen");

        if (pulses == 4) $display("PASS: exactly 4 seq_valid pulses (one per new color)");
        else             $display("FAIL: seq_valid pulses = %0d (expect 4)", pulses);

        // clr 重新开始
        @(posedge clk); #1; clr = 1'b1;
        @(posedge clk); #1; clr = 1'b0;
        @(posedge clk); #1;
        expect_seq(0, 0, 0, 0, 0, "cleared");
        if (complete === 1'b0) $display("PASS: complete deasserted after clear");
        else                   $display("FAIL: complete still high after clear");

        push(3'd2);
        push(3'd3);
        expect_seq(2, 3, 0, 0, 2, "restart after clear");

        $display("INFO: color_seq_tb done");
        $finish;
    end

endmodule
