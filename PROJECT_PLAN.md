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
  LED[6:0] 实时显示 7 路循迹探头电平。
- **一个 24 MHz 心跳计数器**：`heartbeat[23]` 驱动 LED[7] 约 0.7 s 慢闪。这不是演示代码，
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
| hc_trig / hc_echo | GPIOL_N_12 / P_12 (User_IO10/11) | 1B / 1.8V | HC-SR04 |
| i2c_scl / i2c_sda | GPIOL_N_13 / P_13 (User_IO12/13) | 1B / 1.8V | scl=output、sda=inout |
| enc_la/lb/ra/rb | GPIOL_N_10/P_10/N_11/P_11 (User_IO14–17) | 1B / 1.8V | 光电编码器 |
| ml_in1/in2/pwm | GPIOL_N_03/P_03/N_07 (User_IO18–20) | 1A / 1.8V | TB6612 左 |
| mr_in1/in2/pwm | GPIOL_P_07/N_09/P_09 (User_IO21–23) | 1A/1B / 1.8V | TB6612 右 |
| motor_stby | GPIOL_N_14 (User_IO24) | 1B / 1.8V | TB6612 STBY |
| led[0..5] | GPIOR_25/22/28/21/24/27 | BR corner / 3.3V | 板上 LED，低电平点亮（LED6/7 球让给 CMOS_D0/D1） |
| uart_rx / uart_tx | GPIOT_N_16 / P_16 | 2B / 1.8V | CH340N 调试串口 |

其余 User_IO25–33（GPIOL_N/P_15–18）预留；**User_IO0/1（GPIOL_N/P_02）不用**（与核心板 KEY 复用）。
OV5640 走核心板专用 DVP 排针（`cmos_*` 网络，1.8V pclk），骨架未例化相机逻辑，暂未在 peri.xml 声明。

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

## 3. 编译状态：已全部跑通，无需再手工做第 1–5 步

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
   - **Device Settings**：BL / BR / TL / TR 设 **3.3 V LVCMOS**，其余 1.8 V（1A=1.2 V）。
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

## 4. 下一步

**先上板验证本轮成果**：Programmer → Select Image File → `outflow/FpgaCar.bit`（2026-11-10 12:59 生成，
含全部 5 个子模块）→ JTAG → Start Program。**把小车轮子架空**，预期现象：

1. `LED[5]` 约 0.35 s 慢闪 → 位流已加载、24 MHz 时钟在跑。
2. **左轮以 25% 占空比持续转动**、右轮不动 → PWM 通路（pwm_gen → TB6612）打通。
3. 用手转左轮/右轮 → `LED[0]` 闪 → 编码器 AB 相解码正确（这一步能提前发现 A/B 接反、缺上拉）。
4. 串口助手（115200-8-N-1）每 60 ms 一行 `D=xxxcm`；不接 HC-SR04 时是 `D=---cm`；
   接上后用手在探头前晃，数字应跟着变 → 超声波通道打通。
5. `i2c_scl` 恒高、SDA 被上拉恒高（示波器/万用表都可）→ I2C 总线释放正常。

**验证完务必把 `FpgaCar.v` 的 `PWM_BENCH_TEST` 改回 `0` 再上地。**

**下一段 RTL 工作（按依赖排）**：

| 序 | 模块 | 为什么是它 | 依赖 |
|---|---|---|---|
| 1 | `sccb_cfg.v` | 用 `i2c_master` 把资料包 `I2C_OV5640_1280720_Config.v` 的寄存器表灌进 OV5640。**不解锁它，45 分识别类无法开工**；同时解锁 OLED（同一条 I2C） | 仅 `i2c_master`（已完成） |
| 2 | `track_pid.v` + `car_fsm.v` | 用 `track[7:0]` + `enc_*_step` 做循迹 PID，把 `PWM_BENCH_TEST` 换成闭环输出（循迹 20 + 入库 15） | `pwm_gen`/`encoder_dec`（已完成） |
| 3 | `dvp_capture.v` | 移植 `06-.../02-1_.../src/cmos_i2c/CMOS_Capture_RAW_Gray.v`，先做"采到帧、能数到 HREF/VSYNC 边沿"，再谈识别 | OV5640 配置成功 + 摄像头硬件 |
| 4 | `color_detect.v` / `sign_detect.v` | 颜色顺序 20 + 标识 25；需要先确认镜头视野能同时覆盖前方标识牌与侧方 25 cm 色块（结构件问题） | `dvp_capture` |
| 5 | `oled_driver.v` | 颜色顺序必须在车载屏持续显示到裁判拍照 | `i2c_master` |

**硬件侧并行推进**（长周期项，别等 RTL）：扩展底板打样 —— TB6612 两路、编码器接口、
HC-SR04 的 5 V→3.3 V 分压、电池与 DC-DC、底盘电机。55 分运动类全靠它。

## 5. 子模块开发顺序（按依赖与风险排）

**已完成（2026-11-10）**：`pwm_gen.v` + `encoder_dec.v` 及各自 tb —— 全 PASS；
顶层已例化 2×pwm_gen + 2×encoder_dec（en=0/duty=0 安全待命，编码器计数接入 LED[0] 诊断位），
Efinity 综合验证 EFX_ADD 69 / LUT4 55 / FF 55，EXIT=0。

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

## 5. 硬件清单落点（详见根目录 `赛题二_Ti60F225适配性分析.md` §4.7）

- 已具备：OV5640、TB6612FNG、YB-MUX04 八路循迹、HC-SR04、0.96" OLED。
- 必配：车载电源模块（电池 + DC-DC，电源不得脱离车体 3.2.3②）、直流减速电机 ×2 带轮。
- 强烈建议：光电编码器 ×2。
- 可选：第二路避障（VL53L1X 复用 I2C / E18-D80NK）、广角镜头（一个摄像头兼顾前方标识牌与侧方 25 cm 色块）、电平适配。

## 6. 参考

- GUI 点击流程：根目录 `赛题二_Ti60F225适配性分析.md` 之外，官方录屏 `05_FPGA视频教程/2-易灵思官方/`
  第 2 个（建立和编译工程）、第 3 个（Interface Designer 管脚锁定）、第 4 个（Programmer 下载）。
- 手册：`03_芯片数据手册/efinity-tutorial-trion.pdf` 第 5 页（建工程 17 步）、
  `03_芯片数据手册/efinity-ug.pdf` 第 12 / 16 / 58 页（Project Editor / Dashboard / Programmer）。
