# =============================================================================
# FpgaCar.sdc —— 赛题二智能小车 / Ti60F225 顶层时序约束（骨架阶段）
# -----------------------------------------------------------------------------
# 24 MHz 有源晶振从 GPIOL_11 进入，周期 41.667 ns。
# 与 FpgaCar.xml 同级（对齐官方 01_LED_8bit_Test/VIP_System.sdc 的布局）。
# 通过 Efinity 的 Edit Project -> Design -> Import Design & Constraint Files 导入
# （File to Import 选 All Files 才能看到 .sdc）；文件已在工程目录内，不要勾 Copy to Project。
#
# 【后续必做】每新增一个时钟域都要在这里补一条 create_clock：
#   - PLL 输出（如 pll_inst1_CLKOUT0）
#   - OV5640 的 cmos_pclk（DVP 像素时钟，约 48~96 MHz）
#   - DDR3 / MIPI / HDMI 的 IP 内部时钟由对应 IP 的 .sdc 提供，不要重复约束
# 跨时钟域路径用异步 FIFO / 双触发器同步，并加 set_false_path 或
# set_clock_groups -asynchronous，否则 STA 会报大量伪违例。
# =============================================================================

create_clock -period 41.667 [get_ports clk]
