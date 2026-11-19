# Ti60 ST7789 点屏测试

用于奥唯思 VF-Ti60F225-B 底板和 240×320 的 8 针 ST7789 SPI 屏。
测试程序以 750 kHz SPI 发送 RGB565 测试图案，电机使能、PWM 和方向输出保持为低。
初始化含硬件复位、软件复位和唤醒，每条初始化命令与它的参数共用一个独立的 CS 事务。

2026-11-19 台架实测，750 kHz 版通过 JTAG 临时下载后，屏幕显示图案，左上角方块持续切换。
首版 3 MHz 和简化初始化的组合只有背光。两项同时调整，单项影响尚未验证。

| LCD 丝印 | Ti60 P4 物理针号 | FPGA 端口 |
| --- | ---: | --- |
| SCL | 35 | `lcd_sclk` |
| SDA | 36 | `lcd_mosi` |
| A0 | 37 | `lcd_dc` |
| RESET | 38 | `lcd_rst_n` |
| CS | 40 | `lcd_cs_n` |
| GND | 12 或公共地 | — |
| VCC | 外部稳压 3.3 V，与 Ti60 共地 | — |

P4 第 39 脚用于 K230 的 `STB`。背光沿用模块上已验证的接法。

## 生成和下载

在仓库根目录运行以下命令，将工程生成到一个独立目录。

```powershell
python bench/st7789/make_project.py .scratch/st7789-bench
```

在 Efinity 打开生成的 `St7789Bench.xml`，运行 Compile，生成 `outflow/St7789Bench.bit`。
保持电机侧断电，给 Ti60 和屏幕供电，使用 JTAG 临时下载到 FPGA。
本仓库在 Windows 的 FT232H 下载方式如下。

```powershell
New-Item -ItemType Directory -Force .scratch/efuser | Out-Null
tools\dl.bat .scratch\st7789-bench\outflow\St7789Bench.bit
```

屏幕应出现白边。上半部分依次为红、绿、蓝，中间为黑、灰、白，底部为从黑到白的灰阶。
左上区域的小方块约每两秒在黑白间切换一次。Ti60 的 LED5 慢闪表示 FPGA 在运行，LED0 常亮表示第一帧发送结束。
通过目测完整图案和小方块切换确认屏幕收到数据。

## 仿真

在一个已有的 `.scratch` 目录上运行 Icarus Verilog。

```powershell
iverilog -g2012 -s St7789Bench_tb -o .scratch/st7789.vvp bench/st7789/St7789Bench.v bench/st7789/St7789Bench_tb.v
vvp .scratch/st7789.vvp
```

仿真从 SPI 引脚重组命令和像素，检查完整第一帧、第二帧变化的小方块、复位等待和电机输出。
初始化命令和 SPI 时序依据 [Sitronix ST7789V 数据手册](https://dl.espressif.com/dl/schematics/ST7789V_SPEC_V1.0.pdf)。

## OV5640 灰度预览

断电时把匹配这块底板的 OV5640 模组接到 `DVP Sensor`。LCD 沿用上表，电机侧保持断电。
在仓库根目录生成独立工程，在 Efinity 编译 `Ov5640LcdBench.xml` 后用 JTAG 临时下载。

```powershell
python bench/st7789/make_project.py --camera .scratch/ov5640-lcd-bench
tools\dl.bat .scratch\ov5640-lcd-bench\outflow\Ov5640LcdBench.bit
```

OV5640 沿用原工程的 1280×720 RGB565 配置。FPGA 每 8×8 像素取一个样本并转成 Y8，缓存整张 160×90 图。
LCD 横向显示 320×180 的 16∶9 图像，上下各留 30 行黑边。预览在 750 kHz 下约每 1.8 秒刷新一帧。
如果暂时没有完整有效的摄像头帧，LCD 显示原有的彩色条纹测试图。

| 指示灯 | 含义 |
| --- | --- |
| LED5 慢闪 | FPGA 程序运行 |
| LED0 亮 | 已发送完一张 LCD 画面 |
| LED1 亮 | SCCB 配置表已发送完 |
| LED2 亮 | 最近的统计窗口内收到过 OV5640 的 VSYNC |
| LED3 亮 | 已发送完至少一张有效灰度图 |

对着摄像头移动手或纸，等待几次刷新，检查图像内容是否随之改变。
仿真用例 `ov5640_preview_frame_tb.v` 覆盖了非法行长、14,400 个灰度样本和显示锁帧期间的缓存保护。
