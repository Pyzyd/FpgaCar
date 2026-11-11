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
├── ip/                  ← IP Manager 生成的 IP（DDR / FIFO / PLL / Sapphire …）
├── outflow/             ← 编译产物（FpgaCar.bit 已生成 / FpgaCar.hex / 报告）
└── work_pnr/            ← 布局布线中间文件
```

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
iverilog -g2012 -Wall -s <tb> -o _sim\<tb>.vvp src\*.v sim\<tb>.v
vvp _sim\<tb>.vvp
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

## 4. 下一步（2026-11-10 按实际到货情况重排）

### 第 1 步：现在就能做的上板验证（不需要任何待买硬件）

Programmer → Select Image File → `outflow/FpgaCar.bit`（**2026-11-10 19:50 生成**，含
track_line + ir 融合的最新版）→ JTAG → Start Program。5 项预期里先做这 3 项：

1. `LED[5]` 约 0.35 s 慢闪 → 位流已加载、24 MHz 时钟在跑。
2. YB-MUX04 接上（8 根线到 User_IO2~9 + 5V/GND，板子已有）→ 黑线在探头下从左往右推，
   串口看 `T=` 位图的 1 往哪边移动；**若"压黑线显示 0"，把 `track_line` 的 `ACTIVE_HIGH`
   改成 1 重编**——循迹极性现在就能定死，不用等车架。
3. 串口助手（115200-8-N-1）每 60 ms 一行 `D=xxxcm T=xxxxxxxx P=+xx O=x`；不接 HC-SR04
   时是 `D=---cm`；接上后用手在探头前晃，数字跟着变 → 超声波通道打通。
   顺带万用表测 `i2c_scl`/`i2c_sda` 恒高 → I2C 总线释放正常（是第 2 步 sccb_cfg 的前置）。

暂做不了、等电机/编码器到货再验的：**左轮 25% 转动**（PWM→TB6612 通路）、
**手转轮看 `LED[0]` 闪**（编码器 AB 相，能提前发现接反/缺上拉）。

当前顶层是台架态：`FpgaCar.v:139` `PWM_BENCH_TEST = 1'b1`（`ml_in1`/`motor_stby` 直接绑它，
=1 时 TB6612 一上电就工作）。**电机到货、车架上地之前必须改回 `0`。**

### 第 2 步：下一段 RTL = `sccb_cfg.v`（理由：零新硬件依赖 + 卡 45 分）

| 序 | 模块 | 为什么是它 | 依赖 |
|---|---|---|---|
| 1 | `sccb_cfg.v` | 用 `i2c_master` 把资料包 `I2C_OV5640_1280720_Config.v` 的寄存器表灌进 OV5640。**不配通 SCCB，`dvp_capture` 一帧都采不到，标识 25 + 颜色 20 = 45 分全部停摆**；同一条 I2C 顺带解锁 OLED。寄存器表直接用官方 14 KB 那份，别手写 | 仅 `i2c_master`（已完成）+ 手上已有的 OV5640 |
| 2 | `track_pid.v` + `car_fsm.v` | 用 `track[7:0]` + `enc_*_step` 做循迹 PID，把 `PWM_BENCH_TEST` 换成闭环输出（循迹 20 + 入库 15）。纯片内 RTL，可先在仿真里写验，但**参数整定必须等电机到货** | `pwm_gen`/`encoder_dec`（已完成） |
| 3 | `dvp_capture.v` | 移植 `06-.../02-1_.../src/cmos_i2c/CMOS_Capture_RAW_Gray.v`，先做"采到帧、能数到 HREF/VSYNC 边沿"，再谈识别 | OV5640 配置成功 |
| 4 | `color_detect.v` / `sign_detect.v` | 颜色顺序 20 + 标识 25；需要先确认镜头视野能同时覆盖前方标识牌与侧方 25 cm 色块（结构件问题） | `dvp_capture` |
| 5 | `oled_driver.v` | 颜色顺序必须在车载屏持续显示到裁判拍照 | `i2c_master` |

### 第 3 步：硬件侧立刻并行启动（交期不可压缩，别等 RTL）

扩展底板打样 —— TB6612 两路、编码器接口、HC-SR04 的 5 V→3.3 V 分压、E18-D80NK 的
上拉+分压、电池与 DC-DC、底盘电机。55 分运动类全靠这条线。待买件见 §6 与 xlsx「待买清单」。

## 5. 子模块开发顺序（按依赖与风险排）

**已完成（历史快照 2026-11-10）**：`pwm_gen.v`、`encoder_dec.v`、`i2c_master.v`、`hc_sr04.v`、
`uart_tx.v`、`uart_report.v`、`track_line.v` 共 7 个模块全部例化进顶层并跑通仿真；
当时综合 EFX_ADD 166 / EFX_LUT4 486 / EFX_FF 296 / DSP48 2，P&R setup slack 36.36 ns。
**⚠ 这些数字已过时**：截至 §3.14（2026-11-11 21:38）`src/` 共 14 个设计文件（新增
`cam_probe.v` / `dvp_capture.v` / `i2c_timing_ctrl_16bit.v` / `I2C_OV5640_1280720_Config.v` /
`cam_sccb_cfg.v` / `color_detect.v`），`FpgaCar.xml` 14 条 `<efx:design_file>`，
最新综合 **EFX_ADD 276 / EFX_LUT4 2053 / EFX_FF 697 / DSP48 2**，setup slack 36.462 ns，位流 21:38:30。
下表 ① ③ ④ 的 ✅/待办状态也以 §3.11–§3.14 为准（① 和 ③ 前半已完成；**④ `oled_driver.v` 仍是实打实缺口**）。

| 阶段 | 加进 `src/` 的模块 | 说明 | 对应分值 |
| ① 接口控制器（收益最大、风险最低） | ✅ `pwm_gen.v`、✅ `encoder_dec.v`、✅ `i2c_master.v`、✅ `hc_sr04.v`、✅ `uart_tx.v` + ✅ `uart_report.v`；仍缺 `sccb_cfg.v`、`clk_div.v`（后者其实不需要，PLL 走 Interface Designer） | 全部片内 RTL，只需 IO + 无源上拉，不买任何芯片。已完成部分见 §3.7 | 全部 |
| ② 运动闭环 | `track_pid.v`、`car_fsm.v`（整机状态机）、`speed_meter.v`（用 `enc_*_step` 数脉冲测速） | 循迹 PID、避障绕行回线、5 s 停稳入库都靠编码器里程闭环；开环在 4.2 的 5 分钟调试窗口几乎调不稳 | 循迹 20 + 避障 20 + 入库 15 |
| ③ 图像流水线 | `dvp_capture.v`、`rgb2hsv.v`、`color_detect.v`、`sign_detect.v`、`ddr_frame_buf` | 板卡强项。直接改资料包 `07-FPGA_HDL_Image-2023.2/02-1_Ti60_OV5640_LCD-HDMI_1080P60`（**整目录连 `ip/` 一起复制**）。参考实现是 `06-.../02-1_.../src/cmos_i2c/CMOS_Capture_RAW_Gray.v`（6.2 KB）与同目录 `I2C_OV5640_1280720_Config.v`（14 KB 寄存器表）。**注意**：本资料包内**没有** `11_Ti60_Edge_Detect` 工程（2026-11-10 按 `*Edge*` 全盘搜索，0 命中），早期版本本文档引用它"已实证 Sobel→DDR3→HDMI"是不成立的，别按那个前提排期 | 标识 25 + 颜色 20 |
| ④ 显示 | `oled_driver.v` + 点阵字库（放 BRAM） | 细则 4.3.3 / 5.1：颜色顺序必须在**车载显示屏持续显示**到裁判拍照，口头报告不计分；0.96" OLED 建议大号色块 + 字符，别用小字 | 颜色 20 |
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
  0.96" OLED（SSD1306 I2C 4 脚版，接 User_IO12/13 + D3V3）。
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
