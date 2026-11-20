`timescale 1ns/1ns

// Standalone bench: K1 takes one photo; the CH340N UART reads the saved photo.
module Ov5640DdrSnapshot (
    input wire clk_sys, sys_pll_lock, ddr_pll_lock,
    input wire tdqss_clk, core_clk, tac_clk, twd_clk,
    output wire sys_pll_rstn_o, ddr_pll_rstn_o,
    output wire [2:0] shift,
    output wire [4:0] shift_sel,
    output wire shift_ena,
    output wire [15:0] addr,
    output wire [2:0] ba,
    output wire we, reset, ras, cas, odt, cke, cs,
    output wire clk_p_hi, clk_p_lo, clk_n_hi, clk_n_lo,
    input wire [15:0] i_dq_hi, i_dq_lo,
    output wire [15:0] o_dq_hi, o_dq_lo, o_dq_oe,
    output wire [1:0] o_dm_hi, o_dm_lo,
    input wire [1:0] i_dqs_hi, i_dqs_lo, i_dqs_n_hi, i_dqs_n_lo,
    output wire [1:0] o_dqs_hi, o_dqs_lo, o_dqs_n_hi, o_dqs_n_lo, o_dqs_oe, o_dqs_n_oe,
    input wire cmos_pclk, cmos_href, cmos_vsync,
    input wire [7:0] cmos_data,
    input wire cmos_sdat_IN,
    output wire cmos_sclk, cmos_sdat_OUT, cmos_sdat_OE,
    output wire cmos_ctl1, cmos_rst_n, cmos_pwdn,
    input wire key_start_n, uart_rx,
    output wire uart_tx,
    output wire [5:0] led,
    output wire motor_stby, ml_pwm, mr_pwm, ml_in1, ml_in2, mr_in1, mr_in2
);
    localparam integer WIDTH = 1280, HEIGHT = 720;
    localparam integer CLOCK_HZ = 96_000_000, BAUD = 460_800;
    localparam integer KEY_TICKS = CLOCK_HZ / 50;
    localparam integer FIFO_BITS = 10;
    localparam [6:0] ALBUM_SLOTS = 7'd64;
    assign sys_pll_rstn_o = 1'b1;
    assign ddr_pll_rstn_o = sys_pll_lock;
    assign {clk_p_hi, clk_p_lo, clk_n_hi, clk_n_lo} = 4'b0110;
    assign shift_sel = 5'b00100;
    assign {cmos_ctl1, cmos_rst_n, cmos_pwdn} = 3'b000;
    assign {motor_stby, ml_pwm, mr_pwm, ml_in1, ml_in2, mr_in1, mr_in2} = 7'd0;

    wire pll_locked = sys_pll_lock && ddr_pll_lock;
    (* async_reg = "true" *) reg [2:0] reset_pipe = 0;
    always @(posedge clk_sys or negedge pll_locked)
        if (!pll_locked) reset_pipe <= 0;
        else reset_pipe <= {reset_pipe[1:0], 1'b1};
    wire rst_n = reset_pipe[2];

    wire sccb_start, sccb_done, vs_active;
    wire cal_done, cal_pass;
    wire ddr_ready = cal_done && cal_pass;
    wire system_ready = sccb_done && vs_active && ddr_ready;
    cam_probe #(.CLK_FREQ(CLOCK_HZ)) probe (
        .clk(clk_sys), .rst_n(rst_n), .vsync(cmos_vsync), .ready(sccb_start),
        .vs_cnt(), .vs_act(vs_active)
    );
    cam_sccb_cfg #(.CLK_FREQ(CLOCK_HZ)) camera_config (
        .clk(clk_sys), .rst_n(rst_n), .start(sccb_start), .done(sccb_done),
        .sclk(cmos_sclk), .sdat_in(cmos_sdat_IN), .sdat_out(cmos_sdat_OUT),
        .sdat_oe(cmos_sdat_OE)
    );

    (* async_reg = "true" *) reg [1:0] key_sync;
    reg key_stable, key_press;
    reg [$clog2(KEY_TICKS)-1:0] key_count;
    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            key_sync <= 2'b11;
            key_stable <= 1;
            key_press <= 0;
            key_count <= 0;
        end else begin
            key_sync <= {key_sync[0], key_start_n};
            key_press <= 0;
            if (key_sync[1] == key_stable) begin
                key_count <= 0;
            end else if (key_count == KEY_TICKS - 1) begin
                key_stable <= key_sync[1];
                key_press <= !key_sync[1];
                key_count <= 0;
            end else begin
                key_count <= key_count + 1'b1;
            end
        end
    end

    (* async_reg = "true" *) reg [1:0] sensor_reset_pipe;
    always @(posedge cmos_pclk or negedge rst_n)
        if (!rst_n) sensor_reset_pipe <= 0;
        else sensor_reset_pipe <= {sensor_reset_pipe[0], 1'b1};
    wire sensor_rst_n = sensor_reset_pipe[1];
    wire request, capture_done, capture_good, full, push, pop;
    wire [127:0] word, payload;
    wire [FIFO_BITS:0] available;
    ov5640_photo_capture #(.WIDTH(WIDTH), .HEIGHT(HEIGHT)) capture (
        .pclk(cmos_pclk), .rst_n(sensor_rst_n),
        .href(cmos_href), .vsync(cmos_vsync), .data(cmos_data),
        .request(request), .done(capture_done), .good(capture_good),
        .full(full), .push(push), .word(word)
    );
    ov5640_photo_fifo #(.ADDRESS_BITS(FIFO_BITS)) fifo (
        .pclk(cmos_pclk), .sensor_rst_n(sensor_rst_n), .push(push), .word(word),
        .full(full), .clk(clk_sys), .rst_n(rst_n), .pop(pop),
        .payload(payload), .available(available)
    );

    wire avalid, atype, aready, wvalid, wlast, wready, bvalid, rvalid, rlast;
    wire [31:0] aaddr;
    wire [7:0] alen;
    wire [1:0] bresp, rresp;
    wire [127:0] rdata;
    wire [19:0] read_addr;
    wire [7:0] read_y;
    wire uart_active, busy, error, read_request, read_ready, read_error;
    wire [6:0] photo_count;
    wire [5:0] read_slot;
    ov5640_photo_store #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .FIFO_BITS(FIFO_BITS), .SLOTS(ALBUM_SLOTS)
    ) store (
        .clk(clk_sys), .rst_n(rst_n), .shoot(key_press && system_ready), .uart_active(uart_active),
        .request(request), .capture_done(capture_done), .capture_good(capture_good),
        .busy(busy), .photo_count(photo_count), .error(error),
        .available(available), .pop(pop),
        .read_request(read_request), .read_slot(read_slot), .read_addr(read_addr), .read_y(read_y),
        .read_ready(read_ready), .read_error(read_error),
        .avalid(avalid), .atype(atype), .aaddr(aaddr), .alen(alen), .aready(aready),
        .wvalid(wvalid), .wlast(wlast), .wready(wready), .bvalid(bvalid), .bresp(bresp),
        .rvalid(rvalid), .rlast(rlast), .rresp(rresp), .rdata(rdata)
    );
    ov5640_uart_snapshot #(
        .WIDTH(WIDTH), .HEIGHT(HEIGHT), .ADDRESS_WIDTH(20), .CLK_FREQ(CLOCK_HZ),
        .BAUD(BAUD), .STORED_PHOTO(1'b1), .ALBUM_SLOTS(ALBUM_SLOTS)
    ) serial (
        .clk(clk_sys), .rst_n(rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .frame_valid(photo_count != 0 && !busy && ddr_ready), .frame_release(),
        .photo_count(photo_count), .album_flags({error, busy, system_ready}), .read_slot(read_slot),
        .read_addr(read_addr), .read_y(read_y), .sent(), .read_request(read_request),
        .read_ready(read_ready), .read_error(read_error), .active(uart_active)
    );

    DdrCtrl ddr3 (
        .clk(clk_sys), .reset_n(rst_n), .core_clk(core_clk), .tac_clk(tac_clk),
        .twd_clk(twd_clk), .tdqss_clk(tdqss_clk),
        .reset(reset), .cs(cs), .ras(ras), .cas(cas), .we(we),
        .cke(cke), .addr(addr), .ba(ba), .odt(odt),
        .o_dm_hi(o_dm_hi), .o_dm_lo(o_dm_lo),
        .i_dq_hi(i_dq_hi), .i_dq_lo(i_dq_lo),
        .o_dq_hi(o_dq_hi), .o_dq_lo(o_dq_lo), .o_dq_oe(o_dq_oe),
        .i_dqs_hi(i_dqs_hi), .i_dqs_lo(i_dqs_lo),
        .i_dqs_n_hi(i_dqs_n_hi), .i_dqs_n_lo(i_dqs_n_lo),
        .o_dqs_hi(o_dqs_hi), .o_dqs_lo(o_dqs_lo),
        .o_dqs_n_hi(o_dqs_n_hi), .o_dqs_n_lo(o_dqs_n_lo),
        .o_dqs_oe(o_dqs_oe), .o_dqs_n_oe(o_dqs_n_oe),
        .shift(shift), .shift_sel(), .shift_ena(shift_ena),
        .cal_ena(1'b1), .cal_done(cal_done), .cal_pass(cal_pass),
        .wr_addr(32'd0), .wr_addr_en(1'b0), .wr_en(1'b0),
        .wr_data(128'd0), .wr_datamask(16'd0),
        .rd_addr(32'd0), .rd_addr_en(1'b0), .rd_en(1'b0),
        .axi_avalid(avalid), .axi_aready(aready), .axi_atype(atype), .axi_aaddr(aaddr),
        .axi_aid(8'd0), .axi_alen(alen), .axi_asize(3'd4), .axi_aburst(2'b01), .axi_alock(2'd0),
        .axi_wid(8'd0), .axi_wvalid(wvalid), .axi_wready(wready), .axi_wdata(payload),
        .axi_wstrb(16'hffff), .axi_wlast(wlast),
        .axi_bvalid(bvalid), .axi_bready(1'b1), .axi_bid(), .axi_bresp(bresp),
        .axi_rvalid(rvalid), .axi_rready(1'b1), .axi_rdata(rdata), .axi_rid(),
        .axi_rresp(rresp), .axi_rlast(rlast)
    );

    reg [26:0] heartbeat;
    always @(posedge clk_sys or negedge rst_n)
        if (!rst_n) heartbeat <= 0;
        else heartbeat <= heartbeat + 1'b1;
    wire photo_lamp = photo_count == ALBUM_SLOTS ? heartbeat[26] : photo_count != 0;
    assign led = ~{heartbeat[26], error || (cal_done && !cal_pass) || busy || uart_active,
                   ddr_ready, vs_active, sccb_done, photo_lamp};
endmodule
