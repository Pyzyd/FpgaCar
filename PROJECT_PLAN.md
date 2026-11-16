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
├── docs/                ← 硬件接口表等文档
├── data/                ← 抓包数据（_cap*.csv / _frame*.*），可随时重抓，不入库
├── .scratch/            ← 一次性探测脚本与仿真中间产物，可随时删，不入库
├── ip/                  ← IP Manager 生成的 IP（DDR / FIFO / PLL / Sapphire …）
├── outflow/             ← 编译产物（FpgaCar.bit 已生成 / FpgaCar.hex / 报告），不入库
└── work_pnr/            ← 布局布线中间文件，不入库
```

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
| rst_n | GPIOT_P_11 (User_IO35) | 2B / 1.8V | 上拉 |
| track[0..7] | GPIOL_N_06/P_06/N_08/P_08/N_05/P_05/N_04/P_04 (User_IO2–9) | 1A / 1.8V | YB-MUX04 八路 |
| hc_trig / hc_echo | GPIOL_N_12 / P_12 (User_IO10/11) | 1B / 1.8V | HC-SR04。**Echo 5V 必须两个电阻分压**：TXS0108E 的 B 侧绝对最大仅 4.6V，直连超规格 |
| ir_l / ir_r | GPIOL_N_15 / P_15 (User_IO26/27) | 1B / 1.8V | E18-D80NK 红外光电开关 ×2（避障冗余，与 hc 近距取"或"；NPN 低有效=检测到）。**接法修正（联网查证）**：开集输出空闲时内部 10K 上拉为 **5V 高电平，不可直连 1.8V bank**——弃内部上拉，外部 10K 上拉到 D3V3 + 1K/1.2K 分压至约 1.8V。传感器待买 |
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
**其中 User_IO25 / 28 / 29 / 34 已分配给 K230 视觉模块的 4 线并行口（见 §3.18）**，30–33 四根仍预留；
**User_IO0/1（GPIOL_N/P_02）不用**（与核心板 KEY 复用）。

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
`O=` 是障碍标志（超声波 ≤25 cm 或任一路红外触发）。一行约 2.6 ms，一帧 60 ms，发得完。

**上板用法**：接上 YB-MUX04（8 根线到 User_IO2~9 + 5V/GND），把黑线在探头下从左往右推，
看 `T=` 的 1 从哪个方向移动；若"压黑线显示 0"，把 `track_line` 的 `ACTIVE_HIGH` 改成 1 再重编。

### A2 `ir_l` / `ir_r` —— 红外冗余（引脚已锁定，传感器待买）

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
| K1 | `GPIOL_P_02` | CSI | 能用（= KEY[0]，现绑 `rst_n`） |
| K2 | `GPIOL_N_02` | CSO | 能用（= KEY[1]，当前空闲） |
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

> **K1 的定位**：保留，作为**调试专用逻辑复位**——只复位用户逻辑（`sys_rst_n`），
> 不动配置、不掉位流，开发期间可以反复按。K3 则是整片重配置，只在验证上电自启动时用。

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
| `src/track_pid.v` | 位置 PID → 左右占空比 | 定点实现：`corr = pos*P_GAIN + (i_acc>>I_SHIFT) + (pos-pos_d)*D_GAIN`，`corr` 限幅 ±`BASE_DUTY`，所以 `duty_l/r = 600±corr` 恒在 0..1200；**积分在累加处钳位**（不在输出处钳，否则 windup 会让倒车冲出去）；丢线时保持上一拍转向（立刻归零会让车冲直） |
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
| 上电 2 s 内轮子不动，之后按线走 | IDLE → RUN 正常 |
| 压线偏右时左轮明显快 | PID 方向对（`pos>0 → 左快`） |
| 完全离地（全白）→ 约 0.3 s 后原地向左/右转 | LOST → SEARCH 正常 |
| 手挡超声波 → 停住，移开后自动恢复 | 障碍联动正常 |

参数起步值：`BASE_DUTY=600`（50%）、`P_GAIN=40`、`D_GAIN=24`、`I_SHIFT=5`。
上车后先只调 `P_GAIN`（摆振就减、跟不上就加），再动 `D_GAIN`。

### 遗留

- `speed_meter` 已通过仿真但**尚未接入顶层**：当前只做位置环，速度环要先标定
  "每米多少个脉冲"，否则参数没有物理意义。
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
- **加 4 只 10 kΩ 下拉到 GND**（放在 Ti60 排针侧）：K230 没上电时线路不会浮空乱触发。

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
| 第二行 | `R=00300 G=00000 B=00000 Y=00000 S=3F SB=F800 LB=F800`（54 B） | `L=00000123 R=FFFFFFF0 VL=0005 VR=FFF0`（39 B） |

- `M=nn` 是状态机状态两位十进制（00 IDLE / 01 RUN / 02 LOST / 03 SEARCH / 04 STOP）。
  以前车一停，串口只能看到「不动了」，分不清是没起跑、在原地找线、还是永久停车 —— 这三种处置方式完全不同。
- `L=` / `R=` 是左右编码器累计里程，`VL=` / `VR=` 是每 50 ms 窗口的净步数，**都是十六进制二补码**
  （里程 8 位、速度 4 位）。用十六进制是因为 32 位有符号转十进制要在组合逻辑里级联 8 次除 10，
  代价远大于收益，换算放到主机侧。
- 删掉 16 个 `cam_*` 端口（`vs_cnt` / `cam_done` / `cam_width` / `cam_height` / `cam_color` /
  `cam_b0` / `cam_b1` / `cam_cnt_r/g/b/y` / `cam_sat` / `cam_sb0/sb1` / `cam_lb0/lb1`），
  `src/uart_report.v` 的 `dv10()`（16 位除 10）随之删除，只留 `div10u()`。
- 波特率不变，两行 74 字节约 6.5 ms，一帧 60 ms，永远发得完，不需要队列。

### 主机侧脚本同步（本次一并改了）

- `tools/uart_mon.py`：字段换成 `D/T/P/O/M` 与 `L/R/VL/VR`，十六进制按二补码解成有符号数，
  `M` 自动翻成状态名，额外打印「窗口内左右走了多少步」与「速度区间」。
  正则用 `(?:^|\s)` 锚定，否则 `VR=FFF0` 里的 `R=` 会被误当成右里程。
- `tools/cap.py`：原来解 RGB565 看镜头对着什么颜色，没有数据源了，改成**纯遥测记录器**，
  CSV 列为 `t,D,T,P,O,M,L,R,VL,VR`，并汇总状态跳变序列与平均步/秒。
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
（**位流 2026-11-12 19:50**，含 `color_detect` v3 的黄色判据 + 帧内四色轮询）。5 项预期里先做这 4 项：

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

当前顶层是台架态：`FpgaCar.v:153` `PWM_BENCH_TEST = 1'b1`（`ml_in1`/`motor_stby` 直接绑它，
=1 时 TB6612 一上电就工作）。**电机到货、车架上地之前必须改回 `0`。**

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
H 桥 MOSFET / 电机 / 电池 DC-DC、5 V→3.3 V 分压（HC-SR04 Echo、E18-D80NK）、上拉/去耦/晶振、
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
- **待买·必配**：直流减速电机 ×2 带轮、2S 锂电池组 7.4V、DC-DC 5V/≥3A（3.2.3② 电源不得脱离车体；与电机功率地单点共地）。
- **待买·强烈建议**：光电编码器 ×2（**光电式**，3.2.2 禁磁/霍尔）。
- **待买·已确认**：**E18-D80NK ×2**（左/右前端，User_IO26/27，与 HC-SR04 取"或"融合避障冗余，
  上拉+分压接法（开集空闲=5V 不可直连 1.8V bank）；用户反馈 HC-SR04 曾不靠谱，故加红外冗余）。

> **模块侧接线看 [docs/模块接线说明.md](docs/模块接线说明.md)**：TB6612FNG 与 YB-MUX04 的实物丝印顺序、
> 逐脚对应、四条接线硬约束与上板检查顺序，配 [TB6612接线图](docs/TB6612接线图.png) / [YB-MUX04接线图](docs/YB-MUX04接线图.png)。
- 可选：广角镜头（一个摄像头兼顾前方标识牌与侧方 25cm 色块）、VL53L1X（复用 I2C）。
- 接口 Excel 中的两张示意图（框图/引脚图）按用户要求已删除，引脚信息以 §3.5 表格与 xlsx 总表为准。

## 7. 参考

- GUI 点击流程：根目录 `赛题二_Ti60F225适配性分析.md` 之外，官方录屏 `05_FPGA视频教程/2-易灵思官方/`
  第 2 个（建立和编译工程）、第 3 个（Interface Designer 管脚锁定）、第 4 个（Programmer 下载）。
- 手册：`03_芯片数据手册/efinity-tutorial-trion.pdf` 第 5 页（建工程 17 步）、
  `03_芯片数据手册/efinity-ug.pdf` 第 12 / 16 / 58 页（Project Editor / Dashboard / Programmer）。
