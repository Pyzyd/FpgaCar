`timescale 1ns/1ns
module encoder_input_filter_tb;
    reg clk=0, rst_n=0;
    reg [1:0] raw=0;
    wire [1:0] clean;
    wire [31:0] position, right_position;
    always #5 clk=~clk;
    encoder_input_filter #(.STABLE_TICKS(6)) filter (
        .clk(clk), .rst_n(rst_n), .raw(raw), .settled(clean)
    );
    encoder_dec decoder (
        .clk(clk), .rst_n(rst_n), .a(clean[1]), .b(clean[0]),
        .step(), .direction(), .position(position)
    );
    encoder_dec right_decoder (
        .clk(clk), .rst_n(rst_n), .a(clean[0]), .b(clean[1]),
        .step(), .direction(), .position(right_position)
    );
    task ticks(input integer n);
        repeat (n) @(negedge clk);
    endtask
    initial begin
        ticks(4); rst_n=1;
        raw=2'b10; ticks(2); raw=0; ticks(14);
        if (clean != 0 || position != 0 || right_position != 0)
            $fatal(1, "Short pulse counted.");
        raw=2'b10; ticks(14);
        raw=2'b11; ticks(14);
        raw=2'b01; ticks(14);
        raw=2'b00; ticks(14);
        if (position != 32'hfffffffc || right_position != 4)
            $fatal(1, "Quadrature count or right-wheel sign is wrong.");
        $display("PASS: glitch discarded; four quadrature edges; right-wheel sign inverted.");
        $finish;
    end
endmodule
