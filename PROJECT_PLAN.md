# FpgaCar 工程说明与开发顺序

> 第十四届"星火杯"赛题二 · 光电导航智能小车 · 主控 VF-Ti60F225（Titanium Ti60F225 / C4，Efinity 2026.1）

## 1. 目录约定

```
FpgaCar/
├── FpgaCar.xml          ← Efinity 工程主文件（File → Open Project 选它）
├── FpgaCar.peri.xml     ← Interface Designer 配置（已完成：管脚/电平全部锁定）
├── FpgaCar.sdc          ← 顶层时序约束（24 MHz 主时钟），与 .xml 同级
├── PROJECT_PLAN.md      ← 本文件
├── src/                 ← 设计文件（综合用），只放 .v / .sv
│   └── FpgaCar.v        ← 顶层【骨架】，整车 I/O 与模块划分
├── sim/                 ← 仿真文件（**不导入工程**）
│   └── FpgaCar_tb.v     ← 顶层最小 testbench
├── tools/               ← 上板/调试脚本（cap.py 抓包、grab_frame.py 抓缩略图、dl.bat 烧板 …）
├── docs/                ← 硬件接口表等文档
├── data/                ← 抓包数据（_cap*.csv / _frame*.*），可随时重抓，不入库
├── .scratch/            ← 一次性探测脚本与仿真中间产物，可随时删，不入库
├── ip/                  ← IP Manager 生成的 IP（DDR / FIFO / PLL / Sapphire …）
├── outflow/             ← 编译产物（FpgaCar.bit 已生成 / FpgaCar.hex / 报告）
└── work_pnr/            ← 布局布线中间文件
```

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

其余 User_IO25、28–33（GPIOL_N/P_14–18）预留；**User_IO0/1（GPIOL_N/P_02）不用**（与核心板 KEY 复用）。
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
| **LED[5] 常亮不闪** | ❌ 屏从复位起**一次都没回过 ACK** → 查接线（P4 pin 15/16）、`DEV_ADDR`（0x3C↔0x3D）、上拉（TXS0108E 通路）|
| **LED[5] 慢闪（约 0.7 s 周期）** | ✅ 总线**至少 ACK 过一次** → 若屏仍黑，问题在屏侧而非总线：`SCL_FREQ` 400 k→100 k、`BOOT_MS` 20→100、对比度 `81 CF` |

> **LED[5] 是黑屏的第一分诊器**（`oled_driver.v` 的 `nack_seen` 粘滞位，`FpgaCar.v:609`）：
> 它只在复位时清零，运行中一旦出现 NACK 就永久保持。
> 因此上电后看一眼 LED[5] 即可判断「屏从没应答」还是「总线通了但屏不亮」，
> 不必先接串口或示波器。板载 LED 低电平点亮，**常亮 = 故障**。

> 自检可关：`FLASH_MS = 0` 关白闪，`ALIVE_MARK = 0` 关小方块（比赛时想留标记就保持 1）。

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

**省不掉的硬边界**（别试图在片内实现）：传感器本体（红外收发管、CMOS+镜头、超声波换能器及模拟前端）、
H 桥 MOSFET / 电机 / 电池 DC-DC、5 V→3.3 V 分压（HC-SR04 Echo、E18-D80NK）、上拉/去耦/晶振、
屏体本身（SSD1306 在屏内）。**Ti60 没有片内 ADC**，所以模拟输出传感器（如 GP2Y0A21）不要用。

**合规提醒**：编码器必须**光电式**（细则 3.2.2 禁非光电方式导航识别）；严禁任何无线/遥控模块
（3.2.3④ 直接取消资格）；超声波是 3.2.2 明确开的例外，HC-SR04 合规；赛前须主动告知裁判
本车的观测与处理方法（4.3.3）。

## 6. 硬件清单（与 `docs/硬件接口表.xlsx` 的「待买清单」sheet 同步，2026-11-10 更新）

- **已具备（形态已照片确认）**：OV5640（接口匹配、用过）、TB6612FNG 红色突破板（标准 12 脚）、
  YB-MUX04-1.0（X1~X8 = 8 路数字直读 → track[7:0]，TX/RX/SCL/SDA 悬空不接）、HC-SR04、
  0.96" OLED（SSD1306 I2C 4 脚版，接 User_IO12/13 + D3V3 = P4 pin 15/16/29，见 §3.16 接线表）。
- **待买·必配**：直流减速电机 ×2 带轮、2S 锂电池组 7.4V、DC-DC 5V/≥3A（3.2.3② 电源不得脱离车体；与电机功率地单点共地）。
- **待买·强烈建议**：光电编码器 ×2（**光电式**，3.2.2 禁磁/霍尔）。
- **待买·已确认**：**E18-D80NK ×2**（左/右前端，User_IO26/27，与 HC-SR04 取"或"融合避障冗余，
  上拉+分压接法（开集空闲=5V 不可直连 1.8V bank）；用户反馈 HC-SR04 曾不靠谱，故加红外冗余）。
- 可选：广角镜头（一个摄像头兼顾前方标识牌与侧方 25cm 色块）、VL53L1X（复用 I2C）。
- 接口 Excel 中的两张示意图（框图/引脚图）按用户要求已删除，引脚信息以 §3.5 表格与 xlsx 总表为准。

## 7. 参考

- GUI 点击流程：根目录 `赛题二_Ti60F225适配性分析.md` 之外，官方录屏 `05_FPGA视频教程/2-易灵思官方/`
  第 2 个（建立和编译工程）、第 3 个（Interface Designer 管脚锁定）、第 4 个（Programmer 下载）。
- 手册：`03_芯片数据手册/efinity-tutorial-trion.pdf` 第 5 页（建工程 17 步）、
  `03_芯片数据手册/efinity-ug.pdf` 第 12 / 16 / 58 页（Project Editor / Dashboard / Programmer）。
