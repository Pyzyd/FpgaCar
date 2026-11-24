`timescale 1ns/1ns

module avoid_trace #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer BAUD = 115_200,
    parameter integer SAMPLE_MS = 25,
    parameter integer ADDR_W = 10
) (
    input wire clk, rst_n, uart_rx,
    input wire run_enable,
    input wire [3:0] phase,
    input wire [143:0] snapshot,
    output wire tx, busy
);
    localparam integer DEPTH = 1 << ADDR_W;
    localparam integer MS_DIV = CLK_FREQ / 1000;
    localparam integer MS_W = (MS_DIV < 2) ? 1 : $clog2(MS_DIV);
    reg [MS_W-1:0] divider;
    wire ms_tick = (divider == MS_DIV - 1);
    reg [15:0] milliseconds;
    reg [15:0] sample_timer;
    reg [3:0] old_phase;
    reg was_running, frozen;
    reg [ADDR_W-1:0] write_at;
    reg [ADDR_W:0] count;

    localparam integer DIV = CLK_FREQ / BAUD;
    localparam [1:0] RX_IDLE = 0, RX_START = 1, RX_DATA = 2, RX_STOP = 3;
    reg [1:0] rx_sync, rx_state;
    reg [15:0] rx_count;
    reg [2:0] rx_bit;
    reg [7:0] rx_data;
    reg rx_valid;

    // 起始位中点确认，此后采每一位的中点。收串口不会控制电机。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync <= 2'b11;
            rx_state <= RX_IDLE;
            rx_count <= 0;
            rx_bit <= 0;
            rx_data <= 0;
            rx_valid <= 0;
        end else begin
            rx_sync <= {rx_sync[0], uart_rx};
            rx_valid <= 0;
            if (rx_state == RX_IDLE) begin
                if (!rx_sync[1]) begin
                    rx_count <= DIV / 2 - 1;
                    rx_state <= RX_START;
                end
            end else if (rx_count != 0) begin
                rx_count <= rx_count - 1'b1;
            end else begin
                rx_count <= DIV - 1;
                case (rx_state)
                    RX_START: begin
                        rx_state <= rx_sync[1] ? RX_IDLE : RX_DATA;
                        rx_bit <= 0;
                    end
                    RX_DATA: begin
                        rx_data <= {rx_sync[1], rx_data[7:1]};
                        rx_bit <= rx_bit + 1'b1;
                        if (rx_bit == 7) rx_state <= RX_STOP;
                    end
                    RX_STOP: begin
                        rx_valid <= rx_sync[1];
                        rx_state <= RX_IDLE;
                    end
                    default: rx_state <= RX_IDLE;
                endcase
            end
        end
    end

    reg clear_prefix;
    reg [15:0] clear_stamp;
    wire [15:0] since_clear_prefix = milliseconds - clear_stamp;
    wire capture_end = (was_running && !run_enable) || (run_enable && (phase == 4'd9 || phase == 4'hf));
    // 拔掉串口时，单个噪声字节也不会擦除已保存的试车记录。
    wire clear = rx_valid && rx_data == "!" && clear_prefix &&
                 since_clear_prefix <= 16'd25 && !run_enable && !busy;
    wire sample_now = !frozen && (run_enable || capture_end) &&
                      ((!was_running && run_enable) || phase != old_phase || capture_end ||
                       (ms_tick && sample_timer == SAMPLE_MS - 1));
    reg [159:0] mem [0:DEPTH-1];
    reg [ADDR_W-1:0] read_at;
    reg [159:0] read_row;

    // 同步读写，直接映射到 Ti60 块 RAM。
    always @(posedge clk) begin
        if (sample_now) mem[write_at] <= {snapshot, milliseconds};
        read_row <= mem[read_at];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divider <= 0;
            milliseconds <= 0;
            sample_timer <= 0;
            old_phase <= 0;
            was_running <= 0;
            write_at <= 0;
            count <= 0;
            frozen <= 0;
            clear_prefix <= 0;
            clear_stamp <= 0;
        end else begin
            divider <= ms_tick ? 0 : divider + 1'b1;
            if (ms_tick) milliseconds <= milliseconds + 1'b1;
            old_phase <= phase;
            was_running <= run_enable;
            if (rx_valid) begin
                clear_prefix <= (rx_data == "C");
                clear_stamp <= milliseconds;
            end else if (since_clear_prefix > 16'd25) begin
                clear_prefix <= 0;
            end
            if (clear) begin
                sample_timer <= 0;
                write_at <= 0;
                count <= 0;
                frozen <= 0;
            end else if (sample_now) begin
                sample_timer <= 0;
                write_at <= write_at + 1'b1;
                if (count < DEPTH) count <= count + 1'b1;
                if (capture_end) frozen <= 1;
            end else if (run_enable && !frozen && ms_tick) begin
                sample_timer <= sample_timer + 1'b1;
            end
        end
    end

    localparam [2:0] IDLE = 0, QUIET = 1, HEADER = 2, LOAD = 3,
                     DATA = 4, CHECKSUM = 5, FINISH = 6;
    reg [2:0] stage;
    reg [1:0] quiet_elapsed;
    reg [4:0] byte_index;
    reg [15:0] rows_left, send_count;
    reg send_frozen;
    reg [15:0] crc;
    reg [7:0] send_byte;
    wire sending = (stage == HEADER || stage == DATA || stage == CHECKSUM);
    wire uart_busy;
    wire send = sending && !uart_busy;
    assign busy = stage != IDLE;

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) sender (
        .clk(clk), .rst_n(rst_n), .data(send_byte), .start(send), .tx(tx), .busy(uart_busy)
    );

    function [15:0] crc_next;
        input [15:0] previous;
        input [7:0] value;
        integer i;
        reg [15:0] work;
        begin
            work = previous ^ {value, 8'h00};
            for (i=0; i<8; i=i+1)
                work = work[15] ? (work << 1) ^ 16'h1021 : work << 1;
            crc_next = work;
        end
    endfunction

    always @(*) begin
        send_byte = 0;
        case (stage)
            HEADER: case (byte_index)
                0: send_byte = 8'ha5;
                1: send_byte = "A";
                2: send_byte = "V";
                3: send_byte = "D";
                4: send_byte = "1";
                5: send_byte = 8'h5a;
                6: send_byte = send_count[7:0];
                7: send_byte = send_count[15:8];
                8: send_byte = {7'd0, send_frozen};
                default: send_byte = 0;
            endcase
            DATA: send_byte = read_row[8 * byte_index +: 8];
            CHECKSUM: send_byte = (byte_index == 0) ? crc[7:0] : crc[15:8];
            default: send_byte = 0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage <= IDLE;
            quiet_elapsed <= 0;
            byte_index <= 0;
            read_at <= 0;
            rows_left <= 0;
            send_count <= 0;
            send_frozen <= 0;
            crc <= 16'hffff;
        end else begin
            case (stage)
                IDLE: if (rx_valid && rx_data == "G") begin
                    send_count <= frozen ? count : 0;
                    rows_left <= frozen ? count : 0;
                    send_frozen <= frozen;
                    read_at <= write_at - count[ADDR_W-1:0];
                    byte_index <= 0;
                    quiet_elapsed <= 0;
                    crc <= 16'hffff;
                    stage <= QUIET;
                end
                // 切换发送源后留两个毫秒，让 USB 串口结束旧文本字节。
                QUIET: if (ms_tick) begin
                    quiet_elapsed <= quiet_elapsed + 1'b1;
                    if (quiet_elapsed == 2) stage <= HEADER;
                end
                HEADER: if (send) begin
                    if (byte_index >= 6) crc <= crc_next(crc, send_byte);
                    if (byte_index == 8) begin
                        byte_index <= 0;
                        stage <= (rows_left == 0) ? CHECKSUM : LOAD;
                    end else byte_index <= byte_index + 1'b1;
                end
                LOAD: stage <= DATA;
                DATA: if (send) begin
                    crc <= crc_next(crc, send_byte);
                    if (byte_index == 19) begin
                        byte_index <= 0;
                        rows_left <= rows_left - 1'b1;
                        read_at <= read_at + 1'b1;
                        stage <= (rows_left == 1) ? CHECKSUM : LOAD;
                    end else byte_index <= byte_index + 1'b1;
                end
                CHECKSUM: if (send) begin
                    if (byte_index == 1) stage <= FINISH;
                    else byte_index <= 1;
                end
                FINISH: if (!uart_busy) stage <= IDLE;
                default: stage <= IDLE;
            endcase
        end
    end
endmodule
