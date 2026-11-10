// =============================================================================
// cam_sccb_cfg.v —— OV5640 寄存器配置（包装官方 SCCB 引擎 + 寄存器表 LUT）
// -----------------------------------------------------------------------------
// 为什么直接搬官方两个模块，而不是用我们自己的 i2c_master：
//   OV5640 的寄存器写是**一帧 4 字节**（dev_id / reg_hi / reg_lo / data，同一次
//   START-STOP 内完成）。我们的 i2c_master 只支持"单次事务 1 字节"，拆成 4 次
//   事务会被传感器当成 4 次独立的寄存器访问，配置必然失败。
//   官方的 i2c_timing_ctrl_16bit 正是为这个 4 字节序列写的，且已被厂商在
//   同一块板上验证过，直接复用风险最低。
//
// 位宽约定（来自 i2c_timing_ctrl_16bit 源码 272~302 行）：
//   i2c_config_data[31:24] = 从机写地址（OV5640 SCCB 写地址 0x78）
//   i2c_config_data[23:16] = 寄存器地址高字节
//   i2c_config_data[15:8]  = 寄存器地址低字节
//   i2c_config_data[7:0]   = 要写入的数据
// 而 LUT 输出的是 24 位 {reg[15:0], data[7:0]}，所以这里补上高 8 位设备地址。
//
// 复位策略：引擎的 rst_n 用 `sys_rst_n & start` 门控 —— start（cam_probe.ready）
// 之前一直按住，保证引擎内部那 1 ms "等传感器稳"的延时是从 ready 之后开始算，
// 而不是从系统复位开始算（否则 20 ms 的上电等待形同虚设）。
// =============================================================================
`timescale 1ns/1ns

module cam_sccb_cfg #(
    parameter integer CLK_FREQ = 24_000_000,
    parameter integer I2C_FREQ = 100_000,      // SCCB 时钟，100 kHz 最稳
    parameter [7:0]   DEV_ADDR = 8'h78         // OV5640 SCCB 写地址（0x3C << 1）
) (
    input  wire clk,
    input  wire rst_n,        // 系统复位（已同步化）
    input  wire start,        // cam_probe.ready：上电时序完成，可以开始配置
    // ---- SCCB 物理层（三线）----
    output wire sclk,
    input  wire sdat_in,
    output wire sdat_out,
    output wire sdat_oe,
    // ---- 结果 ----
    output reg  done          // 252 条寄存器全部写完
);

    // ------------------------------------------------------------------
    // 官方寄存器表（252 条）
    // ------------------------------------------------------------------
    wire [7:0]  lut_index;
    wire [23:0] lut_data;
    wire [7:0]  lut_size;

    I2C_OV5640_1280720_Config u_lut (
        .LUT_INDEX (lut_index),
        .LUT_DATA  (lut_data),
        .LUT_SIZE  (lut_size)
    );

    // ------------------------------------------------------------------
    // 官方 SCCB 时序引擎
    // ------------------------------------------------------------------
    wire eng_rst_n = rst_n & start;

    wire [7:0]  cfg_index;
    wire [15:0] cfg_rdata;
    wire        cfg_done;

    i2c_timing_ctrl_16bit #(
        .CLK_FREQ (CLK_FREQ),
        .I2C_FREQ (I2C_FREQ)
    ) u_eng (
        .clk              (clk),
        .rst_n            (eng_rst_n),
        .i2c_sclk         (sclk),
        .i2c_sdat_IN      (sdat_in),
        .i2c_sdat_OUT     (sdat_out),
        .i2c_sdat_OE      (sdat_oe),
        .i2c_config_size  (lut_size),
        .i2c_config_index (cfg_index),
        .i2c_config_data  ({DEV_ADDR, lut_data}),
        .i2c_config_done  (cfg_done),
        .i2c_rdata        (cfg_rdata)
    );

    assign lut_index = cfg_index;

    always @(posedge clk or negedge rst_n)
        if (!rst_n)       done <= 1'b0;
        else if (cfg_done) done <= 1'b1;

endmodule
