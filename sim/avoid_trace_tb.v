`timescale 1ns/1ns

module avoid_trace_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, run_enable = 0, host_tx = 1;
    reg [3:0] phase = 0;
    reg [143:0] snapshot = 0;
    wire tx, busy;
    avoid_trace #(.CLK_FREQ(8000), .BAUD(1000), .SAMPLE_MS(1), .ADDR_W(2)) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(host_tx), .run_enable(run_enable),
        .phase(phase), .snapshot(snapshot), .tx(tx), .busy(busy)
    );

    reg [7:0] packet [0:90];
    integer received = 0;
    always @(posedge clk) begin
        if (dut.send) begin
            packet[received] = dut.send_byte;
            received = received + 1;
        end
    end

    task clocks(input integer n);
        repeat(n) @(negedge clk);
    endtask
    task command(input [7:0] value);
        integer bit_index;
        begin
            host_tx = 0;
            clocks(8);
            for (bit_index=0; bit_index<8; bit_index=bit_index+1) begin
                host_tx = value[bit_index];
                clocks(8);
            end
            host_tx = 1;
            clocks(8);
        end
    endtask
    task read_packet;
        begin
            received = 0;
            command("G");
            while (!busy) clocks(1);
            while (busy) clocks(1);
        end
    endtask

    task check(input condition, input [8*75-1:0] label);
        begin
            if (condition !== 1'b1) $fatal(1, "FAIL: %0s",label);
            $display("PASS: %0s",label);
        end
    endtask

    integer i, bit_index;
    reg [15:0] checksum;
    initial begin
        clocks(3);
        rst_n = 1;
        read_packet;
        check(received == 11 && packet[6] == 0 && packet[8] == 0, "empty packet format");
        run_enable = 1;
        for (i=1; i<=8; i=i+1) begin
            phase = i[3:0];
            snapshot[143:136] = i[7:0];
            clocks(1);
        end
        phase = 4'hf;
        snapshot[143:136] = 8'hf6;
        clocks(1);
        run_enable = 0;
        clocks(5);
        check(dut.frozen && dut.count == 4, "fault freezes full circular buffer");
        read_packet;
        check(received == 91 && {packet[0],packet[1],packet[2],packet[3],packet[4],packet[5]} ==
              48'ha5415644315a && packet[6] == 4 && packet[8] == 1,
              "UART command returns trace header and four rows");
        check(packet[28] == 6 && packet[48] == 7 && packet[68] == 8 && packet[88] == 8'hf6,
              "chronological ring order, including final fault record");
        checksum = 16'hffff;
        for (i=6; i<89; i=i+1) begin
            checksum = checksum ^ (16'(packet[i]) << 8);
            for (bit_index=0; bit_index<8; bit_index=bit_index+1)
                checksum = checksum[15] ? (checksum << 1) ^ 16'h1021 : checksum << 1;
        end
        check({packet[90],packet[89]} == checksum, "packet CRC includes header and payload");
        phase = 0; run_enable = 1;
        clocks(10);
        command("C");
        command("!");
        check(dut.frozen && dut.count == 4, "running car cannot clear frozen trace");
        run_enable = 0;
        clocks(2);
        read_packet;
        check(received == 91 && packet[88] == 8'hf6, "reading again preserves failed run");
        command("C");
        check(dut.frozen, "single clear-prefix byte cannot erase the trace");
        command("!");
        clocks(2);
        read_packet;
        check(received == 11 && packet[6] == 0 && packet[8] == 0, "explicit clear when stopped re-arms");
        run_enable = 1;
        clocks(3);
        run_enable = 0;
        clocks(2);
        check(dut.frozen && dut.count != 0,"K2 freezes an incomplete run");
        $finish;
    end

    initial begin
        #250000;
        $fatal(1,"FAIL: trace test watchdog");
    end
endmodule
