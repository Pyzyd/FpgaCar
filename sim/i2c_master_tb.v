// =============================================================================
// i2c_master_tb.v —— i2c_master 自测（含一个行为级 I2C 从机模型）
// iverilog -g2012 -Wall -s i2c_master_tb -o i2c_master_tb.vvp \
//          src/i2c_master.v sim/i2c_master_tb.v && vvp i2c_master_tb.vvp
// -----------------------------------------------------------------------------
// 从机模型：7 位地址 0x50 应答，内部 mem 寄存器供读回。
// 验收：
//   1) 写 0xA5 到 0x50 → 从机收到 0xA5，ack_err=0，done 有脉冲
//   2) 读 0x50 → rd_data=0x5A（从机预设），ack_err=0
//   3) 访问不存在的地址 0x33 → ack_err=1，但事务照样走完（STOP 正常）
//   4) SCL 周期 = 10 us（100 kHz），误差 < 1%
//   5) busy 在事务期间为 1，结束后为 0
// =============================================================================
`timescale 1ns/1ps

module i2c_master_tb;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    always #20.8335 clk = ~clk;          // 24 MHz

    reg         start = 1'b0;
    reg  [6:0]  dev_addr = 7'h50;
    reg         rw = 1'b0;
    reg  [7:0]  wr_data = 8'h00;
    wire [7:0]  rd_data;
    wire        ack_err;
    wire        busy;
    wire        done;
    wire        scl;
    wire        sda_out;
    wire        sda_oe;
    wire        sda_in;

    // 物理 SDA：主机与从机共用一条线，外部上拉
    wire        sda_line;
    reg         slv_oe  = 1'b0;
    reg         slv_bit = 1'b1;

    assign sda_line = sda_oe ? sda_out : (slv_oe ? slv_bit : 1'bz);
    pullup (sda_line);
    assign sda_in = sda_line;

    i2c_master #(.CLK_FREQ(24_000_000), .SCL_FREQ(100_000)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .dev_addr(dev_addr), .rw(rw), .wr_data(wr_data),
        .rd_data(rd_data), .ack_err(ack_err), .busy(busy), .done(done),
        .scl(scl), .sda_in(sda_in), .sda_out(sda_out), .sda_oe(sda_oe)
    );

    // ------------------------------------------------------------------
    // 从机模型
    // ------------------------------------------------------------------
    reg [7:0] slv_mem   = 8'h5A;      // 读操作返回的值
    reg [7:0] slv_wr    = 8'h00;      // 最近一次写入的值
    integer   slv_wr_ok = 0;
    reg [7:0] rx;
    reg [6:0] slv_addr;
    reg       slv_is_read;
    integer   i;

    initial begin : slave_model
        slv_oe = 1'b0;
        forever begin
            @(negedge sda_line);
            if (scl === 1'b1) begin                    // START
                rx = 8'h00;
                for (i = 7; i >= 0; i = i - 1) begin
                    @(posedge scl);
                    rx[i] = sda_line;
                end
                slv_addr    = rx[7:1];
                slv_is_read = rx[0];

                @(negedge scl);
                if (slv_addr == 7'h50) begin
                    slv_oe = 1'b1; slv_bit = 1'b0;      // ACK
                    @(negedge scl);
                    slv_oe = 1'b0;
                end else begin
                    @(negedge scl);                     // NACK
                end

                if (slv_is_read) begin                  // 主读：送出 8 位
                    for (i = 7; i >= 0; i = i - 1) begin
                        slv_oe = 1'b1; slv_bit = slv_mem[i];
                        @(negedge scl);
                    end
                    slv_oe = 1'b0;
                end else begin                          // 主写：收 8 位
                    rx = 8'h00;
                    for (i = 7; i >= 0; i = i - 1) begin
                        @(posedge scl);
                        rx[i] = sda_line;
                    end
                    slv_wr    = rx;
                    slv_wr_ok = 1;
                    @(negedge scl);
                    slv_oe = 1'b1; slv_bit = 1'b0;      // ACK
                    @(negedge scl);
                    slv_oe = 1'b0;
                end

                @(posedge sda_line);                    // 等 STOP
            end
        end
    end

    // SCL 周期测量
    time t_prev = 0, t_now = 0, t_period = 0;
    integer scl_rises = 0;
    always @(posedge scl) begin
        t_now = $time;
        if (scl_rises > 0) t_period = t_now - t_prev;
        t_prev = t_now;
        scl_rises = scl_rises + 1;
    end

    // ------------------------------------------------------------------
    task do_txn (input [6:0] addr, input rd, input [7:0] wd);
        begin
            @(posedge clk); #1;
            dev_addr = addr; rw = rd; wr_data = wd;
            start = 1'b1;
            @(posedge clk); #1;
            start = 1'b0;
            wait (done === 1'b1);
            @(posedge clk); #1;
        end
    endtask

    // ------------------------------------------------------------------
    initial begin
        #200 rst_n = 1'b1;
        #500;

        // 1) 写
        do_txn(7'h50, 1'b0, 8'hA5);
        if (slv_wr !== 8'hA5)      $display("FAIL: slave got 0x%02h (expect 0xA5)", slv_wr);
        else                       $display("PASS: write 0xA5 -> slave received 0x%02h", slv_wr);
        if (ack_err !== 1'b0)      $display("FAIL: write ack_err=1");
        else                       $display("PASS: write acknowledged, ack_err=0");
        if (busy !== 1'b0)         $display("FAIL: busy still 1 after done");
        else                       $display("PASS: busy released after transaction");

        // 2) 读
        do_txn(7'h50, 1'b1, 8'h00);
        if (rd_data !== 8'h5A)     $display("FAIL: read rd_data=0x%02h (expect 0x5A)", rd_data);
        else                       $display("PASS: read -> rd_data=0x%02h", rd_data);
        if (ack_err !== 1'b0)      $display("FAIL: read ack_err=1");
        else                       $display("PASS: read ack_err=0");

        // 3) 从机不存在 → NACK，但事务正常收尾
        do_txn(7'h33, 1'b0, 8'h11);
        if (ack_err !== 1'b1)      $display("FAIL: missing slave should NACK, ack_err=%b", ack_err);
        else                       $display("PASS: missing slave -> ack_err=1, transaction completed");
        if (scl !== 1'b1 || sda_oe !== 1'b0)
            $display("FAIL: bus not released after NACK (scl=%b oe=%b)", scl, sda_oe);
        else                       $display("PASS: bus released after NACK");

        // 4) SCL 频率
        if (t_period < 9900 || t_period > 10100)
            $display("FAIL: SCL period = %0d ns (expect ~10000 ns)", t_period);
        else
            $display("PASS: SCL period = %0d ns -> %.1f kHz", t_period, 1000000.0 / t_period);

        $display("INFO: i2c_master_tb done");
        $finish;
    end

endmodule
