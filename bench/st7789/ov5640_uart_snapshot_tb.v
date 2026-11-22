`timescale 1ns/1ns

module ov5640_uart_snapshot_tb;
    localparam integer BIT_CYCLES = 24;
    reg clk = 0, pclk = 0, rst_n = 0;
    always #5 clk = ~clk;
    always #7 pclk = ~pclk;
    reg href = 0, vsync = 0, rx = 1;
    reg [7:0] data = 0;
    wire tx, frame_valid, frame_release, sent;
    wire [3:0] addr;
    wire [7:0] sample;
    integer tx_edges = 0;
    always @(negedge tx) if (rst_n) tx_edges = tx_edges+1;

    ov5640_preview_frame #(.INPUT_WIDTH(8), .INPUT_HEIGHT(6), .SAMPLE_LOG2(1),
                            .ADDRESS_WIDTH(4)) camera (
        .clk(clk), .rst_n(rst_n), .pclk(pclk), .href(href), .vsync(vsync), .data(data),
        .frame_release(frame_release), .frame_valid(frame_valid), .read_addr(addr), .read_y(sample)
    );
    ov5640_uart_snapshot #(.WIDTH(4), .HEIGHT(3), .ADDRESS_WIDTH(4),
                            .CLK_FREQ(24_000_000), .BAUD(1_000_000)) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(rx), .uart_tx(tx),
        .frame_valid(frame_valid), .frame_release(frame_release),
        .read_addr(addr), .read_y(sample), .sent(sent)
    );

    task frame_boundary;
        begin
            @(negedge pclk); vsync = 1;
            repeat (3) @(negedge pclk);
            vsync = 0;
            repeat (2) @(negedge pclk);
        end
    endtask

    task write_frame(input integer green_base, input malformed);
        integer row, col, columns;
        reg [5:0] green;
        reg [15:0] rgb;
        begin
            for (row=0; row<6; row=row+1) begin
                columns = (malformed && row==1) ? 7 : 8;
                for (col=0; col<columns; col=col+1) begin
                    green = green_base + (row/2)*4 + col/2;
                    rgb = {5'b0, green, 5'b0};
                    @(negedge pclk); href = 1; data = rgb[15:8];
                    @(negedge pclk); data = rgb[7:0];
                end
                @(negedge pclk); href = 0;
                repeat (2) @(negedge pclk);
            end
            frame_boundary();
        end
    endtask

    task command(input [7:0] value, input good_stop);
        integer bit_no;
        begin
            @(negedge clk); rx = 0;
            repeat (BIT_CYCLES) @(negedge clk);
            for (bit_no=0; bit_no<8; bit_no=bit_no+1) begin
                rx = value[bit_no];
                repeat (BIT_CYCLES) @(negedge clk);
            end
            rx = good_stop;
            repeat (BIT_CYCLES) @(negedge clk);
            rx = 1;
        end
    endtask

    task receive_byte(output reg [7:0] value);
        integer bit_no;
        begin
            @(negedge tx);
            repeat (BIT_CYCLES+BIT_CYCLES/2) @(posedge clk);
            for (bit_no=0; bit_no<8; bit_no=bit_no+1) begin
                value[bit_no] = tx;
                repeat (BIT_CYCLES) @(posedge clk);
            end
            if (tx !== 1'b1) $fatal(1, "Bad stop bit in outgoing UART");
        end
    endtask

    task check_photo(input [95:0] expected_y, input [31:0] expected_crc);
        reg [7:0] packet [0:23];
        integer n;
        begin
            for (n=0; n<24; n=n+1) receive_byte(packet[n]);
            if ({packet[0],packet[1],packet[2],packet[3],packet[4],packet[5],packet[6],packet[7]}
                !== 64'h4f56533104000300)
                $fatal(1, "Photo header mismatch");
            for (n=0; n<12; n=n+1)
                if (packet[n+8] !== expected_y[95-n*8 -: 8])
                    $fatal(1, "Pixel %0d is %h, expected %h", n, packet[n+8], expected_y[95-n*8 -: 8]);
            if ({packet[23],packet[22],packet[21],packet[20]} !== expected_crc)
                $fatal(1, "Payload CRC32 mismatch");
        end
    endtask

    initial begin
        // Real asynchronous reset edge before exercising both clock domains.
        #1 rst_n = 1;
        #1 rst_n = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (7) @(negedge pclk);
        frame_boundary();
        write_frame(1,0);
        wait (frame_valid);
        command("X",1);
        command("S",0);
        repeat (BIT_CYCLES*2) @(negedge clk);
        if (!frame_valid || tx_edges!=0) $fatal(1, "Invalid commands changed the snapshot");

        fork
            begin
                command("S",1);
                wait (!frame_valid);
                frame_boundary();
                write_frame(8,1);
                repeat (5) @(negedge clk);
                if (frame_valid || tx_edges!=0) $fatal(1, "Malformed DVP frame transmitted");
                write_frame(17,0);
            end
            check_photo(96'h26292b2d2f323436383b3d3f,32'hda04e756);
        join
        wait (sent);
        if (!frame_valid) $fatal(1, "Snapshot released before the next command");

        fork
            begin
                command("S",1);
                wait (!frame_valid);
                frame_boundary();
                write_frame(33,0);
            end
            check_photo(96'h4b4d4f525456585b5d5f6164,32'h4224a000);
        join
        wait (sent);
        $display("PASS: UART commands, fresh DVP photos, malformed-frame retry, pixel order and CRC32");
        $finish;
    end

    initial begin
        #250000;
        $fatal(1, "Capture simulation timeout");
    end
endmodule
