`timescale 1ns/1ns

// Exercise the sensor-to-UART path with asynchronous clocks and a DDR AXI model.
module ov5640_ddr_snapshot_tb;
    localparam integer WIDTH = 128, HEIGHT = 16, PIXELS = WIDTH * HEIGHT;
    localparam [6:0] SLOTS = 7'd3;
    localparam integer FIFO_BITS = 5, BIT_CLOCKS = 12;
    localparam integer BIT_NS = BIT_CLOCKS * 10;
    reg clk = 0, pclk = 0, rst_n = 0;
    always #5 clk = !clk;
    always #7 pclk = !pclk;
    reg shoot = 0, href = 0, vsync = 0, uart_rx = 1;
    reg [7:0] data = 0;
    wire request, done, good, push, pop, full;
    wire [127:0] word, payload;
    wire [FIFO_BITS:0] available;
    wire active, busy, error;
    wire [6:0] photo_count;
    wire [5:0] read_slot;
    wire read_request, read_ready, read_error;
    wire [19:0] read_addr;
    wire [7:0] read_y;
    wire avalid, atype, wvalid, wlast, uart_tx;
    wire [31:0] aaddr;
    wire [7:0] alen;

    ov5640_photo_capture #(.WIDTH(WIDTH), .HEIGHT(HEIGHT)) camera (
        .pclk(pclk), .rst_n(rst_n), .href(href), .vsync(vsync), .data(data),
        .request(request), .done(done), .good(good), .full(full), .push(push), .word(word)
    );
    ov5640_photo_fifo #(.ADDRESS_BITS(FIFO_BITS)) fifo (
        .pclk(pclk), .sensor_rst_n(rst_n), .push(push), .word(word),
        .full(full), .clk(clk), .rst_n(rst_n), .pop(pop), .payload(payload), .available(available)
    );
    reg [127:0] memory [0:SLOTS*PIXELS/16-1];
    reg [127:0] rdata;
    reg bvalid = 0, rvalid = 0;
    reg [7:0] remaining = 0;
    integer word_index, cycles = 0;
    wire [31:0] model_addr = aaddr[25:20] * (PIXELS/16) + aaddr[19:4];
    // Throttle both command and write-data channels.
    wire aready = remaining == 0 && cycles % 7 == 2;
    wire wready = remaining != 0 && cycles % 5 == 3;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        bvalid <= 0;
        rvalid <= 0;
        if (avalid && aready) begin
            if (aaddr[3:0] != 0 || aaddr[31:26] != 0 || aaddr[25:20] >= SLOTS ||
                aaddr[19:4] >= PIXELS/16)
                $fatal(1, "invalid DDR byte address %h", aaddr);
            word_index <= model_addr;
            if (atype) begin
                remaining <= alen + 1;
            end else begin
                if (alen != 0) $fatal(1, "read requested more than one word");
                rdata <= memory[model_addr];
                rvalid <= 1;
            end
        end
        if (wvalid && wready) begin
            if (wlast != (remaining == 1)) $fatal(1, "incorrect WLAST");
            memory[word_index] <= payload;
            word_index <= word_index + 1;
            remaining <= remaining - 1;
            bvalid <= wlast;
        end
    end
    ov5640_photo_store #(.WIDTH(WIDTH), .HEIGHT(HEIGHT), .FIFO_BITS(FIFO_BITS), .SLOTS(SLOTS)) store (
        .clk(clk), .rst_n(rst_n), .shoot(shoot), .uart_active(active),
        .request(request), .capture_done(done), .capture_good(good),
        .busy(busy), .photo_count(photo_count), .error(error),
        .available(available), .pop(pop),
        .read_request(read_request), .read_slot(read_slot), .read_addr(read_addr), .read_y(read_y),
        .read_ready(read_ready), .read_error(read_error),
        .avalid(avalid), .atype(atype), .aaddr(aaddr), .alen(alen), .aready(aready),
        .wvalid(wvalid), .wlast(wlast), .wready(wready), .bvalid(bvalid), .bresp(2'b0),
        .rvalid(rvalid), .rlast(rvalid), .rresp(2'b0), .rdata(rdata)
    );
    ov5640_uart_snapshot #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .ADDRESS_WIDTH(20),
        .CLK_FREQ(BIT_CLOCKS * 1000), .BAUD(1000), .STORED_PHOTO(1), .ALBUM_SLOTS(SLOTS)
    ) serial (
        .clk(clk), .rst_n(rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .frame_valid(photo_count != 0 && !busy), .frame_release(),
        .photo_count(photo_count), .album_flags({error, busy, 1'b1}), .read_slot(read_slot),
        .read_addr(read_addr), .read_y(read_y), .sent(),
        .read_ready(read_ready), .read_error(read_error),
        .read_request(read_request), .active(active)
    );

    task pulse_vsync;
        begin
            @(negedge pclk) vsync = 1;
            repeat (4) @(negedge pclk);
            vsync = 0;
        end
    endtask
    task shoot_frame;
        input invert, malformed;
        integer x, y;
        begin
            @(negedge clk) shoot = 1;
            @(negedge clk) shoot = 0;
            repeat (5) @(negedge pclk);
            pulse_vsync;
            for (y = 0; y < HEIGHT; y = y+1) begin
                for (x = 0; x < WIDTH - (malformed && y == 0 ? 1 : 0); x = x+1) begin
                    @(negedge pclk) begin
                        href = 1;
                        data = ((x+y) % 3 == 0) ^ invert ? 8'hff : 8'h00;
                    end
                    @(negedge pclk);
                end
                @(negedge pclk) href = 0;
                repeat (3) @(negedge pclk);
            end
            pulse_vsync;
            wait (!busy);
            @(negedge clk);
        end
    endtask

    task send_byte;
        input [7:0] command;
        integer i;
        begin
            @(negedge clk) uart_rx = 0;
            for (i = 0; i < 8; i = i+1) begin
                #BIT_NS uart_rx = command[i];
            end
            #BIT_NS uart_rx = 1;
        end
    endtask
    task request_photo;
        input [7:0] command, number;
        begin
            send_byte(command);
            if (command == "G" || command == "T") begin
                #BIT_NS;
                send_byte(number);
            end
        end
    endtask
    task get_byte;
        output reg [7:0] value;
        integer i;
        begin
            @(negedge uart_tx);
            #(BIT_NS + BIT_NS/2);
            for (i = 0; i < 8; i = i+1) begin
                value[i] = uart_tx;
                #BIT_NS;
            end
            if (!uart_tx) $fatal(1, "bad UART stop bit");
        end
    endtask
    task expect_photo;
        input [7:0] command, number;
        input invert;
        reg [7:0] value, expected;
        reg [31:0] crc, received_crc;
        integer i, j, stride, w, h;
        begin
            stride = command == "T" ? 8 : 1;
            w = WIDTH / stride;
            h = HEIGHT / stride;
            request_photo(command, number);
            get_byte(value); if (value != "O") $fatal(1, "missing photo header");
            get_byte(value); if (value != "V") $fatal(1, "bad header byte 1");
            get_byte(value); if (value != "S") $fatal(1, "bad header byte 2");
            get_byte(value); if (value != "1") $fatal(1, "bad header byte 3");
            get_byte(value); if (value != w) $fatal(1, "bad width");
            get_byte(value); if (value != 0) $fatal(1, "bad width high byte");
            get_byte(value); if (value != h) $fatal(1, "bad height");
            get_byte(value); if (value != 0) $fatal(1, "bad height high byte");
            crc = 32'hffffffff;
            for (i = 0; i < w*h; i = i+1) begin
                get_byte(value);
                expected = ((((i % w + i / w) * stride) % 3 == 0) ^ invert) ? 8'hff : 8'h00;
                if (value !== expected) $fatal(1, "pixel %0d expected %h got %h", i, expected, value);
                crc = crc ^ value;
                for (j = 0; j < 8; j = j+1)
                    crc = (crc >> 1) ^ (crc[0] ? 32'hedb88320 : 32'd0);
            end
            for (i = 0; i < 4; i = i+1) begin
                get_byte(value);
                received_crc[8*i +: 8] = value;
            end
            if (received_crc !== ~crc) $fatal(1, "bad photo CRC");
            wait (!active);
        end
    endtask
    task expect_list;
        input [7:0] count, flags;
        reg [7:0] value;
        begin
            send_byte("L");
            get_byte(value); if (value != "O") $fatal(1, "missing album header");
            get_byte(value); if (value != "V") $fatal(1, "bad album header byte 1");
            get_byte(value); if (value != "A") $fatal(1, "bad album header byte 2");
            get_byte(value); if (value != "1") $fatal(1, "bad album header byte 3");
            get_byte(value); if (value != count) $fatal(1, "bad photo count");
            get_byte(value); if (value != SLOTS) $fatal(1, "bad album capacity");
            get_byte(value); if (value != flags) $fatal(1, "bad album flags");
            wait (!active);
        end
    endtask

    reg [7:0] response;
    initial begin
        repeat (6) @(negedge clk);
        rst_n = 1;
        expect_list(0, 1);
        send_byte("R");
        get_byte(response);
        if (response != "N") $fatal(1, "no-photo request should report N");
        wait (!active);
        shoot_frame(0, 0);
        if (photo_count != 1 || error) $fatal(1, "first independent capture failed");
        shoot_frame(1, 1);
        expect_list(1, 5);
        shoot_frame(1, 0);
        expect_list(2, 1);
        expect_photo("G", 1, 0);
        expect_photo("G", 2, 1);
        expect_photo("T", 1, 0);
        expect_photo("T", 2, 1);
        request_photo("G", 3);
        get_byte(response);
        if (response != "N") $fatal(1, "unpublished photo ID should report N");
        wait (!active);
        send_byte("T");
        wait (active);
        wait (!active);
        shoot_frame(0, 0);
        expect_list(3, 1);
        @(negedge clk) shoot = 1;
        @(negedge clk) shoot = 0;
        if (busy || photo_count != SLOTS) $fatal(1, "full album accepted another shot");
        expect_photo("R", 0, 0);
        expect_photo("T", 2, 1);
        $display("PASS: album count, immutable slots, selected and latest photos, thumbnails, UART CRC, full album");
        $finish;
    end
    initial begin
        #15000000;
        $fatal(1, "snapshot bench timed out");
    end
endmodule
