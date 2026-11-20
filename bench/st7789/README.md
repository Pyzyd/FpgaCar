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

## OV5640 串口拍照

串口台架 `Ov5640UartBench` 使用 OV5640 的 VGA 全视野模式。每 2×2 区域取一个样本，保存 **320×240 灰度 PNG**。测试工程将电机驱动置于停机状态。将 OV5640 接到 `DVP Sensor`，用板载 CH340N 的 Mini-USB 口连接电脑。

在仓库根目录生成工程，在 Efinity 编译 `Ov5640UartBench.xml`，然后用 JTAG 临时加载：

```powershell
python bench/st7789/make_project.py .scratch/ov5640-uart-bench --snapshot
tools\dl.bat .scratch\ov5640-uart-bench\outflow\Ov5640UartBench.bit
```

摄像头准备好后 LED1、LED3 点亮。用 `python -m serial.tools.list_ports` 查 CH340N 的端口号。把下面的 `COM12` 换成实际端口：

```powershell
python tools/ov5640_capture.py COM12 data/ov5640_capture/turn_point.png
```

电脑发送 `S` 后，FPGA 从下一张完整画面取样。串口是 **115200、8N1**，每张传输约 6.7 秒。传完 LED0 点亮，电脑校验尺寸和 CRC32 后保存 PNG。省略输出路径时，文件按时间命名，落在 `data/ov5640_capture/`。拍不同位置时使用新文件名，已有照片会保留。电脑端依赖 `pyserial`。

数据包依次为 `OVS1`、宽和高（各 16 位小端）、从上到下且每行从左到右的灰度字节、像素数据的 CRC32（32 位小端）。像素和摄像头的输入图保持同一视角，便于标注车库两角。

## 复位脚：K1/K2 按键版底板

`make_project.py` 生成工程时会读 `FpgaCar.peri.xml`，按 `key_start_n` → `key_stop_n` → `rst_n` 的顺序挑第一个存在的引脚当复位源，
再把生成的约束块名统一改回 `rst_n`（RTL 端口名必须与约束块名一致）。

2026-11-20 合并进 main 时底板已改成 K1/K2 双按键，没有 `rst_n` 这个约束块，
按旧模板直接生成会报 `Missing Ti60 board pins: ['rst_n']`。现在自适应，两种底板都能生成。
按 K1 即复位 bench（bench 不跑车，只是重新初始化屏幕和摄像头）。

## K1 拍照与电脑相册（720p）

独立工程 `Ov5640DdrSnapshot` 将 OV5640 配置为 1280×720，每张保存 900 KiB 原始灰度像素。
板载 DDR3 可保存 **64 张**，编号按拍摄顺序从 01 到 64。拍满后保留这 64 张，K1 暂停接收。
坏帧不会入册或占用编号。拍摄时可以拔掉电脑串口，保持 Ti60 供电。重新下载位流或断电会清空相册。

1. 将 OV5640 接到 `DVP Sensor`。通过 JTAG 临时加载 `Ov5640DdrSnapshot.bit`，电机控制输出处于停机状态。
2. 等 LED1、LED2、LED3 亮，分别表示摄像头配置写完、检测到帧同步、DDR3 校准通过。
3. 每短按一次 K1 拍一张，等 LED4 熄灭再拍下一张。LED0 常亮表示有图，慢闪表示已拍满。LED4 在拍摄、传输和出错时亮，LED5 为心跳。
4. 用 **板载 CH340N Mini-USB 串口**连接电脑。启动相册，选串口，点击「读取相册」。

```powershell
python tools/ov5640_album.py
```

相册使用 Python 自带的 Tkinter 和 `pyserial`。点选照片即可看 160×90 缩略图。
「导出选中」保存所选照片的原始 1280×720 PNG。「全部导出」在所选目录下建立一组照片，按编号保存。
460800 8N1 下原图约 20 秒一张。停止批量导出会先保存当前照片，随后停止。导出完成后可继续按 K1 拍摄。
如果拍摄后 LED4 持续亮，重新短按 K1 可重试已结束的失败拍摄，已有完整图仍可导出。

`tools/ov5640_capture.py COM12 --stored` 仍可直接导出最后一张。相册状态使用 `L` 查询，
响应 `OVA1` 加三个单字节字段（照片数、容量、状态）。状态 bit0 表示摄像头和 DDR3 就绪、bit1 表示拍摄中、bit2 表示出错。
`G` 读取原图，`T` 读取缩略图，后面都跟一个从 1 开始的原始编号字节。
图像沿用 `OVS1` 帧和 CRC32 校验。若指定照片不可读，板子返回 `N`。

重新编译时，从奥唯思 Ti60 资料里找到带有 `Ti60_Demo.peri.xml` 和 `ip/DdrCtrl` 的
`02-1_Ti60_OV5640_LCD-HDMI_1080P60` 工程。生成脚本使用其中的 DDR3 引脚、PLL 和控制器文件。

```powershell
python bench/st7789/make_ddr_snapshot_project.py .scratch/ov5640-ddr-album "<奥唯思示例工程路径>"
```

在 Efinity 编译生成目录内的 `Ov5640DdrSnapshot.xml`，产物位于该目录的 `outflow`。
临时调试可使用 `tools\dl.bat .scratch\ov5640-ddr-album\outflow\Ov5640DdrSnapshot.bit`。
如果 Ti60 的 Flash 内已有小车程序，JTAG 临时版在下一次重新上电时会自动恢复 Flash 内的程序。
`Ov5640DdrSnapshot.hex` 可用于需要断电后自动启动拍照程序时。

## 与主工程的关系

本目录是**独立工程**，不参与主工程 `FpgaCar.xml` 的综合，也不进 `tools/run_regression.sh` 的 23 个 tb。
测试台可手动运行：

```bash
iverilog -g2012 -s St7789Bench_tb -o .scratch/st7789.vvp bench/st7789/St7789Bench.v bench/st7789/St7789Bench_tb.v
vvp .scratch/st7789.vvp
iverilog -g2012 -s ov5640_preview_frame_tb -o .scratch/preview.vvp bench/st7789/ov5640_preview_frame.v bench/st7789/ov5640_preview_frame_tb.v
vvp .scratch/preview.vvp
iverilog -g2012 -s ov5640_uart_snapshot_tb -o .scratch/snapshot.vvp bench/st7789/ov5640_uart_snapshot_tb.v bench/st7789/ov5640_uart_snapshot.v bench/st7789/ov5640_preview_frame.v src/uart_tx.v
vvp .scratch/snapshot.vvp
iverilog -g2012 -s ov5640_ddr_snapshot_tb -o .scratch/snapshot720.vvp bench/st7789/ov5640_ddr_snapshot_tb.v bench/st7789/ov5640_photo_capture.v bench/st7789/ov5640_photo_fifo.v bench/st7789/ov5640_photo_store.v bench/st7789/ov5640_uart_snapshot.v src/uart_tx.v
vvp .scratch/snapshot720.vvp
```

独立工程复用主工程的摄像头初始化和串口发送模块。本目录的 OV5640 全视野预览用 `FULL_FOV_VGA=1` 切到 4∶3 全阵列，
主工程默认 `FULL_FOV_VGA=0` 走原 720p 表，行为不变。
