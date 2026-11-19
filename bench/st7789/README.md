# Ti60 ST7789 点屏测试

用于奥唯思 VF-Ti60F225-B 底板和 240×320 的 8 针 ST7789 SPI 屏。
测试程序以 3 MHz SPI 发送 RGB565 测试图案，电机使能、PWM 和方向输出保持为低。

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
左上区域的小方块约每秒在黑白间切换一次。Ti60 的 LED5 慢闪表示 FPGA 在运行，LED0 常亮表示第一帧发送结束。
通过目测完整图案和小方块切换确认屏幕收到数据。

## 仿真

在一个已有的 `.scratch` 目录上运行 Icarus Verilog。

```powershell
iverilog -g2012 -s St7789Bench_tb -o .scratch/st7789.vvp bench/st7789/St7789Bench.v bench/st7789/St7789Bench_tb.v
vvp .scratch/st7789.vvp
```

仿真从 SPI 引脚重组命令和像素，检查完整第一帧、第二帧变化的小方块、复位等待和电机输出。
初始化命令和 SPI 时序依据 [Sitronix ST7789V 数据手册](https://dl.espressif.com/dl/schematics/ST7789V_SPEC_V1.0.pdf)。
