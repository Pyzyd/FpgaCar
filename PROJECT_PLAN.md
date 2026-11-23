# FpgaCar 工程说明与开发顺序

> 第十四届"星火杯"赛题二 · 光电导航智能小车 · 主控 VF-Ti60F225（Titanium Ti60F225 / C4，Efinity 2026.1）

## 1. 目录约定

```
FpgaCar/
├── FpgaCar.xml          ← Efinity 工程主文件（File → Open Project 选它）
├── FpgaCar.peri.xml     ← Interface Designer 配置（已完成：管脚/电平全部锁定）
├── FpgaCar.sdc          ← 顶层时序约束（24 MHz 主时钟），与 .xml 同级
├── PROJECT_PLAN.md      ← 本文件
├── CONTRIBUTING.md      ← 【提交 / 推送规则】入库边界、检查清单、回归门禁，必读
├── .gitignore           ← 只提交「输入」不提交「输出」的规则（详见 CONTRIBUTING.md §2）
├── .gitattributes       ← 统一 LF，消除 Windows CRLF 警告（见下文）
├── src/                 ← 设计文件（综合用），只放 .v / .sv
│   └── FpgaCar.v        ← 顶层【骨架】，整车 I/O 与模块划分
├── sim/                 ← 仿真文件（**不导入工程**），全部 *_tb.v 入库
│   └── FpgaCar_tb.v     ← 顶层最小 testbench
├── tools/               ← 上板/调试/回归脚本（cap.py 抓包、run_regression.sh 全量回归、dl.bat 烧板 …）
│   └── hooks/pre-push   ← 推送门禁：回归不过不许 push（git config core.hooksPath tools/hooks 启用）
├── docs/                ← 硬件接口表等文档；上板使用说明.md = 现场操作与判据速查（精简，改代码要同步）
├── data/                ← 抓包数据（_cap*.csv / _frame*.*），可随时重抓，不入库
├── .scratch/            ← 一次性探测脚本与仿真中间产物，可随时删，不入库
├── ip/                  ← IP Manager 生成的 IP（DDR / FIFO / PLL / Sapphire …）
├── outflow/             ← 编译产物（FpgaCar.bit 已生成 / FpgaCar.hex / 报告），不入库
└── work_pnr/            ← 布局布线中间文件，不入库
```

**文档分工**：要蹲在车边照着做、只关心「按什么键、看到什么算过」的，看 `docs/上板使用说明.md`；
要查「为什么这么设计、踩过哪些坑」的，看本文。同一事实只在一处展开，另一处给链接。

**入库边界**：`sim/*_tb.v` 与 `tools/` 下正式脚本是源码、**必须入库**；被忽略的只是
仿真产物（`*.vvp` / `.scratch/` / `_sim/`）、Efinity 产物（`outflow/` 等）、抓包数据（`data/`）和
`_` 前缀的临时脚本。判据是「能否由仓库内文件重新生成 / 随时重抓」。完整对照表与提交推送流程见
`CONTRIBUTING.md`。
**引脚真源是 `FpgaCar.peri.xml`**：`outflow/` 里的 `.lpf` / `.pinout.csv` 是每次编译都会变的派生报告，
不入库；改管脚后除提交 `.peri.xml` 外，必须同步更新本文的接线表（见 §OLED 四脚接线）。

**换行符**：`.gitattributes` 统一 `* text=auto eol=lf`，覆盖 Windows 全局 `core.autocrlf=true`，
消除每次提交刷屏的 `warning: LF will be replaced by CRLF`；不要靠改全局 git config 解决。

**数据落点约定**：`tools/cap.py` 与 `tools/grab_frame.py` 只写文件名时，输出自动落到 `data/`；
要放别处就传带目录的完整路径。`_jtag.jcf` 必须留在工程根（`dl.bat` / `flash.bat` 按 `%~dp0..\_jtag.jcf` 查找）。

**为什么 .sdc 与 .xml 同级**：与资料包官方工程一致（`01_LED_8bit_Test/` 把 `VIP_System.sdc` 放根目录、`.v` 放 `src/`）。.sdc 是给 STA / 布局布线看的时序约束，不是 RTL 源码；后面时钟域变多（PLL 输出、`cmos_pclk`、DDR IP 各自的 .sdc）时按用途分层更清楚，`src/` 只留源码，iverilog 命令也不会误吃约束。

**关键规则**：`sim/` 里的 `_tb.v` 永远不要通过 **Edit Project → Design → Import Design & Constraint Files** 导进工程。Efinity 会把导入的 .v 全部当设计文件综合，官方 tutorial 第 5 页第 16 步就是让你把 `helloworld_tb.v` 从列表里删掉。仿真走 `--flow rtlsim` 或外部 ModelSim / iVerilog。

**Efinix 双向 IO 特别约定**：Titanium 顶层**不允许** `inout` + `1'bz`（综合会报
`ERROR : Signal driving output port 'i2c_sda' is tristated, which is not supported. [EFX-0410]`）。
所以 `src/FpgaCar.v` 里的 I2C SDA 是三根独立端口 `i2c_sda_IN / i2c_sda_OUT / i2c_sda_OE`，
由 Interface Designer 里一个 **`mode="inout"` 的 GPIO 块（块名填 `i2c_sda`）** 在物理管脚上
合成三态缓冲并自动接出这三个名字；SCL 单独建一个 `mode="output"` 块。
`sim/FpgaCar_tb.v` 用 `pullup + 条件驱动` 把这个物理块的行为补出来，三态只存在于 tb（不参与综合）。
资料包可对照：`06-FPGA_HDL_Basic-2023.2/02-1_Ti60_OV5640_LCD-HDMI_1080P60/src/cmos_i2c/i2c_timing_ctrl_16bit.v`
第 44–47、368–370 行与 `Ti60_Demo.peri.xml` 第 205–211 行。

## 2. 顶层骨架做了什么 / 没做什么

`src/FpgaCar.v` 是**正式工程的顶层**，不是流水灯演示：

- 把赛题二 5 个得分点对应的外设端口全部声明好并分组注释：
  循迹 20（YB-MUX04 八路）、避障 20（HC-SR04）、标识 25 + 颜色 20（OV5640 DVP）、
  车载显示（0.96" OLED）、运动执行（TB6612FNG）、里程反馈（光电编码器 ×2）。
- 做复位同步化（异步有效、同步释放）。
- **所有输出给安全默认值**：电机待机、PWM=0、I2C 总线释放（SCL=1、SDA `_OE=0`）、UART 空闲、
  LED[3:0] 显示消抖+极性统一后的循迹探头（见 §3.9）。
- **一个 24 MHz 心跳计数器**：`heartbeat[23]` 驱动 **LED[5]**（板上只有 LED0~LED5 可用）约 0.7 s 慢闪。这不是演示代码，
  而是最终整车保留的诊断逻辑；同时它避免了 Efinity 对"全常量输出"顶层的报错
  `ERROR : Post-synthesis netlist has only vcc and gnd nets because all logic is eliminated.
  Legal, but will cause router to crash. [VDB-9009]`（纯常量骨架进不了布局布线）。
- TODO 注释里列出了后续要例化的子模块名（`i2c_master` / `pwm_gen` / `encoder_dec` /
  `hc_sr04` / `track_pid` / `dvp_capture` / `color_detect` / `sign_detect` / `oled_driver` / `car_fsm` / `uart_tx`）。

**已用 `C:/Efinity/2026.1/bin/efx_map.exe` 做过综合级验证**：EXIT=0、0 ERROR、
`EFX_ADD 23 / EFX_LUT4 31 / EFX_FF 26`。期间修掉两个真实错误（见第 1 节 Efinix 双向 IO 约定
与本节的 VDB-9009），源码可直接导入 Efinity。

**没做**：PLL、图像流水线、决策层。管脚与电平已在 `FpgaCar.peri.xml` 全部锁定（见下）。

> **2026-11-10 第二轮的进展**：`src/` 现有 7 个文件、5 个子模块已例化进顶层，
> 全部通过 iVerilog 自测并重新生成位流（详见 §3.7）。
>
> **当前状态（2026-11-10 第三轮后，历史快照）**：`src/` 已 8 个模块（新增 `track_line.v`）、
> `sim/` 8 个 tb 全 PASS，当时位流 `outflow/FpgaCar.bit` = **19:50**，顶层处于 `PWM_BENCH_TEST=1` 台架态。
>
> **⚠ 最新状态以 §3.14 为准（2026-11-11 21:38）**：`src/` 14 个设计文件、`sim/` 12 个 tb，
> A3.4 颜色识别已进网表且 `map`/`pnr`/`pgm` 全 PASS，位流 **21:38:30**。
> 顶层仍 `PWM_BENCH_TEST=1` 台架态，上地前须改回 0。

## 3.5 管脚与电平分配（已在 FpgaCar.peri.xml 落实，2026-11-10）

**电平的关键事实（读核心板/底板原理图证实）**：核心板电源页标注 `VCCIO1A/1B/2A/2B` 经 0Ω
电阻接 `VDD1V8`（**Default 1.8V**），四个角部 bank（`VCCIO33_BL/BR/TL/TR`）接 `VDD3V3`；
底板第 6 页显示 **DC3-40 的每个 User_IO0–35 都经过 TXS0108EPWR 电平转换**（FPGA 侧 VCCA=D1V8 ↔
排针侧 VCCB=D3V3，红字"默认DC3-40为3.3V电平"）。所以 **FPGA 侧这些引脚必须是 1.8 V LVCMOS**，
3.3V 是排针外侧的电平；peri.xml 里写 3.3V 会报
`gpio_rule_io_standard_compatibility: I/O standard (3.3 V LVCMOS) is not supported in bank 1A/2B`。

| 顶层端口 | 引脚 | bank / 电平 | 说明 |
|---|---|---|---|
| clk | GPIOL_11 | TL corner / 3.3V | 24MHz 晶振，conn_type=pll_clkin（加 PLL 后告警消失） |
| key_start_n | N2 / GPIOL_P_02 (K1 / User_IO1) | 1A / 1.8V | 低有效，启动 |
| key_stop_n | M2 / GPIOL_N_02 (K2 / User_IO0) | 1A / 1.8V | 低有效，停车；长按清空色序 |
| track[0..7] | GPIOL_N_06/P_06/N_08/P_08/N_05/P_05/N_04/P_04 (User_IO2–9) | 1A / 1.8V | YB-MUX04 八路 |
| hc_trig / hc_echo | GPIOL_N_12 / P_12 (User_IO10/11) | 1B / 1.8V | HC-SR04。**2026-11-18 起 Vcc 改 3.3 V 供电，Echo 随之为 3.3 V，pin 14 直连、不分压**（若改回 5 V 供电则必须 1kΩ 串 + 2kΩ 下地 → 3.33 V，TXS0108E 的 B 侧绝对最大仅 4.6 V）。详见 §3.21、§3.23 与 [docs/模块接线说明.md](docs/模块接线说明.md) §3 |
| ir_l / ir_r | GPIOL_N_15 / P_15 (User_IO26/27) | 1B / 1.8V | E18-D80NK 红外光电开关 ×2（避障冗余；NPN 低有效=检测到）。**接法修正（联网查证）**：开集输出空闲时内部 10K 上拉为 **5V 高电平，不可直连 1.8V bank**——弃内部上拉，外部 10K 上拉到 D3V3 + 1K/1.2K 分压至约 1.8V。**2026-11-17：现阶段不用，`USE_IR = 1'b0` 不参与障碍判定**，接线与 RTL 保留，见 §3.9 A2 |
| i2c_scl / i2c_sda | GPIOL_N_13 / P_13 (User_IO12/13) | 1B / 1.8V | scl=output、sda=inout |
| enc_la/lb/ra/rb | GPIOL_N_10/P_10/N_11/P_11 (User_IO14–17) | 1B / 1.8V | 光电编码器 |
| ml_in1/in2/pwm | GPIOL_N_03/P_03/N_07 (User_IO18–20) | 1A / 1.8V | TB6612 左 |
| mr_in1/in2/pwm | GPIOL_P_07/N_09/P_09 (User_IO21–23) | 1A/1B / 1.8V | TB6612 右 |
| motor_stby | GPIOL_N_14 (User_IO24) | 1B / 1.8V | TB6612 STBY |
| led[0..5] | GPIOR_25/22/28/21/24/27 | BR corner / 3.3V | 板上 LED，低电平点亮（LED6/7 球让给 CMOS_D0/D1） |
| uart_rx / uart_tx | GPIOT_N_16 / P_16 | 2B / 1.8V | CH340N 调试串口 |

其余 User_IO25、28–34 为空：User_IO25=GPIOL_P_14 (F1)、28=GPIOL_N_16 (C1)、29=GPIOL_P_16 (D1)、
30=GPIOL_N_17 (C2)、31=GPIOL_P_17 (B1)、32=GPIOL_N_18 (A2)、33=GPIOL_P_18 (B2)、34=GPIOT_N_11 (A9)，
全部落在 1B / 2B 的 1.8V bank（已对 `outflow/FpgaCar.pinout.csv` 逐球核对，Signal Name 列全空）。
**其中 User_IO25 / 28 / 29 / 34 已分配给 K230 视觉模块的 4 线并行口（见 §3.18）**；
**User_IO30 / 31 / 32 / 33 / 35 自 2026-11-20 起归 ST7789 彩屏**（`lcd_sclk`/`lcd_mosi`/`lcd_dc`/`lcd_rst_n`/`lcd_cs_n`，见 §3.38 与 [模块接线说明](docs/模块接线说明.md) §5）。至此 DC3-40 的 User_IO2–35 全部占用，无空脚；
**P4-1、P4-2 留空**，对应核心板 K2、K1。前视联调版操作见 [小车使用说明](docs/小车使用说明.md)。

> **按物理针号排的完整对照表见 [docs/引脚分配表.md](docs/引脚分配表.md)**（2026-11-16 新增）：
> `User_IO(n)` 固定在 pin **n+1**，四个电源脚 pin 11 = D5V0 / 12 = GND / 29 = D3V3 / 30 = GND。
> BGA 球号真源是资料包 `04_原理图&PIN TCL/Ti60_Board_引脚定义-20230703-V1.0.xlsx` 的 `DC3-40` 页，
> 已与 `outflow/FpgaCar.pinout.csv` 逐球核对一致。
OV5640 走核心板专用 DVP 排针（`cmos_*` 网络，1.8V pclk）。**`cmos_xclk` 已在 peri.xml 声明**（clkout，见下）；其余 13 个 `cmos_*` 引脚（pclk/href/vsync/data/sclk/sdat/rst_n/pwdn）待 A3.1 补。

**OV5640 的 XCLK 由 Interface Designer 的 clkout 块输出，不是 RTL 端口（2026-11-10 实验确认）**：
`FpgaCar.peri.xml` 里定义了 `comp_gpio name="cmos_xclk" gpio_def="GPIOR_16" mode="clkout"`，
其 `output_config` 的 **`clock_name` 直接指向系统 24 MHz 时钟 `clk`**；因此 `src/FpgaCar.v` 的端口表里
**没有** `cmos_xclk`（写 `assign cmos_xclk = clk;` 会与 interface 层冲突）。

- 依据 1（Efinix 文档）：时钟树直接连 interface block，"core 到 interface 的时钟输出不出现在 RTL 里，
  只存在于 interface 配置" → 时钟输出必须走 clkout。
- 依据 2（厂商用法）：资料包 **29 个工程全部**是 `mode="clkout"`，没有普通 output 的先例。
- 依据 3（引脚）：官方引脚定义表 `BANK 3.3` 页 `C12 | GPIOR_16 | CMOS_XCLK`。
- **实验结论**：`clock_name="clk"` 被工具完全接受，`outflow/FpgaCar.interface.csv` 生成
  `clkout, 209, 323, -1, clk`（坐标 209,323 = GPIOR_16），interface/map/pnr/pgm 全 PASS，
  **零 PLL**，XCLK = 24 MHz —— 正好是 `I2C_OV5640_1280720_Config.v` 注明的设计点
  `// input clock 24Mhz, PCLK 42Mhz`。
- 官方工程用的 `clk_27m` 是 `lvds_pll`(PLL_TR0) 的 number=2 输出、`out_divider=84`，
  **实际只有 16 MHz**（`Ti60_Demo.pt.sdc` 写 `-period 62.5000`；`clk_54m` 同理实为 32 MHz），
  "27m/54m" 是 AR0135 方案的命名遗留。**别照抄官方的 16 MHz**：那会把 PCLK 压到 ~28 MHz、帧率下降。
- OV5640 手册：XVCLK 典型 24 MHz（范围 6–27 MHz），**可容忍输入抖动 1 ns**；
  这也是"fabric 普通输出也能驱动"的电气依据（仅作 fallback，首选仍是 clkout）。

**编译验证全链路已通过（2026-11-10）**：interface flow EXIT=0（生成 `outflow/FpgaCar.lpf` /
`FpgaCar.interface.csv` / `FpgaCar_or.ini`）→ efx_map（EFX_ADD 23 / EFX_LUT4 29 / EFX_FF 26）→
efx_pnr EXIT=0（setup slack 40.10ns / hold slack 0.16ns @41.667ns）→ efx_pgm EXIT=0 →
**`outflow/FpgaCar.bit`（JTAG 下载用）与 `outflow/FpgaCar.hex`（SPI Flash 固化用）均已生成**。
命令行注意：efx_pmg 生成 .bit 必须带 `--project-xml FpgaCar.xml`，否则报
`Unknown destination file format`。GUI 的 Run Complete Flow 自动完成这些步骤，无需关心。

## 3.7 进度记录：2026-11-10 第二轮（阶段①接口控制器）

### 已落地的模块（`src/`，全部已例化进顶层并被综合）

| 文件 | 功能 | 关键设计点 |
|---|---|---|
| `pwm_gen.v` | 双路 20 kHz PWM，11 位占空比（0~1200） | 24 MHz/20 kHz = 1200 计数，duty=1200 即 100% 无缺口；`en=0` 硬门控 |
| `encoder_dec.v` | AB 相四倍频解码，`step`/`direction`/`position[31:0]` | 格雷码查表，跳两相视为毛刺忽略；A/B 两级同步 |
| `i2c_master.v` | 字节级 I2C 主机（写 1 字节 / 读 1 字节），100 kHz | 3 相位状态机产生 SCL，`sda_in/sda_out/sda_oe` 三线；从机 NACK 不中断流程，只置 `ack_err` |
| `hc_sr04.v` | 超声波测距，60 ms 一帧 | `dist = (us*1130+32768)>>16` 乘倒数代替除 58（1 个 DSP，误差 <0.1%）；无回波/超量程输出 `16'hFFFF` |
| `uart_tx.v` | 8N1 发送器，参数化波特率 | 24 MHz/115200 = 208 分频，位宽实测 8680.6 ns |
| `uart_report.v` | 每次测距打一行 `D=xxxcm\r\n` | 除法用移位-减法（`div10u` 函数），不实例化除法器；`REPORT_EN=0` 可整体静音 |

### 仿真（iVerilog 14.0，`C:\iverilog\bin`，全部 PASS）

```
iverilog -g2012 -Wall -s <tb> -o .scratch\<tb>.vvp src\*.v sim\<tb>.v
vvp .scratch\<tb>.vvp
```

| testbench | 覆盖内容 |
|---|---|
| `sim/pwm_gen_tb.v` | en 门控 / duty=0 / duty=600 实测 600±10 / duty≥1200 饱和高 |
| `sim/encoder_dec_tb.v` | 正转 100 格=+200 且恰好 200 个 step、反转 40 格=-80、direction 翻转、跳两相毛刺不计数、复位清零 |
| `sim/i2c_master_tb.v` | 带行为级从机：写 0xA5 / 读 0x5A / 从机不存在时 ack_err=1 但事务照常收尾 / SCL 周期实测 10000 ns |
| `sim/hc_sr04_tb.v` | 带 HC-SR04 模型：1450 us→25 cm、5800 us→100 cm、无回波→0xFFFF、Trig 脉宽 ≥10 us |
| `sim/uart_tx_tb.v` | 位级解码 0x55 / 0xA3、起始位/停止位、位宽 8680.6 ns |
| `sim/uart_report_tb.v` | 整行比对 `D=123cm` / `D=007cm` / `D=---cm` / `D=400cm` |
| `sim/FpgaCar_tb.v` | 顶层 smoke：台架模式 motor_stby=1、PWM 实测 300/1200、I2C 总线释放、心跳在跑 |

**踩过的三个坑**（都已修，别再犯）：
1. `encoder_dec.v` 原来用 `always @(*)` 加 `dir = dir;` 做"保持"，会推断出锁存器；改成连续赋值 + 只在有效跳变时更新的寄存器。
2. testbench 里 `#20.8335` 在 `` `timescale 1ns/1ns `` 下被舍入成 21 ns，时钟变成 23.81 MHz，导致 µs 节拍偏长 0.8%、100 cm 被测成 99 cm。**新增 tb 一律用 `` `timescale 1ns/1ps ``**。
3. 先撤 `start` 再 `@(negedge tx)` 会漏掉起始位（uart_tx 在采样 start 后下一拍才拉低 tx）；收发必须 `fork ... join` 并发。

### 顶层当前行为（`PWM_BENCH_TEST = 1`，台架试车态）

- `motor_stby = 1`、`ml_in1 = 1`、左轮以 **25% 占空比持续正转**，右轮只给 PWM 不给方向（不转）。
  **上地跑车前必须把 `FpgaCar.v` 里的 `PWM_BENCH_TEST` 改回 `0`**，否则上电即走。
- `LED[5]`：0.35 s 慢闪（心跳）；`LED[4:1]`：循迹探头 1~4 电平（低有效）；
  `LED[0]`：左右编码器里程第 22 位异或 + 心跳 → 任一编码器有脉冲就闪，用来判断 AB 相接对没接对。
- 串口（CH340N，115200-8-N-1）每 60 ms 打一行 `D=xxxcm\r\n`，`D=---cm` 表示没回波（传感器没接/超量程）。
- 编码器读数没接、超声波没接时不会误动作：PWM 只到左轮、且只有 25% 占空比。

### 编译实测耗时（比原估的 18–25 分钟快很多）

本设计规模很小（`EFX_ADD 144 / EFX_LUT4 391 / EFX_FF 221 / 1 个 DSP48`），实测：
`efx_run.bat --flow map` ≈ 1.5 分钟 → `--flow pnr` ≈ **2.5 分钟**（不是预估的 15 分钟）
→ `--flow pgm` ≈ 20 秒。合起来 4~5 分钟。
时序：setup slack ≈ 38.4 ns（约束 41.667 ns @24 MHz），余量极大。

命令行要点：`--flow` 的位流阶段叫 **`pgm`**（不是 `bitstream`），且 `efx_run.bat` **不接受**
`--project-xml` 参数（那是直接调 `efx_pgm.exe` 时才需要的）。正确写法：

```
efx_run.bat --flow map FpgaCar.xml
efx_run.bat --flow pnr FpgaCar.xml
efx_run.bat --flow pgm FpgaCar.xml
```

### 综合里剩下的告警（都是预期的中间状态，不用管）

`track[7]`、`uart_rx`、`i2c_sda_IN`、`cmos_*` 报 `VDB-8003 unconnected` —— 这些输入还没有下游使用者
（I2C 主机 `start` 恒 0、相机流水线未接、UART 只做发送），等 `sccb_cfg` / `car_fsm` 接入后自然消失。
`uart_report.v` 的 `div10u.q/i` 报 `EFX-0200 redundant signal` 是函数内临时变量被优化，正常。


## 3.9 进度记录：2026-11-10 第三轮（A1 循迹采样 + A2 红外冗余）

### A1 `src/track_line.v` —— 八路循迹采样（跑通，可上板）

- 1 kHz 采样 + 连续 4 次一致才认账（消抖），异步输入两级同步。
- 极性用参数 `ACTIVE_HIGH` 统一（默认 0 = 低电平压线，TCRT5000+LM393 模块常见）。
- 位置用**加权质心**：权重 -7,-5,-3,-1,+1,+3,+5,+7，按压线探头个数归一化，
  倒数查表（1024/n 再右移 10 位，含 +512 四舍五入）**不推断除法器**，只多 1 个乘法。
- 输出 `line[7:0]` / `cnt[3:0]` / `on_line` / `lost` / `pos`（signed，-16..+16，正=线在右）。
- tb 覆盖 6 项全 PASS：中间两路(cnt=2,pos=0)、最左(pos=-7)、最右(pos=+7)、
  偏左三路(pos=-3，验证归一化+四舍五入)、全白(lost=1)、0.8 ms 毛刺被滤掉。

### A1+ 调试串口升级为固定 30 字节行

```
D=123cm T=00011000 P=+02 O=0

```

`T=` 是 8 路压线位图（bit7..bit0 = track[7]..track[0]），`P=` 是归一化位置，
`O=` 是障碍标志。**2026-11-17 起默认只看超声波**（`USE_IR = 1'b0`），
即 `O=` = 超声波 ≤25 cm；红外那一路保留在 RTL 里，把 `USE_IR` 改 1 才重新参与取或。
一行约 2.6 ms，一帧 60 ms，发得完。

**上板用法**：接上 YB-MUX04（8 根线到 User_IO2~9 + 5V/GND），把黑线在探头下从左往右推，
看 `T=` 的 1 从哪个方向移动；若"压黑线显示 0"，把 `track_line` 的 `ACTIVE_HIGH` 改成 1 再重编。

### A2 `ir_l` / `ir_r` —— 红外冗余（引脚已锁定，**2026-11-17 起默认停用**）

> **现状（2026-11-17，用户决定）**：现阶段不用红外，「以后不说启用就不用」。
> 顶层加了总开关 `localparam USE_IR = 1'b0;`（`FpgaCar/src/FpgaCar.v`），
> `obstacle = hc_near | (USE_IR & ir_det)` —— **默认只有超声波决定障碍**。
> 接线、引脚、分压接法、RTL 判定全部保留，改一个 `1'b1` 重编即恢复。
> 保留的理由：E18-D80NK 没接时输入端电平不可控，内部 weak pullup 只能勉强拉高，
> 一旦判错就会凭空报障碍把车摁停，是现场最难查的故障之一；而超声波已经够用。

- `FpgaCar.peri.xml` 新增两个 GPIO 块：`ir_l`=GPIOL_N_15(User_IO26)、`ir_r`=GPIOL_P_15(User_IO27)，
  均为 `input` + **weak pullup**（悬空时读 1 = 无障碍，避免误报）。
- 顶层已例化融合逻辑：`obstacle = (dist_cm ≤ 25 cm) | ~ir_l | ~ir_r`。
- 已用 `--flow interface` 重新生成 lpf，`pinout.csv` 确认 E2/E1 两个球分配成功。
- 接线要求（**查证后修正**）：E18-D80NK 的 OUT（黑线）为 NPN 开集 + 内部 10K 上拉到 5V，
  **空闲时是 5V 高电平，绝不能直连 1.8V bank 引脚**。弃用内部上拉：
  **外部 10kΩ 上拉到 D3V3，再经 1kΩ/1.2kΩ 分压到约 1.8V** 后接排针
  （10K∥(1K+1.2K) 分压：3.3V × 1.2/(1+1.2) ≈ 1.8V）。检测到障碍时 OUT=0V，ir_raw=0，RTL 取 `~ir` 判障碍。

### 本轮踩的坑

`FpgaCar.xml` 的 `<efx:design_file>` 列表**必须手工加新文件**，否则综合直接报
`instantiating unknown module 'track_line' (VERI-1063)`。加 `src/*.v` 时别忘同步这里。

### 编译实测（本轮）

`interface` 数秒 → `map` 1.5 min（ADD 166 / LUT4 486 / FF 296 / DSP48 2）→
`pnr` 2.5 min（setup slack **36.36 ns**）→ `pgm` 20 s。位流 19:50 生成。

### 教训：资料包里的频率数字不可信（2026-11-10 记）

对 OV5640 官方工程（`02-1_Ti60_OV5640_LCD-HDMI_1080P60`）逐字核对后发现，**信号名、源码注释、
工程目录名里的频率数字都不能直接引用**：

1. **同一 PLL 内各输出共用基准**，换算关系是 `f_i = f_base × D0 / D_i`，其中 `D0` 是该 PLL
   **第一个输出**的 `out_divider`。只读某一行的 `out_divider`、或只看名字，都会算错。
   - 例：`lvds_pll`(PLL_TR0) 的 `clk_lvds_1x` 是首路（div=28，=48 MHz），则
     `clk_27m`(div=84) = 48×28/84 = **16 MHz**、`clk_54m`(div=42) = **32 MHz**。
   - 名字里的 "27m / 54m" 来自 AR0135 方案，与 OV5640 无关。
2. **最终以 Interface Designer 生成的 `.pt.sdc` 里的 `create_clock -period` 为准**——那是工具
   算出来的绝对值，可直接换算成频率（`f = 1000 / period_ns` MHz）。本次核对中
   `Ti60_Demo.pt.sdc:28` 写 `-period 62.5000 clk_27m`（=16 MHz），与上面手算一致。
3. **未被例化的 `.v` 文件里的注释无效**：`CMOS_Capture_RAW_Gray.v` 满篇 24 MHz 注释，但它
   根本没进 `example_top.v` 的实例树，只是 `Ti60_Demo.xml` 文件列表里躺着的死文件。
4. 推论：OV5640 的 PCLK 由传感器内部 PLL 按 `XCLK × 1.75` 倍频（`I2C_OV5640_1280720_Config.v:257`
   的 "input 24Mhz, PCLK 42Mhz" 即 1.75 倍）。XCLK=16 MHz → **PCLK ≈ 28 MHz**；若真测到
   ≈47.25 MHz，则说明 XCLK 实际是 27 MHz，也就是当前 peri.xml 与实际位流不一致，必须重编核对。

## 3.10 进度记录：2026-11-10 第四轮（A3.1 摄像头链路探测）

### 新增 `src/cam_probe.v`

只做三件事，**不碰 SCCB**（那是 A3.2）：

1. **上电时序**：`pwdn=0` → `rst_n` 拉低 **1 ms** → 拉高 → 再等 **20 ms** 才 `ready=1`。
   太快会导致传感器内部稳压/时钟未稳、后面配置全不生效（最经典的坑）。
2. **SCCB 空闲**：`sclk=1`、`sdat_oe=0`（释放靠外部 4.7k 上拉）。
3. **VSYNC 统计**：两级同步 + 上升沿计数，100 ms 窗口锁存 → 串口 `V=xx`。
   OV5640 只要 XCLK 在跑、复位正确，**一条寄存器都不配也会输出默认帧**，
   所以 `V>0` 能把"时钟/接线/复位"和"SCCB 通不通"彻底解耦。

### `peri.xml` 补齐 14 个 `cmos_*` 引脚

全部从官方 `Ti60_Demo.peri.xml` **原样复制**（同板同网络，避免手写属性出错），
`--flow interface` PASS，`pinout.csv` 逐条核对：

| 信号 | 引脚 | bank/电平 | 模式 |
|---|---|---|---|
| cmos_xclk | C12 / GPIOR_16 | TR 3.3V | clkout（clock_name=clk） |
| cmos_pclk | B8 / GPIOT_P_07 | 2A 1.8V | input（gclk, delay=15） |
| cmos_href | D12 / GPIOR_20 | TR 3.3V | input |
| cmos_vsync | A3 / GPIOL_03 | TL 3.3V | input |
| cmos_data[0..7] | R3,R4,C3,A14,B5,B14,C4,A13 | 3.3V | input（bus cmos_data） |
| cmos_sclk | A4 / GPIOL_09 | TL 3.3V | output |
| cmos_sdat | A12 / GPIOR_13 | TR 3.3V | inout（生成 _IN/_OUT/_OE） |
| cmos_rst_n | B3 / GPIOL_04 | TL 3.3V | output |
| cmos_pwdn | R2 / GPIOL_N_00 | 1A 1.8V | output |

### 调试行扩到 35 字节

```
D=123cm T=00011000 P=+02 O=0 V=03\r\n
```

`V=` 是 100 ms 窗口内的 VSYNC 个数（30 fps 时约 3）。

### 本轮两个真实 bug

1. **`uart_report.v` 的 `idx` 只有 5 位**（最大 31）。消息从 30 字节加长到 35 字节后，
   `idx == MSG_LEN` 永远不成立 → 报文无限循环、CR/LF 发不出去，串口看到的是一串
   重复的乱码。**加长报文时必须同步加宽索引位宽。**
2. **1.8V LVCMOS 的 `drive_strength` 只允许 16/12/8/4**。从官方 3.3V 块复制来的
   `drive_strength="2"` 让 `cmos_pwdn` 报 `gpio_rule_drive_strength` 错误，
   `--flow interface` 直接 FAIL（`outflow/design_issue.xml` 里能看到具体规则名）。
   Interface Designer 失败时先去读 `outflow/design_issue.xml`，比看控制台快。

### 编译实测

`interface` 数秒 PASS → `map` 1.5 min（ADD 201 / LUT4 598 / FF 356 / DSP48 2）→
`pnr` 2.5 min（setup slack **37.122 ns**）→ `pgm` PASS，位流 **22:43:36**。

### 遗留（预期内）

`cmos_pclk` / `cmos_href` / `cmos_data[7:0]` / `cmos_sdat_IN` 仍报 `VDB-8003 unconnected`
—— 采集逻辑（A3.3）和 SCCB（A3.2）还没接，等它们接入自然消失。

## 3.11 进度记录：2026-11-10 第五轮（A3.2 SCCB 配置）

### 新增文件

| 文件 | 来源 | 说明 |
|---|---|---|
| `src/I2C_OV5640_1280720_Config.v` | 官方 02-1 工程原样复制 | 252 条 `{reg[15:0], data[7:0]}` 寄存器表 |
| `src/i2c_timing_ctrl_16bit.v` | 官方 02-1 工程复制 + **改 1 处** | SCCB 4 字节写引擎；`DELAY_TOP` 由 `CLK_FREQ`(=1 s) 改为 `CLK_FREQ/1000`(真正的 1 ms) |
| `src/cam_sccb_cfg.v` | 新写（包装层） | LUT 的 24 位数据补上 8 位设备地址 `0x78` 送引擎；引擎复位用 `rst_n & start` 门控，保证 1 ms 延时从 `cam_probe.ready` 之后才起算 |

**为什么不复用我们自己的 `i2c_master`**：OV5640 寄存器写是**一次 START-STOP 内 4 字节**
（dev_id / reg_hi / reg_lo / data），`i2c_master` 只支持单次事务 1 字节，拆开会写错。

### 调试行扩到 39 字节

```
D=123cm T=00011000 P=+02 O=0 V=03 C=1
```

`C=1` 表示 252 条寄存器已发完（SCCB 写完成）。

### 本轮一个真实 bug（在官方代码里）

`i2c_timing_ctrl_16bit.v` 原文：

```verilog
//localparam DELAY_TOP = SIMU_EN ? 20'hff : CLK_FREQ/1000;  //1ms
localparam  DELAY_TOP = CLK_FREQ;  //1ms Setting time ...
```

注释写 1 ms，代码却是 `CLK_FREQ`（24 MHz 下 = **1 秒**）。仿真表现：400 ms 看门狗超时、
`done` 永远不来。已改为 `CLK_FREQ/1000`。

### 编译实测

`map` 1.5 min（**ADD 233 / LUT4 1111 / FF 415 / DSP48 2**；LUT 从 598 涨到 1111 是 252 条
寄存器表吃掉的）→ `pnr` 28 s（setup slack **36.846 ns**）→ `pgm` 20 s，位流 **23:05:13**。

### 仿真

`cam_sccb_cfg_tb` 4 项 PASS（start 前引擎在复位 / start 后 9325 个 SCLK 沿 / done=1 /
写完 sclk 回空闲高）、`uart_report_tb` 3 项 PASS（39 字节整行）、`cam_probe_tb` 9 项 PASS、
`FpgaCar_tb` 5 项 PASS。

### 上板判据

`V>0` 且 `C=1` → 摄像头已按 1280x720 配置完成。
`C=0` → SCCB 没通（查 SDAT 的 4.7k 上拉、上电 20 ms 够不够、XCLK 是否在跑）。

## 3.12 上板实测修正：三根 CMOS_CTL 必须全部驱动 0（2026-11-11）

### 现象

A3.2 位流上板（OV5640 已插 DVP 排针），串口稳定输出：

```
D=---cm T=00000000 P=+00 O=0 V=00 C=1
```

`C=1` 说明 252 条寄存器都发出去了，但 `V=00` —— **传感器一帧都没输出**。

### 根因

上一版按硬件接口表的命名，把 CTL2 当"高有效复位释放"驱动为 **1**：

```verilog
cam_rst_n (CTL2) <= 1;   // ← 错
```

而官方固件 `example_top.v:378-383` 是：

```verilog
assign cmos_ctl1_o = 0;  assign cmos_ctl1_oe = 1;
assign cmos_ctl2_o = 0;  assign cmos_ctl2_oe = 1;
assign cmos_ctl3_o = 0;  assign cmos_ctl3_oe = 1;
```

**三根全为 0**。如果 CTL2 接的是 PWDN（高=待机），给 1 就等于让传感器一直掉电待机 →
无 VSYNC、无 PCLK，正好对上现象。

### 修正

- `src/FpgaCar.v`：`cmos_ctl1`（新增，GPIOR_15）/ `cmos_rst_n`（CTL2）/ `cmos_pwdn`（CTL3）
  **全部 `assign 1'b0`**，与官方一致。
- `src/cam_probe.v`：不再驱动任何 CTL，只保留 1+20 ms 的 `ready` 时序与 VSYNC 统计。
- `FpgaCar.peri.xml`：新增 `cmos_ctl1` GPIO 块（GPIOR_15，output，3.3 V，drive_strength=4）。

### 教训

**引脚名字 ≠ 电气功能**。硬件接口表写的 `cmos_rst_n` / `cmos_pwdn` 是自己起的名字，
真实的极性/功能必须回到官方 RTL 的赋值去看。这与 §3.9「名字≠频率」是同一类错误。

### 编译

`interface` PASS（`B12/GPIOR_15/cmos_ctl1`）→ `map` PASS → `pnr` PASS → `pgm` PASS，
位流 **2026-11-11 20:25:59**。

## 3.13 进度记录：2026-11-11（A3.3 DVP 时序统计）

### 上板已验证（A3.2 收尾）

```
D=---cm T=00000000 P=+00 O=0 V=00 C=0   ← 上电 1.1 s 内
D=---cm T=00000000 P=+00 O=0 V=03 C=1   ← 稳定态：30 fps，配置生效
```

`V` 稳定在 3/100 ms = **30 fps**，正好是寄存器表 `// 1280x720, 30fps` 的设计点，
说明 SCCB 配置真的写进传感器了（不是默认模式）。

### 新增 `src/dvp_capture.v`

只做时序统计，**不碰 data[7:0]**（先量清楚再谈识别）：

| 统计量 | 含义 | 720p 期望 |
|---|---|---|
| `width` | 一帧里最长的 HREF 行包含的 PCLK 数 | 1280 |
| `height` | 一帧里的 HREF 行数 | 720 |
| `frames` | 完成的帧数（累计） | 递增 |

**跨时钟域做法**：pclk 域在 VSYNC 上升沿把 `w_max/line_cnt` 锁进 `w_lat/h_lat` 并翻转
toggle；24 MHz 域两级同步抓跳变后一次性搬数据。因为几何值两次锁存之间稳定 33 ms，
远超 2 个 24 MHz 周期，所以不需要握手应答。

pclk 域寄存器**用 `rst_n` 做异步复位**（pclk 可能比系统复位晚起，异步复位能保证初值确定）。

### 调试行扩到 52 字节

```
D=123cm T=00011000 P=+02 O=0 V=03 C=1 W=1280 H=720\r\n
```

W 固定 4 位、H 固定 3 位，便于肉眼比对。`width/height` 用新增的 16 位 `dv10()` 函数做
十进制分解（原来的 `div10u` 只有 10 位，装不下 1280）。

### 本轮两个问题

1. **`uart_report` 的 `idx` 已到 6 位上限 63**：报文 52 字节还够，但如果再加字段
   必须再放宽，否则会重演 §3.10 的"报文死循环"。
2. **补丁脚本用 `str.replace` 时锚点重复**：`// 调试串口：每测一次距离打一行` 在顶层出现两次，
   导致 `dvp_capture` 被插入两遍、`dvp_width` 重复声明。
   **教训：改顶层代码的脚本锚点必须唯一**，替换前先 `count` 一下。

### 编译

`map` PASS（ADD 263 / LUT4 1429 / FF 584 / DSP48 2）→ `pnr` PASS（setup slack **35.991 ns**）
→ `pgm` PASS，位流 **2026-11-11 20:40:03**。

### 上板实测结果（2026-11-11，重要）

```
D=---cm T=00000000 P=+00 O=0 V=03 C=1 W=2560 H=720     ← 稳定态
D=---cm T=00000000 P=+00 O=0 V=03 C=0 W=5184 H=801     ← 配置生效前的过渡帧
```

**`W` 的单位是"每行 PCLK 数 = 每行字节数"，不是像素数**：

| 观测 | 换算 | 结论 |
|---|---|---|
| W=5184 | 5184 ÷ 2 = 2592 | 默认全分辨率 2592 宽 |
| W=2560 | 2560 ÷ 2 = **1280** | 目标模式 1280 宽 |
| H=720 | — | 行数正确 |
| V=3/100 ms | = 30 fps | 与寄存器表 `1280x720, 30fps` 一致 |

两个数字都恰好是宽度的 **2 倍**，说明输出是 **16 bit/像素**。
寄存器表 `:56` 的 `24'h4300_61; // RGB.` 即 **RGB565**：
每个像素占 2 个 PCLK，1280 像素 → 2560 PCLK/行。

> **注意**：YUV422 也是 2 字节/像素，所以"2 倍"只能确定是 16 位格式，
> 具体是 RGB565 还是 YUV422 要靠"对着红色物体看数据"来确认（下一轮 color_detect 的第一件事）。

### 修正后的上板判据

| W / H | 含义 |
|---|---|
| **2560 / 720** | ✅ 1280×720 RGB565，时序全对 |
| 5184 / 801 之后跳到 2560/720 | ✅ 配置生效的正常过渡 |
| 2560 / 0 或 0 / 720 | HREF 与 VSYNC 有一根没接对 |
| 一直 5184 / 801 | SCCB 没生效（还是默认全分辨率） |
| 其他数值 | 检查 PCLK 频率与 HREF 极性 |

另：`frames` 计数与 `V=` 互相印证（A3.3 的 `dvp_capture` 内部有 `frames`，暂未打印）。

## 3.14 进度记录：2026-11-11（A3.4 颜色识别，已完成含全链路编译）

### 新增 `src/color_detect.v`

**流式统计，不需要帧缓存/DDR**：DVP 逐像素流，颜色块识别只要统计"一帧里各颜色各占多少像素"，
纯计数器即可。5 个 20 位计数器（1280×720 = 92 万像素/帧）。

| 输出 | 含义 |
|---|---|
| `color[2:0]` | 每帧一次的主色码：0=其他 1=红 2=绿 3=蓝 4=黄 5=白 |
| `new_color` | 1 clk 脉冲（clk 域），跨域用 toggle + 两级同步 |

分类链：先按 `R+G+B` 判黑（<36）与亮（>150），再判黄（R、G 都 >30 且 B <26），
最后按通道领先 `DOM_MARGIN=14` 判红/绿/蓝。阈值均为参数，上板按 `Q=` 调。

### 调试行扩到 56 字节

```
D=123cm T=00011000 P=+02 O=0 V=03 C=1 W=1280 H=720 Q=1
```

`Q=` 是主色代码。`idx` 已到 6 位上限 63，**再加字段必须放宽位宽**。

### 本轮三个真实 bug（都在 color_detect 第一版里）

1. **`BRIGHT_SUM = 7'd150` 超出 7 位**（最大 127）被截断成 22，判定全乱。
   `R+G+B` 最大 187，必须 8 位。
2. **给 HREF 做 2FF、data 不做**，两者错开 2 拍 → **字节奇偶整体反相**，
   现象是"纯红被判成纯蓝"（R=B 互换）。
   **在 pclk 域里 HREF/DATA/VSYNC 本来就是同步信号，只需一级寄存器，不能做 2FF。**
3. **测试台在 posedge 改数据**，与 DUT 的采样沿打架。真实 OV5640 是**下降沿换数据、
   上升沿数据稳定**，tb 必须在 negedge 更新 data/href/vsync。

修完 `color_detect_tb` 7 项全 PASS（红/绿/蓝/黄/黑/小色斑/new_color 计数）。

### 当前状态（2026-11-11 21:38 复核并收尾）

- **补工程文件列表**：此前只写"已加"但实际没加。本轮已在 `FpgaCar/FpgaCar.xml` 的
  `<efx:design_file>` 列表补上 `src/color_detect.v`（现共 14 个设计文件），
  否则 `FpgaCar.v:256` 例化的 `color_detect u_color` 会在综合时报
  `VERI-1063 instantiating unknown module 'color_detect'`。iverilog 不读 xml，
  所以此前"仿真全 PASS"掩盖了这个缺口（同类坑见 §3.9:222）。
- **shell 问题查清**：报 `spawn C:\Program Files\PowerShell\7\pwsh.exe ENOENT` 的是
  编辑器侧的命令通道，不是本机缺文件——本机 `pwsh.exe` = 7.6.10 仍在，
  `C:\Efinity\2026.1\bin\efx_run.bat` 也在。改用 `cmd.exe /c` 直接调用即绕开，
  无需重装 PowerShell。
- **仿真复验**（iverilog 10.x，`-g2012 -Wall`）：
  `color_detect_tb` 7 项 PASS、`uart_report_tb` 3 项 PASS、`FpgaCar_tb` 顶层 smoke 5 项 PASS。
- **全链路编译已跑通**（`cmd.exe /c efx_run.bat --flow <map|pnr|pgm> FpgaCar.xml`，三流水 EXIT=0）：
  `map` PASS（**EFX_ADD 276 / EFX_LUT4 2053 / EFX_FF 697 / DSP48 2**；
  `outflow/FpgaCar.hier_util.rpt` 里 `u_color` = 559 LUT / 104 FF，
  `outflow/FpgaCar.map.out:27,41` 有 `color_detect.v` 的分析与编译记录，证明已进网表）→
  `pnr` PASS（setup slack **36.462 ns**）→ `pgm` PASS。
  位流 **`outflow/FpgaCar.bit` / `.hex` = 2026-11-11 21:38:30**（.bit 1665102 B）。
- 顺手修 `src/uart_report.v:108` 注释笔误：`MSG_LEN 已到 35` → `MSG_LEN=56`（实际值从未变）。

### 上板判据

| 现象 | 含义 |
|---|---|
| 对着纯红 `Q=1`、纯绿 `Q=2`、纯蓝 `Q=3` | ✅ RGB565 假设成立，颜色通路打通 |
| 对着红/绿/蓝 `Q` 都一样或都 0 | 输出不是 RGB565（可能是 YUV422），需要 YUV→RGB 转换 |
| `Q=5` 一直出现 | 白色阈值太低（白纸背景被当成主色） |

### v4 第二行帧统计遥测（2026-11-12 实现并上板）

`uart_report.v` 每帧先发 64 字节第一行，紧跟 54 字节第二行（`MSG2_LEN=54`，
状态机由 4 态扩成 6 态 `R_IDLE/R_LOAD/R_SEND/R_WAIT/R_SEND2/R_WAIT2`）：

```
R=00300 G=00000 B=00000 Y=00000 S=3F SB=F800 LB=F800
```

| 字段 | 含义 |
|---|---|
| `R/G/B/Y` | 本帧判为该色的**像素个数**（20 位，十六进制） |
| `S` | 本帧最大饱和度 `max-min`（7 位，`SAT_MIN=16`） |
| `SB` | **最饱和**那个像素的两个原始字节（RGB565） |
| `LB` | **最亮**那个像素的两个原始字节（按 G 近似亮度） |

解析端按行首字母分流：`'D'`=第一行、`'R'`=第二行。
采集脚本 `tools\cap.py` / `tools\cap.bat`（走 `env.bat` 里的 `PYEXE`，才有 pyserial）：
自动配对两行、按帧打印、给出各色**峰值/均值**、把 SB/LB 解成 R/G/B、可落 CSV。

### 2026-11-12 20:20 实测结论：**画面里没有饱和色，不是数据通路错**

221 帧统计（镜头对着白纸+黑线赛道）：

| 量 | 实测 | 判据 | 结论 |
|---|---|---|---|
| `W` | **2560** | 720p 1280 像素 × 2 字节 | ✅ 8 位 DVP + 16bpp，`W` 本来就该是 2× 像素数 |
| `H` | 720 | — | ✅ 行数正确，VSYNC/HREF 时序无误 |
| `R` | 峰值 77 / 均值 15.9 | `MIN_PIX=200` | ❌ 远不够 |
| `G` | 峰值 **1** / 均值 0.0 | 同上 | ❌ 中性场景里 G 几乎不可能领先 |
| `B` | 峰值 49 / 均值 20.7 | 同上 | ❌ |
| `Y` | 峰值 9 / 均值 0.2 | 同上 | ❌ |
| `S` | 峰值 23 / 63（`SAT_MIN=16`） | — | 有饱和像素但很弱 |
| `LB` | `F71B` → R=60 G=56 B=54 | — | ✅ 最亮像素≈中性白，**RGB565 解码自洽** |
| `SB` | `6C96` → R=26 G=36 B=44 | — | 最饱和处偏蓝，不是黄 |

反证 YUV422：若输出是 YUV，U/V 应聚集在 0x80 附近且伪 `S` 会经常冲到 40~63；
实测 `S` 峰值只有 23、最亮像素解码成中性白，**支持 RGB565 而非 YUV**。
`Q` 恒为 0 的直接原因是**四色计数都 < 200**（`MIN_PIX`），根因是赛道本身没有饱和色块。

### 2026-11-12 20:29 对黄纸实测：`Q=4` 打通，但暴露偏绿白平衡

镜头对准黄纸 8 s（294 帧）：

| 量 | 实测 | 说明 |
|---|---|---|
| `Y` | 峰值 **187373**（均值 14.7 万） | ✅ 黄色计数远超 `MIN_PIX=200` |
| `G` | 峰值 **213555**（均值 19 万） | ⚠️ 同一张纸有相当比例被归成绿 |
| `Q` | **出现 2 和 4 交替** | ⚠️ 每帧翻转，不是稳定黄 |
| `S` | 峰值 36 | ✅ |
| 中心 `XY=8569` | **R=32 G=43 B=18**（6 位） | 关键证据 |
| `LB=958F`（白纸最亮） | R=36 G=44 B=30 | 白纸也偏绿 → **AWB 偏绿，不是黄纸问题** |

诊断：`|R-G| = 11` 只比旧门限 `YEL_DR=14` 小 3，`min(R,G)-B = 14` 只比
`YEL_DB=12` 大 2——**两个门限都卡在边界上**，同一块黄纸的光照微差就把像素劈成两派，
于是 `Y` 和 `G` 各占一半、`Q` 逐帧在 4/2 之间跳。

### 修复：放宽两条判黄门限（`src/color_detect.v:50-51`）

| 参数 | 旧值 | 新值 | 理由 |
|---|---|---|---|
| `YEL_DR` | `6'd14` | **`6'd24`** | 偏绿白平衡下黄纸 `|R-G|` 达 11~18；真绿 `|R-G|=34` 仍在门外，不会误吞 |
| `YEL_DB` | `6'd12` | **`6'd8`** | 黄纸 `min(R,G)-B=14`，旧值只剩 2 的余量；中性色已先被 `SAT_MIN` 滤掉，放宽不影响黑白灰 |

新增两条**上板数据驱动**的回归（`sim/color_detect_tb.v:155-163`）：
- `yelcast` R=137 G=173 B=72 → 必须 `Q=4`（锁死偏绿黄纸的判定）
- `truegrn` R=42 G=177 B=42 → 必须 `Q=2`（防止放宽后误吞真绿）

`color_detect_tb` 现 **12 项全 PASS**（原 11 项 + 1 项 `truegrn`，`yelcast` 并入），
`uart_report_tb` 3 组 × 2 行仍全 PASS。

### 第二轮：`Q` 仍在 4/2 之间轮询 → 两个真因

先用 728 帧 CSV 量化"黄纸那一轮到底黄绿各占多少"（`data/_cap_y4.csv`，十进制列）：

| 指标 | 数值 |
|---|---|
| 黄帧（`Y>100k`）| 371 / 728 |
| 平均 `Y` | 115656 |
| 平均 `G` | 118965 |
| **`G/Y`** | **1.03**（黄绿几乎对半，这才是轮询的根源） |

**真因 1：`YEL_RG=28` 是绝对亮度地板。** 黄纸暗部/背光处 `min(R,G)<28`，
直接被踢出黄色分支，落到下面的"绿最大"分支 → `G` 计数虚高。
改为 `YEL_RG = 6'd16`（`src/color_detect.v:49`）：中性色早已被 `SAT_MIN` 先滤掉，
这里只需防"极暗暖色噪声"。

改完复采 828 帧（`data/_cap_y6.csv`）对比：

| 指标 | 改前 | 改后 |
|---|---|---|
| 平均 `Y` | 115656 | 56707 |
| 平均 `G` | 118965 | **7960** |
| **`G/Y`** | **1.03** | **0.14**（降 7 倍 ✅）|

**真因 2：残留绿仍过 `MIN_PIX`。** 7960 > 200，轮询照样轮到绿，`Q` 依旧 108/104 交替。
新增**主导色门限** `DOM_SHIFT`（`src/color_detect.v:53` + `elig` 计算）：
只有计数 ≥ 本帧最大色的 `1/4` 才算达标。黄纸场景残留绿约 7%，被压掉；
四色等面积（各 25%）仍全部达标，不影响四色轮询。

回归（`sim/color_detect_tb.v`）新增：
- `yeldsdw` R=80 G=104 B=40 → `Q=4`（黄纸暗部不再掉到绿）
- `domyel1/2/3` 黄 4000px + 绿 300px → 连续三帧都必须是 `Q=4`
- `domgrn1` 绿 4000px + 黄 300px → 必须是 `Q=2`（门限双向对称）

`color_detect_tb` 现 **17 项全 PASS**，`uart_report_tb` 仍全 PASS。

> 注：白平衡偏绿是**传感器侧**的问题（`I2C_OV5640_1280720_Config.v` 里未写 AWB 相关寄存器，
> 实测也无 `0x3406`/`0x5001` 写入）。本轮从判定侧兜住；若要根治，
> 可后续在配置表里打开 AWB（`0x3406=0x00` 恢复自动白平衡），届时 `YEL_DR`/`DOM_SHIFT` 都可收紧。

### 第三轮：偶发高 `G` 帧压不住 → 从分类器源头修（2026-11-12 20:43）

主导色门限只能砍掉"占比小"的多数派，砍不掉**整帧突然变绿**的偶发帧。烧入第二轮位流后
30 s 复采（`data/_cap_y8.csv`）仍出现 `Q` ∈ {2,3,4}：

| 指标 | 数值 |
|---|---|
| `Y` 峰值 | 147942 px |
| `G` 峰值 | **21355 px**（已超本帧最大色的 1/4，门限形同虚设）|
| `G/Y` 均值 | ≈0.16 |

根因仍在分类器：黄纸的阴影/背光像素 `min(R,G)` 只有 8~20，被 `YEL_RG=16` 这条
**绝对亮度地板**踢出黄色分支，落到下面"绿最大"分支；而偏绿白平衡下黄纸像素本来就
`R=32 G=43`（G 最大但只比 R 高 11），于是整片黄纸被记成绿。

两处修改（`src/color_detect.v`）：

| 参数 | 旧值 | 新值 | 理由 |
|---|---|---|---|
| `YEL_RG` | `6'd16` | **`6'd8`** | 黄纸阴影 `min(R,G)` 只有 8~20；中性色已被 `SAT_MIN` 先滤掉，这条只防"极暗无彩噪声" |
| `GRN_DR`（新增）| — | **`6'd16`** | 绿色分支从"G 是最大分量"改为"G 必须比 R 高 ≥16"；黄纸 `G-R=11` 不再算绿，真绿 `R=10 G=44` 不受影响 |

绿色分支现在是 `cls = (g7 >= r7 + {1'b0, GRN_DR}) ? 3'd2 : 3'd0;`（`src/color_detect.v:163`）
——G 虽最大但不够绿，就记为**中性**。宁可漏计，也不要造成假绿。

新增两条回归（`sim/color_detect_tb.v`）：
- `yelsdw2` R=32 G=120 B=0（6 位 8/30/0）→ `Q=4`，`min(R,G)=8` 正好卡在新 `YEL_RG` 上
- `grnsdw2` R=16 G=120 B=16（6 位 4/30/4）→ `Q=2`，`G-R=26 > GRN_DR`，暗绿不被误伤

`color_detect_tb` 现 **20 项全 PASS**，`uart_report_tb` 仍全 PASS；
map / pnr / pgm 三段烧录全 PASS，位流已进 Flash。

#### 上板验证（2026-11-12 20:47，`data/_cap_y10.csv`，771 帧有效）

只统计"确实有黄画面"的帧（`Y > 10000`，704 帧），与前一轮同口径对比：

| 指标 | 第二轮位流 | 第三轮位流 | 结论 |
|---|---|---|---|
| 平均 `G` | 7769 | **135** | 假绿基本消失 |
| **`G/Y`** | **0.115** | **0.005** | 降 23 倍 ✅ |
| `Q=2` 帧占比 | 47.7%（375/786）| **0.1%（1/704）** | 绿不再抢轮询 ✅ |

**绿污染问题已解决。** 该窗口内 `Q` 仍见 1/3/4 交替，但那是**真实画面内容**：
现场同时有红色和蓝色物体（`R` 峰值 17869、`B` 峰值 17002，两者都过 200 门限且
都超过本帧最大色的 1/4），四色轮询按设计依次把红/蓝/黄送到"最大色"位置，属于正确行为。
按"每帧 `Q` 是否属于本帧达标集合"复核：771 帧中 494 帧命中，277 帧"未命中"全部是
多色同时达标时轮到了别的颜色，不是判定错误。

### 第四轮：v5 门限（占总量 1/32）上板失效 → v6 改回「占最大色 1/5」（2026-11-12 21:40）

v5 为解决「小块真色被一大块主色挤掉」，把主导色门限从「占最大色 1/4」换成「占鲜艳总量 1/32」。
仿真与三段流水全 PASS，但**上板实测反而退化**：

| 批次 | 场景 | 帧数 | Q 分布 |
|---|---|---|---|
| `data/_cap_y10.csv`（v4，1/4 of max） | 真实多色物体 | 771 | `Q=2` 仅 0.1% |
| `data/_cap_y12.csv`（v5，1/32 of total） | 黄纸 + 固定蓝残留 | 546 | **`Q=3` 占 48%** |

**根因**：总量口径没有绝对锚点。画面里稳定存在一块蓝色（蓝布/反光，`B` ≈ 3840~6145 px），
占鲜艳总量的 4.3% > 1/32(3.125%) → **帧帧过门限**，与黄交替。总量越小（主色越暗）门限塌得越低，
反而更容易被固定亮度的小残留钻空子。

**v6 口径**：门限基数改回**本帧最大色**，比例从 1/4 收紧到 **1/5**，用整数比较实现
（`cnt*5 >= cnt_mx`，避免整除截断在边界抖动；`cnt*5` 综合成 `(x<<2)+x` 两个加法器）。
参数由 `DOM_SHIFT`（3 位移位量）改为 `DOM_DIV`（4 位除数），见 `src/color_detect.v:66`。

选 1/5 的依据（同一批实测数据回算）：

| 口径 | `data/_cap_y13` 蓝入选 | `data/_cap_y10` 真实多色可轮 |
|---|---|---|
| 1/8（12.5%） | 1.8% | 99.6% |
| 1/7 | 0.8% | 99.6% |
| 1/6 | 0% | 99.5%（余量仅 0.17%，太险）|
| **1/5（20%）** | **0%** | **99.2%** ✅ |
| 1/4（25%） | 0% | 93.9%（开始饿死真色）|

**回归同步**（`sim/color_detect_tb.v`）：`domrot` 场景由「黄 4000 + 绿 300」改为「黄 4000 + 绿 900」
（900×5=4500 ≥ 4000，绿占 22.5% 过门限）；`domyel1-3`/`domgrn1` 的「黄 9000 + 绿 250」不变
（250×5=1250 < 9000，仍被压）。`tools/tune_color.py` 同步改为按最大色复刻，并对「样本标签 < 3 类」
的情况跳过网格搜索（单色样本下门限恒不起作用，搜出的值必然退化到最小值）。

**上板验证（`data/_cap_y14.csv`，623 帧）**：

| 指标 | v5（`data/_cap_y12`） | v6（`data/_cap_y14`） |
|---|---|---|
| `Q` 取值 | {3, 4}，`Q=3` 占 48% | **{4}，100%** ✅ |
| 蓝/最大色 p99 | 12.0% | 12.16% |
| 蓝/最大色 max | 16.5% | **14.16%**（门限 20%，余量 5.8 个点）|
| 蓝过门限帧数 | 264/546 | **0/623** ✅ |

四个 tb（`color_detect_tb` 20 项、`color_seq_tb` 11 项、`uart_report_tb` 6 项、`frame_snap_tb` 6 项）
全 PASS，map/pnr/pgm 三段 EXIT=0，位流已烧入。

> 注意：这一轮只修的是「固定亮度小残留被放行」，**没有**改判黄门限，也没有开 AWB。
> 若后续打开 AWB（`0x3406=0x00`），白平衡会变，届时 `YEL_DR` 与 `DOM_DIV` 都需按新实测重标。

#### 位宽缺陷修复：`cnt*5` 22 位会溢出（2026-11-12 21:47）

v6 用 `cnt*5 >= cnt_mx` 代替移位比较，但初版把 `cnt_*5` 声明成 `[21:0]`（22 位）：

- 单色上限 = 1280×720 = **921600**，×5 = **4,608,000** > 2^22 = 4,194,304 → **溢出回绕**；
- 溢出临界像素 = ⌊2^22 / 5⌋ = **838860**；
- 更隐蔽的一点：`({2'b00, cnt_r} << 2)` 的移位结果宽度 = 左操作数宽度（也是 22 位），
  所以即使把左边加宽，只要操作数没先补位，高位照样被截掉。

**后果**：`cnt > 838860` 时乘积回绕后**小于** `cnt_mx`，`elig` 全 0 → 整帧被判成「无色」（`Q=0`）。
实测：`cnt=921600` 时 22 位算出 413696；`cnt=838861` 更直接回绕成 1。

**修法**（`src/color_detect.v:215-219`）：宽度 22 → **23 位**（2^23 = 8,388,608 够），
并先把操作数补到 23 位再移位：

```verilog
// 移位结果宽度 = 左操作数宽度，必须先补到 23 位再移，否则高位被截掉。
wire [22:0] cnt_r5 = {3'b000, cnt_r} + ({3'b000, cnt_r} << 2);   // g/b/y 同形
```

**回归固化**（`sim/color_detect_tb.v` 新增 `bigframe`）：发一帧 900000 px 纯黄
（900000×5 = 4,500,000，22 位下回绕成 305,696 < 900000 必判 0），断言 `color==4` 且
`dbg_cnt_y==900000`。突变测试确认该用例有效：临时改回 22 位 → `FAIL: bigframe -> color=0`；
恢复 23 位 → `PASS`。iVerilog 跑这一帧约 +10 s（仿真总时长 45.5 ms），可接受。

**回归结果**：`color_detect_tb` 21 项全 PASS（17 条 `check()` + 轮询/小色块/`new_color` 三条 +
`bigframe`）、`color_seq_tb` 11 项、
`uart_report_tb` 6 项、`frame_snap_tb` 6 项，无 FAIL。map/pnr/pgm 三段 EXIT=0 并重新烧板。

**上板复测（`data/_cap_y15.csv`，655 帧）**：`Q` 全为 4，蓝过门限 **0/655**，
蓝/最大色 p50=8.30% p99=14.44% max=15.72%。与 y14 一致的「不回退」结果——
真实画面单色计数远低于 838860，本修复是为极端帧兜底，不是改变常态行为。
#### 能否用网上图片训练阈值？（2026-11-12 结论：像素级能验，帧级不能）

分两层看，别混为一谈：

**① 像素级门限（`SAT_MIN` / `YEL_RG` / `YEL_DR` / `YEL_DB` / `GRN_DR`）——网图能验，而且已经验过。**
把 sRGB 典型色直接喂进 `classify()`（逐位复刻 RTL），全部判对：

| 输入 | 期望 | 实际 |
|---|---|---|
| `#E8C33A` `#FFF44F` `#FFD700` `#CCFF00` | 黄 | YELLOW |
| `#E53935` | 红 | RED |
| `#43A047` | 绿 | GREEN |
| `#1E88E5` | 蓝 | BLUE |
| 白 `#FFFFFF` / 灰 `#808080` | 中性 | NEUTRAL |

即使板上白平衡偏绿（板上黄纸实测 `G>R`，6 位 28/34/18），这些 sRGB 色**不经任何校正**也判对。
原因是判黄用的是**相对关系**（`|R-G|<=24` 且 `min(R,G)>=B+8`），对整体色偏不敏感。
结论：**换色卡/换光源想验像素级规则，拍张照片跑 `webimg_to_frame.py` 就够，不用上板。**

**② 帧级门限（`MIN_PIX` / `DOM_DIV`）——网图验不了，只能上板。**
这两个值取决于「目标占画面多大比例 / 背景有多少同色残留 / 传感器噪声」，
而网上图片的构图比例和你的车模视野毫无关系。`tune_color.py` 的网格搜索在有 3 类以上标签时才会跑，
单色样本下会退化到最小值（工具里已打印警告）。

**一个必须知道的坑：不要试图用"每通道增益"把网图拉成板子色域。**
用白色和黄色两个锚点分别反解增益，结果互相矛盾：

| 锚点 | 增益 (R,G,B) | 反推另一种色 |
|---|---|---|
| 白（中性必须仍中性） | (0.546, 0.592, 0.472) | 黄变 (126,115,27)，板上实测 (110,138,72) |
| 黄（饱和色必须吻合） | (0.474, 0.708, 1.241) | 白变 (113,169,255) **青蓝**，板上实测 (131,142,111) |

板上黄纸 `R/G=0.80`，sRGB 黄 `R/G=1.19`——**大小关系是反的**，
说明 OV5640 固定白平衡下的响应不是每通道线性增益。实测用黄锚定增益变换白墙，
1200 px 里 **735 px 被判成绿**。所以 `webimg_to_frame.py --wb board` 只做白锚定，
只保证"中性色进去还是中性色"，**不承诺复现板上饱和色相**。

**工具用法**（依赖 Pillow，必须用系统 Python，Efinity python311 没装 PIL）：

```bash
# 网图 → 40x30 RRGGBB CSV（与 frame_snap.v 的 GW=40/GH=30 同构，BOX 区域平均降采样）
python tools/webimg_to_frame.py shot.png data/_web_yellow.csv --label yellow
# 可选：白锚定白平衡
python tools/webimg_to_frame.py shot.png data/_web_yellow.csv --label yellow --wb board
# 喂给调参工具（可多帧混跑）
python tools/tune_color.py data/_web_yellow.csv:yellow data/_frame_1.csv:yellow data/_frame_2.csv:yellow
```

**推荐工作流**：网图批量验像素级规则 → 上板抓 `data/_frame_*.csv` 标帧级门限 →
用 `data/_cap_*.csv` 的整段录像做回归（`Q` 是否稳定、蓝残留比例）。三档证据不能互相替代。

### 采集工具补充（`tools/cap.py`）

中心像素 `XY` 之前只解析不打印，现已补一行解码输出：

```
last XY 8D6B -> R=34 G=43 B=22 (center pixel)
```

排查"镜头到底对着什么颜色"时，这一行比 `SB`/`LB`（最饱和/最亮像素，可能是画面的边缘或高光）
更直接。

## 3.15 下载与调试工具链（2026-11-12 打通，命令行全自动）

目标：不再依赖 Efinity GUI 的 Programmer 按钮，从命令行完成"烧位流 / 固化 Flash / 看遥测"。

### 三个可用的脚本（`FpgaCar/tools/`）

| 脚本 | 作用 | 实测结果 |
|---|---|---|
| `tools\dl.bat [file.bit]` | JTAG 烧 `outflow\FpgaCar.bit`，掉电丢失 | `Device ID read from JTAG: 0x10660A79` / `PROGRAMMING DONE` |
| `tools\flash.bat [file.hex]` | 把 `.hex` 写进板上 SPI Flash（三步全自动） | `Flash device: Winbond W25Q64 8 MiB (JEDEC ID: 0xEF6017)` / `Flash verify successful` / `FLASH DONE` |
| `tools\mon.bat [COM12] [秒]` | 读调试串口（CH340 → COM12，115200-8-N-1）并汇总各字段 | 4 s 收到 149 行遥测 |

辅助文件：`tools\env.bat`（Efinity 2026.1 全套环境变量 + `PYEXE`）、
`tools\jtag_program.py`（修复 Efinity 自带下载器的越界 bug）、
`tools\uart_mon.py`（串口解析）、`FpgaCar\_jtag.jcf`（JTAG 链描述，已生成）。

### 官方命令行也能直接烧（2026-11-12 实测有效）

```bat
cd /d D:\VF-Ti60F225_HDK_V2.1_20251009\FpgaCar
C:\Efinity\2026.1\bin\efx_run.bat FpgaCar.xml --flow program --pgm_opts mode=jtag
```

注意 **design 位置参数必须在最前**，`--flow program` 放后面；只给 `--flow` 会报
`error: the following arguments are required: design`。
实测输出（EXIT=0，约 14 s）：

```
Programming using Board Profile: Generic Board Profile Using FT232H
Connecting to JTAG_TAP: efx_ti
JTAG Programming on ftdi://0x0403:0x6014:0:ff/1
Programming 'outflow\FpgaCar.bit' via JTAG at freq 3.0 MHz
Device ID read from JTAG: 0x10660A79
... finished with JTAG programming
```

这与 3.15 前面记的 `ftdi_program.py:3090` 越界 bug 不冲突：走 `efx_run --flow program` 时
`run_program()` 里的 `set_up_urls()` 已经被 `efx_run.py` 自己的 URL 填充路径绕开，
所以**这条路不需要 `tools\jtag_program.py` 补丁**。`tools\dl.bat` 仍保留（它更短、能指定任意 `.bit`）。

烧完立刻读串口可确认新位流已在跑（`V=03`、`W=2560 H=720` 是本次编译的值）：
`cmd /c "tools\mon.bat COM12 5"`。JTAG 烧写是**易失**的，掉电后回到 Flash 里的旧镜像，
要固化仍需 `tools\flash.bat`。

### 官方 FlashShell 的勘察结论（2026-11-18，结论：不能替代）

Efinity 2026.1 确实自带一套命令行 Flash 工具 `C:\Efinity\2026.1\pgm\flashshell\`
（`flashshell.py`，基于 cmd2），命令包括
`find_devices` / `auto_config` / `jtag_flash_read` / `jtag_flash_write` / `jtag_flash_erase` /
`spi_flash_read` / `spi_flash_write` / `spi_flash_erase` / `spi_reg_*`。

在命令行里执行 `flashshell.py help` 能正常列出命令，`find_devices` 也能识别到
`('Single RS232-HS', '')`，但 **`auto_config -t jtag` 在本机直接失败**：

```
'FlashJtagManager' object has no attribute 'add_debug_profile'
EXCEPTION of type 'AttributeError' occurred with message: 'NoneType' object has no attribute 'flash_load'
```

原因是 `exts/ext_ftdi.py` 的 `do_auto_config` 走 `jtag` 分支时调用了
`FlashJtagManager.add_debug_profile()`，而本版本 `efx_dbg.flash.FlashJtagManager` 没有这个方法
（安装包内部版本不一致）。`spi` 分支则需要 FTDI 直连 CCK/CS，本板排针上没有，同样不可用。

**结论**：官方 FlashShell 在这块板 + 这个安装版本上不成立，继续用 `tools\flash.bat`
（它调用的 `ftdi_program.py` 是同一套官方后端，只是绕过了那个失效的 JTAG 分支）。
若日后升级 Efinity 到版本自洽的安装包，可重试 `auto_config -t jtag` + `jtag_flash_write -i <hex>`。

另外记一个环境要求：`flashshell.py` 和 `ftdi_program.py` 的 `__main__` 都会读
`EFINITY_USER_DIR` 与 `EFINITY_USER_DIR_INI`，缺任一个都直接 `KeyError` 退出。
`tools\env.bat` 里已经设好，手敲命令时别漏。

### 为什么 `flash.bat` 必须三步

1. **SPI Active 直连不可用**：本板 FT232H 只引到 JTAG 引脚，CCK/CS 不在 FTDI 排针上，
   直接烧报 `ERROR: Unknown error trying to read flash device, aborting`。
2. **Flash 只能经 JTAG→SPI bridge 访问**，而 bridge 本身是要先跑起来的位流。
   Efinity 自带预编译镜像 `C:\Efinity\2026.1\pgm\fli\titanium\u10660A79.bit`；
   不先烧它会报 `Unsupported JTAG Bridge version: 255.255`。
3. 写完 Flash 后板上跑的是 bridge 设计，所以要回烧应用位流，否则车不工作。

### 踩过的两个坑（都可复现）

- **Efinity 2026.1 下载器自身 bug**：`ftdi_program.py:3090` `set_up_urls()` 用
  `bus_to_url_idx['B'] = 1` 取 `url_list[1]`（JTAG 的 TCK 在 BDBUS），
  而单接口 FT232H 的 `target.URLS` 只有 1 项 → `IndexError: tuple index out of range`。
  `tools\jtag_program.py` 把 URL 列表补成 4 项后同时修好了 `set_up_urls()` 与
  `configure_jtag_session()`。
- **环境变量必须齐**：缺 `PYTHONHOME` 报 `No module named 'encodings'`，
  缺 `EFINITY_USER_DIR(_INI)` 报 `KeyError`。全部集中在 `tools\env.bat`。

### 调试能力现状（重要：分三档）

| 档 | 能力 | 现状 | 代价 |
|---|---|---|---|
| A | **串口遥测**：`D/T/P/O/V/C/W/H/Q/XY` 全部关键量，60 ms 一行 | ✅ 已可用 | 0（已占 56 字节/行） |
| B | **加更多遥测字段**：任何内部信号都能塞进串口行 | 改 `uart_report.v` + `FpgaCar.v` 后重编 | 改 RTL，占少量逻辑 |
| C | **Efinity Debugger（VIO/LA）在线看波形** | ❌ 当前位流里没有任何调试核 | 见下 |

C 档的根本原因：`FpgaCar.xml:109-113` 的 `<efx:debugger>` 是
`auto_instantiation="off"` / `profile="NONE"`，`FpgaCar.peri.xml` 里没有
`<efxpt:jtag_info>` 块，顶层也没有 `jtag_inst1_*` 端口 —— 所以 Debugger 连上去也看不到信号。
要走 C 档需四件套：

1. `FpgaCar.peri.xml` 加 `<efxpt:jtag_info>`（`JTAG_USER1`，11 根 `jtag_inst1_*`，
   参考 `C:\Efinity\2026.1\examples\helloworld-dbg_AUTO_AND_MANUAL\helloworld.peri.xml:132-148`）；
2. 顶层加对应端口并标 `(* syn_peri_port = 0 *)`；
3. 写 `debug_profile.wizard.json`（要抓的信号列表 + 采样深度）；
4. `FpgaCar.xml` 的 `<efx:debugger>` 改 `auto_instantiation="on"` + 指向该 profile，
   再走 `efx_run --flow compile`（会自动生成 `work_dbg/debug_top.v` 并给 pnr 加 `--enable_dbg`）。

另外 `efx_dbg.shell` 虽然能无头跑（`python -m efx_dbg.shell < cmds.txt`），但它的
`auto_config` 在本板会 `KeyError: 'Single RS232-HS'`（本板 FT232H **序列号为空的**，
而它的描述表只认官方 devkit 名字），`config_jtag` 又不收 URL —— 所以不能纯脚本化驱动，
C 档实际操作时得开 GUI。

**结论**：日常迭代用 A 档（`dl.bat` + `mon.bat` 循环，几秒一轮）；
只有当某个 bug 靠串口数值定位不了（例如 DVP 时序毛刺、PID 内部抖动）才值得上 C 档。

## 3.8 编译状态：已全部跑通，无需再手工做第 1–5 步

以下步骤历史上走过的 GUI 路径保留作参考；当前工程已配置完成，直接打开即可编译下载：

1. **File → Open Project** → 选 `FpgaCar/FpgaCar.xml`（你已经建好的那个空工程）。
2. 工具栏 **Edit Project** → **Design** 选项卡：
   - 点 **Import Design & Constraint Files** → **File to Import = All Files**（否则看不到 .sdc）→ 分两次把文件加进列表：先浏览 `FpgaCar/src/` 选 `FpgaCar.v`，再浏览 `FpgaCar/` 根目录选 `FpgaCar.sdc` → **Choose**。
     两个文件本来就在工程目录里，**不要勾 Copy to Project**（勾了会复制出副本、把 .xml 里的相对路径弄乱）。
     导入后 `FpgaCar.xml` 会自动出现 `<efx:design_file name="src/FpgaCar.v"/>` 与 `<efx:sdc_file name="FpgaCar.sdc"/>`，
     正好对齐官方 `06-FPGA_HDL_Basic-2023.2/01_LED_8bit_Test/LED_8bit_Test.xml` 第 10–12、23 行。
   - **Top Module** 填 `FpgaCar`（你建工程时已填，核对一下）。
   - 确认 `sim/FpgaCar_tb.v` **没有**出现在文件列表里。
   - 点 **OK**。
3. 工具栏 **Interface Designer** → 这是 Titanium 必做的一步（管脚不写在 HDL 里）：
   - **Device Settings**：BL / BR / TL / TR 设 **3.3 V LVCMOS**，其余全部 **1.8 V**（1A/1B/2A/2B 经 0Ω 电阻接 VDD1V8；3A 默认也是 1.8 V，只有走 MIPI 时才需要改 1.2 V——本工程没用到）。
   - 按顶层端口逐个 **Add Block / Create a GPIO bus** 建 GPIO 实例，IO Standard 选 3.3 V LVCMOS。
     **I2C 的两个块要按 Efinix 约定建**：`i2c_scl` → `mode="output"`；`i2c_sda` → `mode="inout"`
     （自动生成 `i2c_sda_IN` / `i2c_sda_OUT` / `i2c_sda_OE` 三个端口，正好对上顶层）。
     其余输入用 `mode="input"`、输出用 `mode="output"`，总线（track[7:0] / cmos_data[7:0] / led[7:0]）
     用 **Create a GPIO bus** 一次建 8 位。
   - 点 **Show/Hide Resource Assigner** → Instance View 里**双击 Resource / Package Pin 单元格**下拉选资源 → 回车。
     可分配管脚查资料包 `04_原理图&PIN TCL/Ti60_Board_引脚定义-20230703-V1.0.xlsx` 的 **DC3-40** 页；
     **避开 User_IO0 / User_IO1**（与核心板复用且默认上拉）。
     参考：24 MHz 时钟 → `GPIOL_11`；板上 8 LED → `GPIOR_25/22/28/21/24/27` + `GPIOL_01/02`；
     调试串口 → `GPIOT_N_16`(RX) / `GPIOT_P_16`(TX)；OV5640 走独立 DVP 排针，不占 DC3-40。
   - 点 **Generate Constraints File** → **Save** → 关闭。首次会生成 `FpgaCar.peri.xml`。
4. 时序约束：工程根目录的 `FpgaCar.sdc` 已写好 `create_clock -period 41.667 [get_ports clk]`（24 MHz），
   第 2 步一起导入即可（先跑通可跳过这一步，正式设计必做）。
   以后新增时钟域要逐条补 `create_clock`，跨时钟域加异步 FIFO / 双触发器 + false path。
5. Dashboard 保持 **Automated** → 点 **Synthesize**（或 **Run Complete Flow**）→ 看 Results 报告。
6. **Programmer** → **Select Image File** 选 `outflow/FpgaCar.bit` → 模式 **JTAG** → **Start Program**。
   比赛前改选 `outflow/FpgaCar.hex` + **SPI Active**（勾 Erase Before Program）固化到板载 W25Q64JWSSIQ，
   满足细则 3.2.3④ 一键启动、掉电不丢。

> 骨架阶段未例化 PLL，所以顶层时钟端口就叫 `clk`，不需要先配 PLL 块。
> 等做图像流水线 / Sapphire 软核需要高频时钟时，再去 Interface Designer 加 PLL 块，
> 把顶层端口改成该块输出名（参考 `06-FPGA_HDL_Basic-2023.2/01_LED_8bit_Test/src/LED_8bit_Test.v`
> 用的是 `pll_inst1_CLKOUT0` / `pll_inst1_LOCKED`）。

## 3.16 进度记录：2026-11-12（A3.5 车载显示 = OLED 驱动 + 颜色顺序记录）

### 为什么这一轮先做显示，而不是继续图像

细则 4.3.3 / 5.1 明确：颜色顺序必须**在车载屏上持续显示到裁判拍照**，口头报告不计分。
而 `color_detect` 每帧只输出"本帧占比最大的那一个颜色"，**根本不含顺序信息**——
同一色块会被连报几十上百帧，若直接送去显示，屏上永远只有一个颜色。
所以显示链路要两级：`color_detect`（逐帧判色）→ **`color_seq`（去重 + 先到先得记顺序）** → `oled_driver`（画屏）。
这一段不依赖电机、不依赖车架，纯片上 RTL + 手上已到货的 0.96" OLED，是当前能拿到分的最短路径。

### 新增 `src/color_seq.v`（2563 B）

```verilog
module color_seq (clk, rst_n, color_in[2:0], new_color, clr,
                  seq0..seq3[2:0], cnt[2:0], seq_valid, complete);
```

- `complete = (cnt == 3'd4)`。
- 去重：`wire dup = (color_in == seq0) | ... | (color_in == seq3);`。
  **空槽恒 0，而 `color_in` 进到这里时已非 0**（0 = 中性色被下面的条件挡住），所以不会误判重复。
- 只在 `new_color && color_in != 0 && cnt < 4 && !dup` 时写入 `seq{cnt}` 并给 `seq_valid` 打一拍。
- 4 槽填满后冻结（先到先得，后来的不覆盖）；`clr` 清空重来（顶层当前接常量 0，留给 `car_fsm` 的"新一轮"）。

### 新增 `src/oled_driver.v` + `src/oled_font.v`

- `oled_driver` **自带 I2C 字节引擎**，不复用 `i2c_master`：一帧要连发 1026 字节
  （1 地址 + 1 控制 + 1024 数据），和 SCCB 交错会让两个状态机互相打断。
- 显存 `reg [7:0] fb [0:1023]`（128×64 页格式），写只在清屏/渲染状态，读只在发送时 → 综合推断为 RAM。
- 上电序列：`AE`（关显示）→ `D5 80` → `A8 3F`（1/64 duty）→ `8D 14`（电荷泵）→ `AF`（开显示）；
  之后每帧 `21 00 7F`（列窗 0..127）+ `22 00 07`（页窗 0..7）再推 1024 字节整屏显存（单事务 1026 字节）。
- 版面：4 个 32×32 汉字横排（红/绿/蓝/黄），纵向居中在 page 2~5，空槽不画。
- `oled_font.v` 是 `tools/gen_oled_font.py` 从 `simhei.ttf`（30 号）生成的点阵 ROM：
  1=红 2=绿 3=蓝 4=黄，4 字形 × 128 B = 512 B，地址 `(color-1)*128 + page*32 + col`。

### 上电自检「白闪 + 存活标记」（2026-11-12 补，解决黑屏无从判断）

**问题**：初版驱动清屏后就等着颜色输入，而 4 个槽初值全是 0、空槽不画 → 上电屏就是**全黑**，
和"没接好/没烧进去/屏坏了"完全同一个现象，用户在现场无法区分（现场反馈："本来就是黑的，也看不出来有没有启动"）。

**做法**（`oled_driver.v`，状态机加了 `S_FLASH_WAIT = 3'd6` / `S_MARK = 3'd7` 两个原本空着的编码）：

1. 复位后 `clr_val = 8'hFF`，`S_CLEAR` 把 1024 B 显存全填 `0xFF` → `S_PUSH` 整屏推出去 → 屏**全白**；
2. 进 `S_FLASH_WAIT` 停 `FLASH_MS × 24 MHz`（默认 600 ms），让肉眼看得见；
3. 计时到 → `clr_val = 8'h00` 再走一遍 `S_CLEAR`/`S_PUSH` → 屏**转黑**；
4. 之后才进正常渲染；`ALIVE_MARK = 1` 时先走 `S_MARK` 在 page 0 / col 0..7 写 `0xFF`，
   即左上角一个 8×8 常亮小方块——**没有颜色可显示时，屏上就只剩这个小方块**，一眼分辨死屏与活屏。

参数在顶层 `FpgaCar.v:415-420`：`FLASH_MS (600)`、`ALIVE_MARK (1)`；`FLASH_MS = 0` 关白闪、`ALIVE_MARK = 0` 关标记。
新增寄存器：`clr_val / boot_flash / need_render / flash_cnt[25:0] / mk[3:0]`。
`S_PUSH` 推完一屏后：`boot_flash` → `S_FLASH_WAIT`，其余一律回 `S_WAIT`，由 `S_WAIT` 在 `!pend`
（传输真正结束）后再进 `S_RENDER`——这样"白屏那一帧"和"色块那一帧"都不会漏推
（初版 `S_CLEAR` 完直接进 `S_RENDER`，清屏结果从来没上过屏）。

**仿真逮到的三个时序坑**（`sim/oled_driver_tb.v` 全 PASS 之后才敢上板）：

1. **白闪计时不能边推边数**：1026 B @ 400 kHz ≈ 26 ms，若 `S_FLASH_WAIT` 一进去就倒计时，
   计时到点会把还在发送中的 `fb` 改掉，整屏只推出去一半。改成 `if (pend) flash_cnt <= 0;`
   ——必须等这一笔真正发完再开始数。
2. **推完不能立刻渲染**：同理会改掉还没发出去的显存（表现为"一半黑一半色块"）。
   渲染入口统一收到 `S_WAIT` 里，且 `S_WAIT` 先看 `need_render` 再看 `dirty`。
3. **tb 里不能用 `wait (frame_done === 1'b1)`**：`frame_done` 是 1 clk 脉冲，
   电平 wait 会在脉冲还没撤的同一拍立刻返回，等于没等——第二帧起比对就串位了。
   必须 `@(posedge frame_done)`。

最终仿真结论：白闪全 `0xFF`、转黑全 `0x00`、frame1/2/3 逐字节匹配、1024 B 单事务、
无 NACK、SCL 4.00 MHz、总线收尾空闲，全 PASS。

### 本轮两个真实 bug

1. **`gp + 2'd2` 位宽溢出**：`fb[{(gp + 2'd2), 7'd0} + ...]` 里 `gp+2'd2` 只有 2 位，
   `gp=3` 时回绕成 1 → page 5 全空、page 1 被覆盖（frame1 有 357 字节对不上）。
   改成 `{(gp + 3'd2), 7'd0}` 后逐字节全对。
2. **`ndata` 在控制字节处被清零**：初始化命令是一条一条发的，原先在每个事务的
   控制字节（`byten==1`）就清 `ndata`，导致只保留最后一条命令，AE/8D14/AF 全都抽查不到。
   修法：只有 `rx == 8'h40`（显存数据流）才清 `ndata`，命令路径不清。

### 验证结果

- `sim/color_seq_tb.v`：11 项全 PASS（忽略中性色、红先、蓝次、重复丢弃、填满冻结、
  恰好 4 个 `seq_valid` 脉冲、`clr` 后 `complete` 拉低并可重新记录）。
- `sim/oled_driver_tb.v`（10593 B）：frame1（红绿蓝黄）/ frame2（蓝黄红绿）/ frame3（只 2 槽）
  **显存 1024 字节逐字节匹配**；1024 数据字节单事务；无 NACK；init 含 AE/8D 14/AF；
  21/22 窗口命令正确；SCL 周期 250 ns = **4.00 MHz**；结束总线空闲。
- `sim/FpgaCar_tb.v` 顶层 smoke 5 项仍全 PASS。

### 全链路编译（2026-11-12 19:05，带白闪自检，efx_run 三流水 EXIT=0）

| 阶段 | 结果 |
|---|---|
| `map` | PASS，**FF 3718 / ADD 408 / LUT4 12392 / DSP48 2**（`outflow/FpgaCar.res.csv`）|
| `pnr` | PASS，`clk` setup slack **31.805 ns**、hold slack 0.090 ns；XLR **15612/60800 = 25.68%** |
| `pgm` | PASS，位流 `outflow/FpgaCar.bit` = **2026-11-12 19:05:40**（1886343 B） |

> 相比 18:21 那一版（12636 XLR / 20.78%），白闪自检让 `u_oled` 涨到 **2967 FF + 10408 LUT**
> （`res.csv:22`），整片多用了约 3000 XLR。原因同上：`fb` 被映射成逻辑存储器，
> 而自检又多加了一整套清屏/标记/计时寄存器。25.68% 仍然宽裕。

`outflow/FpgaCar.map.out:28-30` 有 `color_seq.v` / `oled_font.v` / `oled_driver.v` 的分析记录，
`FpgaCar.map.out:56-59` 有编译记录，`hier_util.rpt` 里 `u_oled` = 7788 XLR、`u_seq` = 29 XLR，确认已进网表。
关键路径在 `u_oled/txa[0]` → `u_oled/shreg[5]`（显存读 + 移位寄存器），8.343 ns。

### 一条需要注意的警告（不影响功能）

```
WARNING: Mapping into logic memory block 'u_oled/fb' (8192 bits) because read port is not synchronous. [EFX-0657]
```

显存 `fb` 是异步读（`fb[txa]` 直接进移位寄存器加载路径），所以综合把它铺成逻辑存储器而不是块 RAM，
`u_oled` 因此占了 7788 个 XLR。当前整片用 20.78%，完全够用；若以后要省资源，
把读改成同步读（`fb` 输出打一拍，发送状态机相应延一拍）即可换回 BRAM。

### 上板判据

上电自检（`FLASH_MS = 600` / `ALIVE_MARK = 1`，见 `FpgaCar.v:415-420`）：
复位后整屏填 `0xFF` 推出去 → **全白闪 0.6 s** → 整屏填 `0x00` 推出去 → 转黑 →
正常渲染 4 个色块；`ALIVE_MARK = 1` 时 page 0 / col 0..7 常亮一个 8×8 实心方块。

| 现象 | 含义 |
|---|---|
| 上电**全白闪一下**（然后转黑） | ✅ 初始化 + 清屏 + 整屏推送 + 屏本体**全通**。这是「固件起来了」的硬证据 |
| 没白闪，但左上角有 8×8 小方块 | ✅ 通；只是还没有颜色顺序要显示（`ALIVE_MARK` 常亮标记） |
| 没白闪、也没小方块，屏全黑 | ❌ 没有一次事务成功：先量 P4 pin 15 静态高（无波形 = 引脚/约束），再查 `DEV_ADDR` 是否该用 `7'h3D` |
| 屏全黑且 SCL 完全没有波形 | `i2c_scl` 没到 P4 pin 15 / 引脚约束缺失；先万用表量 P4 pin 15 静态高 |
| SCL 有波形但无 ACK | 屏地址不是 0x3C（有些模块是 0x3D），改 `DEV_ADDR`（`FpgaCar.v:418`）|
| 白闪之后花屏/雪花，或整屏常白不转黑 | I2C 时序或上拉问题：`SCL_FREQ` 400 k→100 k 重编；`BOOT_MS` 20→100（电荷泵没稳定）|
| 对着红/绿/蓝/黄色块，每认出一个就从左往右多一格汉字 | ✅ `color_detect` → `color_seq` → `oled_driver` 整链打通 |
| 串口 `Q=` 出现 **4** | ✅ v3 判黄生效（v2 的绝对门限在这盏灯下永远出不来 4，见 §3.16 color_detect v3）|
> **⚠ 2026-11-16 更正**：本节早先写的「LED[5] 是黑屏第一分诊器（接 `nack_seen`）」**已失效**。
> 现在 `FpgaCar/src/FpgaCar.v:571` 是 `assign led = ~{heartbeat[23], car_state, obstacle, line_lost};`，
> 即 **LED[5] = 心跳（恒慢闪）、LED[4:2] = 状态机状态、LED[1] = 障碍、LED[0] = 全丢线**；
> `nack_seen` 只在 `g_oled` 块里声明（`FpgaCar.v:490`），**没有接到任何管脚**。
> 所以 LED[5] 现在**永远慢闪，不带任何 I2C 信息**，别再拿它分诊。
> 要看 ACK 情况：串口 / 示波器看 SCL 波形，或临时把 `nack_seen` 接一根 LED 重编。

> 自检可关：`FLASH_MS = 0` 关白闪，`ALIVE_MARK = 0` 关小方块（比赛时想留标记就保持 1）。

### 屏上调试区（2026-11-17 新增）

**动机**：调试时既要盯串口又要盯车，串口线一动就断、看波形还得回电脑。屏是常亮的，
把**全部可见调试量**铺到屏上，蹲在车边一眼就能判断状态，不必接串口。

色块必须占 page 2~5（细则 4.3.3 / 5.1），因此调试区只占**空闲的 page 1 与 page 6/7**，
与色块永不重叠。实现见 `FpgaCar/src/oled_driver.v` 的 `S_DBG` 状态与 `dbg_*` 组合绘制块，
ASCII 点阵在 `FpgaCar/src/oled_glyph.v`（5×7，手写、只收这三行用到的字符）。

**2026-11-22 起改成三行纯文字**。此前是「八路竖条 + 16×16 数字 + 四个小方格 + page0 二进制串」，
现场站远一点、或者屏的角度一斜，条状和格状就只能靠「整格实心 vs 只剩一条底边」来分辨，
经常看错。改成 ASCII 文字后每个字段自带标签，和串口报文的字段名一一对得上：

| 行 | 显存位置 | 屏上内容 | 判读 |
|---|---|---|---|
| 第 1 行 | page 1 | `ST:RUN  LOST:0  ` | 车状态机 4 字符名（`IDLE/RUN /LOST/SRCH/STOP/A-BK/A-TN/A-PB`）+ 丢线标志 |
| 第 2 行 | page 6 | `DIST:123 CM OB:1` | 超声距离 cm，**`---` = 无回波**（`dist_cm == 16'hFFFF`），>999 饱和 999；`OB` = 障碍标志 |
| 第 3 行 | page 7 | `LN:10000001 TR:R` | 循迹原始值，**自左向右 = `line[7]`→`line[0]`（高位在前）**，与串口 `T=` 逐字对照；`TR` = 转向 L/R/- |

字符格宽 8 列（5 列点阵 + 3 列间隙），16 字符正好铺满 128 列。每字符 8 列、每行 16 字符 = 128 字节，
三行共 384 字节，每次无条件重写，改布局不会留残影。

> **page 0 仍是 `S_MARK` 的地盘**：col 0..7 存活标记、col 120..127 K230 掉线叉号，与上面三行不重叠。

刷新策略：`DBG_SAMPLE_MS = 100` 采样一次，7 个调试输入**任一变化**才整屏重推；
一次全屏 1026 字节 @400 kHz 约 23 ms，最坏占空比约 23%，不影响颜色识别与电机控制。
未变化时不重推，避免 I2C 被刷屏占满。

判读速查：

- **`DIST:---`** → 无回波：模块没供电 / Trig 没接 / Echo 线松 / 目标太远或太吸音（3.3 V 供电下超 2 m 开始丢）。
- **距离恒 `DIST:006` 之类偏小值** → Echo 线接触不良把脉宽截短、模块被 5 V 反接过、或目标太近落在盲区（<2 cm）。
- **`LN=11111111`（全 1）** → 未校准 / 校准值不匹配当前高度（本模块靠按键校准，无电位器，见 `docs/模块接线说明.md` §2.3），或车停深色地面；抬离桌面做对照。
- **`LN=00000000`（全 0）** → 模块没供电，或 ACTIVE_HIGH 极性与实物不符。
- **`ST:IDLE` 一直不变** → 还在上电 2 s 内，或 `rst_n` 没释放。

### 复位键到底接哪根脚（2026-11-16 修正，现场踩坑）

**现象**：屏上一直有左上角 8×8 小方块（说明 I2C 全通、初始化全过），但**怎么按板上的按键都看不到白闪**。

**根因**：`rst_n` 原来绑的是 `GPIOT_P_11`（User_IO35，P4 排针 pin 40）。那是**扩展排针**，
板上复位键根本没接到那里；排针悬空 + `pull_option="weak pullup"` 使 `rst_n` 恒为高，
按键按下去影响不了它。所以白闪自检只在**真正上电**时跑过一次（那一次确实闪了，
所以后来屏上有小方块），按键永远重触发不了自检。

**真源**（`04_原理图&PIN TCL/Ti60_Board_引脚定义-20230703-V1.0.xlsx` 的 `【GPIOL】` / `DC3-40` 页）：

| BGA | FPGA 引脚 | 核心板网络 | 备注 |
|---|---|---|---|
| N2 | `GPIOL_P_02` | **KEY[0]** → User_IO1 | 「和核心板复用了，Default 上拉了」 |
| M2 | `GPIOL_N_02` | **KEY[1]** → User_IO0 | 同上 |

即**板载按键走 User_IO0 / User_IO1，与核心板复用**，不在 P4 排针的自由脚上。
`FpgaCar.peri.xml:168` 已改为 `gpio_def="GPIOL_P_02"`（KEY[0]，按下接地 = 低有效，与 RTL 一致）。
`GPIOL_P_02` 同时是 P4 pin 2 (User_IO1)，本项目不用那根针；`GPIOL_N_02`(KEY[1]) 保持空闲。

> **判据**：改绑后按一下按键 → 屏整屏白闪 0.6 s → 转黑 → 小方块。
> 若改绑后仍不闪，才是驱动/时序问题，按上表往下查。
> **重要**：改 `peri.xml` 的 `gpio_def` 后必须按 `interface → pnr → pgm` 跑。
> `--flow map` **不会刷新** `outflow/FpgaCar.lpf`，而 PnR 只认这个 lpf，跳过 interface 等于没改；
> `--flow pnr` 也**不生成位流**，`pgm` 那一步才 `do_export_bitstream`。只烧旧位流不会生效。

#### 三个按键各自的真实去向（2026-11-16 补，之前只记了 KEY[0]/KEY[1]）

核心板原理图 `04_原理图&PIN TCL/Ti60_F225_Core_V1.4.pdf` 第 7 页右上角是 K1/K2/K3 三个按键，
全部 10K 上拉、按下接地：

| 按键 | 接到 | 网络 | 我们能不能用 |
|---|---|---|---|
| K1 | `GPIOL_P_02` | CSI | 能用（= KEY[0]，现绑 `key_start_n` 启动） |
| K2 | `GPIOL_N_02` | CSO | 能用（= KEY[1]，现绑 `key_stop_n` 停车） |
| K3 | 专用配置脚 | CRESET_N | **不能**，见下 |

`outflow/FpgaCar.pinout.csv` 里 `J5,CRESET_N,,Input,1A,1.8 V,,,Configuration` —— CRESET_N 属于
Configuration 类引脚，直接进 FPGA 的配置控制器，**RTL 完全碰不到**。按 K3 等于整片重新配置
（效果接近重新上电），不是用户逻辑复位。所以「按键触发逻辑复位」只能选 K1/K2。

#### 「按一次有白闪、再按没有」的根因：Flash 是空的（2026-11-16）

不是显存被改写。`tools/dl.bat` 做的是**被动 JTAG 配置，掉电即失**，SPI Flash 里一直没有镜像。
于是按 K3 → FPGA 重新配置 → Flash 无可用位流 → 设计根本不存在 → 屏停在 GDDRAM 里的旧画面
（黑底 + 8×8 方块），自然不再白闪。第一次闪，是因为 JTAG 下载后设计真的跑了一遍。

修法：`tools/flash.bat` 把 `outflow/FpgaCar.hex` 写进板载 SPI Flash（Winbond W25Q64 8 MiB）。
已实测：擦除写入 562 KiB、读回校验 `Flash verify successful`、随后回烧应用位流 `FLASH DONE`。
固化后按 K3 每次都会重新配置并重跑白闪自检。

**最近一次固化（2026-11-18 16:41）**：位流含 OLED 调试区、page0 八位二进制串、`USE_IR = 1'b0`、
`P_GAIN=72`/`D_GAIN=40`、`car_fsm` 起跑安全锁（`START_REQUIRE_LINE=1`）。三步实测记录：

| 步骤 | 输出 |
|---|---|
| ① 载入 JTAG→SPI 桥 | `Programming 'C:/Efinity/2026.1/pgm/fli/titanium/u10660A79.bit'` → `PROGRAMMING DONE` |
| ② 经桥写 Flash | `Flash device: Winbond W25Q64 8 MiB (JEDEC ID: 0xEF6017)` / 擦除 **652 KiB** / 写入 **648 KiB** / 校验通过（无 mismatch） |
| ③ 回烧应用位流 | `Programming 'outflow/FpgaCar.bit'` → `PROGRAMMING DONE` |

> **擦写参数（2026-11-18 实测，含一次踩坑订正）**
>
> 两个参数必须一起给，而且**只能用 `all`，不能用 `erase_and_write`**：
>
> ```
> -m jtag_bridge --jtag_bridge_mode all --verify_method hostx1
> ```
>
> `all` = 解锁全部扇区 → 擦除 → 写入 → 从 Flash 读回逐字节比对，是 Efinity 自己的默认值，
> 也是**唯一真正带校验的路径**。`hostx1` 让 PC 通过 JTAG 把 Flash 内容读回来算 SHA1 与源文件比；
> `onchipx*` 靠 Flash loader 的片上 CRC，不是每块板都支持。
>
> **踩坑记录**：曾经改用 `--jtag_bridge_mode erase_and_write`，理由是「默认模式不擦旧扇区所以校验失败」。
> 这个推论是错的 —— `ftdi_program.py` 的 `jtag2spi()` 分发里，`erase_and_write` 和 `write` 两个分支
> 把 `verify_method` **硬编码成 `'none'`**（见 `jtag2spi_program(... verify_method='none')`），
> 所以它打印的 `Flash verify successful` 来自另一条代码路径，**实际上什么都没校验**，退出码仍是 0。
> 后果：一个坏镜像被静默写进 Flash，断电重启后设计起不来、核心板 LED 全灭（只有 JTAG 下载才能跑起来）。
> 改成 `all + hostx1` 后读回 648 KiB SHA1 与源文件完全一致，才排除了这个隐患。
>
> 判据：日志里必须同时出现 `Reading ... from flash` 与 `Flash verify successful`，
> 且 `--verify_method` 不是 `none`。只有 `PROGRAMMING DONE` 不足以证明写入正确。
>
> 固化的**只是裸位流**，不含 RTL 之外的状态；Flash 里没有第二镜像，回退只能靠重新综合再固化。
> 固化后上电自启动的是这一版，与 JTAG `dl.bat` 烧的是同一份 `outflow/FpgaCar.bit`。

> **K1/K2 的定位（2026-11-20 起）**：`src/car_panel.v` 把两个按键做成了运行面板——
> K1 短按启动（`key_start_n`），K2 短按停车（`key_stop_n`），长按 K2 约 1 s 清结果回 READY。
> 用户逻辑复位改为上电自复位（`FpgaCar.v` 的 `power_on` 移位 4 拍），K1 不再承担复位。
> K3 仍是整片重配置（CRESET_N，RTL 碰不到），只在验证上电自启动时用。

### OLED 四脚接线（已按原理图逐脚核对，2026-11-12）

模块 4 脚 → 板上 **P4（`DC3-40P`，顶层 sheet）** 针脚：

| OLED 模块 | 接到 | 通路 / 说明 |
|---|---|---|
| VCC | **P4 pin 29 = `D3V3`** | 3.3V。**不要接 pin 11 的 `D5V0`**：TXS0108E B 侧绝对最大 4.6V，模块板载上拉会把 SCL/SDA 顶到 VCC |
| GND | **P4 pin 12 或 pin 30 = `GND`** | 两个 GND 脚等价 |
| SCL | **P4 pin 15 = `User_IO12`** | `User_3V3_IO12` → TXS0108E 通道 → `GPIOL_N_13`（BGA `E3`，bank 1B）；RTL `i2c_scl` = output |
| SDA | **P4 pin 16 = `User_IO13`** | `User_3V3_IO13` → TXS0108E 通道 → `GPIOL_P_13`（BGA `F3`，bank 1B）；RTL `i2c_sda` = inout |

- **P4 针脚排布**：左列奇数 1/3/…/39，右列偶数 2/4/…/40；**pin 11 = `D5V0`、pin 12 = `GND`、pin 29 = `D3V3`、pin 30 = `GND`** 是四个电源脚，
  IO 编号跨过它们：左列 pin1–9 = IO0–IO8、pin13–27 = IO10–IO24、pin31–39 = IO26–IO34（右列 = IO1–IO9 / IO11–IO25 / IO27–IO35）。
  所以 **IO12 = pin 15、IO13 = pin 16**（不是 13/14）。
- **电平**：0Ω 选择电阻 `R1 = 0R` 把 `VOUT` 接到 `D3V3`（默认；`R10` 空贴 `D1V8`），与丝印"默认 DC3-40 为 3.3V 电平"一致；TXS0108E 的 `OE` 接 `D1V8` 常使能。
- **上拉核算**：TXS0108E B 侧内部 10 kΩ ∥ 模块板载 10 kΩ ≈ 5 kΩ；400 kHz 要求上升沿 < 300 ns，排线电容 > 60 pF 就会临界。
  上板若 NACK / 花屏，先把 `FpgaCar.v:417` 的 `SCL_FREQ` 从 `400_000` 降到 `100_000`（`oled_driver.v:30` 默认值同步改）。
- **从机地址**：`FpgaCar.v:418` / `oled_driver.v:31` 为 `7'h3C`；部分模块是 `0x3D`，全黑无 ACK 时先查这个。
- 手册里 `VCC` 允许 1.65–3.3V（模块内部电荷泵升到 7.5V 驱动面板），**模块板载没有稳压器**，所以外部供 3.3V 是硬要求。

### color_detect v3：相对判黄 + 帧内四色轮询（2026-11-12 19:50）

#### 为什么改：串口实测第 4 槽永远空

上板跑 v2 后连续采样 40 s，串口 `Q=` **只在 2 和 3 之间跳，一次都没出现过 4（黄）**。
同期 `XY=` 在 `0862/0863/0882/0883/08A2/08A3/1083` 之间变，拆开是 R5=1,G=3,B=6 这种近黑深蓝灰——
**色块根本不在画面正中**，所以「打中心像素」这条排查路走不通，只能从判据本身找原因。

根因在 v2 的判黄是**绝对门限**：

```verilog
// v2（错）：px_b < YEL_B_MAX(26)
else if (px_r > YEL_RG && px_g > YEL_RG && px_b < YEL_B_MAX) cls = 4;
```

室内灯光下印刷黄卡的 B 通道实测落在 **28~35**，恒 > 26，于是 `cls=4` 永不成立；
像素落进 `mx==r7` / `mx==g7` 分支被判成红/绿，又被 `color_seq` 的 `dup` 吃掉。
结果就是前 3 槽能填、第 4 槽永远空。

#### v3 判据：只比通道之间的关系，不设绝对亮度

`src/color_detect.v:48-52` 参数改成 5 个（**`YEL_B_MAX` 已删除**）：

| 参数 | 值 | 含义 |
|---|---|---|
| `SAT_MIN` | `6'd16` | 饱和度下限，低于此值算中性色（判 0） |
| `YEL_RG` | `6'd28` | 黄：`min(R,G)` 至少这么大（太暗的不算黄） |
| `YEL_DR` | `6'd14` | 黄：`\|R-G\|` 不超过这么大（黄的 R≈G） |
| `YEL_DB` | `6'd12` | 黄：`min(R,G) - B` 至少这么大（黄一定比 B 亮一截） |
| `MIN_PIX` | `20'd200` | 单帧某色像素少于这么多不认（滤小色斑） |

```verilog
wire [6:0] rg_diff = (r7 > g7) ? (r7 - g7) : (g7 - r7);
wire [6:0] yel_b_lim = b7 + {1'b0, YEL_DB};
wire is_yel = (rg_min >= {1'b0, YEL_RG}) && (rg_diff <= {1'b0, YEL_DR})
           && (rg_min >= yel_b_lim);
```

分类链：`sat < SAT_MIN → 0`；`is_yel → 4`；`mx == r7 → 1`；`mx == g7 → 2`；否则 `3`。

这样**换成暖黄（255,240,140）或冷白偏黄（250,250,180）也都能判成黄**，
因为它只看「R≈G 且明显高于 B」，不看 B 的绝对值。

#### 第二处改动：整帧单赢家 → 帧内四色轮询

v2 每帧只在 `cnt_r/g/b/y` 里挑**全局最大**的那个当主色。当画面里同时有多个色块
（或某个色块面积大得多）时，小面积的那色永远选不上，四个槽就凑不齐。

v3 改成**轮询（round-robin）**：帧末先算出四个「够格」标志

```verilog
wire [3:0] elig = {(cnt_y>=MIN_PIX),(cnt_b>=MIN_PIX),(cnt_g>=MIN_PIX),(cnt_r>=MIN_PIX)};
```

再按当前轮询指针 `rr` 把 `elig` 循环右移 `rr` 位，取最低的置位项——即「从 rr 开始往前找第一个够格的」：

```verilog
wire [1:0] sel_off = er[0] ? 2'd0 : (er[1] ? 2'd1 : (er[2] ? 2'd2 : 2'd3));
wire       sel_ok  = |er;
wire [1:0] sel     = (rr + sel_off) & 2'd3;
// vs_rise：
col_lat <= sel_ok ? ({1'b0, sel} + 3'd1) : 3'd0;   // 1..4
if (sel_ok) rr <= sel + 2'd1;                       // 下次从下一色开始找
```

于是同一画面连续几帧会依次吐出 1 → 2 → 3 → 4，四色一定能凑齐，
而不是「谁面积大谁一直赢」。`sel_ok = 0`（这帧一个色都不够格）时仍报 0，不会污染顺序。

> **一个设计决定**：计数没有改成 `reg [19:0] cnt [0:3]` 配 `rr` 做非阻塞下标。
> 那样会触发动态部分选择（variable part-select），综合出来是一堆多路选择器，
> 代价比四个平坦寄存器大得多。这里保持 `cnt_r/cnt_g/cnt_b/cnt_y` 平面写法，
> 只在帧末做一次 4 选 1。

#### 仿真（`sim/color_detect_tb.v` 重写，11 项全 PASS）

tb 用 `task px(r5,g6,b5)` 逐字节在 negedge 驱动、posedge 采样，
`send_frame(r,g,b,n)` 灌单色帧，`send_quad(n)` 连发红/绿/蓝/黄四帧。

| 断言 | 期望 | 结果 |
|---|---|---|
| 红 (255,0,0) | 1 | PASS |
| 绿 (0,255,0) | 2 | PASS |
| 蓝 (0,0,255) | 3 | PASS |
| 印刷黄 (255,255,0) | 4 | PASS |
| 黑 (0,0,0) | 0 | PASS |
| 稀疏小斑点（总量 < 200） | 0 | PASS |
| **暖黄 (255,240,140)** | 4 | PASS（v2 会判成 1） |
| **淡黄 (250,250,180)** | 4 | PASS（v3 的核心回归项） |
| **quad 连发 4 帧** | 依次 1,2,3,4 全覆盖 | PASS |
| `new_color` 脉冲数 | ≥ 6（实测 13） | PASS |

期间还修了 tb 自己的两个 bug：quad 的红段误写成 `px(5'd31,6'd63,5'd0)`（那是黄）；
`reg [3:0] seen` 存不下下标 4，改成 `reg [4:0]`。

回归全绿：`color_seq_tb` 11 项、`uart_report_tb` 3 组 64 字节整行、`oled_driver_tb`（白闪/转黑/3 帧逐字节/1026 B 单事务/无 NACK/SCL 4.00 MHz）。

#### 全链路编译（2026-11-12 19:50，efx_run 四段 EXIT=0）

| 阶段 | 结果 |
|---|---|
| `map` | PASS，**FF 3739 / ADD 422 / LUT4 12195 / DSP48 2** |
| `interface` | PASS |
| `pnr` | PASS，`clk` setup slack **32.622 ns**（约束 41.667 ns）、hold slack **0.090 ns**；XLR **15815/60800 = 26.01%** |
| `pgm` | PASS，位流 `outflow/FpgaCar.bit` = **2026-11-12 19:50**（1881027 B）|

> 对比 19:05 版（408 / 12392 / 2 / 3718、slack 31.805 ns、XLR 15612 = 25.68%）：
> 逻辑**没涨反降**约 200 LUT，多出的 203 个 XLR 来自新增的轮询/比较逻辑。
> 资源占用四分之一，离满还很远。
> 关键路径仍是 `u_oled/txa[0]` → `u_oled/shreg[3]`（显存异步读），8.819 ns。

#### 上板验证（这版要看的判据）

1. 拿**黄色**色卡对着摄像头：串口 `Q=` 应该出现 **4**（这是 v3 的唯一验收点；v2 永远看不到 4）。
2. 依次出示红→绿→蓝→黄：OLED 四格应该**按出示顺序**填满，不再留空槽。
3. 如果黄仍判不出来，按顺序调参重编：先降 `YEL_DR`（14→18，放宽 R/G 不等程度），
   再降 `YEL_RG`（28→20，容许更暗的黄），最后降 `SAT_MIN`（16→10）。

## 3.17 进度记录：2026-11-12（B 组运动闭环 = 测速 + PID + 状态机）

### 为什么先做这一段（不依赖待买件）

`PROJECT_PLAN` §4 原来把运动闭环排在"电机到货之后"。实际上**闭环的纯 RTL 部分完全不依赖电机**：
只要 `track_line` 的 `pos` 能测出来（YB-MUX04 已有实物、已上板验证格式），
PID 和状态机就能写好、能仿真、能综合。等电机到货，只需标定参数即可上车。
这也是当前唯一能"边等货边推进 55 分运动类"的路径。

### 新增三个模块

| 文件 | 作用 | 关键设计 |
|---|---|---|
| `src/speed_meter.v` | 固定窗口数编码器脉冲 | 单位 = 每 `WIN_MS`(50 ms) 的净步数，带方向、饱和不翻转；**不做除法**（测周期法低速分辨率差，数脉冲最省逻辑）。当前只写不接（见下） |
| `src/track_pid.v` | 位置 PID → 左右占空比 | 定点实现：`corr = pos*P_GAIN + (i_acc>>I_SHIFT) + (pos-pos_d)*D_GAIN`，`corr` 限幅 ±`BASE_DUTY`，所以 `duty_l/r = BASE_DUTY±corr` 恒在 0..1200（模块默认 600，顶层覆盖 480，见 §3.42）；**积分在累加处钳位**（不在输出处钳，否则 windup 会让倒车冲出去）；丢线时保持上一拍转向（立刻归零会让车冲直） |
| `src/car_fsm.v` | 整车状态机 | `IDLE --2s--> RUN --丢线--> LOST(保持300ms) --超时--> SEARCH(原地转，方向按最后线位) --重新压线--> RUN`；障碍 → `STOP`（消除后自动恢复）；找线超时 → `STOP` 且**永久锁存**；**方向切换有 10 ms 死区**（TB6612 同相翻转会有电流尖峰） |

### 顶层接线

```
track_line.pos ──► track_pid ──► pid_duty_l/r ──► car_fsm ──► ctrl_duty_l/r
                                  (en 来自 car_fsm)                │
                                                    ml/mr_in1/in2 + motor_stby
```

- `ml_in1 = motor_en & dir_l`，`ml_in2 = motor_en & ~dir_l` —— **IN1/IN2 永不同时为 1**（否则是短路刹车）
- `motor_stby = motor_en`，IDLE/STOP 时电机自由（不是刹车）
- **`PWM_BENCH_TEST` 已改回 `0`**（原台架态是 1 = 左轮 25% 常转）；=1 时仍可旁路闭环做台架试车

### 仿真结果（三个新 tb 全 PASS）

| tb | 项 | 内容 |
|---|---|---|
| `speed_meter_tb` | 4 | 30 正转脉冲 → +30；10 反转 → −10；空窗口 → 0；valid 每窗口一拍 |
| `track_pid_tb` | 7 | 居中 600/600、corr=0；pos=+7 → 880/320；pos=−7 → 313/887；积分增长但 ≤600；丢线保持；en=0 归零 |
| `car_fsm_tb` | 16 | IDLE(en=0) → RUN(双轮正转、duty 跟 pid) → LOST(保持 duty、en 不断) → SEARCH(朝最后线位转、duty=500) → 重新压线回 RUN → 障碍 STOP(en=0) → 恢复 → 找线超时永久 STOP |
| `FpgaCar_tb` | 5 | 顶层 smoke 改为"闭环态"期望：IDLE 时 `motor_stby=0`、方向脚全 0、`ml_pwm` 恒低 0/1200 |

### 编译实测

`map` ADD 638 / LUT4 13287 / FF 4353 / DSP48 2 / RAM10 4 → `pnr` PASS，setup slack **31.783 ns**
→ `pgm` PASS，位流 **2026-11-12 22:31:35**。

### 踩到的两个坑

1. **`_sim/` 目录被删掉后 iverilog 只报 `Code generator failure: -1`**，不给任何行号。
   真实原因是输出文件路径不存在。以后见到这条先去 `Test-Path _sim`。
2. **状态机 tb 的检查点必须晚于"ms 节拍 + 方向死区"**：`car_fsm` 在 1 ms 节拍上动作，
   `duty` 还要再等一个节拍装载，方向切换另有 10 ms 死区。
   早查会看到 `duty=0/0`、`dir=10` 这种"半过渡态"，误判成 bug。

### 上板判据（电机接上后）

| 现象 | 含义 |
|---|---|
| 上电后轮子不动，**把车放到黑线上持续 2 s** 才起跑 | 安全锁正常（2026-11-18 起） |
| 压线偏右时左轮明显快 | PID 方向对（`pos>0 → 左快`） |
| 完全离地（全白）→ 约 0.3 s 后原地向左/右转 | LOST → SEARCH 正常 |
| 手挡超声波 → 停住，移开后自动恢复 | 障碍联动正常 |

参数起步值：`BASE_DUTY=600`（50%）、`P_GAIN=72`、`D_GAIN=40`、`I_SHIFT=5`、`I_LIMIT=640`。
上车后先只调 `P_GAIN`（摆振就减、跟不上就加），再动 `D_GAIN`。

> **2026-11-22 降速**：顶层加 `TRACK_BASE_DUTY=480`（40%）覆盖模块默认 `BASE_DUTY=600`，解决"修正不及时直接甩出去"。改的是 `src/FpgaCar.v:170` 一个 localparam，模块默认值与 `sim/track_pid_tb.v` 都不动。详见 §3.42。

> **2026-11-18 参数调整（P 40→72、D 24→40）**：原 `P_GAIN=40` 在 pos=7 时只有 280 计数
> （23% 占空比），`sum_lim` 的 ±`BASE_DUTY`(600) 限幅永远碰不到，两轮只能在 300~900 之间
> 变化，急弯内侧轮降不到低速。改成 72 后 pos=7 → 504 计数（42%），限幅才真正起作用。
>
> **同时修的两个缺陷**：
> 1. **重新压线时 D 项打尖峰**：`track_line` 丢线时把 `pos` 强制清 0，而 `track_pid` 每拍都
>    执行 `pos_d <= pos`，于是丢线期间 `pos_d` 被拖到 0；重新压线那一拍 `err_d` 突变成 5~7 格，
>    D 项打出 200~280 计数（≈20% 占空比）的尖峰，车会猛甩一下。修法：`pos_d <= pos` 移进
>    非丢线分支冻结，并新增 `lost_d` 把恢复后第一拍的 D 项清零。
> 2. **积分几乎不起作用**：`i_acc` 钳在 ±I_LIMIT=640，右移 `I_SHIFT=5` 后最大 ±20 计数
>    （1.7% 占空比），而总修正量是 ±500 量级 —— 等于没有积分。当前按 PD 用（循迹用 PD 本身
>    没问题），要消一侧电机偏慢的稳态偏差时再把 `I_LIMIT` 放大到 8000 量级。

> **2026-11-18 起跑安全锁**：`car_fsm` 新增 `START_REQUIRE_LINE`（默认 1），起跑条件从
> 「上电计时 START_MS」改为「**连续压线 START_MS**」。电机接上后，旧逻辑会让上电 2 s 的车
> 在桌面/箱子里自己窜出去（没线就走 RUN→LOST→SEARCH 原地打转）。现在没压线会一直停在
> IDLE、`motor_stby=0`，把车放到线上才算"钥匙"。`START_REQUIRE_LINE=0` 可退回旧行为，
> 仅台架/专项测试用。

### 遗留

- ~~`speed_meter` 已通过仿真但尚未接入顶层~~ → **2026-11-22 已接入**：`speed_meter` + 新增的
  `speed_pid.v` 组成左右轮同步环，顶层 `SPEED_LOOP_EN=1'b1`。选「同步」而非「绝对速度」正是为了绕开
  "每米多少脉冲"的标定：只依赖两个编码器的相对读数，接上就准。详见 §3.42。
- 串口还没有 `M=`（状态机状态）字段。要加必须同时把 `MSG_LEN` 和 3 行报文索引一起放宽，
  属于下一轮的小改动。

## 3.18 方案变更：K230 接管颜色与交通牌识别（2026-11-15，仅计划，未动 RTL）

### 为什么改

原计划里「颜色顺序 20 分 + 标识 25 分」两笔都由板载 OV5640 + 片内 `color_detect` / `sign_detect` 完成。
实际跑下来 `color_detect` 是能出结果的（§3.14–§3.16，v3 已能稳定认出黄纸），但两个结构性短板绕不过去：
一是 OV5640 固定白平衡偏绿，红/蓝要逐色标定增益，换光照就漂（§3.14 第三、四轮）；
二是交通标志要做形状/图案分类，Ti60 片内做模板匹配吃 LUT，而 LUT 已经用到 12195（§3.16 综合数）。

用户 2026-11-15 决定（m00168）：**颜色识别与方向（交通牌）识别改由 K230 视觉模块承担**，
OV5640 改为**后置摄像头**，只用于倒车入库（看库位线），不再承担得分主线。
效益很直接：K230 官方例程里已经有「多颜色识别」和「道路标志识别」两章现成代码，
识别算法不占 FPGA 一个 LUT，FPGA 只做一个 4 根线的接收器。

**这件事没有改任何代码**：`color_detect.v` / `dvp_capture.v` 原样保留（后视还要用），
下面写的全是接线与协议约定，RTL 下一轮才写。

### K230 侧的硬件事实（真正的瓶颈在它，不在 Ti60）

模块是 **亚博 AIMOTION2 K230 视觉识别模块（豪华版，带 2.4 寸触摸屏）**，
官方教程 https://www.yahboom.net/study/K230 （提取码 pmff）。

**散热片旁 2×6 双排 2.54 排针**（官方原话：为压缩模块体积，并没有把芯片支持的引脚都引出来）：

| 针 | 信号 | 可复用功能 |
|---|---|---|
| 1 | GPIO42 | UART1_RTS / PWM0 / QSPI1_D2 |
| 2 | GPIO43 | UART1_CTS / PWM1 / QSPI1_D3 |
| 3 | GPIO33 | **IIC0_SDA** / IIS_WS / UART3_RXD |
| 4 | GND | — |
| 5 | GPIO32 | **IIC0_SCL** / IIS_CLK / UART3_TXD |
| 6 | GPIO26 | **MMC1_CLK** / PDM_CLK |
| 7 | GND | — |
| 8 | GPIO34 | IIC1_SCL / IIS_D_IN0 / PDM_IN3 / UART3_RTS |
| 9 | 5V **输出** | — |
| 10 | GPIO35 | IIC1_SDA / IIS_D_OUT0 / PDM_IN1 / UART3_CTS |
| 11 | 5V **输出** | — |
| 12 | 3.3V 输出 | — |

**USB 口旁 4pin 通讯口**（PH2.0）：1=5V、2=GND、3=UART1_TXD（复用 GPIO9）、4=UART1_RXD（复用 GPIO10）。
默认就是 UART1，亚博提供 `ybUtils.YbUart`；本方案暂不使用，留作后备。

12 个针里只有 7 个 GPIO，其中三个大概率已被模块自身占用：

- GPIO32/33 = IIC0，模块自带摄像头，SCCB 配置走 IIC0。反证：亚博 I2C 教程点 OLED 用的是 IIC1，不是更顺手的 IIC0。
- GPIO26 = MMC1_CLK，模块靠 TF 卡装固件，卡槽接这里。

**豪华版的 2.4 寸屏和触摸不占这 12 个针**：教程第 15/16 章是 `Display.init(Display.ST7701, 640, 480)`
与 `TOUCH(0)`，全程没有 `fpioa.set_function`，说明屏与触摸走专用 FPC 和专用控制器。
→ 结论（待现场 `fpioa.help()` 实证）：**真正自由的 GPIO 是 GPIO42 / 43 / 34 / 35 四根**，
正好够一个「3 位数据 + 1 根 strobe」的并行口。**不是 6 根，也别指望凑 6 根。**

### 现场必做的三项验证（明天交给同学，做完再接线）

1. **`fpioa.help()` 抄回真实占用** —— 这是唯一权威答案，本文全是文档推断。

   ```python
   from machine import FPIOA
   fpioa = FPIOA()
   fpioa.help()                                      # 全部引脚现状
   fpioa.help(26); fpioa.help(32); fpioa.help(33)    # 这三个是不是被摄像头/TF 卡占了
   ```

   判据：pin 26/32/33 的 `func` 若不是 GPIO 而是 MMC1/IIC0 之类，则确认必须走 4 根方案；
   若显示为 GPIO（空闲），也只是**多出余量**，方案不变。
2. **量电平** —— K230 的 GPIO 到底是不是 3.3V。依据是 12pin 引出了 3.3V 电源脚、IIC1 能直接点 3.3V 的 OLED，
   但这是推断。做法：把 GPIO42 配成输出写 1，用万用表量 GPIO42 对 GND。
   **若是 1.8V**，不能直连 Ti60 排针（排针外侧是 3.3V），中间得加一级电平转换，方案要重排。
3. **跑通两个官方例程**：5.3「多颜色识别」、10.11「道路标志识别」，确认识别结果可用，
   并记下各自的阈值与调用方式（后面要在这两个例程上改输出）。

### 通信协议：3 位数据 + 1 根 strobe（共 4 根线）

一次只传一个「符号」，每符号 3 bit；**一条消息 = 两个符号**：先「类别」，后「数值」。

类别 CAT：

| 值 | 含义 |
|---|---|
| `001` | 颜色事件 |
| `010` | 方向 / 交通牌事件 |
| `011` | 命令（清空顺序、新一圈等） |
| `111` | 心跳（数值位忽略） |

数值 VAL：

| 类别 | `001` | `010` | `011` | `100` |
|---|---|---|---|---|
| 颜色 | 红 | 黄 | 绿 | 蓝 |
| 方向 | 左转 | 右转 | 直行 | — |
| 命令 | 清空顺序 | 新一圈 | 保留 | 保留 |

**帧格式与容错**：符号 `000` 只作分隔，不承载语义。
发送侧固定写 `000 → CAT → 000 → VAL → 000`，每条消息**连发两遍**；
接收侧只在连续两遍解析结果一致时才采纳，不一致就 `err_cnt` 加一。
这样即使漏采一个 strobe，下一个 `000` 也会把状态机拉回同步。

**时序（关键：K230 是 Python 侧，写 GPIO 的抖动可达毫秒级）**：

```
D[2:0] = 数据      # 先写数据
sleep 1 ms         # 等它稳住（数据建立时间）
STB = 1            # 再拉 strobe
sleep 1 ms
STB = 0
sleep 1 ms         # 符号间隔
```

`1 ms` 是宽裕值（100 µs 也能跑，没必要省）。一条消息 3 符号 × 2 ms × 2 遍 ≈ 12 ms，
视觉事件最高 30 Hz，带宽完全够。FPGA 侧对 strobe 打两拍同步、**在上升沿采样 D[2:0]**，
所以「数据先稳 → 再拉 strobe」这个顺序保证 D 上永远不会出现半个符号。

### FPGA 侧待实现 `k230_link.v`（接口契约，下一轮写）

```verilog
module k230_link (
    input             clk,        // 24 MHz
    input             rst_n,
    input      [2:0]  k230_d,     // 来自 K230 GPIO42/43/34
    input             k230_stb,   // 来自 K230 GPIO35
    output reg [3:0]  color_evt,  // 0=无 1=红 2=黄 3=绿 4=蓝，单周期脉冲
    output reg [2:0]  dir_evt,    // 0=无 1=左 2=右 3=直，单周期脉冲
    output reg [7:0]  cmd_evt,    // 命令位图，单周期脉冲
    output reg        link_alive, // 2 s 内收到过合法消息
    output reg [7:0]  err_cnt     // 两遍不一致次数，挂到调试行
);
```

**输出刻意与 `color_detect.v` 的颜色事件同构** —— `color_seq.v` / `oled_driver.v` 一行都不用改，
把顶层里颜色事件的来源从 `color_detect` 换成 `k230_link` 即可。
`dir_evt` 交给 `car_fsm.v`（交通牌决策），`link_alive` 用于 OLED 显示 `K230 OFF` 提示。

### 接线表（K230 12pin ↔ Ti60 DC3-40）

**2026-11-17 固定线束**：下表通信编号保持不变，完整冲突核对、电平验证与 LCD 分配（2026-11-20 起已例化，见 §3.38）以
[docs/K230_GPIO_FIXED.md](docs/K230_GPIO_FIXED.md) 为准。K230 程序已改为匹配现有 strobe 协议，
旧 REQ/ACK 原型废止。这里只确认源码/约束分配，尚不能宣称已完成实物电平及两板联调。

| K230 信号 | K230 引脚 | 12pin 针号 | FPGA 端口 | FPGA 引脚 | User_IO | bank/电平 | DC3-40 针号 |
|---|---|---|---|---|---|---|---|
| D0 | GPIO42 | 1 | `k230_d[0]` | GPIOL_P_14 | User_IO25 | 1B / 1.8V | 28 |
| D1 | GPIO43 | 2 | `k230_d[1]` | GPIOL_N_16 | User_IO28 | 1B / 1.8V | 33 |
| D2 | GPIO34 | 8 | `k230_d[2]` | GPIOL_P_16 | User_IO29 | 1B / 1.8V | 34 |
| STB | GPIO35 | 10 | `k230_stb` | GPIOT_N_11 | User_IO34 | 2B / 1.8V | 39 |
| GND | GND | 4 或 7 | — | — | — | — | 12 或 30 |

这四根全部取自 §3.5 的预留池（User_IO25 / 28–33 / 34），**不动任何已用引脚**。
DC3-40 针号按「pin1–10 = User_IO0–9、pin13–28 = User_IO10–25、pin31–40 = User_IO26–35」推得，
与 §3.16 OLED 用的「P4 pin 15/16/29 = User_IO12/13 + D3V3」自洽；接线前照丝印再核一遍。

**两个一看就错的坑**：

- **`GPIOL_P_16`（User_IO29）与板载调试串口的 `GPIOT_P_16` 是两颗不同的球**，只差一个字母，看错就把串口弄哑。
- K230 排针是**双排**，官方编号 1/3/5/7/9/11 在一排、2/4/6/8/10/12 在另一排，**不要按顺序数**。

### 供电与地（最容易烧板的一条）

- K230 由 **USB 口供电（5V）**，从车载 DC-DC 拉一路 5V 经 USB 线进去。
  亚博文档原话「K230 视觉模块耗电较大，请使用 USB3.0 接口连接」，峰值不低。
- **12pin 的 pin9 / pin11 是 5V 输出，不是输入**，别往里灌电。
- **绝对不能从 Ti60 板的 D3V3 取电**：板载 AMS1117-3.3 余量很小（xlsx「电源分配」原话「建议独立 LDO」）。
- **必须共地**：K230 的 GND 与 Ti60 的 GND 接在一起，否则信号没有参考电平，读出来全是垃圾。
- 信号线本身是 3.3V ↔ 3.3V（排针外侧），不需要再转换；FPGA 侧 1.8V 由板上 TXS0108EPWR 负责。
- **下拉怎么来（2026-11-20 改）**：`FpgaCar.peri.xml` 里这 4 根脚已从 `pull_option="none"` 改成 `weak pulldown`，用 FPGA 内部弱下拉保证 K230 没上电时不浮空。原来计划的「在 Ti60 排针侧加 4 只 10 kΩ 下拉」现在只是可选冗余（内部弱下拉与外部电阻并联，无害）。K230 接上后是推挽驱动，轻松压过弱下拉，功能无影响。

### 备选方案（万一自由 GPIO 不足 4 根）

| 方案 | 线数 | 何时用 | 代价 |
|---|---|---|---|
| **A 并行 4 线（本方案）** | 4 | 自由 GPIO ≥ 4 | 无 |
| B SPI 从机 | 3（SCLK/MOSI/CS） | 只剩 3 根 | K230 用硬件 SPI；FPGA 侧移位寄存器 + CS 边沿，约 25 行 |
| C 4pin 通讯口走 UART | 1 对 | 12pin 全被占 | 占用唯一串口口；帧同步靠字节超时 |
| D 3 位并行无 strobe | 3 | 绝对没余量 | 靠「数据一变就是事件」，连发同色无法区分，**不建议** |

### 交给同学的 TODO（按顺序，做完勾一项）

- [ ] 装 CanMV IDE，用亚博提供的固件（保持 TF 卡启动，别刷成通用固件，屏幕驱动会没了）。
- [ ] 跑 `fpioa.help()`，把 pin 26 / 32 / 33 / 34 / 35 / 42 / 43 的当前 func 抄回来（**最关键的一条**）。
- [ ] 量 GPIO42 输出高电平，确认是 3.3V 还是 1.8V。
- [ ] 跑 5.3「多颜色识别」例程，稳定认出红/黄/绿/蓝，记下 LAB 阈值。
- [ ] 跑 10.11「道路标志识别」例程，确认能分出左转/右转/直行，记下模型与调用方式。
- [ ] 把两个例程的识别结果改成走 4 根线输出（按本文的时序与编码）。
- [ ] 与 Ti60 板对接联调，用逻辑分析仪或示波器看 STB 上升沿与 D[2:0] 的对应关系。

**同学那边不需要碰 Ti60 的任何东西**，只要 CanMV IDE + K230 + 一根 USB 线；
FPGA 侧的接收模块与 `peri.xml` 的四个新管脚由我们补。

### 风险与验收判据

| 风险 | 影响 | 处理 |
|---|---|---|
| GPIO32/33 其实没被占、而 34/35 反被占 | 接线表要改 | `fpioa.help()` 一次就能定 |
| K230 GPIO 是 1.8V | 电平不匹配 | 加一级转换，或改走 4pin 通讯口跑 UART |
| Python 侧抖动导致漏脉冲 | 丢一个颜色 | 两遍一致才采纳 + `000` 分隔自同步 |
| K230 与 Ti60 上电顺序不同 | 上电瞬间误触发 | 10 kΩ 下拉 + `link_alive` 2 s 超时 |
| 光照变化导致颜色误判 | 顺序记错，扣 20 分 | K230 侧用 LAB + 色卡现场标定；FPGA 侧保留「同色连报只记一次」去重 |

**验收判据**（联调当天就能判）：

1. 两边上电，`link_alive=1`，OLED 不显示 `K230 OFF`。
2. 拿红/绿/蓝/黄色卡依次对着 K230，OLED 从左往右按同样顺序出现四个色块，`err_cnt` 保持 0。
3. 拔掉 K230 的连线，2 s 内 OLED 出现 `K230 OFF`；插回后自动恢复。

**尚未同步的地方**：`docs/硬件接口表.xlsx` 的「总表」还没加这 4 行，
`FpgaCar.peri.xml` 也还没加这 4 个管脚 —— 两者与 `k230_link.v` 一起，在下一轮改代码时一次性同步，
避免出现「表里改了、工程里没改」的半成品状态。
## 3.19 方案变更：暂停 OV5640，遥测报文换格式（2026-11-16，已改 RTL 并全量回归）

**结论先行**：摄像头整条链路（`cam_probe` / `cam_sccb_cfg` / `dvp_capture` / `color_detect` / `frame_snap`）
从顶层数据通路摘掉，改成两个一行恢复的开关；串口报文从「距离 + 颜色统计」换成「距离 + 状态机 + 里程 + 速度」。
18 个测试台全过，RTL 与管脚约束之外的源文件一个没删。

### 为什么停

K230 接管颜色与交通牌（§3.18）之后，OV5640 链路在赛场上没有职责了。而它一直是整机里最耗资源、
最容易在上电顺序上出岔子的一块：DVP 需要 XCLK 起来、SCCB 配置成功、PCLK 相位对，任何一环不对就是黑屏，
而且故障现象和「镜头盖没摘」长得一模一样，现场排查代价极高。停用它之后，摄像头相关的所有引脚都有确定电平，
示波器一搭就能判断「到底是摄像头的问题还是别的问题」。

### 怎么停的（两个开关，一行恢复）

`src/FpgaCar.v` 模块体开头新增：

```verilog
localparam USE_CAMERA = 1'b0;   // 置回 1'b1 即恢复整条 DVP/SCCB/颜色识别链路
localparam USE_OLED   = 1'b0;   // 同理，恢复 SSD1306
```

两者都用 `generate` 分支实现，**端口列表、引脚约束 `FpgaCar.peri.xml`、`.sdc` 全部不动**。
恢复时只改这一个 `1'b0`，不用碰别处，也不会出现「代码改了但管脚没配」的半成品状态。

停用分支里摄像头的输出全部赋确定值：`cmos_sclk=0`、`cmos_sdat_OUT=0`、`cmos_sdat_OE=0`
（释放 SDA 靠外部上拉），`cam_color=3'd0`、`cam_color_evt=1'b0` 继续喂给 `color_seq`，避免出现孤立网络。

**三根 `CMOS_CTL` 与开关无关，永远驱动 0**（`cmos_ctl1` / `cmos_rst_n` / `cmos_pwdn`）。
这条来自 §3.12 的上板实测：CTL2 给 1 会让传感器完全不出图，照抄官方 `example_top.v` 的实测值即可，
不是「复位脚」。改这块的时候最容易被误当成复位逻辑顺手改掉。

### 报文换成了什么

| | 旧（v6） | 新（v7） |
|---|---|---|
| 第一行 | `D=123cm T=00011000 P=+02 O=0 V=03 C=1 W=2560 H=720 Q=1 XY=0861`（64 B） | `D=123cm T=00011000 P=+02 O=0 M=01`（35 B） |
| 第二行 | `R=00300 G=00000 B=00000 Y=00000 S=3F SB=F800 LB=F800`（54 B） | `L=00000123 R=FFFFFFF0 VL=0005 VR=FFF0 X=00011000 C=+036 DL=27C DR=234`（71 B） |

- `M=nn` 是状态机状态两位十进制（00 IDLE / 01 RUN / 02 LOST / 03 SEARCH / 04 STOP）。
  以前车一停，串口只能看到「不动了」，分不清是没起跑、在原地找线、还是永久停车 —— 这三种处置方式完全不同。
- `L=` / `R=` 是左右编码器累计里程，`VL=` / `VR=` 是每 50 ms 窗口的净步数，**都是十六进制二补码**
  （里程 8 位、速度 4 位）。用十六进制是因为 32 位有符号转十进制要在组合逻辑里级联 8 次除 10，
  代价远大于收益，换算放到主机侧。
- 删掉 16 个 `cam_*` 端口（`vs_cnt` / `cam_done` / `cam_width` / `cam_height` / `cam_color` /
  `cam_b0` / `cam_b1` / `cam_cnt_r/g/b/y` / `cam_sat` / `cam_sb0/sb1` / `cam_lb0/lb1`），
  `src/uart_report.v` 的 `dv10()`（16 位除 10）随之删除，只留 `div10u()`。
- 2026-11-18 追加第二行尾部四个循迹调试字段（详见 §3.24），第二行由 39 B 变成 71 B。
- 波特率不变，两行 106 字节约 9.2 ms，一帧 60 ms，仍然发得完，不需要队列。

### 主机侧脚本同步（本次一并改了）

- `tools/uart_mon.py`：字段换成 `D/T/P/O/M` 与 `L/R/VL/VR`（2026-11-18 再补 `X/C/DL/DR`），十六进制按二补码解成有符号数，
  `M` 自动翻成状态名，额外打印「窗口内左右走了多少步」与「速度区间」。
  正则用 `(?:^|\s)` 锚定，否则 `VR=FFF0` 里的 `R=` 会被误当成右里程。
- `tools/cap.py`：原来解 RGB565 看镜头对着什么颜色，没有数据源了，改成**纯遥测记录器**，
  CSV 列为 `t,D,T,P,O,M,L,R,VL,VR,X,C,DL,DR`，并汇总状态跳变序列与平均步/秒。
  这个脚本现在正是标定每米脉冲数的工具：直行已知距离，取 `|L|`，脉冲/米 = 步数 / 米。
- 两者都用假串口做过端到端冒烟测试（6 帧合成报文），CSV 落盘与汇总输出均正确。

### 休眠而不是删除的摄像头工具

`tools/grab_frame.py`（抓 40×30 缩略图）、`tools/tune_color.py`（离线复现 `color_detect` 门限并网格搜索）、
`tools/webimg_to_frame.py`（网图转 CSV）、`tools/snap.bat` 全部保留原样。
它们依赖 DVP 出图，现在没有数据源，但**代码本身没错**，恢复 `USE_CAMERA=1'b1` 当天即可继续用。
删了反而会在「万一 K230 方案落地不了、要退回 OV5640」时重写一遍。

### 验证与遗留

- `bash tools/run_regression.sh`：18 个测试台全 OK，0 失败，44 s。
  其中 `FpgaCar_tb` 新增两条断言：LED 按新映射（`{heartbeat,car_state,obstacle,line_lost}` 取反）检查，
  以及「摄像头停用后所有 cmos 输出都是确定值」。
- `uart_report_tb` 重写为 5 个用例、逐字节比对两行共 74 字节，`ALL PASS`。
  坑：模板串里的 `\r\n` 写在 Verilog 字符串里会被当成真换行截断字符串（`Missing closing quote`），
  测试台改为只写正文 n 字节、末尾两个字节单独赋 `8'h0D`/`8'h0A`。
- **必须保留 `heartbeat` 计数器**，哪怕它只驱动一个 LED：全逻辑被优化光之后 Efinity 会报
  `VDB-9009 Post-synthesis netlist has only vcc and gnd nets ... will cause router to crash`。
- 未做：`docs/硬件接口表.xlsx` 总表注 6 里 `User_IO25/28~33/34` 仍写「预留」，与 §3.18 的 K230 分配冲突，
  等同学把 `fpioa.help()` 实测结果发回来再一次性改，避免来回改两遍。
## 3.20 底盘定型：四轮，左右各两电机并联一个 TB6612 通道（2026-11-16）

**硬件事实**：四轮底盘，左侧两个电机并联用 A 通道（`PWMA` / `AO1` / `AO2`），
右侧两个并联用 B 通道（`PWMB` / `BO1` / `BO2`）。TB6612FNG 模块是 **16 脚（每侧 8 脚）**，
不是本文此前写的「标准 12 脚」—— 那是另一款裸芯片转接板的叫法，以实物丝印为准。

**RTL 完全不用改**：顶层本来就是两路（`ml_*` / `mr_*`），与「左右各一路」严格对应。
`pwm_gen` 出 20 kHz，TB6612 允许到 100 kHz，余量充足。

### 三条接线硬约束（第一条最容易踩）

| # | 约束 | 原因 |
|---|---|---|
| 1 | **`VCC` 接 `D3V3`（P4 pin 29），绝不能接 `D5V0`（pin 11）** | TB6612 手册：`VIH = VCC × 0.7`。VCC=5 V 时门限 **3.5 V**，而排针外侧只有 3.3 V，逻辑高**不被保证识别**；VCC=3.3 V 时门限 2.31 V，有约 1 V 余量。这条与 §3.16 OLED 的警告同源（TXS0108E 的 B 侧绝对最大 4.6 V） |
| 2 | **`STBY` 必须接 `User_IO24`，不能悬空** | 悬空时芯片状态不定；本设计默认输出 0 = 待机，安全 |
| 3 | **同侧两电机先各自单独试转向** | 极性反了只是反转不会烧，但两个轮子对打会让循迹彻底失效 |

`VM` 单独接电池（2S 锂电 7.4 V，手册允许 4.5–13.5 V，绝对最大 15 V），**不要从 D3V3 或 D5V0 取**。

### 电流预算（唯一需要盯的风险）

TB6612 每通道 **1.2 A 连续 / 3.2 A 峰值**（10 ms 单脉冲）。TT 减速电机空载约 0.15 A、
正常行驶 0.3–0.5 A，**堵转 1.5–2.5 A**。一侧两电机并联 → 正常 1 A 以内没事，
**但任一轮被卡住时单侧就可能越过 3.2 A 峰值**，芯片 175 °C 热保护后直接停机。

现场表现是「跑着跑着突然不动，凉了又能动」—— 看到这个现象先摸芯片温度，不要先怀疑代码。

三个应对，按代价排序：

1. **先按一块板接**，跑的时候摸芯片温度、盯串口 `M=` 有没有莫名掉 `STOP`。不热保护就不用管。
2. 若经常热保护：**加第二块 TB6612，两块各自把 A/B 两通道并联**当一个大通道用
   （`AIN1`-`BIN1`、`AIN2`-`BIN2`、`PWMA`-`PWMB`、`AO1`-`BO1`、`AO2`-`BO2` 全短接），
   单侧能力翻倍到 2.4 A。**FPGA 侧一根引脚都不用加**，因为并联后两侧输入本来就该一样。
3. 更彻底：每轮一个通道（两块板四通道），但要**多 2 根 PWM**（`User_IO30/31` 现成可用）。
   好处是能单独微调每个轮子的占空比来修正直行偏差 —— 四轮车靠这个比靠 PID 更有效。

### 电机电压与 `DUTY_MAX`

TT 电机额定多为 **3–6 V**，而 VM 是 7.4 V。50% 占空比平均 3.7 V 正合适，
但 `DUTY_MAX = 1200`（100%）会让电机吃到 7.4 V，电池满电时 8.4 V。
**确认电机额定电压后，若为 6 V 就把 `DUTY_MAX` 降到 970 左右（80%）**。

### 编码器怎么装

四轮但只有两路编码器输入：**每侧装一个**，装在负载较轻、不容易打滑的那个轮上。
左右里程差（`L=` / `R=`）仍是 PID 之外判断「是不是真跑偏」的唯一硬指标 ——
四轮并联时两轮转速天然有差异，只能靠里程差发现。

### 对上板参数的影响

四轮 + 固定轮 + 靠打滑转向（skid steer），转向阻力比两轮大得多，三处参数要重新试：

- `SEARCH_DUTY = 500`（42%）原地转**可能转不动**，先试到 700–800。
- `BASE_DUTY = 600` 是按两轮估的，四轮摩擦大，多半要往上调。
- `DIR_DEAD_MS = 10` 保留 —— TB6612 同相翻转有电流尖峰，四轮电流更大更需要这段死区。

## 3.21 HC-SR04 接线定稿 + 编码器暂缓 + 剩余待买清单（2026-11-16）

### HC-SR04：3.3 V 直连定稿（2026-11-18 修订）

实物照片已确认 4 脚自上而下是 `Vcc / Trig / Echo / Gnd`。逐脚对应与配图见
[docs/模块接线说明.md](docs/模块接线说明.md) §3 与 [docs/HC-SR04接线图.png](docs/HC-SR04接线图.png)。

| 脚 | 接往 | 关键点 |
|---|---|---|
| `Vcc` | **3.3 V**（外部电源模块的 3.3 V 输出） | 2026-11-18 实测：3.3 V 下 2.2 m 仍稳定回波，旧「量程掉到 1 m」结论作废 |
| `Trig` | `hc_trig` = User_IO10 / G4 / pin 13 | 3.3 V 直驱够用，脉宽 15 µs（`TRIG_US`） |
| `Echo` | **直连** → `hc_echo` = User_IO11 / G3 / pin 14 | 高电平 = `Vcc`，3.3 V 供电时即 3.3 V，直连合法；**改回 5 V 供电才需 1 kΩ 串 + 2 kΩ 下地**（5 V × 2k/(1k+2k) = 3.33 V，TXS0108E B 侧绝对最大 4.6 V） |
| `Gnd` | **面包板 GND**，两根线回 Ti60 `pin 12` / `pin 30` | 功率地与信号地单点相接；面包板上下电源轨要桥接 |

现在**不需要任何分压电阻**。理由：Echo 由模块板上 MCU 在 `Vcc` 轨上推挽输出，`Vcc` 给 3.3 V，
Echo 顶多 3.3 V，`pin 14` 直连不超 TXS0108E 的 4.6 V 绝对最大值。

若将来改回 5 V 供电，分压取值仍是 `1 kΩ + 2 kΩ`：手上只有 2.2 kΩ 时输出 3.44 V 仍安全；
**不要 1 kΩ+1 kΩ**（2.5 V 余量太小），**也不要 10 kΩ 级**（TXS0108E 靠边沿加速，驱动太弱会拖慢上升沿）。
分压电阻必须放在**排针侧**：模块到电阻之间走 5 V，电阻到排针走 3.3 V，放反了等于把 5 V 灌进电平转换器。

上板判据：串口 `D=` 随手远近变化即通；一直 `D=---cm` 按 ① 模块 Vcc 3.2–3.4 V → ② Trig 有 15 µs 脉冲
→ ③ Echo 对 GND ≤3.4 V → ④ 并 100 nF 的顺序查（详见模块接线说明 §3.3）。

### 编码器：本轮不买，等实测再定

用户决定（2026-11-16）：**暂时不采购编码器，等测试之后再考虑要不要买**。

- RTL 侧不受影响：`encoder_dec.v`（AB 四倍频）与 `speed_meter.v`（50 ms 窗口净步数）已完成并进过回归，
  引脚 `enc_la/lb/ra/rb` = User_IO14–17 继续留在 `peri.xml` 里锁好，将来装上直接能用，不用改管脚。
- 没有编码器时的**降级调试路径**（先按这条跑通运动类）：
  1. 速度用 `pwm_gen` 的占空比当开环量，标定「多大占空比 → 多快」靠秒表和地面距离，不靠闭环；
  2. 循迹 PID 用 `track[7:0]` 的 `pos` 做单环（位置环），没有速度环 —— 直道能跟，弯道会甩，参数容错更窄；
  3. 入库停准改用**时间 + 超声距离**双条件（跑固定时长后看 `D=` 到阈值就停），误差靠现场调；
  4. 串口 `L=` / `R=` 会恒为 `0`，`VL=` / `VR=` 恒为 `0000` —— 这不是故障，是没装编码器的正常表现；
  5. `LED[0]`（左右里程异或 + 心跳）不会因手转轮子而闪，**所以「手转轮看 LED 闪」这条自检暂时失效**，
     别把它当成编码器接错的证据。
- 装上编码器后立刻能多拿回：里程闭环、直行纠偏、5 s 停稳入库（15 分）的精度。**建议先跑一轮无编码器版本，
  把机械与接线问题暴露完，再决定买不买** —— 这也正是用户的意思。

### 还缺什么（按「到货才能推进哪一步」排）

| 优先级 | 物件 | 数量 | 卡住什么 | 备注 |
|---|---|---|---|---|
| **必配** | 直流减速电机（带轮） | 2 | 运动类 55 分的全部（循迹 20 + 避障 20 + 入库 15） | 与 2S 电池电压匹配；§3.20 定的是四轮、每侧两电机并联一个 TB6612 通道，**实际要 4 个电机**，若按「2 个电机 + 四轮底盘」则需确认底盘是否自带减速箱 |
| **必配** | 2S 锂电池组 7.4 V | 1 | 整车供电 | 带保护板，≥2000 mAh；**另需配套充电器**（待买清单里原来漏了） |
| **必配** | DC-DC 降压 5 V / ≥3 A | 1 | 传感器 + K230 + FPGA 板 | 与电机功率地单点共地 |
| **保留·暂不买** | E18-D80NK 红外 ×2 | 2 | 不卡任何一步 | User_IO26/27；开集空闲 5 V，须外部 10 kΩ 上拉 D3V3 + 1 kΩ/1.2 kΩ 分压到约 1.8 V（注意与超声的 1k/2k 不同）。**2026-11-17：现阶段不用，`USE_IR = 1'b0`；以后不说启用就不接** |
| **暂缓** | 光电编码器 ×2 | 2 | 里程闭环（不是跑通的前置） | 本轮不买，见上 |
| **辅料** | 10 kΩ / 1 kΩ / 1.2 kΩ 电阻 | 各 10 | E18-D80NK 上拉与分压（红外暂不启用，可顺手买） | 1/4 W 金属膜，1% 更稳。**HC-SR04 已改 3.3 V 直连，2 kΩ 不再是必需件** |
| **辅料** | 杜邦线、2.54 排针、热缩管、XT30/XT60 接头 | 若干 | 整车接线 | 杜邦线建议公母各一包 |
| **辅料** | 保险丝座 + 5 A 保险丝、船型开关 | 各 1 | 电池安全 | 2S 锂电短路电流很大，**建议加**（不是硬性） |
| 可选 | 广角镜头、VL53L1X | — | 视野/近距补充 | 不影响主线 |

> 编码器暂缓后，**运动类 55 分的路径不变**：先用开环 + 超声把循迹和避障跑起来，
> 拿分点仍然是「能循迹、能避障、能停」而不是「闭环调得多漂亮」。

## 3.22 超声周期 bug 修复 + 循迹八位读数排查（2026-11-17）

### 3.22.1 `hc_sr04.v` 的 `S_PERIOD` 少了 `us_tick` 门控（真 bug，已修）

上板实测报文速率 **80.6 行/秒（间隔 12.41 ms）**，而设计是每 60 ms 一行。根因：

- `S_PERIOD` 分支里原本是 `period_cnt <= period_cnt + 18'd1;`，**每个 24 MHz 时钟加一**；
- 而 `S_TRIG` / `S_WAIT` / `S_MEAS` 三个状态都写了 `if (us_tick)`；
- 于是 `PERIOD_US = 60_000` 实际只等了 60 000 个时钟 = **2.5 ms**，短了 24 倍。

**危害不只是"报得快"**：HC-SR04 规格要求两次触发间隔 ≥ 60 ms，太快触发会让上一次的余波
与下一次的发射混在一起 —— 这正是实测「**约一半帧是 `D=---cm`**」（567/1134）的原因。
余波未散时模块自己都收不到回波，所以不是模块坏了。

**修法**（`src/hc_sr04.v:93-107`）：`S_PERIOD` 整体包进 `if (us_tick)`，与其它三个状态一致。
修完仿真实测 **66.2 ms**（60 ms 等待 + 5.8 ms 回波测量），≈15.1 Hz，满足 ≥60 ms。

**为什么原测试台没抓到**：防的是"用了 10 ms 周期"和"从不断言 Trig 间隔"两个坑 ——
`sim/hc_sr04_tb.v:17` 把 `PERIOD_US` 缩短成 `10_000`，且只 `wait_meas()` 等 `valid`，
**从不检查两次 Trig 之间隔多久**，周期再错也 PASS。

**新增 `sim/hc_sr04_period_tb.v`**：用真实 `PERIOD_US = 60_000`，固定 5800 µs 回波，
逐次打印 `TRIG#n gap = xx us`，判定 `0.95 × PERIOD_US ≤ gap ≤ 1.60 × PERIOD_US`，
末尾 `ALLPASS`。改回旧代码时会立刻 `FAIL`，这就是这次能守住的原因。

> **教训**：定时类的状态机，凡是有一处忘了 `us_tick` 就会整体失真；测试台必须断言
> **物理时间**（µs/ms），不能只断言"最终产出了正确值"。

### 3.22.2 循迹 `T=` 恒为 `10000001` 的含义（待硬件确认）

静置 10 s、1134 帧，`T=` **零抖动，恒为 `10000001`**。按 `uart_report.v:236-243` 的打印顺序
（`msg[10] = ln[7]` 最右 … `msg[17] = ln[0]` 最左），首字符是 **bit7**：

| 位 | 探头位置 | 实测 | 含义 |
|---|---|---|---|
| bit7 | 最右 X8 | 恒 `1` | 判定压线 |
| bit6..bit1 | 中间六路 | 恒 `0` | 判定未压线 |
| bit0 | 最左 X1 | 恒 `1` | 判定压线 |

两侧压、中间不压 → 加权和 `+7 - 7 = 0` → `P=+00`。**这个对称结构不像噪声**：真悬空会随机跳，
而这里 10 s 一位都没翻过。要么最外侧两路对着车架边缘/桌面反射，要么校准值把两侧调到了
"恒判黑"（本模块无电位器，见 `docs/模块接线说明.md` §2.3），要么 X1/X8 那两根线接到了别的东西上。

**上板判定步骤**（需要人配合，代码侧无法自证）：

1. 把黑线单独移到 X1 正下方 → `bit0` 应翻成 `0`（`ACTIVE_HIGH = 0` 时压线报 0 经取反为 1，
   实际看的是"移开黑线时该位是否变化"）；
2. 逐路重复，确认 8 路各自独立可控；
3. 若某一路怎么移都不变 → 该路没接好/没供电/探头坏；
4. 若全部恒 `1` 或恒 `0` → `ACTIVE_HIGH` 极性反了，改参数重编（**不要改接线**）。

## 3.23 供电路径整改：HC-SR04 改 3.3 V 直连（2026-11-18）

### 3.23.1 起因：Echo 5 V 直连 pin 14，超 TXS0108E 绝对最大

用户此前的实际接法（m03342 确认）：HC-SR04 的 `Vcc` 接在 **Ti60 排针 pin 11（`D5V0`）**，
YB-MUX04 的 `5V` 接外部电源模块，Ti60 的 GND 接面包板 GND，**Echo 未加任何分压电阻**。

三处超规格 / 隐患：

| # | 问题 | 依据 |
|---|---|---|
| 1 | **Echo 5 V 直连 `pin 14`**，超 TXS0108E B 侧绝对最大 4.6 V 达 0.4 V | §3.16、`引脚分配表.md:33` |
| 2 | **`Vcc` 从 `pin 11` 取电**：该脚在引脚表里是「5V **电源输入**」，不是输出，等于让电流反向穿进板子 5 V 轨 | `引脚分配表.md:30` |
| 3 | **只开 Ti60 时 YB-MUX04 断电，但 X1~X8 仍插在排针上** → TXS0108E 的 B 侧推挽高电平经模块输入端 ESD 钳位二极管倒灌进模块 5 V 轨，形成「反向供电」。这与「只开 Ti60 就有电流声」的现象吻合 | `模块接线说明.md:128` |

### 3.23.2 改法：Vcc 改 3.3 V，Echo 直连合法

`Echo` 由板上 MCU 在 `Vcc` 上推挽输出，高电平电压 = `Vcc`。因此**把 Vcc 改到 3.3 V 之后，
Echo 也就是 3.3 V，`pin 14` 可直连，不需要任何分压电阻**。

- 3.3 V 取自**外部电源模块的 3.3 V 输出**，不从 Ti60 的 `D3V3`（pin 29）取。
- 附带修正：用户随后发现 `3.3 V` 的地与 `5 V` 的地**没有共到一起**，补上共地后重测（m03381）。

### 3.23.3 实测结果（COM12 / 115200-8N1，`.scratch/diststats.ps1`、`.scratch/tbitstats.ps1`）

**距离（3.3 V 供电，15~20 s 采样）**

| 指标 | 改之前（5 V，未分压） | 改之后（3.3 V，共地补齐） |
|---|---|---|
| 丢帧（`D=---cm`） | 约一半帧（567/1134） | **0 帧**（215/215 有回波） |
| 非 ASCII 字节 | 偶发 | **0** |
| 帧间隔 | 12.41 ms（周期 bug 未修时） | **约 70 ms**（60 ms 周期 + 回波测量 + 发报） |
| 主读数 | `006cm` 恒定 / `092` 乱跳 | **182~220 cm 可达 2.2 m**，另有 41~46 cm 一簇 |

> **订正**：`模块接线说明.md` 原写「3.3 V 供电时量程掉到 1 m 以内」，**实测不成立**。
> 3.3 V 下 2.2 m 仍稳定收到回波。原因推测：该模块板载升压，或该批次发射效率高于标称。
> 因为顶层只用到 `OBSTACLE_CM = 16'd25`（`FpgaCar.v:280`），量程无论如何都够。

读数为两簇（41~46 cm 与 182~220 cm）交替，属**锥角（约 15°）同时照到两个反射面**的正常多路径
现象，簇内稳定（`043/042/041` 连续、`219/220` 连续），不是乱跳。判「准不准」需人把物体放在
已知距离（如 20 cm）正前方再读。

### 3.23.4 循迹 `T=` 八位恒为 `11111111`（待硬件定性）

共地补齐后 15 s / 211 帧、另 25 s 观测，**`T=` 恒为 `11111111`，25 s 内一位未翻**，`M=01`（RUN）。

**先纠正一个易误读点**：串口打印的 `T=` 不是原始电平，而是**极性统一之后**的结果 ——
`FpgaCar.v:630` 接的是 `line_bits`（`track_line` 的 `line` 输出），而 `track_line.v:93` 为
`line = ACTIVE_HIGH ? trk_stable : ~trk_stable;`，`ACTIVE_HIGH` 取默认 `0`。
所以 `T=11111111` = **八路全部判定「压线」**，对应原始电平全为**低**。

注意这**推翻了 §3.22.2 的推断**：当时观察到 `10000001`（两侧报压线），现在变成八路全报压线，
说明那两根线的异常只是当时的状态，现在的问题变成了整体性误判。

排除法：**不是断电**。模块断电时 X1~X8 悬空，TXS0108E 内部上拉会把它们拉成高电平，
经取反后 `T=` 应为 `00000000`；现在全 `1` 反而说明模块在正常工作，只是「看到的东西全是黑的」。

三种可能，按概率排：

1. **模块正压在深色表面上** —— 探头离桌面仅 1~2 cm，桌面深色即八路全判黑。最易验证：把模块悬空、
   探头顶白墙，看 `T=` 是否变 `00000000`。
2. **未校准 / 校准值不匹配** —— 本模块**没有可调电阻**，阈值靠板载 MCU 按键校准（2026-11-19 依官方说明书订正，详见 `docs/模块接线说明.md` §2.3）。校准缺失或与当前离地高度不符时，八路会一起判黑。
3. **接线顺序或接触问题** —— 但八路同时出同样的问题概率低。

**判定步骤**（需人配合）：

1. 抬起模块悬空 / 探头顶白墙 → `T=` 应变 `00000000`；
2. 量 **X1 对 GND**：应是稳定的 3.3 V 或接近 0 V，**不能是 1.5 V 之类中间值**（中间值=比较器抖动或无供电）；
3. 看模块板上的**电源指示灯**是否亮（亮 = 5 V 与地到位）；
4. 用白纸/黑色绝缘胶带单独只晃 **X1**，只看 `T=` 最右一位（bit0）是否翻转，逐路重复。

### 3.23.5 硬件侧结论：5 V 负载一律不挂 Ti60 排针

- 所有 5 V 负载（HC-SR04 → 现在改 3.3 V、YB-MUX04 100~200 mA、以后的 K230）**统一由外部电源模块供电**，
  Ti60 只提供逻辑电平与地，一块负载都不从排针取电。
- **共地要接两根**（`pin 12` 与 `pin 30`）：循迹模块 100~200 mA 的回流全走这根线，单根杜邦线的
  接触电阻会让地电位浮动。
- 面包板电源轨中间通常是断开的，上下两半要用短接线桥接。
- `D5V0`（pin 11）与 `D3V3`（pin 29）都是「输入」性质，**不作为对外供电口使用**。
- 若将来需要 5 V 版超声的长量程，正解是换 **HC-SR04P**（原生 3.3 V、输出 3.3 V、约 3 m 量程，直连不分压）。

## 3.24 循迹可观测性：报文补 X= / C= / DL= / DR=（2026-11-18）

起因：车已经组装完（电源模块、Ti60、OLED、YB-MUX04、TB6612、HC-SR04，K230 暂不接），
要开始调循迹。但对着现有的 `T=` 与 `P=`，遇到问题时分不清是哪一层出了事。

### 3.24.1 为什么原来的字段不够

`T=` 是 `track_line` **按 `ACTIVE_HIGH` 统一极性之后**的结果（`src/track_line.v:93`
`line = ACTIVE_HIGH ? trk_stable : ~trk_stable;`，默认 `ACTIVE_HIGH=0`）。
于是"极性设反了"和"模块真的八路全报黑"在 `T=` 上都是 `11111111` —— 两条完全不同的故障，
报文上长得一模一样。11-18 夜里就是卡在这里：八位恒 `11111111`、一位不跳，
既可能是校准缺失/失配，也可能是 ACTIVE_HIGH 设反，只能靠猜。

`P=` 是加权质心，丢线时被强制清 0（`src/track_line.v` 的 `lost` 分支），
所以 `P=+00` 既可能是"线在正中"也可能是"啥也没看见"。
而且 `P=` 和 `T=` 都只是**传感器侧**的量，看不到 PID 到底输出了什么。

### 3.24.2 四个新字段

| 字段 | 来源 | 含义 |
|---|---|---|
| `X=xxxxxxxx` | `track_line.raw`（新增输出端口） | 消抖后的**原始电平**，未经 `ACTIVE_HIGH` 取反。位序同 `T=`，bit7..bit0 = X8..X1 |
| `C=±nnn` | `track_pid.corr` | PID 转向修正量，带符号三位十进制，限幅 ±`BASE_DUTY`（顶层现值 480）。正 = 向右修 |
| `DL=xxx` | `loop_duty_l` | **速度环之后**真正下发给左轮的占空比，3 位十六进制（0..4B0）。2026-11-22 起报环后值，不再是 `ctrl_duty_l` |
| `DR=xxx` | `loop_duty_r` | 同上，右轮 |

判读要点：

- **`X=` 与 `T=` 应当逐位互补**（`ACTIVE_HIGH=0`）。互补 = 链路正常。
  两者完全相同 → `ACTIVE_HIGH` 可能没生效，或者模块输出恒为某一电平（先量 X1 对 GND）。
- **`C=` 是调 PID 时唯一该盯的数**。稳态跑直线时 `C=` 应在一个小范围里来回，
  持续偏向一侧说明一侧电机偏慢（这时才需要积分项）。
- **`DL=` / `DR=` 与 `C=` 的关系是 `DL = 600 + C`、`DR = 600 - C`**（BASE=600=0x258）。
  两者对不上说明状态机在接管输出（LOST 保持 / SEARCH / TURN 会直接覆盖 duty），
  这时候看 `C=` 已经没意义了。
- `ctrl_en=0`（IDLE，未压线）时 PID 不跑，`C=/DL=/DR=` 全是 0 —— 这是预期行为。

### 3.24.3 顺带说明为什么 `P=` 在 IDLE 下不该被当故障

`car_fsm` 的 `START_REQUIRE_LINE=1` 安全锁（`src/car_fsm.v:167-174`）要求**连续压线 `START_MS``
才从 IDLE 进 RUN。把车拿在手里、放到桌上没压线时，它就一直停在 `M=00`，
此时 PID 被 `ctrl_en` 关掉，四个新字段全 0 —— 推车沿黑线走想看 PID 数据，**必须先让它起跑**。

### 3.24.4 报文长度与带宽

第二行 39 B → 71 B，两行合计 106 B。115200-8-N-1 下约 9.2 ms，
一帧 60 ms，余量 6.5 倍，不需要队列。

### 3.24.5 主机侧同步

- `tools/uart_mon.py`：新增 `FIELDS3` 解析 `X/C/DL/DR`，并输出 `X` 与 `T` 的互补关系统计
  （完全相同 / 逐位互补 / 混合），这是判极性的直接手段。
- `tools/cap.py`：新增 `RE3`，CSV 列变为 `t,D,T,P,O,M,L,R,VL,VR,X,C,DL,DR`。
  `RE3` 允许缺省，旧位流抓包仍能解析（新列留空/0）。
- 两个脚本都已 `py_compile` 通过，并用样本报文 `L=0000007B R=FFFFFFF0 VL=0005 VR=FFF0 X=00011000 C=+036 DL=27C DR=234`
  验证过正则（八个字段全命中；旧格式返回 `None`，兼容分支正确）。

## 3.25 单测循迹的临时开关（2026-11-18）

车已装配完成（电源模块 + Ti60 + OLED + YB-MUX04 + TB6612 + HC-SR04，K230 不接），
先只验证循迹。为了让循迹不被别的功能打断，顶层加了两个开关，并把 K230 关掉。

### 3.25.1 三个开关的当前取值

| 开关 | 位置 | 现值 | 含义 |
| --- | --- | --- | --- |
| `USE_ULTRA` | `src/FpgaCar.v:300` | `1'b0` | 超声波不参与障碍判定（O 恒 0） |
| `USE_IR` | `src/FpgaCar.v:292` | `1'b0` | 红外不参与（原就关） |
| `USE_K230` | `src/FpgaCar.v:123` | `1'b0` | K230 链路停用，OLED 不再画掉线叉号 |

`USE_ULTRA` 是这次新加的。改法是把融合式从
`wire obstacle = hc_near | (USE_IR & ir_det);`
改成
`wire obstacle = (USE_ULTRA ? hc_near : 1'b0) | (USE_IR & ir_det);`
（`src/FpgaCar.v:306`）。

**注意 `u_ultra` 仍然例化、仍在测距**，`D=` 和 OLED 上的距离照常刷新，
只是结果不再送到 `car_fsm`。这样测循迹时超声依然可观测，接回来只需改一个常量。

### 3.25.2 为什么要关超声

`OBSTACLE_CM = 16'd25`（`src/FpgaCar.v:282`），只要正前方 25 cm 内有东西，
`car_fsm` 就进 `S_STOP` 把两轮占空比清零（`src/car_fsm.v:210-212`）。
桌面/室内测试时车头正前方通常就是墙或桌沿 —— 实测 `D=014cm` 稳定不变，
127 帧里 `O=1 M=04` 一帧没松过，车根本起不来。

`S_STOP` 的退出条件是 `if (!final_stop && !obstacle)`（`src/car_fsm.v:261`），
即障碍消失自动回 `S_RUN`，不需要重新压线；只有找线超时（`final_stop=1`）才是永久停。
所以以前把车往后拉也能恢复，只是每次靠近墙都会被再摁一次。

### 3.25.3 关掉 K230 的原因

`wire k230_off = USE_K230 & ~k_alive;`（`src/FpgaCar.v:577`），K230 没接线时
`k_alive` 恒 0 → `k230_off` 恒 1 → OLED 右上角一直画一个叉号。
看着像故障，实际只是没接。关掉后 OLED 干净，只剩循迹与距离。

### 3.25.4 测完怎么恢复

| 想恢复什么 | 改哪里 |
| --- | --- |
| 超声波避障 | `USE_ULTRA` → `1'b1` |
| K230 视觉 | `USE_K230` → `1'b1`（OLED 会重新画掉线叉号，接线后才该开） |
| 红外避障 | `USE_IR` → `1'b1`（须先接好 E18 的上拉与分压） |

三处都是 `localparam`，改完要重新综合烧录，不能在线切换。

## 3.26 现场测试手册 + 找线超时回 IDLE（2026-11-18）

### 3.26.1 为什么要单独一份精简文档

`PROJECT_PLAN.md` 记的是「为什么这么设计、踩过哪些坑」，篇幅已经不适合边蹲车边翻。
上板时需要的是「按哪几个键、屏幕上看到什么算过、看到什么算什么故障」。
所以另起 `docs/上板使用说明.md`，只保留操作与判据，约 120 行，改代码后同步更新。
两边的分工：本文记设计与取舍，说明书记操作与判读。**同一事实只在一处展开**，另一处给链接。

### 3.26.2 `SEARCH_FAIL_TO_IDLE`：桌面反复测试的必要条件

改之前：`S_SEARCH` 超时（`SEARCH_MS = 1500`）→ `final_stop <= 1'b1` → `S_STOP`，
而 `S_STOP` 的出口条件是 `!final_stop && !obstacle`，`final_stop` 一旦置位就只能靠复位解除。
实测已经踩到：车跑离线后 `M=04` 卡死，必须拔电重来 —— 每次调试都要重启一次，桌面测试根本没法迭代。

改法是在 `car_fsm.v` 加一个参数，把「超时之后干什么」变成可选的：

```verilog
parameter integer SEARCH_FAIL_TO_IDLE = 1, // 找线超时后：1=回 IDLE 等重新压线，0=永久停车
```

`S_SEARCH` 超时分支改成按参数分流：`1` 回 `S_IDLE`（重新压线 2 s 即起跑），`0` 保持原永久停车。
顶层 `FpgaCar.v:359` 传 `1`，**正式比赛要改回 `0`** —— 规则上找线失败就是失败，不能无限重试。

测试台 `car_fsm_tb.v` 例化两个实例共用同一组激励，只差这一个参数：
`u_dut` 传 `0` 验永久停车（原用例 6），`u_dut2` 传 `1` 验回 IDLE 并能重新起跑（新用例 7）。
这样一个 tb 同时钉住两种行为，不会因为改了默认值就把比赛语义悄悄改掉。

### 3.26.3 屏上五块调试区的最终布局

> **2026-11-22 已改为三行纯文字，本节表格是旧布局，仅作历史记录。** 现行布局见 §5「屏上调试区」一节
> （`ST:/DIST:/LN:` 三行，page 1 / 6 / 7，共 384 字节）。

当时 `oled_driver.v` 的 `S_DBG` 每次无条件重写 432 字节（`DK_SEG2=128 / DK_SEG3=224 / DK_SEG4=272 / DK_SEG5=368 / DK_END=432`），
不依赖旧显存，所以改布局不会留残影：

| 显存段 | 屏上位置 | 内容 |
| --- | --- | --- |
| `dk 0..127` | page 1 | 八路循迹竖条，每路 16 列；第 1 根 = X1 = 车体最左 |
| `dk 128..223` | page 6/7 col0..47 | 三位距离数字，无回波显示 `---`，>999 饱和 999 |
| `dk 224..271` | page 7 col48..63 + page 6/7 col64..79 | `cm` 小字 + 一位车状态号 |
| `dk 272..367` | page 6/7 col80..127 | 四标志格：障碍 / 丢线 / 左转 / 右转 |
| `dk 368..431` | page 0 col8..71 | 八位二进制串，自左向右 = `line[7]`..`line[0]` |

page 0 的 col0..7（存活标记）与 col120..127（K230 叉号）由 `S_MARK` 写，与二进制串不重叠。
二进制串的字符序与串口 `T=` 一致，可以逐字对照抄 —— 这是现场不接串口时的第一手依据。

### 3.26.4 本轮烧录与实测

位流 `outflow/FpgaCar.bit` = 1864347 B（关 K230 后比上一版 1997538 B 小）。
JTAG 烧录后串口确认：

```
D=015cm T=00011000 P=+00 O=0 M=00
L=00000000 R=00000000 VL=0000 VR=0000 X=11100111 C=+000 DL=000 DR=000
```

- 第二行 69 字符（不含 CR LF）→ 新位流确实在跑。
- `O=0` → `USE_ULTRA=0` 生效，超声不再摁停车。
- `X=11100111` 与 `T=00011000` 严格逐位互补 → `ACTIVE_HIGH=0` 极性链路正常。
- `M=00` + `DL=DR=000` → 起跑安全锁生效（未连续压线 2 s）。

全量回归 20 个 tb 全绿（54 s）。

## 3.27 换相死区计数器位宽 bug：`M=01` 却不走（2026-11-18）

### 3.27.1 现象

烧完带 `X=/C=/DL=/DR=` 的新位流、把车压到线上跑起来之后，串口第二行持续是：

```
D=016cm T=00110000 P=+02 O=0 M=01
L=00000000 R=00000000 VL=0000 VR=0000 X=11001111 C=+000 DL=000 DR=000
```

`M=01` 是 RUN，说明状态机在跑、`ctrl_en=1`、电机使能已经放出；但 `DL=`/`DR=` 恒 `000`、`C=` 恒 `+000`，车轮不动。6 s 内 95 帧无一例外（`.scratch/mduty.ps1` 统计），所以不是起跑瞬间的过渡帧。

### 3.27.2 根因

`src/car_fsm.v` 的方向死区靠一个计数器计时：

```verilog
localparam integer MS_DIV   = CLK_FREQ / 1000;      // 24 MHz → 24000
localparam integer DEAD_CYC = MS_DIV * DIR_DEAD_MS; // 24000 * 10 = 240000
reg [15:0] dead_cnt;                                // ← 上限只有 65535
```

`dead_cnt` 是 16 位，永远追不上 `DEAD_CYC - 1 = 239999`，于是 `dead` 一旦置位就再也不清。而 `dead` 会把两条通路一起掐死：

- `src/car_fsm.v:99`：`assign en = en_run & ~dead;` → `en` 恒 0，`motor_stby` 落低，TB6612 整个关断；
- `src/car_fsm.v:140-141`：换相进死区的同一拍把 `duty_l/duty_r` 清零，而 `:207-210`、`:247-250` 的 `if (!dead)` 又不让 PID 值重新装进来 → duty 停在 0。

`en=0` 还会让 `track_pid` 走 `!en` 分支（`src/track_pid.v:96-103`）把 `corr` 清 0，所以 `C=+000` 是同一个根因的连带现象，不是独立故障。

**为什么一定要换过相才会出事**：`dead` 只在 `dir_l_des/dir_r_des` 与当前 `dir_l/dir_r` 不一致时置位（`:137`）。正常循迹时两轮都朝前（`1,1`），永远进不了死区；一旦丢线进 `S_LOST`→`S_SEARCH`，`:236-237` 把一侧车轮反转（`dir 1,1` → `1,0`），死区立刻触发。于是「先在线上跑几秒 → 丢一次线 → 之后就再也不动」。

### 3.27.3 为什么测试台没抓到

`sim/car_fsm_tb.v` 原来只例化了一个实例，用的是 `.DIR_DEAD_MS(1)` → `DEAD_CYC = 24000`，**刚好放得进 16 位**，计数器能数到头，死区行为完全正常。参数取值恰好落在 bug 边界之外，是这类位宽 bug 最典型的漏网方式。

### 3.27.4 修法与回归

- `src/car_fsm.v`：`reg [15:0] dead_cnt;` → **`reg [31:0] dead_cnt;`**，四处赋值同步改成 `32'd0` / `+32'd1`，并在声明处写明「宽度不够的后果不是死区变短，而是 dead 永不清除」。
- `sim/car_fsm_tb.v` 新增第三个实例 `u_dut3`，用 `.DIR_DEAD_MS(3)`（`DEAD_CYC = 72000 > 65535`，越过 16 位上限），并加用例 8：推入 SEARCH 触发换相，等 4 ms 后断言 `en3 === 1'b1` 且 `duty_l3/duty_r3 == 500`。
- 该实例必须设 `.SEARCH_FAIL_TO_IDLE(1)`，否则它在用例 6 里就已永久停车，用例 8 根本进不了 SEARCH（第一版写错，实测报 `FAIL: dead test: in SEARCH | st=4`）。
- **反向验证**：把 `dead_cnt` 临时改回 `[15:0]` 后跑 `car_fsm_tb` → `FAIL: dead zone clears (en)`，改回 32 位→ 25 项全过。这条用例确实能抓到 bug，不是假绿灯。
- `bash tools/run_regression.sh` 全量 **20 个 tb 全绿（55 s）**。

### 3.27.5 本版位流

map 699 s / pnr / pgm 全 PASS，`outflow/FpgaCar.bit` = **1840716 B**（比上一版 1858368 B 小）。JTAG 烧录后串口第二行仍是 69 字符，判据见 `docs/上板使用说明.md` 第 4 节。

---

## 3.28 宽黑兜底 + 避障三段（2026-11-18，仅仿真，未综合）

> 本轮按 m04952「今天到此就不烧录代码了」只改 RTL 与测试台，**没有综合、没有烧录**。
> 下面所有参数都还没在实车上跑过。

### 3.28.1 宽黑兜底：修「影子被当成完美居中」

现象推演：影子或整片深色遮住整排探头 → 八路齐判压线 → `mag_left = mag_right = 16`、`wsum = 0` → `pos = 0`，同时 `cnt = 8`、`on_line = 1`、`lost = 0`。`car_fsm` 看到的是「线在正中」，于是全速直冲 —— 比丢线更危险（丢线至少会减速找线），而且一片持续 2 s 的影子就能解开 `START_REQUIRE_LINE` 安全锁。

判据依据：赛道线宽 16 mm，探头间距约 11 mm，物理上最多压住 3 路。`cnt >= 5` 在真实赛道上不可能出现。

实现（`src/track_line.v`）：

| 项 | 值 | 说明 |
|---|---|---|
| `WIDE_CNT_TH` | `5'd5` | 压线数 ≥ 此值判宽黑；写 0 = 关闭（内部取 9，条件永不成立） |
| `WIDE_MS` | `200` | 宽黑持续多久降级成丢线 |
| 新端口 `wide` | 1 位 | 本拍是否判宽黑，直通串口 `W=` |

行为：

- 宽黑但未超时：`pos <= pos`（保持上一拍），`on_line`/`lost` 不变 → 车按上一个可信位置继续走，不会突然打正。
- 宽黑超过 `WIDE_MS`：`wide_lost` 置位 → `lost = 1`、`on_line = 0`、`pos = 0` → 正常进入丢线流程（`S_LOST` → `S_SEARCH`）。
- 恢复正常压线数：`wide_tmr` 清零，立即恢复。

**踩坑记录（重要）**：`wide_tmr` 第一版直接每个 `clk` 加一，`WIDE_MS=200` 实际只有 8.3 us，等于兜底完全失效。第二版加了 `tick` 门控，但当时的 tick 周期是 1 us 而不是 1 ms（`SAMPLE_KHZ` 名不副实，详见 §3.29），所以仍然差了三个数量级。最终用 `localparam integer WIDE_TICKS = WIDE_MS * SAMPLE_KHZ;` 换算成 tick 数，并把计数器加宽到 24 位。

> 注：`WIDE_TICKS = WIDE_MS * SAMPLE_KHZ` 这个写法在 §3.29 修正 `SAMPLE_KHZ` 之后依然成立 —— tick 周期与乘数用的是同一个参数，误差天然抵消。宽黑计时从一开始就是对的，错的是消抖。

### 3.28.2 避障三段：后退 → 原地转身 → 低速试探

原来 `S_RUN` 遇 `obstacle` 直接进 `S_STOP`（占空比 0），障碍消失才回 `S_RUN`。车贴着墙角或桌腿时会出现「停了→障碍还在→永远停」，能力等于零。

`state` 是 3 位，原用到 0..4，5/6/7 空着，正好扩三段（串口 `M=` 两位十进制、OLED 状态号都无需扩位）：

| 状态 | 值 | 动作 | 参数 |
|---|---|---|---|
| `S_AVOID_BACK` | 5 | 两轮反转后退 | `AVOID_BACK_MS=400`、`AVOID_BACK_DUTY=500` |
| `S_AVOID_TURN` | 6 | 原地转（一正一反） | 默认 `AVOID_TURN_MS=600`、`AVOID_TURN_DUTY=600`；顶层覆盖为 1000 / 620 |
| `S_AVOID_PROBE` | 7 | 低速两轮正转 | `AVOID_PROBE_MS=400`、`AVOID_PROBE_DUTY=450` |

- 进 `S_AVOID_BACK` 时按 `avoid_left = !last_pos_neg` 定转向：线在右边就往左绕，避免绕到线的另一侧。
- 试探期间 `obstacle` 仍为 1 → `avoid_tries` 加一、`avoid_left` 取反、回 `S_AVOID_BACK` 再来一轮；用满 `AVOID_TRIES=3`（顶层传 2）进 `S_STOP`。
- 试探期间 `obstacle` 已清 0 且走满 `AVOID_PROBE_MS` → 回 `S_RUN`。
- `S_STOP` 的自动恢复路径（`!final_stop && !obstacle` → `S_RUN`）保留，`AVOID_EN=0` 时退回老行为。
- `en_run` 扩为也包含三段，所以避障期间电机是通电的；`en = en_run & ~dead` 中的换相死区照常生效。

`AVOID_EN=1` 时 `USE_ULTRA` 应同时为 1，否则 `obstacle` 恒 0、避障永不触发。本轮顶层取 `USE_ULTRA=1'b1`、`USE_IR=1'b0`、`USE_K230=1'b0`。

### 3.28.2b 侧绕改为弧线差速（2026-11-22，AVOID_ROUTE_EN=1）

上面三段（后退 → 原地转身 → 试探）在细则上是有问题的：4.3.2 原文禁止「以大转弯的形式绕开障碍物」，而**原地转身恰好是车体横向摆幅最大的动作** —— 驱动轮在距车头 3 cm 处，绕驱动轴原地转时车尾扫出约 √((20−3)² + 6.5²) ≈ 17 cm 的半径，10 cm 立方体旁边根本留不出这个空间。

更关键的是：原来的 `AVOID_ROUTE_EN=1` **并没有跳过倒车和原地转**。四处避障入口当时都写成 `state <= (AVOID_EN != 0) ? S_AVOID_BACK : S_STOP;`，侧绕只是把后面的「试探前进」换成了五段，前面照样先退 400 ms、再原地转 1000 ms。所谓「侧绕」实际是「倒车 + 掉头 + 直冲」的矩形路线。

改法：`AVOID_ROUTE_EN=1` 时改由 `avoid_entry_state` 直接进 `S_AVOID_PROBE`，并把这五段全部改成**两轮都正转、只靠左右差速画弧**：

| 段 | 动作 | 参数（顶层取值） |
|---|---|---|
| `BY_OUT` | 朝绕行侧画弧，把车推到障碍侧边 | `AVOID_OUT_MS=524`、`AVOID_OUT_DUTY=860` / `AVOID_OUT_IN_DUTY=380` |
| `BY_ALIGN` | 反向弧摆正，车沿障碍侧边平行 | `AVOID_ALIGN_MS=524`、`AVOID_ALIGN_DUTY=840` / `AVOID_ALIGN_IN_DUTY=400` |
| `BY_PASS` | 两轮同速直线超越 | `AVOID_PASS_MS=900`、`AVOID_PASS_DUTY=620` |
| `BY_TURN_IN` | 反向弧斜切回原线，扫到线提前结束 | `AVOID_TURN_IN_DUTY=860` / `AVOID_TURN_IN_IN_DUTY=420`，上限 `AVOID_TURN_IN_MS` |
| `BY_REJOIN` | 小差速把残余偏角找回 | `AVOID_REJOIN_DUTY=640` / `AVOID_REJOIN_IN_DUTY=430`，超时 `AVOID_REJOIN_MS` |

约定：`*_DUTY` 是外侧（快）轮，`*_IN_DUTY` 是内侧（慢）轮；`avoid_left=1` 表示从线的左侧绕，OUT 段往左打、其余段往右反打。

**绕行期间不再用超声判阻塞**（`bypass_blocked = 1'b0`）。方块必然处在 25 cm 阈值以内 —— 否则根本不会触发绕行 —— 若继续用 `obstacle` 冻结动作，车会被自己的绕行对象钉在原地。旧逻辑把 `BY_OUT` 也算「正对障碍前进」，一进绕行就停住。安全性改由 `BY_TURN_IN` 扫线上限与 `BY_REJOIN` 超时进 `S_STOP` 兜底。

几何核算（`bench/avoid_sim6.py`，车宽 18.5、方块 10、驱动轮距 16 cm，按车身矩形轮廓逐 0.5 ms 采样与方块求最近距离）：

| 触发距离 | 单弧角度 | 横移 | 最小间隙 |
|---|---|---|---|
| 25 cm | 55° | 17.6 cm | 1.96 cm（紧） |
| 25 cm | 60° | 20.7 cm | **4.47 cm** |
| 25 cm | 65° | 23.8 cm | 6.46 cm |

车心需偏离线中心 ≥ (18.5+10)/2 = 14.25 cm 才能擦过，所以 60° 是留了约 6 cm 横移余量的取值。**因此 `OBSTACLE_CM` 维持 25 不变**（早先担心 25 cm 来不及，仿真证明够用）。

### 3.28.3 串口与测试台

- `uart_report.v` 第二行 `MSG2_LEN` 71 → **75**，末尾新增 ` W=`+1 位（`msg2[69]`=空格、`[70]`=`W`、`[71]`=`=`、`[72]`=值、`[73]`=CR、`[74]`=LF）。新端口 `input wire wide`，与其它字段一起在 `R_LOAD` 单拍锁存。
- `sim/uart_report_tb.v`：`MSG2_LEN=75`，5 条期望串尾部补 ` W=0`（用例 4 补 ` W=1` 覆盖置位分支）。因为 `check_line` 只比对到 `MSG2_LEN`，不改长度就会静默漏掉新增字节。
- `sim/track_line_tb.v`：新增 `u_dut2`（`WIDE_MS=1000`，永不超时）验「`wide=1` 且 `pos` 冻结在 +7」；`u_dut3`（`WIDE_MS=3`）验「宽黑超时降级成丢线」。看门狗 80 ms → 150 ms。
- `sim/car_fsm_tb.v`：原三个实例显式补 `.AVOID_EN(0)`（否则默认 1 会让用例 5「障碍→STOP」走进 BACK 而挂掉）；新增 `u_dut4`（`AVOID_EN=1`、各段 8 ms、`AVOID_TRIES=2`、`DIR_DEAD_MS=3`）配独立激励，覆盖用例 9~11。
- 测试台写法教训：进新一段时先改 `dir_*_des`，换相死区会把 `dir/duty` 压住 `DIR_DEAD_MS`；且 `S_AVOID_PROBE` 在障碍仍在时只停留约 1 ms。**定长延时不可靠**，必须用 `wait_state4` / `wait_avoid` 轮询「状态 + 方向 + 双轮占空比」三者同时到位。

### 3.28.4 回归

`bash tools/run_regression.sh` 全量 **20 个 tb 全绿（74 s）**；单项 `track_line_tb` PASS=8、`car_fsm_tb` PASS=44 ALLPASS=1、`uart_report_tb` ALLPASS=1。

### 3.28.5 弧线侧绕的上板编译结果（2026-11-22）

`AVOID_ROUTE_EN=1` 的弧线五段落地后，第一次把 **全量回归 + 综合 + 布局布线 + 烧录生成** 跑通：

| 环节 | 结果 | 关键数据 |
|---|---|---|
| 仿真回归 | **24 个 tb 全部无 FAIL**（约 335 条 PASS） | `car_fsm_tb` 85 条 PASS、`bypass_rejoin_tb` 21 条 PASS |
| `--flow map` | `Stage completed: map`，595 s，**零 ERROR** | LUT 20994（15%）、FF 6184（20%）、RAM 15、DSP 2、ADD 687、SRL 1 |
| `--flow pnr` | `Stage completed: pnr`，45 s，**零 ERROR** | Setup slack **+30.348 ns**、Hold slack **+0.091 ns**，无违例 |
| `--flow pgm` | `pgm : PASS` | 产出 `outflow\FpgaCar.bit`（2.12 MB）与 `outflow\FpgaCar.hex`（2.12 MB） |

综合只报了 5 条 `Input/inout port ... is unconnected` 警告，全部是	extbf{设计上就不接}的端口：`ir_l`/`ir_r`（`USE_IR=0`，红外冗余备用）、`i2c_sda_IN`、`cmos_sdat_IN`、`uart_rx`。这类警告不影响功能，但不能当作"没看见"——它们正好印证 §3.20 的红外通道与 §3.19 的相机通道都处于停用状态。

> **烧录已完成（2026-11-22）**：`tools\flash.bat` 三步全部走通——JTAG→SPI bridge 载入 `PROGRAMMING DONE`、
> 写 flash（Winbond W25Q64 8 MiB，JEDEC `0xEF6017`）后回读比对输出 **`Flash verify successful`**（erase 3 s / write 4 s / read 13 s，692 KiB 区），
> 最后回装应用位流 `PROGRAMMING DONE`。设备 ID 读回 `0x10660A79`，与 `_jtag.jcf` 的 `id_code` 一致。
>
> **踩坑：判断下载器在不在，不能用 `FriendlyName` 匹配 'FTDI'。** 这块 FT232H 由 **libusbK** 驱动，
> 设备名是 **`ELITES-232DL`**，InstanceId 为 `USB\VID_0403&PID_6014\7&212A54EF&1&2`。
> 按名字搜 FTDI 会得到 0 个结果，从而误判成"下载器没插"。正确判据是查 `InstanceId -like '*VID_0403*'` 且 `Status = OK`。
>
> **另一个坑：`cmd //c tools\flash.bat` 在 MSYS 里不会真正执行**（只弹出一个交互式 cmd 就返回）。
> 可靠写法是 `cd tools && cmd.exe /c flash.bat`；且**不要用 `| head -N` 截断输出**，那会在第 2 步写 flash 途中杀掉进程。

> **别把历史 ERROR 当成本次失败**：`outflow\FpgaCar.err.log` 是**追加**写入的，里面留着 11 月 10 日的 `instantiating unknown module 'track_line'` 等旧记录。判断本次成败只看 `outflow\FpgaCar.log` 末尾的 `Stage completed: <flow>`。

> **综合卡不卡死怎么判**：日志重定向到文件后是块缓冲的，`FpgaCar.log` 可能十几分钟停在同一个行数。用 `Get-Process efx_map` 的 `CPU` 列采样两次即可——实测 25 s 内从 549 s 涨到 594 s，是多线程全速算，不是死锁。

---

## 3.29 `SAMPLE_KHZ` 单位错：消抖一直只滤 4 us（2026-11-18）

### 3.29.1 现象与发现过程

读 `docs/` 时发现文档写「消抖采样节拍 1 ms、连续 4 次」：`src/track_line.v:64` 是 `localparam integer TICK_RAW = CLK_FREQ / (SAMPLE_KHZ * 1000);`，而 `:39` 的默认值是 `SAMPLE_KHZ = 1_000`。按名字读是 1000 kHz = 1 MHz，代进去就是 24 个时钟 = 1 us。

写临时探针台实测（`.scratch/probe_glitch.v` / `.scratch/probe_wide.v`，未纳入回归）：

| 量 | 修前实测 | 设计意图 |
|---|---|---|
| 消抖延迟（4 次采样） | 4.854 us | 4 ms |
| 0.8 ms 毛刺是否被滤掉 | 未滤掉（line 翻转 1 次） | 应被滤掉 |
| `WIDE_MS=200` 实际时长 | 200.012 ms | 200 ms（对） |

结论：宽黑计时是对的，**消抖形同虚设**。原因是 tick 周期与 `WIDE_TICKS` 的乘数共用同一个 `SAMPLE_KHZ`，两处误差互相抵消；消抖没有这种抵消，所以差了 1000 倍。

### 3.29.2 为什么测试台没抓到（值得记的教训）

`sim/track_line_tb.v` 用例 6「单拍毛刺」原本只在毛刺结束后检查 `line` 是否仍是原值。毛刺期间 line 翻转了一次又翻回来，结束时值相同 → 判 PASS。**这是典型的「只查终态、不查过程」假绿灯。**

修法：加一个 `line_changes` 计数器，用 `always @(posedge clk)` 记录 `line` 的每一次变化，用例 6 除终态外还断言 `line_changes == 0`。

反向验证：把测试台实例参数临时改回 `SAMPLE_KHZ(1_000)` → `FAIL: glitch flipped line 2 times (should be 0)`；改回 `1` → PASS。说明这条断言真的有效。

### 3.29.3 修法

- `src/track_line.v:39` 参数默认值 `1_000` → `1`，注释改为「消抖采样率，单位 kHz（1 = 1 ms 一次）」。
- `src/FpgaCar.v:265` 例化处 `.SAMPLE_KHZ (1_000)` → `.SAMPLE_KHZ (1)`。
- `sim/track_line_tb.v` 三个实例同步改 `1`；用例 8 的等待由 7 ms 加长到 10 ms（4 ms 消抖 + 3 ms 宽黑超时正好卡边界）。
- tick 与 `WIDE_TICKS` 的计算式不变 —— 改完参数后 `WIDE_MS=200` 仍是 200 ms。

### 3.29.4 回归

`bash tools/run_regression.sh` **20 个 tb 全绿（74 s）**。修后探针：消抖延迟 **5.000 ms**（4 ms 消抖 + 1 ms 采样量化）、0.8 ms 毛刺 **FILTERED**、`WIDE_MS` 实测 205.007 ms。

> 通用教训：本工程凡以 `MS` / `US` / `KHZ` 结尾的参数，写进 RTL 前必须把单位代数算一遍。§3.28 的 `wide_tmr` 与本节是同一类错误的两次发作。

### 3.29.5 文档同步

- `docs/模块接线说明.md` §2.2 参数表：`SAMPLE_KHZ` 由 `1000` 改 `1` 并标注单位；补 `WIDE_CNT_TH` / `WIDE_MS` 行；`DEBOUNCE_N` 补「1 ms × 4 = 4 ms」。
- 同文件三处过期行号订正：`FpgaCar.v:357-361` → `394-397`、`:142` → `144`、`:630` → `658`、`track_line.v:93` → `108`。
- `docs/上板使用说明.md`：`START_REQUIRE_LINE` 行号 `car_fsm.v:28` → `:33`、PID 例化 `FpgaCar.v:313` → `:320`；避障轮数由「2 轮」订正为 **3 轮**（`AVOID_TRIES=3`，`FpgaCar.v:374` 传入）。
---

## 3.30 赛题硬指标与当前实现的差距（2026-11-18）

依据 `docs/第十四届“星火杯”赛题二细则.pdf`（5 页，PyMuPDF 抽取全文）与 `docs/scene/星火杯/` 17 张现场实拍。

### 3.30.1 赛题硬指标（原文摘录）

| 项 | 要求 | 原文位置 |
|---|---|---|
| 场地 | 约 4.5 m × 3.0 m，喷绘布闭合赛道，四角半径 30 cm 圆角 | 3.3.1 |
| 线宽 | 黑色循迹线**宽约 1～2 cm** | 3.3.1 附注 |
| 分岔区 | 左转/右转两种交通牌置于分岔区中央，每轮裁判随机一块，识别后驶入对应线路 | 3.3.4 |
| 障碍 | 黑线直线路段放**边长约 10 cm 立方体**，中心与线中心重合；任选一侧绕行且**须自主回到原线路**；避让区以障碍为中心左右各 50 cm、前后各 50 cm | 3.3.5 / 4.3.2 |
| 颜色块 | 距循迹线约 **25 cm** 处 4 个 **10 cm** 正方体，红绿蓝黄任选；须在车载显示装置按顺序显示（如「红-绿-蓝-黄」） | 3.3.6 |
| 车库 | 净尺寸 **40 cm × 40 cm**，入口一侧留开口；**车尾先入**并**停稳 ≥ 5 秒** | 3.3.7 / 五 |
| 尺寸限制 | 车身俯视投影 ≤ 40 cm × 35 cm，最高 ≤ 40 cm | 3.2.1 |
| 传感器 | 严禁非光电方式导航/识别，**超声波模块除外** | 3.2.2 |

评分（满分 100）：循迹 20（通过前两个弯道才得分）、避障 20（绕开且重回线 20，仅绕开 10，碰障碍 −10）、交通牌 25（驶入对应支路）、颜色顺序 20（每对 1 个 5 分）、倒车入库 15（入库并停 5 s 得 15，投影未全进 10，未进 0）。另有「小车偏离赛道每次扣 5 分，每组共两次调整机会」。

> 注意 3.2.2：超声波被明确豁免，所以 `USE_ULTRA` 继续用不违规；但**颜色识别必须靠光电（摄像头/颜色传感器）**，不能用超声替代。

### 3.30.2 现场实测几何（用 10 cm 色块标定）

俯拍图 `docs/scene/星火杯/...XwCejlhaFlhUnzR...jpeg` 里，四色方块在各自景深处的像素宽度：红 121、蓝 103、黄 89、绿 81 px。以「边长 10 cm」做标定 → 8.1~12.1 px/cm；同一深度上黑胶带厚度实测 **14~15 px** → **线宽约 1.3 cm**。

与赛题「1～2 cm」一致。但**比仓库此前记录的 16 mm 更细**：`track_line.v` 的 `WIDE_CNT_TH = 5` 是按「16 mm 线最多压 3 路（探头间距 11 mm）」推的，1.3 cm 只会压得更少（1~2 路），这个阈值余量反而更大。

矩形闭环俯图（`...XRejlhcURqWER...jpeg`）测量：线宽 16~19 px、车道净宽约 330 px → 按线宽 13 mm 折算，**单条直道净宽约 25~27 cm，赛道整体外框约 4.2~4.5 m**，与细则的 4.5 m × 3.0 m 吻合。

### 3.30.3 当前实现的差距（按分数高低排）

**① 倒车入库：完全没有（15 分）**
`car_fsm.v` 的 8 个状态（IDLE/RUN/LOST/SEARCH/STOP/AVOID_BACK/AVOID_TURN/AVOID_PROBE）里没有任何「找车库 → 对准 → 倒车 → 停稳计时」的路径。现有唯一会反转车轮的是 `S_SEARCH` 的原地打转与 `S_AVOID_TURN`。要在 40 cm × 40 cm 的车库里「车尾先入」，必须新增至少：车库检测、倒车直线保持、入库完成判定、停稳 5 s 计时。这是非视觉侧最大的一块缺口。

**② 交通牌分岔：现在是盲转 0.7 s，不是「驶入支路」（25 分）**
`car_fsm.v:172-182` 把 `dir_evt`（来自 K230）锁存成 `turn_req`/`turn_left`；`S_RUN` 里 `turning` 分支（`:209-231`）用 `turn_cnt <= TURN_MS`（`FpgaCar.v` 传 700 ms）+ `TURN_DUTY` 原地转固定时长，然后靠 `S_LOST` 去重新找线。
问题：分岔口的支路是**两条都还在的线**，原地转 0.7 s 之后车可能正对着岔口的另一条线，`S_LOST` 根本不会触发，车会直接沿着错的那条走。比赛要求「按指示驶入对应支路」，只靠定时转不稳。**更可靠的做法是转向后主动向目标侧偏移着找线**（把 `pos` 目标从 0 改成 +3/−3 一段时间），而不是等丢线。

**③ 避障：规则要求「不能大转弯」，现在正好是大转弯（20 分）**
`S_AVOID_BACK`（后退）→ `S_AVOID_TURN`（一侧轮反转原地转）→ `S_AVOID_PROBE`（试探前进）→ 回 `S_RUN` 靠循迹自己拉回线。细则 4.3.2 原文「不能以『大转弯』的形式绕开障碍物」，且避让区只有 ±50 cm。原地转的轨迹半径接近零但**车头摆幅很大**，容易被判成大转弯；同时三段各 400~600 ms、`SEARCH_DUTY=500`，按 0.4 m/s 估算合计位移可能超过 50 cm 边界。
建议：改成「减速 → 向一侧偏转绕行 → 直线通过 → 反向偏转回线」的平滑 S 形，全程保持前进、不反转车轮；只在被卡住时才允许短距离倒退。

**④ 循迹只到 20 分门槛，30 cm 圆角弯是主要风险**
评分要求「成功通过前两个弯道」才拿 20 分。场地四角是 **R=30 cm** 圆角，按车宽约 15~20 cm 估算，内侧轮速要明显低于外侧。当前 `BASE_DUTY=600`、`DUTY_MAX=1200`、`P_GAIN=72`，`pos` 满量程 ±7 时 `corr` 最大 504（≈42% 占空比），理论够用；但**从未上过实车**，且实测数据显示 `pos` 常常只到 ±2~±3，对应修正只有 144~216。过 R=30 cm 弯时很可能偏大。

**⑤ 颜色顺序显示：OLED 四槽位已具备**
`oled_driver.v` 已有 4 个 32×32 汉字槽（page 2~5，色码 1=红 2=绿 3=蓝 4=黄，0=空槽），与赛题「按顺序显示 4 个颜色」的要求恰好对应。这部分不用改，只等 K230 分支把 `seq0..seq3` 填进来。

**⑥ 分岔口的「宽黑」误判风险**
分岔区两条候选线路从这里分开，车正对岔口时可能同时压到 4~6 路 → 触发 `WIDE_CNT_TH=5` 兜底，`pos` 被冻结保持不变。好在兜底设计为「保持上一拍 pos」而不是清零，不会导致失稳；但要意识到**恰好在分岔口那一刻方向信息是冻结的**，转向必须靠 `dir_evt` 而不是靠 `pos`。

### 3.30.4 与视觉分支的分工（重要）

用户 2026-11-18 明确：**K230 相关代码由他人在另一个 git 分支完成，暂不合并；本分支只做非视觉部分。** 因此——
- 不要动 `cam_probe.v` / `dvp_capture.v` / `color_detect.v` / `color_seq.v` / `k230_link.v` 的行为与端口；
- `USE_K230` 保持 `1'b0`，`k230_off` 恒 1；
- 双边接口只依赖既有契约：`seq_valid`/`seq0..seq3`（颜色，送 OLED）与 `dir_evt`（方向，`3'd1` 左 / `3'd2` 右 / `3'd3` 直行，送 `car_fsm`）。**新增逻辑只能用这两个既有信号，不得改契约。**

### 3.30.5 建议的优先级

1. **实车跑通循迹直线 + 两个弯道**（拿到 20 分的地基，也是后面一切的前提）。
2. **避障改成不反转车轮的平滑绕行**（20 分，改动集中在 `S_AVOID_*`）。
3. **分岔转向改成「目标偏移 + 主动拉线」**（25 分，改动在 `turning` 分支与 `S_LOST`）。
4. **倒车入库**（15 分，需新增状态与车库检测，工作量最大）。
5. 颜色顺序（20 分）等视觉分支合入即可，本分支只管 `seq0..seq3` → OLED 这条链路。
## 3.31 拐角兜底：没有转向牌时一律左转（2026-11-18）

### 3.31.1 需求与为什么不是「无条件左转」

用户 2026-11-18 明确两点（原话）：「给识别左右转向牌的时候加一个保留代码容错：在 K230 没有识别到转向时或没有装 K230 时（现在），一律向左转。…转向这一部分是一个类似菱形的形状，就是需要左转两次。」

直接做成「丢线就左转」是错的：正常赛道跑直线偏出去一条边，车也会进入找线，此时朝固定方向转有一半概率朝反方向找 —— 越找越远，直接跑飞。所以必须先把「拐角」和「普通跑偏」区分开。

### 3.31.2 判据：宽黑是拐角的物理特征

直角弯与菱形的两条边在八路阵列上的表现是同一套：**先宽黑（同时压 4~8 路），随后线整体消失**。普通跑偏不会先宽黑，它只会让压线位一路移到边缘然后掉出去。

因此用 `track_line` 已有的 `wide` 输出（§3.28 为影子兜底加的）做拐角记忆：`wide=1` 时把 `corner_cnt` 置满 `CORNER_WIDE_MS`，之后每 ms 递减。找线时如果 `corner_cnt != 0`，说明刚过拐角。

### 3.31.3 三级优先级（`src/car_fsm.v` S_LOST 超时分支）

1. **转向牌事件**（`dir_evt` 1/2，K230 送来）：完全按牌走，兜底不介入。
2. **刚过拐角且没有牌**：按 `DEFAULT_TURN_LEFT`（默认 1）一律左转 —— 这就是用户要的容错，菱形两段各触发一次。
3. **其余（普通跑偏丢线）**：线在哪边往哪边转，保持原行为。

### 3.31.4 参数与端口

| 位置 | 新增 | 说明 |
|---|---|---|
| `src/car_fsm.v:53` | `DEFAULT_TURN_LEFT = 1` | 1 = 兜底左转；0 = 关闭兜底（退回原逻辑） |
| `src/car_fsm.v:55` | `CORNER_WIDE_MS = 500` | 宽黑后多久内丢线算拐角；0 = 关闭拐角判断 |
| `src/car_fsm.v` 端口 | `input wide` | 接 `track_line.wide` |
| `src/car_fsm.v` 端口 | `output reg [1:0] turn_dir` | 0 无 / 1 左 / 2 右，供串口判读 |
| `src/car_fsm.v` 内部 | `reg [15:0] corner_cnt` | 拐角记忆倒计时，ms_tick 步进 |
| `src/uart_report.v` | `input [1:0] turn_dir`、`reg [1:0] td` | 第二行新增 `S=` |

### 3.31.5 串口新增 S= 字段

`MSG2_LEN` 75 → **79**，第二行 75 → **77 字符**（正文）。尾部布局：

```
msg2[72] = W 的值
msg2[73] = ' '
msg2[74] = 'S'
msg2[75] = '='
msg2[76] = '0'/'1'/'2'
msg2[77] = CR
msg2[78] = LF
```

为什么必须加：转向是这台车最容易「看起来在跑、实际方向错了」的环节。没有 `S=` 时，现场只能靠车实际往哪开来反推，而找线只有 1.5 s，肉眼很难分辨是"按兜底左转"还是"按原逻辑右转"。

### 3.31.6 测试台

`sim/car_fsm_tb.v` 的 4 个旧实例全部补 `.wide()` 与 `.turn_dir()` 连接（旧实例拉 0，保持原语义）。新增第五个实例 `u_dut5`（`DEFAULT_TURN_LEFT=1`、`CORNER_WIDE_MS=500`、`DIR_DEAD_MS=3`）与两条用例：

- 用例 12：`pos=+3`（线在右，原逻辑应右转）→ 拉一拍 `wide` → 丢线 → 断言 `dir=(0,1)` 且 `S=1`。**故意用与兜底相反的 pos**，只有兜底生效才能通过。
- 用例 13：`pos=+3` → 不拉 `wide` → 丢线 → 断言 `dir=(1,0)` 且 `S=2`。这条是兜底的边界：证明正常跑偏没被拐角兜底污染。

`sim/uart_report_tb.v`：`MSG2_LEN=79`、新增 `turn_dir` 输入、5 条期望串尾部补 ` S=n`（用例 1~3 为 0，用例 4 为 2 右转，用例 5 为 1 左转）。

### 3.31.7 回归

`bash tools/run_regression.sh car_fsm_tb uart_report_tb` → car_fsm_tb PASS=50（原 44，+6）、uart_report_tb ALLPASS=1。
全量 `bash tools/run_regression.sh` → **20 个 tb 全绿，81 s**。

### 3.31.8 尚未验证的部分（下地前必须知道）

- 拐角兜底**从未上过实车**。判据全部基于「直角/菱形拐角会先宽黑」这个推断，而现场线宽约 1.3 cm、探头间距约 11 mm，正常直道只压 2 路；拐角处能否稳定压到 `WIDE_CNT_TH=5` 路**没有实测数据**。若实际压在拐角只出现 3~4 路，`corner_cnt` 永远是 0，兜底不生效（表现为拐角处按原逻辑随机方向找线）。
- 现场验证方法：`S=` 是新增字段，拐角测试时盯它 —— **过拐角后进入 `M=03` 的瞬间 `S=` 应为 1**。若为 2，说明没触发兜底，需下调 `WIDE_CNT_TH`（`src/track_line.v:42`，当前 5）或加大 `CORNER_WIDE_MS`。
- 本轮按用户要求**未综合、未烧录**（用户 2026-11-18 明确「今天到此就不烧录代码了」）。

## 3.32 OLED 四标志格改显转向方向 + 回归脚本两处静默失败（2026-11-19）

### 3.32.1 需求

用户 2026-11-19 原话：「现在没有左红外和右红外，还有把 S 在 oled 上显示，修改代码，同时进行 bug 检测与修复」。

左/右 E18-D80NK 红外已从车上拆下（`USE_IR = 1'b0`，`src/FpgaCar.v:296`），原 OLED 上「障碍 / 左红外 / 右红外 / 丢线」四格里有两格永远是灭的，等于浪费一半屏幕；而转向方向（串口 `S=`）恰恰是现场最需要蹲在车边看的量 —— 找线只有 1.5 s，肉眼很难分辨车是"按兜底左转"还是"按原逻辑右转"。

### 3.32.2 为什么用两格而不是一位数字

`turn_dir` 有三态（0 无 / 1 左 / 2 右）。显示成数字需要再占一段字形 ROM 和一段显存，而两格指示（左转格 / 右转格）语义最直接、不需要读数字。改完仍是 4×12×2 = 96 字节，**`DK_SEG2..DK_SEG5` 与 `DK_END`（128 / 224 / 272 / 368 / 432）一个字节都没动**，段边界不变意味着 `build_exp_dbg` 的框架也不用改。

新顺序（`src/oled_driver.v:805` 起）：`fl=0` 障碍、`fl=1` 丢线、`fl=2` `turn_dir==1`、`fl=3` `turn_dir==2`。

### 3.32.3 顺手修的真 bug：turn_dir 置位后永不清零

`turn_dir` 在 §3.31 里只是"最近一次转向方向"，所有赋值点都只写不清。结果是一旦转过一次弯，OLED 那一格（以及串口 `S=`）就会一直亮着 —— 直道上也显示"正在左转"，四标志格反而失去意义。

修法：新增参数 `TURN_DIR_HOLD_MS = 1500`（`src/car_fsm.v:61`，顶层 `src/FpgaCar.v:376` 显式传 1500），配套 `reg [15:0] turn_dir_cnt`。每个置 `turn_dir` 的地方同时装计时；`ms_tick` 拍递减，**减到 0 的那一拍把 `turn_dir` 清掉**（`src/car_fsm.v:226-229`）。

为什么是 1500 ms：OLED 的 `DBG_SAMPLE_MS = 100`（`src/oled_driver.v:68`），太短的脉冲根本采不到；但一直保持又会让直道也显示转向。1500 ms 正好覆盖整个 `S_SEARCH`（`SEARCH_MS=1500`），转向动作结束、车重新上线后不久自动熄灭。

语义澄清：屏上左/右转格表示「**1.5 s 内**转过哪边」，**不是**"车身此刻正在转"。串口 `S=` 同理。

### 3.32.4 测试台

`sim/oled_driver_tb.v`：`dbg_irl/dbg_irr` 两个 reg → `reg [1:0] dbg_turn`；`build_exp_dbg` 的 case 改 `2 → (dbg_turn==2'd1)`、`default → (dbg_turn==2'd2)`；新增 `check_flags(e0,e1,e2,e3,tag)` 硬编码断言（不经 `build_exp_dbg`，避免"期望值与实现同错"），并新增第 5b 阶段左转帧（`dbg_turn=2'd1` → 断言 `(1,0,1,0)`）。

`sim/car_fsm_tb.v`：`u_dut5` 加 `.TURN_DIR_HOLD_MS(20)`，新增用例 14 —— 转弯后先断言 `td5==2'd2`（亮），等 30 ms 再断言 `td5==2'd0`（灭了）。只验"亮"不验"灭"的话，计时器写了但没接上就是假绿灯。

### 3.32.5 顺带修的两处回归脚本静默失败

`tools/run_regression.sh` 有两个会让「明明没跑成却报全部通过」的缺陷，正好在本次多 agent 并行时暴露：

1. **临时文件名固定**（`.scratch/_run_<tb>.out`）。两个进程同时跑同一个 tb 会互相覆盖日志。改为 `_run_<tb>_$$.*`（`RUN_ID=$$`）。
2. **`grep -c` 在文件缺失时不打印数字**，`$(...)` 得到空串，后续 `[ "" -eq 0 ]` 报 `integer expected` 并把 `status` 留在 `OK` —— 于是 PASS 栏是空白，汇总却说"全部通过"。现在每个计数都 `${var:-0}` 兜底。

实测复现：并行时 `track_line_tb` 与 `track_pid_tb` 都出现过 `PASS=` 空白 + "全部通过"。

### 3.32.6 回归

`bash tools/run_regression.sh` → **20 个 tb 全绿，89 s**（car_fsm_tb PASS 44→52、oled_driver_tb PASS 18→21）。

### 3.32.7 文档与遗留

- `docs/上板使用说明.md` 升 **v1.5**：第 3 节四格顺序、`O=` 说明（红外已拆）、`S=` 保持语义、版本记录。
- `PROJECT_PLAN.md` 本小节 + §3.26.3 与 §3.31 相关表格同步。
- 遗留：`ir_l_det` / `ir_r_det`（`src/FpgaCar.v:307-308`）现在**没有任何观测出口**（OLED 不再显示），只经 `ir_det` 参与 `obstacle`。RTL 保留是对的（以后可能重装红外），但要清楚：`USE_IR=0` 时排查红外接线只能靠重新编译加回显示或接示波器。

## 3.33 全仓 RTL 审查 + 三处状态机盲区（2026-11-19）

用户要求「同时进行 bug 检测与修复」，于是起了一个只读审查子代理（rtl-audit）通读 `src/*.v`，产出 12 条问题清单，逐条复核后修了 4 条。**审查报告本身有一条判断是错的**，记在 3.33.6。

### 3.33.1 修的第一条：丢线/找线期间完全看不见障碍

`obstacle` 原先只在两处被检查：`src/car_fsm.v` 的 `S_RUN`（含 turning 分支）与 `S_AVOID_PROBE`。这两个状态之外还有两段时间车在动：

- `S_LOST`：按上一刻的 `pid_l/pid_r` 继续保持 `LOST_HOLD_MS(300 ms)`。按 0.4 m/s 估算约 **10 cm**，在 25 cm 阈值下完全来得及撞上去。
- `S_SEARCH`：一侧轮反转原地转，最长 `SEARCH_MS(1500 ms)`。贴着障碍转很容易蹭上，而细则 4.3.2 明确「避让过程中车身不得触碰障碍物」。

修法：两处各补一个 `else if (obstacle)` 分支，走与 `S_RUN` 完全相同的避障入口（`avoid_tries <= 0; avoid_left <= !last_pos_neg; state <= (AVOID_EN != 0) ? S_AVOID_BACK : S_STOP;`）。

### 3.33.2 修的第二条：试探段被障碍判定抢先打死

`S_AVOID_PROBE` 里 `if (obstacle)` 的优先级高于 `else if (ms_cnt >= AVOID_PROBE_MS - 1)`。从转身进试探时障碍通常仍在正前方（车还没动），所以进 PROBE 的第一个 `ms_tick` 就命中障碍分支 → `avoid_tries+1`、翻向、回 BACK。**「试探前进」实际只跑 1 ms**，3 轮配额被瞬间烧光（每轮只真正消耗 600 ms 的转身），避障退化成「原地左右各抖 600 ms 再停车」，与 3.28.2 的设计意图不符。`sim/car_fsm_tb.v` 原注释也承认「PROBE 期间若障碍仍在会立刻重试，PROBE 只停留约 1 ms」——当时把它当成测试台的麻烦，没意识到是设计缺陷。

修法：新增参数 `AVOID_PROBE_SETTLE_MS = 100`（`src/car_fsm.v:53`，顶层 `src/FpgaCar.v:377` 传入），判定改为 `if (obstacle && (ms_cnt >= AVOID_PROBE_SETTLE_MS[15:0]))`。

### 3.33.3 修的第三条：绕障结束无条件回 RUN

`S_AVOID_PROBE` 超时后原来无条件 `state <= S_RUN`。但绕行结束时车体朝向与线的相对关系已经完全改变，按「线就在脚下」进 RUN 会用一份过期的 pid 值瞎跑。

修法：`state <= (!lost && on_line) ? S_RUN : S_LOST;`。

**诚实记录**：做了反向验证（改回无条件 RUN），**用例仍然通过** —— 因为 `lost=1` 时进 RUN 后下一个 `ms_tick` 就会经 `src/car_fsm.v` 的 `else if (lost)` 跳 S_LOST，两者在 1 ms 内等价。所以这条是**可读性改进，不是 bug 修复**。审查报告把它列为「最该修第 1 条」是过重的判断，已在清单里降级。

### 3.33.4 修的第四条：直行牌不熄转向指示

`dir_evt == 3'd3`（直行牌）原来只清 `turn_req/turning/turn_cnt`，不清 `turn_dir` 与 `turn_dir_cnt`，于是收到「取消转向」后 `S=` 与 OLED 左右转格仍亮满 1500 ms。补 `turn_dir <= 2'd0; turn_dir_cnt <= 16'd0;`。

### 3.33.5 测试台：新增第六个实例 u_dut6

`sim/car_fsm_tb.v` 新增 `u_dut6`（`LOST_HOLD_MS=200`、`AVOID_EN=1`、`AVOID_PROBE_MS=20`、`AVOID_PROBE_SETTLE_MS=5`、`DIR_DEAD_MS=1`、`DEFAULT_TURN_LEFT=0`），与 `chk6` / `wait_state6` 两个任务，以及三条用例：

- 用例 15：丢线后立刻给障碍，只等 60 ms（**远小于 LOST_HOLD_MS=200**）就必须进 BACK。若障碍分支没生效，车会一直停在 LOST 直到 200 ms 超时 —— 区分度就在这个时间差上。
- 用例 16：先回线上重新起跑，再拉低 `on6` 走「丢线 → 超时 → SEARCH」的干净路径，然后给障碍，断言转 BACK。
- 用例 18：全程保持障碍进试探段，断言进入后 3 ms（< 静默窗 5 ms）仍留在 PROBE，之后才弹回 BACK。

**三条用例全部做了反向验证**（把对应分支改成 `1'b0` / 去掉静默窗条件），失败点分别精确落在 `lost+obs -> BACK fast`（`st6=2`）、`search+obs -> BACK`（`st6=0`）、`settle: stays in PROBE`（`st6=5`）。既然 `LOST_HOLD_MS` 从 5 改成 200，看门狗也相应从 `#600_000_000` 放宽到 `#1_200_000_000`。

car_fsm_tb PASS 52 → **64**，单跑约 100 s。

### 3.33.6 审查报告里被驳回的一条

报告把「拐角兜底一律左转」列为「最该修第 3 条」，理由是 `USE_K230=0` 时它是唯一转向来源、右弯宽黑丢线会反向跑满 1500 ms。但没有采纳，因为：

- 这是用户 2026-11-18 明确要求的行为（原话见 §3.31.1「一律向左转」），不是实现走偏；
- 兜底只在「宽黑后 500 ms 内丢线」触发，普通右弯跑偏不会命中（§3.31.3 三级优先级，测试用例 13 专守这条边界）；
- 真要在右弯上触发兜底，说明车已经在拐角处看不到线了，此时「一律左转」至少是个确定行为，比随机方向更可预测。

如果后续实测发现右转弯道被误判，正确做法是把 `DEFAULT_TURN_LEFT` 改 0 退回「线在哪边往哪边转」（§3.31.4），而不是在 `car_fsm` 里按 `last_pos_neg` 做条件分支——那会让三级优先级的语义变得难以预测。

### 3.33.7 其余 8 条的处置

| # | 问题 | 处置 |
|---|---|---|
| 4 | 宽黑 200 ms 窗口内 `pos` 冻结，车按过期位置全速漂移约 6 cm | **保留**。这是宽黑兜底的设计代价：宁可短暂按上一拍位置走，也不能采信「八路全黑 = 居中」的假信号（§3.28.1）。真要改应缩短 `WIDE_MS`，不是改冻结逻辑 |
| 5 | `S_LOST` 的 `duty_l <= pid_l` 没加 `if (!dead)` 门控 | **不修**。`assign en = en_run & ~dead` 已保证死区期间 `pwm_gen` 的 `en=0` 不出波，引脚行为正确，纯可读性问题 |
| 6 | `S_STOP` 恢复条件不含 `lost` | **不修**。已验算：STOP 期间 `state` 不在 `en_run` 内 → `track_pid` 走 `!en` 分支清 duty，进 RUN 后 lost=1 时 PID 自保持 0，下一 `ms_tick` 就跳 LOST，这 1 ms 不会窜车 |
| 7 | `saw_line` 只写不读，是死寄存器 | **已删除（2026-11-19）**。原打算用它区分「从没压上线」与「跑丢后找不回」，但进入 `S_SEARCH` 必须先经过 `S_RUN`，而起点安全锁要求 `on_line && !lost` 才会进 `S_RUN` —— 读到它时恒为 1，加了判断也是死代码。删掉同时消掉一条编译警告 |
| 8 | `final_stop` 通路在 `SEARCH_FAIL_TO_IDLE=1` 下是死代码 | **保留**。比赛会把它改回 0（§3.26.2），届时就是活路径 |
| 9 | `uart_report.v` 的 `idx2` 注释写「0..39」但实际 `MSG2_LEN=79` | **已修**（纯注释） |
| 10 | `oled_driver.v` 的 `dbg_state` 注释写「0..4」但状态已用满 0..7 | **已修**（纯注释） |
| 11 | 直行牌不熄转向指示 | **已修**，见 3.33.4 |
| 12 | `hc_sr04.v` 的超时比较少减 1，多等 1 us | **不修**。无功能影响 |

另：审查报告确认了 24 个计时器的位宽全部够用，最紧的是 `oled_driver.v` 的 `refresh_cnt[25:0]`（上限 47,999,999，余量仅 1.4 倍）—— 刷新周期调到 >2.79 s 会静默截断，已在此留痕。

### 3.33.8 回归

`bash tools/run_regression.sh` → **20 个 tb 全绿，160 s**（car_fsm_tb 因新增用例与 `LOST_HOLD_MS=200` 涨到约 100 s，全量总时长从 88 s 涨到 160 s）。

## 3.34 YB-MUX04 阈值校准：是按键校准，没有电位器（2026-11-19）

### 3.34.1 起因

用户 2026-11-19 下地实测反馈「刚才下地发现不识别黑线」，接着问「这个寻迹模块怎么调阈值」并要求「你查一下这个型号的怎么调」。

我此前在对话里给的是通用 TCRT5000 调法（「拧电位器，白底拧到指示灯刚灭再退回留 30% 余量」）。**这条对本模块是错的**，已撤回。本文件 §3.22.4 与 `docs/模块接线说明.md` §3.6 里把「阈值电位器拧到极端」列为故障原因，也一并订正。

### 3.34.2 官方依据

模块型号 `Yahboom YB-MUX04-1.0`。官方仓库 `YahboomTechnology/8-Channel-tracking-module` 的 README 原文：

> **No need to manually adjust the potentiometer**, users can let the module complete automatic calibration. Equipped with key calibration function.

官方说明书 `0. 8-channel line tracking module usage/8-channel line tracking module usage.pdf`（3 页，已下载到 `FpgaCar/.scratch/mux04_usage.pdf`，219152 B）第 2 节给出完整校准步骤。

### 3.34.3 校准步骤（照抄说明书，落到可操作粒度）

| 步 | 操作 | 灯语（红灯） |
|---|---|---|
| 1 | 上电，**等至少 20 秒**让探头稳定（每次上电都要等） | — |
| 2 | 首次上电且未校准，红灯持续闪烁 | 慢闪 |
| 3 | **长按 key1**，等红灯常亮 → 进入校准模式 | 常亮 |
| 4 | 按实际行驶高度把探头压在**黑线**上，停 **3 秒**不动 | — |
| 5 | **轻按 key1** 记录黑线值 | 快闪一下 |
| 6 | 把探头放到**白色地面**上，停 **3 秒**不动 | — |
| 7 | **按 key1** 记录白线值 | 快闪一下 |
| 8 | 成功 → 红灯熄灭、进检测模式；失败 → 红灯缓慢持续闪烁，需重校 | 灭 / 慢闪 |

补充要点：

- **必须按实际离地高度校准**。在桌面上校好，装到车上高度变了，反射强度差很多 —— 这是最容易白跑一趟的地方。
- 进入校准模式后**探头指示灯不再响应黑白线**，属正常，校准完成才恢复。
- 误入校准模式：**按 reset 键**复位模块，或**快速双击 key1** 退出。
- 校准值**掉电保存**，下次上电直接可用；只有**更换环境或高度**才需要重校。
- 板上 `KEY` / `RESET` 两个排针脚与板上按键并联，本工程**不接**（`docs/模块接线说明.md` §2.1 第 3、4 行）。

### 3.34.4 协议备查（本项目不用）

- I2C 地址 `0x12`；寄存器 `0x01` 写 `1` 进校准 / `0` 退出（默认），`0x30` 读 8 位红外状态（bit 对应 x1~x8）。
- 串口命令 `$校准开关,模拟量开关,数字量开关#`：`$1,0,0#` 只进校准（仍须按键读黑白值）、`$0,0,1#` 数字量、`$0,1,0#` 模拟量、`$0,1,1#` 两者。
- 上电**默认不主动发数据**，收到命令后才持续发。数字帧 `$D,x1:0,...,x8:0#`；模拟帧 `$A,x1:4096,...#`。

### 3.34.5 极性再次确认（与现有 RTL 一致）

官方 STM32 例程注释原文：「**L1为X1，白底灭灯时为1，黑线亮时为0**」→ 压黑线输出**低电平**，与 `src/track_line.v:41` 的 `ACTIVE_HIGH = 0` 完全一致。**接线与参数都不用改。**

该例程还给出直角判据：`x1..x5 全 0 && x6..x8 全 1` 这类「一侧全黑、另一侧全白」的组合优先当直角/锐角处理 —— 与本轮 §3.31 用宽黑判拐角的思路同源，可作为后续改进的参考。

### 3.34.6 现场排查顺序（校准仍是第一嫌疑）

下地不识别黑线时，按此顺序，**不要先怀疑代码**：

1. 上电等 20 s，看红灯是否慢闪 → 慢闪 = 从未校准 / 校准失效，先按 §3.34.3 校准。
2. 校准完成后，用黑胶带在探头下移动，看串口 `X=` 对应位是否翻转。`X=` 是**原始电平**，压黑线应为 `0`。
3. `X=` 一位都不翻 → 查供电（模块 5 V、共地）、查 X1~X8 顺序、量 X 脚电平（须稳定 3.3 V 或 0 V，不能是 1.5 V 中间值）。
4. `X=` 正常但 `T=` 不互补 → `ACTIVE_HIGH` 设反（`src/track_line.v:41`）。

### 3.34.7 校准失败（红灯慢闪）的原因分析

官方说明书**只给判据、不列原因**（原文：「if it fails, the red light on the board will flash slowly and continuously, and recalibration is required」）。以下为按反射式光电传感器物理特性推导，已与 `docs/模块接线说明.md` §2.3.1 同步：

1. **黑白对比度不足** —— 校准本质是记录「全黑模拟值」与「全白模拟值」并取中间阈值，差值过小则无效。深灰桌面当黑、米色地板当白是最常见的错。
2. **采样期间移动探头** —— 黑白各需静置 3 秒；按 key1 后要等快闪结束再移动。
3. **探头离地过高** —— 反射光强随距离平方衰减，>3 cm 时黑白差值被噪声淹没。检测高度建议 1~2 cm（感为同类模块手册给 4~100 mm，典型 20 mm）。
4. **环境光过强或频闪** —— 直射阳光、正对窗户、老式日光灯 100 Hz 闪烁都会抬高白基线。
5. **单路探头脏/坏/虚焊** —— 八路是**一次性全部校准**，任一路异常则整次作废。
6. **供电不足或地不稳** —— 模块 100~200 mA，电压跌落导致模拟量整体偏移。
7. **上电 20 秒内就校** —— 红外管温度漂移未稳定。

排查顺序：1→2→3 重做（占绝大多数）→ 逐路见黑看指示灯（第 5 条）→ 量供电（第 6 条）。

**与本车的关联**：若板上红灯一直慢闪，说明校准从未成功，此时 `T=` 无论恒 `11111111` 还是恒 `00000000` 都属预期，调 PID 参数没有意义。**先确认红灯已熄灭，再谈循迹。**
### 3.34.8 本次未做的事

未改动任何 RTL，未重新综合烧录（板上跑的是 `df145c4` 的位流，串口第二行 77 字符带 `S=`）。本次只订正文档。
## 3.35 第二轮全仓审查（audit2）：假绿灯与转向牌隐患（2026-11-19）

### 3.35.1 为什么要再查一遍

上一轮 §3.33 已经查过一次，但那次的检查者没有逐条复现，其中「回归全部通过」这个结论本身没有被质疑。这轮换了独立审查（子代理只读、禁改文件），要求它对每条结论给出可复现的命令与输出。结果**推翻了一条既有结论**：全量 20 个 tb 报「全部通过」并不可信。

### 3.35.2 P0-a：回归门禁有假绿灯（已复现，已修）

`tools/run_regression.sh` 判定「有汇总行」用的正则是 `grep -ciE 'ALL PASS'`（**要求有空格**），而 `sim/hc_sr04_period_tb.v` 打的是无空格的 `ALLPASS=%0d`。两处对不上，加上失败条件里没有 `ALLPASS=0` 这一条，导致：

```
hc_sr04_period_tb  OK  PASS=3  ALLPASS=0  FAIL=0  TIMEOUT=0  9s
回归汇总：1 个 tb，0 失败 ... 全部通过   [exit code: 0]
```

更糟的是那个 tb 的 `(n >= 4) ? 1 : 0` 表达的就是「Trig 触发次数够不够」，不足时**只打 `ALLPASS=0`、不打 `FAIL:`**，所以是 100% 漏检，不是小概率。

修法三条：
1. 正则改 `'ALL ?PASS'`，同时吃 `ALL PASS` 与 `ALLPASS` 两种写法。
2. 新增 `na0` 计数匹配 `'ALL ?PASS=0'`，非零直接判 FAIL。
3. tb 侧改用标准标记：够了打 `PASS:`，不够打 `FAIL:`，另加一行 `INFO: ... ALL PASS`。

同批还收紧了该 tb 的周期容差：原上界 `1.60×` 太宽（60 ms 的目标，96 ms 都算过）。但**不能收到 1.10×** —— 一个完整周期 = `PERIOD_US` + Trig 15 us + Echo 等待与回波宽（本 tb 是 400 + 5800 us）≈ 1.10×，所以定在 `0.98× ~ 1.20×`。

### 3.35.3 P0-b：拐角记忆被转向动作本身污染（未上板，但会废掉 25 分项）

`src/car_fsm.v` 的拐角记忆在 `case(state)` **之前**无条件运行：

```verilog
if (wide && CORNER_WIDE_MS > 0) corner_cnt <= CORNER_WIDE_MS[15:0];
```

而交通牌强制转向的那 700 ms 里，车是**有意离开赛道的**（注释里就这么写的），车体扫过线/宽黑区域时 `wide` 必然置位。失效链：

1. 牌子要求右转 → `turning=1`，车离开线 → `wide` 被填满 `corner_cnt=500`
2. 转向结束回 `S_RUN`，但车已不在线上 → 丢线进 `S_LOST`
3. `LOST_HOLD_MS=300` 后到决策点，命中 `else if (DEFAULT_TURN_LEFT != 0 && corner_cnt != 0)`
4. 兜底强制 `dir_l_des<=0, dir_r_des<=1`（左转），**把刚按牌子做的右转反着执行一遍**

这直接违反代码自己承诺的「① 有转向牌事件：完全按牌走」。**当前影响为 0**，因为 `USE_K230=0` 时 `dir_evt_mux` 恒 0、`turning` 进不去；但三处注释都写着「接回 K230 时改回 1'b1」，一旦恢复立刻生效，而交通牌是 25 分项。

修法（双保险）：
- 拐角记忆加 `!turning` 门控；
- 转向正常结束时清 `corner_cnt`；
- `dir_evt == 3`（直行牌）分支同样清。

### 3.35.4 P1：转向牌逻辑此前零测试覆盖

审查发现 `sim/car_fsm_tb.v` 的六个实例**一次都没驱动过 `dir_evt`**（grep 命中 0 次）。这意味着事件锁存、`turning` 全段、按牌找线、以及 `TURN_MS`/`TURN_DUTY`/`TURN_DIR_HOLD_MS` 三个参数全都没有仿真保护 —— 上面那个 P0-b 能活下来正是因为这一点。

新增第七个实例 `u_dut7`（`TURN_MS=20`、`TURN_DUTY=400`、`TURN_DIR_HOLD_MS=50`、`LOST_HOLD_MS=2`）与四条用例：

| 用例 | 内容 | 断言 |
|---|---|---|
| 19 | `dir_evt=1` 左转牌 | `dir=(0,1)`、`duty=400`、`S=1`、20 ms 后回 RUN |
| 20 | `dir_evt=2` 右转牌 | `dir=(1,0)`、`S=2`、自动结束 |
| 21 | `dir_evt=3` 直行牌 | `S` 由 1 清回 0 |
| 22 | **转向中置 `wide=1`，转向后丢线** | 找线方向仍为**右**、`S=2` 未被翻转 |

用例 22 就是 P0-b 的直接回归。同时把六个旧实例悬空的 `dir_evt` 接成 `3'd0` —— 悬空输入在仿真里是 X，编译警告一直在提示（这也是过去被扔掉警告的直接代价）。

### 3.35.5 回归上限：180 s 会把正常完成误判成静默失败

加了第七个实例后 `car_fsm_tb` 实测约 **236 s**，而脚本内置 `timeout 180`。表现是「PASS=0 FAIL=0 无任何输出」—— 看着像死锁，实际是被杀掉了。上限改 420 s。

这一条值得单独记：**超时与真失败在日志上长得一模一样**，如果不看「PASS=0 且 FAIL=0」这个组合，很容易误判成 RTL 死锁去改状态机。

### 3.35.6 P1：编译警告不再被丢弃

原脚本 `iverilog ... >"$clog" 2>&1`，只在编译**失败**时打印日志。死寄存器、悬空端口、未引用参数这三类问题只在警告里出现，等于永远看不见。现在按 tb 收集 `warning:` 行到 `.scratch/_warnings_<pid>.log`，跑完统一打印前 12 条。

### 3.35.7 P3 一并修掉的四处

| 位置 | 问题 | 处置 |
|---|---|---|
| `src/track_line.v` | `DEBOUNCE_N` 参数**从未被引用**：`dbuf` 固定 `[0:3]`、比较固定写 4 项，顶层传 4 是空转 | 真正参数化（`localparam DN`、`dbuf [0:DN-1]`、循环比较） |
| `src/track_line.v` | 消抖实际要 **5 个 tick** 才生效：`dbuf[0]` 是非阻塞赋值，同一拍比较读到的是旧值 | 改成「本拍 + 最近 N-1 拍」，正好 N 个采样 |
| `src/track_line.v` | `pos <= ±$signed({1'b0, pmag[4:0]})` 脆弱：`pmag==16` 会被当成 −16，方向反了 | 取 `pmag[3:0]`（实测 pmag 最大 7） |
| `src/oled_driver.v` | `ack_err` / `nack_seen` 不在复位块内，复位后到首笔事务间是 X | 补进复位初值 |

`saw_line` 一并删除。它原是「只写不读」的死寄存器，本想用它区分「从没压上线」与「跑丢后找不回」，但进入 `S_SEARCH` 必须先经过 `S_RUN`，而起点安全锁要求 `on_line && !lost` 才进 `S_RUN` —— 读到它时恒为 1，加判断也是死代码。

### 3.35.8 明确判定为「不是问题」的几条

审查还列了若干看起来可疑、但逐条核对后确认无害的：
- 25 个计数器位宽余量逐项算过，唯一紧张的是 `oled_driver.v` 的 `refresh_cnt[25:0]`（2 s 刷新周期用掉 26 位的 71%），改到 >2.79 s 会静默截断 —— 已在代码注释标注。
- `track_pid` 全链路有符号扩展正确：`pos` 5 位 → `{{11{pos[4]}}, pos}` → 限幅 → `BASE±sum` 必落 0..1200。
- 顶层 `generate` 分支互斥、12 处 `always @(*)` 全有完整赋值、无组合环路、无多驱动。
- S_AVOID_BACK/TURN 不看障碍是**正确设计**（这两段就是在背离障碍）。

### 3.35.9 回归

`bash tools/run_regression.sh` → 20 个 tb，`car_fsm_tb` PASS 由 64 增至 **78**，全绿。

（本版**报文格式与长度完全不变**，仍是第二行 77 字符；只是内部逻辑与测试设施修复。）

## 3.36 fix/k230-p0：修 H1（转向牌被兜底反转）与 M2（侧绕误判退赛）（2026-11-20）

本节的改动全部落在分支 `fix/k230-p0`（工作树 `_wt_fix`，基于 `origin/codex/k230-field-vision`），**尚未合回 main**。提交 `4e62982`，5 文件 120 增 5 删，已推 `origin/fix/k230-p0`。

### 3.36.1 H1：转向牌方向被拐角兜底反转（[高]）

**现象**：接回 K230 后，某些情形下按牌右转之后，下一次丢线会被拐角兜底强制左转，方向正好反过来。

**根因**：拐角记忆的武装条件原只有 `!turning`。但交通牌有**两条**执行路径 —— S_RUN 里的 `turning` 分支，以及 S_LOST 里消费 `turn_req` 的找线方向决策。后者**从不置 turning**；随后 1.5 s 的原地旋转会让车体自己扫过赛道线，`wide` 被自己的转向动作转出来 → `corner_cnt` 重新填满 → 下一次丢线时兜底命中，把刚按牌子做的方向反着执行。

**修法**（`src/car_fsm.v`，ms_tick 开头的拐角记忆块）：

```verilog
end else if (!turning && !lost && (state == S_RUN) &&
             wide && CORNER_WIDE_MS > 0) begin
    corner_cnt <= CORNER_WIDE_MS[15:0];
end else if (corner_cnt != 16'd0) begin
    corner_cnt <= corner_cnt - 16'd1;
end
```

门控收到 `state == S_RUN` 是关键：真正的拐角只出现在正常循迹途中。中间过程值得记一笔 —— **只加 `(state == S_RUN)` 时复现仍然 FAIL**，还必须加 `!lost`（宽黑在丢线同时到达时也不能武装）。倒计时不受门控影响，仍每 ms 衰减。

**固化**：`sim/turn_at_corner_tb.v` 新增 dut2 与第三条用例，时序为「右转牌 → 拐角宽黑 → 丢线（消费牌，右转）→ **自激宽黑** → 回线 → 再丢线」，断言第二次仍必须是 `dir=(1,0)`、`turn_dir=2`。反向验证：门控改回 `!turning && wide` → `FATAL: FAIL: corner fallback overrode the right card`。

**当前影响为 0**（`USE_K230=1'b0` 时 `dir_evt` 恒 0，turning 进不去），但转向牌是 25 分硬指标，接回即生效。

### 3.36.2 M2：侧绕 BY_PASS 出口误判退赛（[中]）

**现象**：绕障全程都压着线时，`BY_PASS` 结束直接 `final_stop + S_STOP`，绕障绕到一半自己退赛。

**根因**：`bypass_left_line` 只在 S_AVOID_PROBE 里 `if (lost)` 才置位。若全程压线，该标志恒 0 → 出口条件 `if (bypass_left_line && lost)` 为假 → 落到 else 的「找不回线」分支。

**修法**（`src/car_fsm.v` 的 BY_PASS 段，四分支）：

```verilog
if (bypass_left_line && lost) begin
    bypass_step <= BY_TURN_IN;          // 离过线且仍丢线：反向切回去
end else if ((bypass_has_line) || !bypass_left_line) begin
    ms_cnt <= 16'd0;
    state  <= S_RUN;                    // 全程压线 / 已重新压线：交回循迹
end else begin
    final_stop <= 1'b1;                 // 离过线、丢线、又没重新压上
    state <= S_STOP;
end
```

`bypass_has_line` 的定义是 `on_line && !lost && !wide`（`src/car_fsm.v:186` 附近），带 `!wide` 是为了不让一片影子被当成「已回线」。

**固化**：`sim/bypass_rejoin_tb.v` 新增用例 —— 复位 → RUN → 置 obstacle → 等 TURN → 撤 obstacle → **全程不动 on_line/lost** → 等 `state==BYPASS && bypass_step==PASS_SIDE` → 有界守卫等 RUN/STOP → 断言 `bypass_left_line==0` 且 `state==RUN`。反向验证：改回旧两分支版本 → `INFO: bypass_rejoin_tb 1 FAIL(S)`。

### 3.36.3 M1：TURN_REQUEST_MS 顶层收紧到 3000

`car_fsm.v:42` 默认 `TURN_REQUEST_MS = 12000`，顶层 `src/FpgaCar.v` 覆盖为 **3000**。

原因：一旦锁存了一枚过期箭头，它会在整整 12 s 内压制拐角兜底 —— 车遇到没有牌的真拐角也不会按 `DEFAULT_TURN_LEFT` 转，直接冲出赛道。按 3 m 场地、约 0.4 m/s 估算，走完一段直道 3 s 足够。

### 3.36.4 L2：OLED 面板列下溢保护

`src/oled_driver.v` 原 `wire [5:0] panel_col = dk - DK_SEG6;`，在 `dk < DK_SEG6` 的拍上 6 位减法会回绕成 63，`panel_letter` 的位选 index 越界取到别的字符。改为 `(dk >= DK_SEG6) ? (dk - DK_SEG6) : 6'd0`。时序上原也不会显示错，但这是「靠上下文惯例才正确」的写法，收紧后不依赖调用顺序。

### 3.36.5 L5：bypass_rejoin_tb 会真的失败

`task check` 原只 `$display("FAIL:")`，单跑 `vvp` 退出码仍是 0，工具链看起来是绿的。改为累计 `integer fails`，新增 `task finish_summary` 打印 `ALL PASS` / `n FAIL(S)`，末尾用 `finish_summary` 代替裸 `$finish`。

### 3.36.6 两个审查项判定为「不改」

| 项 | 决定 | 理由 |
|---|---|---|
| M3：K230 四脚无内部下拉 | **已改（2026-11-20 撤销「不改」）** | 当初判断「板上会加 10 kΩ 下拉」属计划未落地：实测 K230 未接时 4 根脚真浮空，`k230_stb` 浮空会产生大量假上升沿，三重校验挡得住单次假帧但挡不住长期等下去；假 `dir_evt` 会被 `TURN_WAIT_FOR_CORNER` 存起来，等真拐角时按假方向转（失败现象极难归因）。已改 `pull_option="weak pulldown"`，`outflow/FpgaCar.peri.pbn` 里确认出现 4 条 `WEAK_PULLDOWN`。 |
| H2：`motion_rst_n = sys_rst_n && run_enable` | 待确认 | 读 `src/car_panel.v` 全文，这是**有意设计**：找线失败 → 面板锁停 → 按 K1 重试（`run_enable = rst_n && (status == RUN) && stop_sync[1]`）。与审查所说的「抹平 final_stop」是同一现象的两种解读，取决于产品语义，需用户裁定。 |

### 3.36.7 回归

`bash tools/run_regression.sh`（`_wt_fix`，**23 个 tb**）→ 全绿 0 失败 218 s。新增的两个台：`turn_at_corner_tb` PASS=3、`bypass_rejoin_tb` PASS=17。

编译警告 23 条全部是同一句历史遗留：`src/I2C_OV5640_1280720_Config.v:302: warning: Extra digits given for sized hex constant.`

### 3.36.8 尚未做的事

- **未合回 main**：这条分支还带着 `USE_K230=1`、`car_panel` 按键面板、`AVOID_ROUTE_EN=1` 侧绕整段、`AVOID_FIXED_RIGHT=1` 等一整套行为改动，合并与否需用户决定。
- **未综合、未烧录**：本轮只跑仿真。
- **H2 未动**：等用户明确「找线失败算不算判负」。
## 3.37 侧绕回线转向改成扫线闭环（2026-11-20）

### 3.37.1 现场现象

用户实测避障后反馈：「BY_TURN_IN 朝黑线转 这个步骤转的有点少，之后找不到黑线」。

### 3.37.2 根因：定长转角不可复现

`BY_TURN_IN` 原来是纯定长动作：`if (ms_cnt >= AVOID_TURN_IN_MS - 1)` 就到点转下一段，`AVOID_TURN_IN_MS=650`。问题在于**电机转过的角度不只由时长决定**：

- 电池电压下降 → 同样的占空比转速变低；
- 地面摩擦（瓷砖 / 磨砂地板胶 / 地毯）差异很大；
- 从 `BY_PASS` 结束时的车头角度本来就是浮动的。

同一个 650 ms，昨天够、今天就不够。转不到位，`BY_REJOIN` 直行时线根本不在前方视野内，2.5 s（`AVOID_REJOIN_MS`）内找不到就 `final_stop` + `S_STOP` —— 现场表现就是「转得少，之后一路找不到线，最后停住」。

### 3.37.3 改法：能看见线就停，时间只作上限

`BY_TURN_IN` 段新增 `bypass_turn_in_cnt` 计数器，边转边看 `bypass_has_line`（= `on_line && !lost && !wide`）：

- 连续 `AVOID_LINE_MS`(=20) ms 看到线 → 立即结束 `BY_TURN_IN`，进 `BY_REJOIN`；
- 否则到 `AVOID_TURN_IN_MS` 上限才结束。

`AVOID_TURN_IN_MS` 同时从 650 提到 **1100**（`src/FpgaCar.v:392`），因为它不再决定「转多少」，只决定「最多转多久」。转的角度由线决定，与电池和地面无关。

进入 `BY_TURN_IN` 时把 `bypass_turn_in_cnt` 清零（`src/car_fsm.v` 的 `BY_PASS` 出口），避免沿用上一段的残留计数。

### 3.37.4 测试台与反向验证

`sim/bypass_rejoin_tb.v` 新增用例：进 `TURN_IN` 后先确认还在转（此时 `lost=1` 看不到线），然后拉 `on_line=1 / lost=0`，数还要几拍才离开 `TURN_IN`，断言 `t <= LINE_TICKS + 4`。

- 为拉开两条通路的差距，测试台把 `TURN_IN_TICKS` 从 8 提到 **40**（原来 8 拍与扫线所需 3 拍太近，区分不出来），并显式定义 `LINE_TICKS = 3`。
- **反向验证**：把 `bypass_turn_in_cnt >= AVOID_LINE_MS - 1` 改成 `1'b0 && ...` 禁用扫线通路 → `FAIL: turn-in ends early once the line is seen`，`FAIL=1`。恢复后 PASS=19。
- 教训：第一版用例用 `t < TURN_IN_TICKS` 判据，且循环前已消耗 2 拍，禁用扫线后**仍然全过**（假绿灯）。是反向验证把它抓出来的 —— 光看「新用例通过了」不足以证明用例有效。

### 3.37.5 验证与烧录

- `bash tools/run_regression.sh`：**23 个 tb 全绿，0 失败，223 s**。
- map（约 9 min）/ pnr / pgm 全部 PASS，新位流 `outflow/FpgaCar.bit` = **2038176 B**、`hex` = 2038236 B。
- `bash .scratch/reflash.sh`：擦 664 KiB / 读 663 KiB / **`Flash verify successful`** / 三步 `PROGRAMMING DONE`。已落盘，掉电保留。

### 3.37.6 转角再次加大（2026-11-20 晚，现场反馈）

扫线闭环上线后用户复测：「避障还是不行，就是把开始的转向加大一点，后面的转向也加大，后面的转的更多」。

三处参数同时上调（均在 `src/FpgaCar.v:391-393` 的 `car_fsm` 例化处，`car_fsm.v` 的默认值不动）：

| 参数 | 旧值 | 新值 | 影响 |
|---|---|---|---|
| `AVOID_TURN_MS` | 800 | **1000** | 出线转向（`S_AVOID_TURN`）与摆正（`BY_ALIGN`）各用这段时长 |
| `AVOID_TURN_IN_MS` | 1100 | **1600** | 回线扫转的**上限**（扫到线会提前结束），比出线更长 |
| `AVOID_TURN_DUTY` | 540 | **620** | 两处原地转共用，占空比 45% → 约 52% |

为什么这么配：出线转不够就摆不正、侧边超越会压到障碍；回线转不够则 `BY_REJOIN` 直行时线不在前方。回线上限给得比出线大一截，是因为它只会被「扫到线」提前终止，留大没有副作用 —— 转不到才是问题。

`sim/bypass_rejoin_tb.v` 不受影响：它给两个 DUT 都显式传了 `TURN_TICKS` / `TURN_IN_TICKS` / `TURN_DUTY`，不继承顶层覆盖值，断言仍然成立。

回归：`bypass_rejoin_tb` PASS=19、`car_fsm_tb` PASS=78（159 s）。

### 3.37.6 仍需现场确认

`AVOID_LINE_MS=20` 是「连续 20 ms 看到线」才认，配合 `track_line` 的 4 ms 消抖。拐角处线是斜的，车一边转一边扫，可能扫过线但维持不到 20 ms。若现场仍出现「扫到了却继续转」，把 `AVOID_LINE_MS` 降到 10 或 8。
## 3.38 ST7789 彩屏接进主工程：先看画面（2026-11-20）

### 3.38.1 起因

用户问「屏幕不刷新」。此前 `bench/st7789/` 只是**独立工程**，用 `Ov5640LcdBench.xml` 单独综合、单独烧 JTAG，不参与 `FpgaCar.xml`。把小车固件烧进 Flash 后，那一版 bench 位流就被覆盖了，屏幕自然全黑。

用户选 B 方案：**把屏接进小车固件本体**，先能在屏上看到摄像头灰度预览，之后再谈刷新率。

### 3.38.2 硬件接线（P4 排针，与 K230 的 STB 脚不冲突）

| 屏丝印 | P4 针号 | FPGA 引脚 | 端口名 |
| --- | ---: | --- | --- |
| SCL | 35 | `GPIOL_N_17` | `lcd_sclk` |
| SDA | 36 | `GPIOL_P_17` | `lcd_mosi` |
| A0 | 37 | `GPIOL_N_18` | `lcd_dc` |
| RESET | 38 | `GPIOL_P_18` | `lcd_rst_n` |
| CS | 40 | `GPIOT_P_11` | `lcd_cs_n` |

P4 第 39 脚（`GPIOT_N_11`）已经被 `k230_stb` 占用，屏的 CS 只能走 40。屏的 VCC 用外部 3.3 V，必须与 Ti60 共地。

### 3.38.3 代码结构：一份驱动，两处引用

把 `st7789_panel` 与 `st7789_spi_byte` 从 `bench/st7789/St7789Bench.v` 里抽出来，成为 `src/st7789_panel.v`；`ov5640_preview_frame.v` 也从 bench 挪到 `src/`。理由：主工程与 bench 各存一份必然分叉，出问题时分不清是哪份在跑。

- `bench/st7789/St7789Bench.v` 现在只剩顶层（1.1 KB），面板驱动引用 `src/st7789_panel.v`
- `bench/st7789/make_project.py` 的 `files` 列表同步改，camera 分支追加 `src/ov5640_preview_frame.v`
- `FpgaCar.xml` 登记两个新源文件，design_file 计数 24 → 26

顶层新增两个开关（`src/FpgaCar.v`，紧跟 `USE_K230`）：

| 开关 | 当前值 | 说明 |
| --- | --- | --- |
| `USE_LCD_PREVIEW` | `1'b1` | 打开彩屏预览。会顶掉 `USE_CAMERA` 那条老链路（两者互斥） |
| `LCD_SPI_HALF_CYCLES` | `2` | SPI 时钟 = 24 MHz / (2×N)。N=16→750 kHz（1.64 s/帧）、N=4→3 MHz（0.41 s）、**N=2→6 MHz（0.20 s）** |

### 3.38.4 数据通路

`cam_probe` → `cam_sccb_cfg #(.FULL_FOV_VGA(1'b1))` 把 OV5640 配成 640×480 → `ov5640_preview_frame #(.INPUT_WIDTH(640) .INPUT_HEIGHT(480) .SAMPLE_LOG2(2))` 抽成 160×120 的 Y8 灰度 → 双缓冲 + request/ack 握手 → `st7789_panel` 铺满 320×240。

- 取样地址：屏幕坐标右移一位就是样本坐标，`pv_sample_addr = (row<<7) + (row<<5) + col`，即 160 列 × 120 行的二维展开
- 灰度转 RGB565：`{gray[7:3], gray[7:2], gray[7:3]}`
- `lcd_capture_ready = sys_rst_n && lcd_cfg_done`：SCCB 配置完成前不采帧，避免吃半配置状态的图像
- 屏驱动的 `led` 输出不接（板载 LED 由顶层统一给），`preview_valid` 喂 `lcd_capture_ready && pv_frame_valid`

`FULL_FOV_VGA=1` 是给 `cam_sccb_cfg` 加的新参数，把读取窗口从 720p 的纵向 250–1705 行扩到 4:3 全阵列 0–1951 行（横向两边都是 0–2623）。默认 `0` 时主工程原有行为完全不变。

### 3.38.5 刷新率：瓶颈在 SPI，不在相机

| 环节 | 耗时 |
| --- | --- |
| OV5640 采集一帧 640×480（PCLK 下） | 约 26 ms |
| SPI 发一帧 320×240 RGB565 @ 750 kHz（bench 默认） | **1.64 s** |
| SPI 发一帧 @ 3 MHz（N=4） | 0.41 s |
| SPI 发一帧 @ 6 MHz（N=2，当前） | **0.20 s** |

两者差 60 倍，所以采集侧用双缓冲解耦，采集不必等屏发完。再往上提 SPI 时钟受 ST7789 手册上限约束（一般标称 62.5 ns 周期，实际模块排线长时容易出错），6 MHz 是这块屏比较稳的一档。

### 3.38.6 测试台：为什么必须拆成单元测试

`sim/FpgaCar_tb.v` 里原本想直接断言「上电 166 ms 后 CS 拉低、SCLK 在动」，结果一直 FAIL。查下来是**测试台自己的时间账算错了**，不是 RTL 问题：初始化是「发一字节 → 抬 CS → 等稳定 → 再发」的节奏，字节之间 CS 是高的；而 `init_delay_cycles` 对 `init_index < 2` 返回的是整段 `WAKE_CYCLES`（120 ms），SWRESET 和 SLPOUT 后面各有一段。整段初始化约 380 ms，比测试台等的 166 ms 长了 2 倍多，而且固定时刻采样必然撞在 CS 抬高的间隙里。

结论：**这段不适合放在顶层测试台**。顶层实时基下跑完初始化 380 ms + 整帧 200 ms，会让整个回归超时。处理方式：

1. `sim/FpgaCar_tb.v` 只保留零成本的上电静态约束（复位期间 `lcd_rst_n=0`、`lcd_cs_n=1`、端口不是 X）
2. 新增 `sim/st7789_panel_tb.v`，把 `CLK_HZ` 从 24 MHz 缩到 **24 kHz**（时序比例不变），全程约 6300 拍、几百微秒跑完
3. 那个测试台自带一个 SPI 从机：在 `lcd_sclk` 上升沿按 bit 收 MOSI，攒满 8 位算一字节，按 `lcd_dc` 分成命令/数据两路，**逐字节断言初始化命令序列**

断言内容：`SWRESET(0x01)` → `SLPOUT(0x11)` → `COLMOD(0x3a)` → `MADCTL(0x36)` → `INVON(0x20)` → `CASET(0x2a)` → `RASET(0x2b)` → `NORON(0x13)` → `DISPON(0x29)` → `RAMWR(0x2c)`，外加 COLMOD 的数据字节必须是 `0x55`（RGB565）。

**反向验证**：把 `NORON` 的 `8'h13` 改成 `8'h12` 重跑，`FAIL: cmd7 NORON`，精确命中；恢复后 ALL PASS。这是本工程第四次靠反向验证确认测试台有效。

回归结果：**24 个 tb 全绿，226 s**，`st7789_panel_tb` PASS=17 ALLPASS=1、`FpgaCar_tb` PASS=12。

### 3.38.7 仍需现场确认

- 6 MHz 下屏幕是否有花屏/闪烁。若有，把 `LCD_SPI_HALF_CYCLES` 调回 4（0.41 s/帧）或 8
- OV5640 在 `FULL_FOV_VGA=1` 下输出的 640×480 是否正常（此前主工程一直是 720p 那套参数，全阵列窗口没上板验证过）
- 预览方向：`LANDSCAPE=1` + `MADCTL=8'h60` 是 bench 上验证过的组合，换屏或换排线方向要重新对
- 颜色：预览是灰度转 RGB565，偏绿是正常的（G 用 6 位、R/B 各 5 位），不是配置错

### 3.39 牌转向改成闭环：菱形锐角不再转不到位（2026-11-21）

#### 3.39.1 现场现象

K230 识别转向牌后转弯本身是对的，但遇到**菱形的角**，转向没有足够角度，随后丢线。

#### 3.39.2 根因：牌转向是定长动作

`car_fsm.v` 的 `S_RUN` 里 turning 分支只按 `TURN_MS` 倒计时：

```verilog
turn_cnt <= turn_cnt - 16'd1;
if (turn_cnt <= 16'd1) begin
    turning <= 1'b0;
    ms_cnt  <= 16'd0;
    corner_cnt <= 16'd0;
end
```

完全不看线有没有转回来。菱形锐角需要的转角比直角大得多，700 ms 到点就把车交回 PID，车头还差一截 → 进 `S_LOST` → 按上一刻占空比继续前进 `LOST_HOLD_MS`(300 ms) 才决策 → 车已经冲出去了。与 §3.37 的 `BY_TURN_IN` 定长缺陷是同一类错误。

#### 3.39.3 改法：边转边看线，时长只作上限

`car_fsm.v` 参数区新增两个参数（紧跟 `TURN_MS`）：

| 参数 | 默认 | 含义 |
|---|---|---|
| `TURN_MIN_MS` | 250 | 至少先转这么久。防止刚起步时车还压着线，闭环立刻判定"线已找回"而一秒都不转 |
| `TURN_LINE_MS` | 20 | 连续压线多少 ms 才算线真的找回来（配合 4 ms 消抖） |

新增 `reg [15:0] turn_line_cnt`（复位清零、起转时清零），并抽出 `wire line_visible = on_line && !lost && !wide;`（`bypass_has_line` 改为引用它，语义等价）。turning 分支改成：

```verilog
turn_line_cnt <= line_visible ? (turn_line_cnt + 16'd1) : 16'd0;
turn_cnt <= turn_cnt - 16'd1;
if (turn_cnt <= 16'd1) begin
    turning <= 1'b0;                  // 到达上限，强制结束
    ...
end else if ((TURN_LINE_MS > 0) &&
             (turn_line_cnt >= TURN_LINE_MS - 1) &&
             ((TURN_MS - turn_cnt) >= TURN_MIN_MS)) begin
    turning <= 1'b0;                  // 线已经找回来，提前收工
    ...
end
```

顶层 `src/FpgaCar.v` 的 `.TURN_MS` 从 700 提到 **1100**，并显式写 `.TURN_MIN_MS(250)`、`.TURN_LINE_MS(20)`。1100 只是上限——正常直角大约 400~600 ms 就会自己结束，只有锐角才会一路转到上限。

#### 3.39.4 测试台与反向验证

`sim/car_fsm_tb.v` 新增第八个实例 `u_dut8`（`TURN_MS=40`、`TURN_MIN_MS=5`、`TURN_LINE_MS=3`、`TURN_DUTY=400`）。第七个实例的 `TURN_MS=20` 小于默认 `TURN_MIN_MS=250`，闭环恒不触发，所以必须再开一个实例才能真正覆盖这段逻辑。

两条用例：

| 编号 | 激励 | 断言 |
|---|---|---|
| 23 | 压线状态下收到 `dir_evt=1` | 15 ms 后已结束转向（定长要 40 ms），回到直行占空比 |
| 24 | `wide=1` 把 `line_visible` 按住，收到 `dir_evt=2` | 32 ms 时仍在转（闭环不得误判）；再把线放开，6 ms 内必须收工 |

**反向验证**：把闭环条件改成 `1'b0 && (TURN_LINE_MS > 0) && ...`，重跑正好这两条 FAIL（`ends early once line seen` / `ends once the line returns`），失败点精确；恢复后 ALL PASS。

#### 3.39.5 写这两条用例时踩到的两个坑

**坑一：`dir_evt` 必须给单时钟脉冲。** 最初写成 `dir_evt8 = 3'd1; wait_us(2000); dir_evt8 = 3'd0;`，结果探针显示 `turn_cnt` 走了 `39→34→…→4→40`，看起来像"转不完"。真因是这个实例 `TURN_WAIT_FOR_CORNER=0`，事件锁存块 `if ((dir_evt == 3'd1 || dir_evt == 3'd2) && ((TURN_WAIT_FOR_CORNER == 0) || !turning))` 在 `TURN_WAIT_FOR_CORNER==0` 时把 `!turning` 门控整个短路掉——转向结束的同一拍，仍在保持的 `dir_evt` 会把 `turn_req` 重新置起，立刻开始第二次相同的转向。生产配置 `TURN_WAIT_FOR_CORNER=USE_K230=1` 有 `!turning` 保护，不受影响。改法是 `@(negedge clk) dir_evt8 = 3'd1; @(negedge clk) dir_evt8 = 3'd0;`。

**坑二：`turning` 只存在于 `S_RUN`。** 想构造"转向期间一直看不到线"，不能用 `lost=1`——`S_RUN` 里 `else if (lost) state <= S_LOST` 会立刻把车踢出 RUN，根本进不到 turning 分支（实测 `st8=0`、`dir8=11`、`duty=0/0`）。正确做法是用 `wide=1` 把 `line_visible` 按住，同时保持在 `S_RUN`。

#### 3.39.6 回归

`bash tools/run_regression.sh` → **24 个 tb 全绿，0 失败，263 s**。编译警告仍是历史遗留的 `src/I2C_OV5640_1280720_Config.v:302: warning: Extra digits given for sized hex constant.`

#### 3.39.7 仍需现场确认

- 菱形锐角是否一次转到位。若仍不足，直接加大顶层 `TURN_MS`（比如 1400）——闭环会自己提前结束，加大上限没有副作用
- 正常直角的实际转向时长。若发现车在岔口明显"转过再回来"，说明 `TURN_LINE_MS=20` 太短、`TURN_MIN_MS=250` 太长，可下调
- `TURN_DIR_HOLD_MS=1500` 的转向指示保持时间是否符合观感

### 3.40 Flash 烧不进去的真因：FT232H 驱动绑错，改用 HiFTDI(D2XX) 后端（2026-11-22）

#### 3.40.1 现象
所有 `--jtag_bridge_mode all` 都报 `ERROR: Flash verify unsuccessful... mismatch found`，
而 `-m jtag` 临时配置 100% 成功（`Device ID read from JTAG: 0x10660A79` + `PROGRAMMING DONE`）。
中途还出现 `Cannot unprotect flash device`、`Command timeout (1 cycles)`、
JEDEC 读成 `0x595712`/`0x41921A`/`0x040082` 等一堆互相矛盾的报错。

#### 3.40.2 真因：FT232H 落在了 FTDIBUS 驱动上
Efinity 的下载器走 pyftdi + libusb，要求 FT232H 绑定 **libusbK** 驱动
（`C:/Efinity/2026.1/pgm/bin/efx_pgm/ftdi_program.py:92-101` 的注释里写明要用 Zadig 装 libusbK）。

本机这颗 FT232H 被 FTDI 官方 `ftdibus.inf` 抢走了：

```
pnputil /enum-devices /instanceid "USB\VID_0403&PID_6014\6&253f4ca5&0&4" /drivers
  oem126.inf  ftdibus.inf   FTDI        2024-10-28 2.12.36.20   Best Ranked / Installed
  oem128.inf  elites-232dl.inf  libusbK  2014-04-28 3.0.7.0     Outranked
```

新版 FTDI 官方包按 rank 顶掉了老的 libusbK 包，**换 USB 口无效**——新枚举出的节点一律落 FTDIBUS。
改驱动绑定要管理员权限跑 Zadig，当前会话没有。

#### 3.40.3 解法：Efinity 自带的 HiFTDI(D2XX) 后端
`C:/Efinity/2026.1/pgm/bin/efx_pgm/usb_resolver.py:705-713`：
Windows 下设 `EFX_HIFTDI_ENABLE=1` 就会追加 `HiFTDIDeviceResolver`，走系统自带的
`C:\Windows\system32\ftd2xx.dll`，**完全不依赖 libusbK**。设备 URL 随之变成
`hiftdi://0x0403:0x6014/-1`。

#### 3.40.4 该后端的三处 bug（运行时 monkeypatch，不改安装文件）

| # | 位置 | 毛病 | 补丁 |
| --- | --- | --- | --- |
| 1 | `hiftdi/jtag.py:448` | `configure(self, url)` 只收 1 个参数，而 `efx_dbg/jcf.py:795` 传 2 个 → `TypeError` | 包一层只取 url |
| 2 | `efx_hw_common/manager.py:252-253` | hiftdi 的 `JTAGFINEGRAIN` 分支被注释掉，而 `--jtag_bridge_mode` 恰好强制走这个类型 → `NotImplementedError` | 让 `hiftdi://` + `JTAGFINEGRAIN` 返回 `hj.JtagEngine` |
| 3 | `hiftdi/jtag.py` 的 `write_tms` / `write` | 链式引擎会传 0 位 TMS 和裸 `bytes`，两者都不被接受 | 0 位 TMS 直接返回；bytes 按 pyftdi 语义拆成 bit 序列 |

补丁都在 `tools/hiftdi_runner.py` 里，用 `runpy` 转交给 `tools/jtag_program.py` 原有的命令行逻辑。

#### 3.40.5 结果

```
flash.bat 等价流程（tools/flash_hiftdi.sh）：
  [1] 装桥镜像 u10660A79.bit      -> Device ID read from JTAG: 0x10660A79 / PROGRAMMING DONE
  [2] --jtag_bridge_mode all --verify_method onchipx1 @1.5MHz
        第一遍：erase 2s / write 5s / read 3s -> ERROR: Flash verify unsuccessful... mismatch found
        第二遍：erase 2s / write 13s / read 3s -> Flash verify successful
  [3] 回烧应用位流               -> PROGRAMMING DONE
```

独立回读验证：`--jtag_bridge_mode read --num_bytes 687104` 落 `.scratch/rb_final.hex`，
逐行 `int(line,16)&0xFF` 解码后与 `outflow/FpgaCar.hex` 比对：
**`diff bytes 0 of 687104`，完全一致**。

**第一遍 mismatch 是正常的**，`all` 模式失败会自动重试一轮；判据只看 `Flash verify successful`，
不要看退出码。

#### 3.40.6 此前所有「Flash 物理故障」结论全部作废
11-21 到 11-22 之间做过的一大批实验——擦除分区残留 72.2%、双图案 AND 残留、
写入非确定性、六遍连续写收敛到 7.1%、地址别名回绕、`Cannot unprotect flash device`——
**根因都是设备在 libusb 路径下根本打不开**，测出来的全是无效数据，不要再引用。

另外两个被这次排查顺带纠正的判断：
- `u10661A79.bit` 不能当桥镜像（那是别的 die 的，桥版本报 0.0），必须用 `u10660A79.bit`
- `--spi_active_freq` 对 JTAG 桥模式无效，只写进 `self.spi_flash_program_freq`，走的是 SPI Active 路径；
  桥的时钟只受 `--jtag_clock_freq` 控制

#### 3.40.7 现场怎么判断板子有没有上电
整板没电时 JTAG 读回 `Device ID read from JTAG: 0xFFFFFFFF`，**而工具仍打印 `PROGRAMMING DONE`**，
极易误判成功。判据顺序：
1. 核心板 D9（`VDD3V3 → R42 4.7K → D9 → GND`）是否常亮——这是全板唯一的电源指示灯
2. 按钮板船型开关 SS-12D11G5R 有没有被碰关
3. 六颗 LED 全灭 + OLED 黑屏 + JTAG 读 0xFFFFFFFF 三件事同时出现 = 没电

**核心板 USB-Mini 口只给 CH340 供电，不给整板供电。**

## 3.41 侧视倒车入库方案（2026-11-20）

在 `codex/reverse-parking` 上开发。K230 前视识别停车牌「P」，OV5640 装在车尾附近并侧向观察车库入口，Ti60 执行入库和回线。按车库在行驶方向右侧推导。入库前向左转 90°，让车尾朝向库内。出库直行压到主线后向右转，接回原行驶方向。两个转弯均由左轮驱动，右轮停住作支点。

| 阶段 | Ti60 动作与切换条件 |
|---|---|
| 看到「P」 | K230 连续确认停车牌后发出一次事件。Ti60 锁存停车请求，低速循迹，开启侧视找库窗口。 |
| 找库口并停车 | OV5640 在侧视画面内找入口的两个直角。用两角的间距、朝向和连续帧位置确认同一个库口。按车尾相机相对右轮支点的位置标定两角中点的停车参考位置。到位后停住，使左转后车尾对准库口。 |
| 入库前左转 | 右轮保持停转，左轮后退，车身绕右轮转约 90°。实车标定左轮占空比、转向时长和车尾扫过的范围。有可靠里程反馈时再用它约束转角。 |
| 直线倒入 | 两轮同向后退。首版按实车标定的倒车时长停止，标定时检查车尾先入、停车后车身投影完全在库内。 |
| 停稳 | 脱离倒车动作后停车至少 5 秒，停车计时从车轮停稳后开始。 |
| 直线出库 | 两轮同向前进。驶出库口后，等红外循迹探头稳定看到主线。 |
| 右转回线 | 右轮保持停转，左轮前进。等中部探头重新稳定压到主线后交给循迹 PID。找库、转向和回线各设超时。超时或按 K2 则停车。 |

接入点和第一轮验证目标

- K230 在 `k230/field_vision.py` 加入「P」识别。固定数据线和 STB 沿用现有接线。可在现有命令通道预留 `CAT=3, VAL=3`，由 `src/k230_link.v` 输出停车请求脉冲。先对照图片和非停车牌验证分类，再做收发两端仿真。
- 侧装 OV5640 先沿用 `bench/st7789/Ov5640LcdBench.v` 的 VGA 取景和灰度数据，在 ST7789 画面上标记两角与中点。检测按摄像头帧更新，LCD 刷新独立进行。用侧装实拍定两角的搜索范围、最小间距和停车参考位置。
- 在 `src/car_fsm.v` 的车控路径上接入停车流程，复用现有电机输出、换向死区、K2 停车和红外循迹。先验证两角同时命中与丢帧超时，再实测 90° 转向、倒车时长和出库后右转接回主线的位置。

K230 已实现侧拍「P」的本地标框和事件记录。Ti60 停车请求接收、库口两角检测及入库动作待实现。

## 3.42 左右轮同步环：speed_meter + speed_pid（2026-11-22）

现场反馈是"循迹修正不及时，车直接甩出去"。根因不是 PID 参数，而是两轮实际转速不一致：同一个占空比给到左右两个 TB6612 通道，两个电机空载转速、负载和轮径都有差异，车会持续偏航，PID 只能靠加大修正去追，修正量大到一定程度就冲出赛道。所以先做一层轮速闭环把两轮拉齐，再让循迹 PID 在上面做位置修正。

### 为什么是"左右同步"而不是"绝对速度环"

绝对速度环要把占空比映射成 m/s，必须标定"每米多少脉冲"。这项标定会随电池电压、地面摩擦、轮胎磨损漂移，每次换场地都得重做。同步环只用两个编码器的相对读数：

```
diff = spd_l - spd_r                 // 17 位有符号，避免 ±32767 相减溢出
sum  = P*diff + I_acc>>4             // 限幅 ±SYNC_MAX
duty_l = duty_l_in - sum
duty_r = duty_r_in + sum
```

它保证的只是"两轮同速"，不保证"车跑多快"。速度由上游 `track_pid` 的 `BASE_DUTY` 决定。这个分工的好处是：换电池、换地面、换轮胎都不用重新标定，只要编码器还在出脉冲就有效。

### 降速：基础占空比 600 → 480

同步环只做左右差分，**不动基础占空比**；整车快慢由 `track_pid` 的 `BASE_DUTY` 决定。现场"修正不及时直接甩出去"除了两轮不同步，也有整体太快、留给修正的时间太短的因素，所以同时下调基础占空比。

改法是在顶层加一个覆盖参数，**不动 `src/track_pid.v:24` 的模块默认值**：

```verilog
// src/FpgaCar.v:189-192
localparam [10:0] TRACK_BASE_DUTY = 11'd480;   // 480/1200 = 40%

// src/FpgaCar.v:394
track_pid #( .DUTY_MAX(1200), .BASE_DUTY(TRACK_BASE_DUTY), ... ) u_pid (...);
```

这样 `sim/track_pid_tb.v:30` 和 `:57` 里硬编码的 `600` 断言仍然成立，单测不用改。调速只需改这一个 localparam：600 = 50%（原值），480 = 40%（现行），420 = 35% 以下会明显发飘。

### 参数与信号

| 参数 | 值 | 含义 |
|---|---|---|
| `DUTY_MAX` | 1200 | = CLK_FREQ/PWM_FREQ，占空比上限 |
| `K_SYNC` | 12 | 同步比例增益（每脉冲差 → 12 计数） |
| `I_SYNC_SHIFT` | 4 | 同步积分右移（Ki = 1/16） |
| `I_SYNC_LIMIT` | 400 | 积分累加钳位（抗 windup） |
| `SYNC_MAX` | 180 | 单侧修正量上限（15% duty） |
| `NOENC_WIN` | 20 | 连续 20 个窗口无脉冲即判编码器失效 |

修正量上限 `SYNC_MAX`=180 小于基础占空比 480（180/480 = 37.5%），保证任何情况下两轮都不会被拉到反向；`d_l_raw`/`d_r_raw` 另做 0..`DUTY_MAX` 钳位兜底。

### 失效与换相处理

- `active = en && enc_ok && same_dir`。编码器连续 `NOENC_WIN` 个窗口没脉冲 → `enc_ok=0` → 整层直通，退回纯开环，不至于因为编码器坏了车就不走。
- 两轮转向不同（`dir_l != dir_r`，原地转向/倒车）时 `same_dir=0`，同样直通——原地转向本来就该两轮反向，不能拉齐。
- `en=0`（停机）时积分清零并直通，避免下次启动带着旧修正。

### 接入点

- `src/FpgaCar.v:185` 顶层开关 `localparam SPEED_LOOP_EN = 1'b1;`
- `src/FpgaCar.v:283-306` 例化 `speed_meter` + `speed_pid`，`src/FpgaCar.v:194-195` 选择 `loop_duty_l/r = SPEED_LOOP_EN ? spd_duty_* : ctrl_duty_*`。
- 串口 `DL=`/`DR=` 改报**环后**真实占空比（`loop_duty_l/r`），不再是 `ctrl_duty_l/r`；否则上板看到的数字和车轮实际拿到的对不上。

### 验证

`sim/speed_pid_tb.v` 覆盖：两轮同速不修正、单侧偏快反向修正、修正量钳位、换相直通、编码器失效直通、停机清积分。全量回归通过。

## 3.43 差速幅度整形：过弯不再把内侧轮压到 0（2026-11-23）

### 问题：PID 饱和时的等效指令是「绕车体中心原地转」

`track_pid` 的 `corr` 限幅正好等于 `BASE_DUTY`（顶层 `TRACK_BASE_DUTY=480`），所以位置误差一大，两轮占空比就顶到 `960 / 0` —— **内侧轮精确等于 0**。占空比 0 不是「慢转」：电机既不出力，又被反电动势和减速箱拖着，近似刹车。此时三轮瞬时旋转中心落在两驱动轮连线上，内侧轮从「驱动」变成「被拖」，纵向约束少一条，旋转中心开始沿线漂移，车尾就甩出去了。

几何上更直接。设弯道半径 `R`、轮距 `W=WHEEL_BASE_MM=160 mm`，内外轮线速度正比于 `R±W/2`，而占空比近似正比于线速度，于是 `内/外 = (R−W/2)/(R+W/2)`。代入 `960/0` 得 `内/外 = 0`，即 `R = W/2 = 80 mm`。**PID 饱和时的等效指令是绕车体中心原地转**，而赛道圆弧半径通常 ≥200 mm —— 指令本身远超需要，这是过弯动作过大的根，不是调参问题。

### 改法：输出层串一级 `duty_shaper`，不去动 PID

`track_pid` 的 ±`BASE_DUTY` 限幅同时保证了两轮都落在 `0..2*BASE`，这是它自己的内部不变式，`sim/track_pid_tb.v` 的断言也按这个行为写死（`:57` 等处硬编码 600）。而「动作幅度别这么大」是电机死区和机械约束的工程要求，属于输出层语义。所以新增独立一级放在 `speed_pid` **之后**、`pwm_gen` 与串口上报之前：

```
track_pid ──► car_fsm ──► speed_pid ──► duty_shaper ──► pwm_gen / 串口 DL=DR=
                              │                            
                              └── 差速缩放只对「循迹同向」生效
```

三步互相独立，各自可单独关：

| 步 | 参数 | 作用 | 默认 |
|---|---|---|---|
| ① 差速缩放 | `SHAPE_DIFF_SHIFT=1` | `mid=(dl+dr)>>1`、`diff=(dl-dr)>>1`，只把 `diff` 右移 `DIFF_SHIFT` 再回代。**均值不变**，所以压幅度不改整体速度 | 开 |
| ② 低占空比地板 | `SHAPE_MIN_DUTY=0` | 占空比非零但低于地板时抬到地板；**`0` 保持 `0`** | 关（需实测死区） |
| ③ 斜率限制 | `SHAPE_SLEW_STEP=0` | 每个 ms 占空比变化不超过 `SLEW_STEP` 计数 | 关（有相位滞后） |

`960/0 → 720/240`（`DIFF_SHIFT=1`）：均值仍是 480，等效最小转弯半径从 80 mm 变成 240 mm，内侧轮保持能出力的区间。**动作幅度减半，而平均前进速度完全不变**。

### 为什么只在「循迹同向」时整形

顶层 `shape_follow = ((car_state==3'd1)||(car_state==3'd2)) && (ctrl_dir_l==ctrl_dir_r)`，即 `S_RUN` 或 `S_LOST` 且两轮同向。其余情形全部直通：

- **原地转 / 找线**（`TURN`、`SEARCH`、`S_AVOID_TURN`）两轮反向，差速不是「转向量」而是动作本身，整形只会让它转不动。
- **避障侧绕**（`S_AVOID_*` 五段弧）是里程闭环的圆弧，改差速会改半径；闭环虽仍收敛，但会偏离 `arc_mileage` 标定过的路径，故不介入。
- **停车**：`car_fsm` 在复位、换相前、`IDLE`、`STOP` 多处把 `duty` 清 0（`src/car_fsm.v:342-343`、`:381-382`、`:459-460`、`:636-637`），0 是明确的停车语义，地板必须放过它。
- **换相死区**：`en=0` 时整形器每拍直通输入并同步内部状态，不引入任何滞后，`DIR_DEAD_MS=10` 的时序不被拉长。

### 接入点

- `src/duty_shaper.v`：参数 `CLK_FREQ` / `DUTY_MAX` / `DIFF_SHIFT` / `MIN_DUTY` / `SLEW_STEP`，端口 `en` / `follow` / `duty_l_in` / `duty_r_in` → `duty_l_out` / `duty_r_out`。
- `src/FpgaCar.v` 开关 `DUTY_SHAPE_EN=1'b1`、`SHAPE_DIFF_SHIFT=1`、`SHAPE_MIN_DUTY=0`、`SHAPE_SLEW_STEP=0`；`final_duty_l/r` 送 `pwm_gen` 与串口 `DL=`/`DR=`。
- **串口 `DL=`/`DR=` 现在报的是整形后的最终值**，与 `480±C` 的偏差又多了一个来源（见 `docs/上板使用说明.md` 第 2 节末）。

### 验证

`sim/duty_shaper_tb.v`（4 项）：`960/0 → 720/240` 差速减半且均值不变；`480/480` 不变；`follow=0` 时 `700/0` 直通；`en=0` 直通。
`sim/duty_shaper_floor_tb.v`（2 项）：`MIN_DUTY=120` 时 `30→120` 而 `0` 仍为 `0`；`SLEW_STEP=40` 时每 ms 变化 ≤40 且最终爬到 1000。

### 综合与布局布线（2026-11-23）

`map` PASS（855 s）：**EFX_ADD 1058 / EFX_LUT4 17087 / EFX_FF 4974 / DSP48 2 / RAM10 15**。
整形器本身只占 `res.csv:9` 的 **23 FF + 52 ADD + 55 LUT4**，可以忽略。

`pnr` PASS（路由 14 s、整轮 35 s）：`clk` setup slack **29.704 ns**、hold slack **0.090 ns**；
整片 XLR **19078 / 60800 = 31.4%**（`hier_util.rpt:7`），`u_shaper` 只占 107 XLR（`hier_util.rpt:26`）。

> 这比 v1.12 记录的 22442 XLR（36.91%）**降了约 3300**，是同期 OLED 调试区改三行文字省下的逻辑，
> 整形器那 107 XLR 完全被它盖住。29.704 ns 是 setup **松弛量**（约束 41.667 ns），余量充裕。

### 待实车确认

- 整形后弯道是否还跟得住（`DIFF_SHIFT=2` 更保守，`0` 等于关掉）。
- `SHAPE_MIN_DUTY` 需要用实测的电机起转死区来定；工程里目前**没有任何起转死区数据**，所以默认必须是 0。

## 4. 下一步（2026-11-10 按实际到货情况重排）

### 第 1 步：现在就能做的上板验证（不需要任何待买硬件）

**命令行直接烧（2026-11-12 起可用，见 §3.15）**：

```
cd FpgaCar
tools\dl.bat          # JTAG 烧 outflow\FpgaCar.bit（掉电丢失）
tools\mon.bat COM12 5 # 读 5 秒串口遥测
tools\flash.bat       # 固化进 SPI Flash（三步：bridge → 写入 → 回烧应用）；上电自启动用这个
```

也可继续走 GUI：Programmer → Select Image File → `outflow/FpgaCar.bit` → JTAG → Start Program
（**位流 2026-11-17 20:54**，含 `hc_sr04` 周期修复，见 §3.22）。5 项预期里先做这 4 项：

1. `LED[5]` 约 0.35 s 慢闪 → 位流已加载、24 MHz 时钟在跑。
2. YB-MUX04 接上（8 根线到 User_IO2~9 + 5V/GND，板子已有）→ 黑线在探头下从左往右推，
   串口看 `T=` 位图的 1 往哪边移动；**若"压黑线显示 0"，把 `track_line` 的 `ACTIVE_HIGH`
   改成 1 重编**——循迹极性现在就能定死，不用等车架。
3. 串口助手（115200-8-N-1）每 60 ms 一行 `D=xxxcm T=xxxxxxxx P=+xx O=x`；不接 HC-SR04
   时是 `D=---cm`；接上后用手在探头前晃，数字跟着变 → 超声波通道打通。
   顺带万用表测 `i2c_scl`/`i2c_sda` 恒高 → I2C 总线释放正常（是第 2 步 sccb_cfg 的前置）。
4. **OLED 接好先看「有没有白闪」**（接线见 §3.16，只能接 P4 pin 15/16/29，VCC 千万别上 pin 11 的 D5V0）：
   按复位（或重新烧）后，屏应**整屏白闪约 0.6 s，然后转黑**，之后左上角留一个 8×8 小方块——
   这就是「固件起来了、屏在线」的判据（`FLASH_MS`/`ALIVE_MARK`，`FpgaCar.v:415-420`）。
   没白闪也不该继续等：全黑 = 一次事务都没成功，先量 P4 pin 15 有没有波形，再换 `DEV_ADDR` `7'h3D`。
   白闪之后花屏/雪花 = I2C 时序或上拉问题，先把 `FpgaCar.v:417` 的 `SCL_FREQ` 降到 `100_000` 重编。
   然后拿红/绿/蓝/黄色卡逐张对着摄像头：每认出一个，屏上从左往右多一个 32x32 汉字，
   顺序与出示顺序一致 → `color_detect`→`color_seq`→`oled_driver` 整链打通。
   注意 OLED 一帧 1026 字节、400 kHz 下约 26 ms，且走独立 I2C 总线，不会卡住摄像头采集。

暂做不了、等电机/编码器到货再验的：**左轮 25% 转动**（PWM→TB6612 通路）、
**手转轮看 `LED[0]` 闪**（编码器 AB 相，能提前发现接反/缺上拉）。

~~当前顶层是台架态~~ —— **已过期**：`FpgaCar.v:142` 现为 `PWM_BENCH_TEST = 1'b0`，
闭环已接管（2026-11-16 起）。台架态（`=1`，左轮 25% 常转）只在需要单独验 PWM→TB6612 通路时
临时打开，且**开着时右轮 IN1/IN2 恒 0 不转**。

### 第 2 步：下一段 RTL = `sccb_cfg.v`（理由：零新硬件依赖 + 卡 45 分）

| 序 | 模块 | 为什么是它 | 依赖 |
|---|---|---|---|
| 1 | `sccb_cfg.v` | 用 `i2c_master` 把资料包 `I2C_OV5640_1280720_Config.v` 的寄存器表灌进 OV5640。**不配通 SCCB，`dvp_capture` 一帧都采不到，标识 25 + 颜色 20 = 45 分全部停摆**。（OLED 走板上另一组 `i2c_scl/i2c_sda`，不占 SCCB，见 §3.16。）寄存器表直接用官方 14 KB 那份，别手写 | 仅 `i2c_master`（已完成）+ 手上已有的 OV5640 |
| 2 | `track_pid.v` + `car_fsm.v` | 用 `track[7:0]` + `enc_*_step` 做循迹 PID，把 `PWM_BENCH_TEST` 换成闭环输出（循迹 20 + 入库 15）。纯片内 RTL，可先在仿真里写验，但**参数整定必须等电机到货** | `pwm_gen`/`encoder_dec`（已完成） |
| 3 | `dvp_capture.v` | 移植 `06-.../02-1_.../src/cmos_i2c/CMOS_Capture_RAW_Gray.v`，先做"采到帧、能数到 HREF/VSYNC 边沿"，再谈识别 | OV5640 配置成功 |
| 4 | `color_detect.v` / `sign_detect.v` | 颜色顺序 20 + 标识 25；需要先确认镜头视野能同时覆盖前方标识牌与侧方 25 cm 色块（结构件问题） | `dvp_capture` |
| 5 | ✅ `oled_driver.v`（已完成，见 §3.16） | 颜色顺序必须在车载屏持续显示到裁判拍照。已做成自带 I2C 引擎的独立驱动 + 1024 B 显存 + 4×32×32 汉字点阵 ROM，仿真 3 帧逐字节比对全 PASS | 无（自带引擎，不依赖 `i2c_master`） |

### 第 3 步：硬件侧立刻并行启动（交期不可压缩，别等 RTL）

扩展底板打样 —— TB6612 两路、编码器接口、HC-SR04 的 5 V→3.3 V 分压、E18-D80NK 的
上拉+分压、电池与 DC-DC、底盘电机。55 分运动类全靠这条线。待买件见 §6 与 xlsx「待买清单」。

### 第 4 步：K230 视觉链（2026-11-15 新增，与上面并行，不占 RTL 排期）

颜色 20 + 标识 25 改由 K230 承担，FPGA 侧只需新增 `k230_link.v`（4 根线接收，接口契约见 §3.18）。
**卡点不在我们这边**：明天由同学在 K230 侧跑 `fpioa.help()` 确认自由引脚、量电平、跑通两个识别例程。
验证结果回来之前，`peri.xml` 与 RTL 一律不动（免得按错引脚锁死再返工）。

## 5. 子模块开发顺序（按依赖与风险排）

**已完成（历史快照 2026-11-10）**：`pwm_gen.v`、`encoder_dec.v`、`i2c_master.v`、`hc_sr04.v`、
`uart_tx.v`、`uart_report.v`、`track_line.v` 共 7 个模块全部例化进顶层并跑通仿真；
当时综合 EFX_ADD 166 / EFX_LUT4 486 / EFX_FF 296 / DSP48 2，P&R setup slack 36.36 ns。
**⚠ 这些数字已过时**：截至 §3.14（2026-11-11 21:38）`src/` 共 14 个设计文件（新增
`cam_probe.v` / `dvp_capture.v` / `i2c_timing_ctrl_16bit.v` / `I2C_OV5640_1280720_Config.v` /
`cam_sccb_cfg.v` / `color_detect.v` / `color_seq.v` / `oled_font.v` / `oled_driver.v`），
`FpgaCar.xml` 17 条 `<efx:design_file>`，
最新（§3.16，2026-11-12 19:50，color_detect v3）**EFX_ADD 422 / EFX_LUT4 12195 / EFX_FF 3739 / DSP48 2**，setup slack 32.622 ns，XLR 26.01%，位流 1881027 B。
（§3.14 那次是 EFX_ADD 276 / EFX_LUT4 2053 / EFX_FF 697、slack 36.462 ns、位流 21:38:30。）
下表 ① ③ ④ 的 ✅/待办状态以 §3.11–§3.14 与 §3.16 为准（① 已完成；③ 前半已完成；**④ 显示已补齐**）。

| 阶段 | 加进 `src/` 的模块 | 说明 | 对应分值 |
| ① 接口控制器（收益最大、风险最低） | ✅ `pwm_gen.v`、✅ `encoder_dec.v`、✅ `i2c_master.v`、✅ `hc_sr04.v`、✅ `uart_tx.v` + ✅ `uart_report.v`；仍缺 `sccb_cfg.v`、`clk_div.v`（后者其实不需要，PLL 走 Interface Designer） | 全部片内 RTL，只需 IO + 无源上拉，不买任何芯片。已完成部分见 §3.7 | 全部 |
| ② 运动闭环 | `track_pid.v`、`car_fsm.v`（整机状态机）、`speed_meter.v`（用 `enc_*_step` 数脉冲测速） | 循迹 PID、避障绕行回线、5 s 停稳入库都靠编码器里程闭环；开环在 4.2 的 5 分钟调试窗口几乎调不稳 | 循迹 20 + 避障 20 + 入库 15 |
| ③ 图像流水线 | `dvp_capture.v`、`rgb2hsv.v`、`color_detect.v`、`sign_detect.v`、`ddr_frame_buf` | 板卡强项。直接改资料包 `07-FPGA_HDL_Image-2023.2/02-1_Ti60_OV5640_LCD-HDMI_1080P60`（**整目录连 `ip/` 一起复制**）。参考实现是 `06-.../02-1_.../src/cmos_i2c/CMOS_Capture_RAW_Gray.v`（6.2 KB）与同目录 `I2C_OV5640_1280720_Config.v`（14 KB 寄存器表）。**注意**：本资料包内**没有** `11_Ti60_Edge_Detect` 工程（2026-11-10 按 `*Edge*` 全盘搜索，0 命中），早期版本本文档引用它"已实证 Sobel→DDR3→HDMI"是不成立的，别按那个前提排期 | 标识 25 + 颜色 20 |
| ④ 显示 | ✅ `oled_driver.v` + ✅ `color_seq.v` + ✅ `oled_font.v`（32×32 汉字点阵） | 细则 4.3.3 / 5.1：颜色顺序必须在**车载显示屏持续显示**到裁判拍照，口头报告不计分；0.96" OLED 建议大号色块 + 字符，别用小字。已按 32×32 汉字横排 4 格实现（§3.16） | 颜色 20 |
| ⑤ 决策层（二选一） | 纯 Verilog FSM，或 Efinity **Sapphire RISC-V** 软核跑 C | Ti60 无硬核 CPU，二者都不需要外挂 STM32/Arduino | 全部 |

**2026-11-15 变更**：③ 图像流水线里的「标识 25 + 颜色 20」已改由 K230 承担（§3.18），
`sign_detect.v` 不必再做；`dvp_capture.v` / `color_detect.v` 保留，定位降为 OV5640 后视倒车（看库位线）。

**省不掉的硬边界**（别试图在片内实现）：传感器本体（红外收发管、CMOS+镜头、超声波换能器及模拟前端）、
H 桥 MOSFET / 电机 / 电池 DC-DC、5 V→3.3 V 分压（E18-D80NK；HC-SR04 已改 3.3 V 供电不再需要）、上拉/去耦/晶振、
屏体本身（SSD1306 在屏内）。**Ti60 没有片内 ADC**，所以模拟输出传感器（如 GP2Y0A21）不要用。

**合规提醒**：编码器必须**光电式**（细则 3.2.2 禁非光电方式导航识别）；严禁任何无线/遥控模块
（3.2.3④ 直接取消资格）；超声波是 3.2.2 明确开的例外，HC-SR04 合规；赛前须主动告知裁判
本车的观测与处理方法（4.3.3）。

## 6. 硬件清单（与 `docs/硬件接口表.xlsx` 的「待买清单」sheet 同步，2026-11-10 更新）

- **已具备（形态已照片确认）**：OV5640（接口匹配、**已停用**，见 §3.19）、TB6612FNG 红色突破板（**16 脚，每侧 8 脚**，见 §3.20）、
  YB-MUX04-1.0（X1~X8 = 8 路数字直读 → track[7:0]，TX/RX/SCL/SDA 悬空不接）、HC-SR04、
  0.96" OLED（SSD1306 I2C 4 脚版，接 User_IO12/13 + D3V3 = P4 pin 15/16/29，见 §3.16 接线表）。
- **已具备（2026-11-15 补）**：**亚博 AIMOTION2 K230 视觉识别模块（豪华版，2.4 寸触摸屏 + 摄像头）**，
  承担颜色识别与交通牌识别，接 User_IO25/28/29/34 共 4 根信号线（见 §3.18）；
  **由车载 DC-DC 的 5V 经 USB 口供电，不从板载 D3V3 取电**，只与 Ti60 共地。
- **待买·必配**：直流减速电机 ×2 带轮、2S 锂电池组 7.4V、**电池充电器**、DC-DC 5V/≥3A（3.2.3② 电源不得脱离车体；与电机功率地单点共地）。
- **待买·已确认**：**E18-D80NK ×2**（左/右前端，User_IO26/27，与 HC-SR04 取"或"融合避障冗余，
  上拉+分压接法（开集空闲=5V 不可直连 1.8V bank）；用户反馈 HC-SR04 曾不靠谱，故加红外冗余）。
- **暂缓（2026-11-16 决定）**：光电编码器 ×2 —— **本轮不采购，等无编码器版本实测后再决定要不要买**。
  理由与降级调试路径见 §3.21；RTL（`encoder_dec.v` / `speed_meter.v`）与 User_IO14–17 的管脚锁定都保留，
  将来装上直接可用。买的话必须**光电式**（3.2.2 禁磁/霍尔）。
- **辅料**：10kΩ / 1kΩ / 1.2kΩ 电阻各 10（E18-D80NK 上拉分压；**2kΩ 只是「若把 HC-SR04 改回 5 V」的备用件**）、
  杜邦线公母各一包、2.54 排针、热缩管、XT30/XT60 电源接头；**建议**加 5 A 保险丝座 + 船型开关。
- 可选：广角镜头（一个摄像头兼顾前方标识牌与侧方 25cm 色块）、VL53L1X（复用 I2C）。
- 接口 Excel 中的两张示意图（框图/引脚图）按用户要求已删除，引脚信息以 §3.5 表格与 xlsx 总表为准。

> **模块侧接线看 [docs/模块接线说明.md](docs/模块接线说明.md)**：TB6612FNG、YB-MUX04、HC-SR04 的实物丝印顺序、
> 逐脚对应、接线硬约束与上板检查顺序，配 [TB6612接线图](docs/TB6612接线图.png) / [YB-MUX04接线图](docs/YB-MUX04接线图.png) / [HC-SR04接线图](docs/HC-SR04接线图.png)。

## 7. 参考

- GUI 点击流程：根目录 `赛题二_Ti60F225适配性分析.md` 之外，官方录屏 `05_FPGA视频教程/2-易灵思官方/`
  第 2 个（建立和编译工程）、第 3 个（Interface Designer 管脚锁定）、第 4 个（Programmer 下载）。
- 手册：`03_芯片数据手册/efinity-tutorial-trion.pdf` 第 5 页（建工程 17 步）、
  `03_芯片数据手册/efinity-ug.pdf` 第 12 / 16 / 58 页（Project Editor / Dashboard / Programmer）。
