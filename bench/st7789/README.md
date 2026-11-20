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
iverilog -g2012 -s St7789Bench_tb -o .scratch/st7789.vvp src/st7789_panel.v bench/st7789/St7789Bench.v bench/st7789/St7789Bench_tb.v
vvp .scratch/st7789.vvp
```

面板驱动（`st7789_panel` + `st7789_spi_byte`）已经抽到 `src/st7789_panel.v`，
主工程和本 bench 共用这一份，bench 目录下不再留副本。单独的驱动回归用
`sim/st7789_panel_tb.v`，它把 `CLK_HZ` 缩小 1000 倍，在几百微秒里逐字节断言
初始化命令序列（SWRESET / SLPOUT / COLMOD / MADCTL / INVON / CASET / RASET / NORON / DISPON / RAMWR）：

```powershell
iverilog -g2012 -s st7789_panel_tb -o .scratch/st7789_panel.vvp src/st7789_panel.v sim/st7789_panel_tb.v
vvp .scratch/st7789_panel.vvp
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

后摄用 OV5640 的 640×480 RGB565 模式。SCCB 把读取窗口扩到 4∶3 全阵列，启用合并采样和 ISP 缩放。
原 720p 模式的纵向寄存器窗口是 250–1705 行，新模式是 0–1951 行，两者横向寄存器窗口均为 0–2623 列。
板上实际视野由模组镜头和安装决定，可固定镜头后对比两版的画面边缘。
FPGA 每 4×4 像素取一个样本并转为 Y8，缓存 160×120 图，再按 2×2 放大，完整铺满 320×240 横屏。
预览在 750 kHz 下约每 1.8 秒刷新一帧。
如果暂时没有完整有效的摄像头帧，LCD 显示原有的彩色条纹测试图。
取景窗口参照 [Espressif 的 OV5640 4∶3 模式表](https://github.com/espressif/esp32-camera/blob/master/sensors/private_include/ov5640_settings.h)。

台架上已从彩条切换到后摄灰度图。采集按 VSYNC 上升沿切帧，用 HREF 判有效数据。
这块屏在 `INVON` 时黑白反相，灰度预览采用 ST7789 的 `INVOFF` 命令。

| 指示灯 | 含义 |
| --- | --- |
| LED5 慢闪 | FPGA 程序运行 |
| LED0 亮 | 已发送完一张 LCD 画面 |
| LED1 亮 | SCCB 配置表已发送完 |
| LED2 亮 | 最近的统计窗口内收到过 OV5640 的 VSYNC |
| LED3 亮 | 已发送完至少一张有效灰度图 |

对着摄像头移动手或纸，等待几次刷新，检查图像内容是否随之改变。
仿真用例 `ov5640_preview_frame_tb.v` 覆盖非法行长、19,200 个灰度样本和显示锁帧期间的缓存保护。

## 复位脚：K1/K2 按键版底板

`make_project.py` 生成工程时会读 `FpgaCar.peri.xml`，按 `key_start_n` → `key_stop_n` → `rst_n` 的顺序挑第一个存在的引脚当复位源，
再把生成的约束块名统一改回 `rst_n`（RTL 端口名必须与约束块名一致）。

2026-11-20 合并进 main 时底板已改成 K1/K2 双按键，没有 `rst_n` 这个约束块，
按旧模板直接生成会报 `Missing Ti60 board pins: ['rst_n']`。现在自适应，两种底板都能生成。
按 K1 即复位 bench（bench 不跑车，只是重新初始化屏幕和摄像头）。

## 与主工程的关系

本目录是**独立工程**，不参与主工程 `FpgaCar.xml` 的综合，也不进 `tools/run_regression.sh` 的 23 个 tb。
两个测试台需要手动跑：

```bash
iverilog -g2012 -s St7789Bench_tb -o .scratch/st7789.vvp bench/st7789/St7789Bench.v bench/st7789/St7789Bench_tb.v
vvp .scratch/st7789.vvp
iverilog -g2012 -s ov5640_preview_frame_tb -o .scratch/preview.vvp bench/st7789/ov5640_preview_frame.v bench/st7789/ov5640_preview_frame_tb.v
vvp .scratch/preview.vvp
```

唯一与主工程共用的源文件是 `src/cam_sccb_cfg.v`：本目录的 OV5640 预览用 `FULL_FOV_VGA=1` 切到 4∶3 全阵列，
主工程默认 `FULL_FOV_VGA=0` 走原 720p 表，行为不变。
