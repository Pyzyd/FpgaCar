# Flash 烧录说明

面向：把这台小车（Efinix Ti60F225 + FT232H 下载器）的位流**固化进板载 SPI Flash**、断电重启仍能自启动的操作者。
假定你已经能综合出 `outflow/FpgaCar.hex`；若还没有，先看第 2 节。

---

## 0. 一句话结论

| 情况 | 用哪个 |
|---|---|
| 正常机器（FT232H 绑定 libusbK） | `cd tools` 后 `cmd.exe /c flash.bat` |
| 报 `ERROR: No USB target detected, aborting!` | `bash tools/flash_hiftdi.sh` |
| 只想临时跑一下、不要求掉电保留 | `cd tools` 后 `cmd.exe /c dl.bat`（易失） |

**成功判据只有一个：日志里出现 `Flash verify successful`。**
退出码 0 不算数 —— Efinity 有一条零校验分支同样返回 0（见第 5 节）。

---

## 1. 前提

### 1.1 硬件

| 项 | 值 |
|---|---|
| FPGA | Efinix Titanium **Ti60F225**（工程里 `--family Titanium --device Ti60F225`） |
| JTAG ID | **0x10660A79** |
| 下载器 | **FT232H**，USB `VID_0403` / `PID_6014`（常见型号 ELITES-232DL） |
| 板载配置 Flash | **Winbond W25Q64，8 MiB**，JEDEC `0xEF6017` |
| 调试串口 | **CH340 → COM12**，115200-8-N-1 |

**供电要点（最容易白折腾一条）**：核心板上的 USB-Mini 口**只给 CH340 供电，不给整板供电**。
整板必须另有电源（电池 / 船型开关打开）。整板没电时 JTAG 也能读出 `0xFFFFFFFF`，
而工具照样打印 `PROGRAMMING DONE` —— 看起来像成功。判断顺序：

1. 核心板 **D9** 是否常亮（`VDD3V3 → R42 4.7K → D9 → GND`，全板唯一的电源指示灯）
2. 按钮板船型开关 SS-12D11G5R 有没有被碰关
3. 六颗 LED 全灭 + OLED 黑屏 + JTAG 读 `0xFFFFFFFF` 三件事同时出现 = 没电

### 1.2 软件

| 项 | 值 |
|---|---|
| Efinity | **2026.1**，默认装在 `C:\Efinity\2026.1` |
| Python | Efinity 自带 `C:\Efinity\2026.1\python311\bin\python.exe` |
| 工程根 | `D:\VF-Ti60F225_HDK_V2.1_20251009\FpgaCar`（下称“工程根”） |

换机器时路径会变，见第 9 节。

---

## 2. 位流从哪来（必须先做对这一步）

从 RTL 到可烧写的文件要跑**三个阶段**，缺一不可：

| 阶段 | 命令（在工程根下） | 产物 |
|---|---|---|
| `map` | `C:\Efinity\2026.1\bin\efx_run.bat --flow map FpgaCar.xml` | `outflow/FpgaCar.vdb`、`FpgaCar.map.v` |
| `pnr` | `C:\Efinity\2026.1\bin\efx_run.bat --flow pnr FpgaCar.xml` | 布局布线结果、时序报告 |
| `pgm` | `C:\Efinity\2026.1\bin\efx_run.bat --flow pgm FpgaCar.xml` | **`outflow/FpgaCar.bit`** 和 **`outflow/FpgaCar.hex`** |

> ⚠️ **改了 RTL 必须从 `--flow map` 重跑。**
> 只跑 `--flow pnr` 时它用 `--vdb_file outflow\FpgaCar.vdb` 当输入，综合网表还是旧的，
> 位流时间戳甚至都可能不变，于是你烧进去的仍是上一版逻辑。
> 判断办法：看 `outflow/FpgaCar.bit` 的修改时间，或者 `outflow/FpgaCar.map.out` 里
> `Hierarchical pre-synthesis` 段落有没有带上你刚改的参数值。

**烧进 Flash 的是 `.hex` 不是 `.bit`**。两者内容一致、格式不同；脚本默认取 `outflow/FpgaCar.hex`。

---

## 3. 两个烧录脚本的区别

| | `tools/flash.bat` | `tools/flash_hiftdi.sh` |
|---|---|---|
| 下载器后端 | pyftdi + **libusb** | Efinity 自带 **HiFTDI(D2XX)**，走 `C:\Windows\system32\ftd2xx.dll` |
| 对驱动的要求 | FT232H 必须绑定 **libusbK** | 不需要，任何 FTDI 驱动都能用 |
| 第 2 步校验方式 | `--verify_method hostx1`（PC 回读比对 SHA1） | `--verify_method onchipx1`（Flash 装载器片上 CRC） |
| JTAG 时钟 | 板级默认（3 MHz） | 显式 `--jtag_clock_freq 1500000`（1.5 MHz） |
| 成功判据 | `findstr` 三重检查日志（见第 5 节） | `grep 'Flash verify successful'` |
| 运行环境 | Windows `cmd` | MSYS/Git-Bash `bash` |

两者**都做三步**（bridge → 写 Flash → 回烧应用），只是走的 USB 通道不同。
优先用 `flash.bat`；它跑不通再换 `flash_hiftdi.sh`。

---

## 4. 为什么必须三步

1. **SPI Active 直连不可用。**
   本板 FT232H 只引到 JTAG 引脚，CCK/CS 不在 FTDI 排针上。
   直接烧会报 `ERROR: Unknown error trying to read flash device, aborting`。
2. **Flash 只能经 JTAG→SPI bridge 访问**，而 bridge 本身是一个必须先跑起来的位流。
   Efinity 自带预编译镜像 `C:\Efinity\2026.1\pgm\fli\titanium\u10660A79.bit`。
   不先装它会报 `Unsupported JTAG Bridge version: 255.255`。
3. **写完 Flash 后 FPGA 里跑的是 bridge 设计**，必须回烧应用位流 `outflow/FpgaCar.bit`，
   否则小车不工作（所以第 3 步不是可选的）。

> 桥镜像的 die 型号必须和板子一致：`u10660A79.bit` 对应 JTAG ID `0x10660A79`。
> 用成 `u10661A79.bit`（另一个 die）会报桥版本 0.0。

---

## 5. 正常流程：`tools/flash.bat`

### 5.1 怎么调用

在 **MSYS/Git-Bash** 里：

```bash
cd /d/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/tools
cmd.exe /c flash.bat
```

或者在 Windows `cmd` 里直接 `cd tools` 然后 `flash.bat`。

可以带一个参数烧别的 hex：`flash.bat other.hex`。

**两个坑（都可复现）**：

- 别用 `cmd //c flash.bat` —— MSYS 下不会真正执行，只会弹一个交互式 cmd 然后返回。
- 别用 `| head -N` / `| tail` 截断输出 —— 会在第 2 步写 Flash 途中把进程杀掉，得到半截镜像。

### 5.2 它做了什么

```text
[1/3] Loading JTAG-to-SPI bridge image ...
      jtag_program.py -m jtag -u ftdi://0x0403:0x6014:0:ff/1 -x _jtag.jcf -n 1 u10660A79.bit
[2/3] Writing outflow/FpgaCar.hex into SPI flash ...
      jtag_program.py -m jtag_bridge --jtag_bridge_mode all --verify_method hostx1 ...
      日志落到 outflow/flash_write.log
[3/3] Restoring application bitstream ...
      jtag_program.py -m jtag ... outflow/FpgaCar.bit
FLASH DONE
```

### 5.3 判据为什么是三重 findstr

`flash.bat` 不信任退出码，要求日志同时满足：

| 检查 | 含义 |
|---|---|
| 出现 `from flash` | 说明真的发生了回读（没有回读就没有验证） |
| 出现 `Flash verify successful` | 比对结论是通过 |
| **不出现** `Flash verify unsuccessful` | 防“重试一次成功”掩盖了第一遍 mismatch |

这不是啰嗦。`--jtag_bridge_mode erase_and_write` 这条分支在 `ftdi_program.py` 里
被硬编码成 `verify_method='none'`：不校验、直接打印 `PROGRAMMING DONE`、退出码 0。
2026-11-18 实测走过这条路径，坏镜像被写了进去，断电重启后板子直接黑屏。
**所以不要用 `erase_and_write`**，用 `all`（擦→写→回读比对）。

---

## 6. 备用流程：`tools/flash_hiftdi.sh`

### 6.1 什么时候用它

`flash.bat` / `dl.bat` 报下面这条，就是驱动不对：

```text
[1/3] Loading JTAG-to-SPI bridge image ...
ERROR: No USB target detected, aborting!
FLASH FAILED
```

原因：Efinity 的下载器走 pyftdi + libusb，要求 FT232H 绑定 **libusbK**；
而这颗 FT232H 常被 FTDI 官方 `ftdibus.inf` 按 rank 抢走：

```text
pnputil /enum-devices /instanceid "USB\VID_0403&PID_6014\..." /drivers
  oem126.inf  ftdibus.inf        FTDI     2.12.36.20   Best Ranked / Installed
  oem128.inf  elites-232dl.inf   libusbK  3.0.7.0      Outranked
```

换 USB 口无效（新枚举出来的节点一样落 FTDIBUS）。装 libusbK 要管理员权限跑 Zadig；
**不想动驱动就用 HiFTDI 后端**。

### 6.2 怎么用

```bash
cd /d/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar
bash tools/flash_hiftdi.sh                    # 烧 outflow/FpgaCar.hex
bash tools/flash_hiftdi.sh path/to/other.hex  # 烧指定文件
```

脚本会自己 `export` 全部 Efinity 环境变量并置 `EFX_HIFTDI_ENABLE=1`，不用先跑 `env.bat`。

### 6.3 为什么脚本默认**不传** `-u`

`tools/flash_hiftdi.sh` 里 `URL=''`、`UARG=()`，默认让后端自己枚举设备。
这是踩过坑之后改的：显式给 `hiftdi://0x0403:0x6014/-1` 或 `ftdi://...` 都会报

```text
ERROR: Specified FTDI URL could not be matched to any connected USB targets
```

而设备本身是好的（`Get-PnpDevice -PresentOnly` 能看到 `VID_0403&PID_6014`，libusbK 正常）。
不传 `-u` 反而稳定，日志会打出实际枚举结果：

```text
INFO: usb_targets=1, raw url_list=['ftdi://0x0403:0x6014:0:ff/1']
```

只有**机器上插了多个 FT232H、必须指定某一个**时才填 `URL`，值从上面那行 INFO 里抄。

### 6.4 它做了什么

```text
[1/3] 装 JTAG 桥镜像          -> Device ID read from JTAG: 0x10660A79 / PROGRAMMING DONE
[2/3] 写 Flash 并校验          -> 擦 660 KiB / 写 657 KiB / 读回 657 KiB
[3/3] 回烧应用位流            -> PROGRAMMING DONE
FLASH DONE
```

第 2 步的完整日志固定写到 `.scratch/flash_hiftdi.log`，失败时先看它。

### 6.5 该后端的三处官方 bug（已在脚本里绕过）

`tools/hiftdi_runner.py` 在运行时 monkeypatch（不改 Efinity 安装文件）：

| # | 位置 | 毛病 | 补丁 |
|---|---|---|---|
| 1 | `hiftdi/jtag.py:448` | `configure(self, url)` 只收 1 个参数，`efx_dbg/jcf.py:795` 传 2 个 → `TypeError` | 包一层只取 url |
| 2 | `efx_hw_common/manager.py:252-253` | hiftdi 的 `JTAGFINEGRAIN` 分支被注释掉，而 `--jtag_bridge_mode` 恰好强制走它 → `NotImplementedError` | 让 `hiftdi://` + `JTAGFINEGRAIN` 返回 `hj.JtagEngine` |
| 3 | `hiftdi/jtag.py` 的 `write_tms` / `write` | 链式引擎会传 0 位 TMS 和裸 `bytes`，两者都不被接受 | 0 位 TMS 直接返回；bytes 拆成 bit 序列 |

以后升级 Efinity 版本，若这三处被官方修好，这个 runner 可以退役。

---

## 7. 烧完怎么确认成功

### 7.1 日志（必须看）

两个脚本共用同一条判据：**`Flash verify successful`**。

```text
Flash device: Winbond W25Q64 8 MiB (JEDEC ID: 0xEF6017)
Erasing ...
Writing ...
Reading ...
Flash verify successful
```

**第一遍出现 `ERROR: Flash verify unsuccessful... mismatch found` 是正常的**，
`--jtag_bridge_mode all` 会自动重试一轮，第二遍才通过。只要最终有 `verify successful` 即成功。
但如果两遍都失败，说明写进去的内容确实不对，别急着断电重启。

### 7.2 串口（确认新逻辑真的在跑）

```bash
cd /d/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/tools
cmd.exe /c "mon.bat COM12 5"     # 读 5 秒调试串口
```

帧率约每 60 ms 两行。能收到遥测就说明应用位流起来了（收到的是 bridge 的话不会有这些字段）。
更细的分析用 `python bench/serial_tool.py watch --sec 20` 或 `analyze --csv <文件>`。

### 7.3 独立性检查（可选，最稳）

单独把 Flash 内容回读出来比对：

```bash
python tools/hiftdi_runner.py -m jtag_bridge --jtag_bridge_mode read \
  --num_bytes 687104 ... > .scratch/rb.hex
```

再与 `outflow/FpgaCar.hex` 逐字节比较，应当 `diff bytes 0`。

---

## 8. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `ERROR: No USB target detected, aborting!` | FT232H 绑的是 FTDI 官方驱动，不是 libusbK | 改用 `bash tools/flash_hiftdi.sh` |
| `ERROR: Specified FTDI URL could not be matched to any connected USB targets` | 脚本里显式指定的 `-u` 地址与当前枚举不符 | 清空 `URL`（脚本默认已是空的），或从 `INFO: raw url_list=[...]` 抄正确值 |
| `Unsupported JTAG Bridge version: 255.255` | 第 1 步没成功，FPGA 里没有 bridge | 先确认第 1 步打印了 `PROGRAMMING DONE`；确认桥镜像路径与 die 型号（`u10660A79.bit`） |
| `ERROR: Unknown error trying to read flash device, aborting` | 走了 SPI Active 直连（本板没接 CCK/CS） | 不要用 `spi` 模式；必须走 JTAG→SPI bridge |
| `Device ID read from JTAG: 0xFFFFFFFF` 但仍打印 `PROGRAMMING DONE` | **整板没电**（USB-Mini 只给 CH340 供电） | 查 D9 常亮 / 船型开关；整板另接电源 |
| `Cannot unprotect flash device` / `Command timeout` / JEDEC 读出乱码 | 设备在 libusb 路径下根本打不开 | 换 `flash_hiftdi.sh`；这类报错下测出的“Flash 物理故障”结论全部无效 |
| `KeyError: 'EFINITY_USER_DIR'` 或 `No module named 'encodings'` | 没设 Efinity 环境变量 | `flash.bat` 会 `call env.bat`；手敲命令时先跑 `env.bat` |
| `PermissionError: [Errno 13]` 指向 `C:\Users\<你>\.efinity` | Efinity 默认用户目录不可写 | `EFINITY_USER_DIR` 指到工程内 `.scratch\efuser`（`env.bat` 已这样做） |
| 烧完断电重启板子是黑的 | 写了坏镜像 / 没校验 / 用了 `erase_and_write` | 重烧并确认 `Flash verify successful`；禁用 `erase_and_write` |
| 第 2 步中途失败、镜像半截 | 输出被 `\| head` 截断导致进程被杀 | 不要在管道里调用 |
| 串口完全没输出 | CH340 没枚举 / 旧位流 / 烧录失败 | `Get-PnpDevice -PresentOnly -Class Ports` 查 COM12；重烧 |

---

## 9. 换一台电脑 / 给别人用时要改什么

### 9.1 Efinity 安装路径

如果 Efinity 不在 `C:\Efinity\2026.1`，要改两处：

- `tools/env.bat`：`EFINITY_HOME`、`EFXPT_HOME`、`EFXPGM_HOME`、`EFXDBG_HOME`、`EFXSVF_HOME`、
  `PYTHONHOME`、`PYTHONPATH`、`QT_PLUGIN_PATH`、`PYEXE`
- `tools/flash_hiftdi.sh`：脚本开头的同名 `export` 一段（共 6 行路径）

版本不同也可能要改：桥镜像路径 `pgm/fli/titanium/u10660A79.bit` 与 monkeypatch 的源码行号。

### 9.2 用户目录

`EFINITY_USER_DIR` / `EFINITY_USER_DIR_INI` 必须指向**可写**目录。
两个脚本都指到工程内 `.scratch\efuser`，别改回默认的 `C:\Users\<你>\.efinity`。

### 9.3 JTAG 链文件 `_jtag.jcf`

工程根的 `_jtag.jcf` 描述 JTAG 链，内容是：

```xml
<?xml version="1.0" ?>
<chain>
	<device chip_num="1" id_code="0x10660a79" ir_width="5" istr_code="11000"/>
</chain>
```

换板子/换 die 时要重新生成：`jtag_chain_detect.py -f <url> -o _jtag.jcf`。
缺这个文件两个脚本都会直接报 `JTAG chain file missing`。

### 9.4 USB 地址

`flash.bat` / `dl.bat` 里写死 `ftdi://0x0403:0x6014:0:ff/1`。
接了别的下载器（FT2232H、带序列号、或多颗 FT232H）时，从日志的
`INFO: raw url_list=['...']` 抄实际值替换。

### 9.5 驱动

对方机器上 `flash.bat` 能跑就不用管驱动；跑不了就用 `flash_hiftdi.sh`，
它只要求系统有 `C:\Windows\system32\ftd2xx.dll`（装过 FTDI 官方驱动就有）。
想彻底修好 `flash.bat` 的话，用 Zadig 把 FT232H 的驱动换成 **libusbK**（需管理员）。

---

## 10. 附：文件与环境变量

### 10.1 相关文件

| 文件 | 作用 |
|---|---|
| `outflow/FpgaCar.hex` | 要烧的镜像（默认） |
| `outflow/FpgaCar.bit` | 同一份位流，第 3 步回烧用 |
| `outflow/flash_write.log` | `flash.bat` 第 2 步日志 |
| `.scratch/flash_hiftdi.log` | `flash_hiftdi.sh` 第 2 步日志 |
| `_jtag.jcf` | JTAG 链描述，必须在工程根 |
| `tools/env.bat` | Efinity 2026.1 全套环境变量（cmd 用） |
| `tools/jtag_program.py` | 修复 Efinity 下载器 `set_up_urls()` 越界 bug |
| `tools/hiftdi_runner.py` | HiFTDI 后端三处 monkeypatch |
| `tools/flash.bat` | 三步固化（libusb 路径） |
| `tools/flash_hiftdi.sh` | 三步固化（D2XX 路径） |
| `tools/dl.bat` | 只做 JTAG 易失下载 |
| `tools/mon.bat` | 读调试串口 |

### 10.2 环境变量清单

两个脚本都必须有下面这些，缺一个就会在很晚的阶段报莫名其妙的错：

| 变量 | 值 |
|---|---|
| `EFINITY_HOME` | `C:/Efinity/2026.1` |
| `EFXPT_HOME` | `C:/Efinity/2026.1/pt` |
| `EFXPGM_HOME` | `C:/Efinity/2026.1/pgm` |
| `EFXDBG_HOME` | `C:/Efinity/2026.1/debugger` |
| `EFXSVF_HOME` | `C:/Efinity/2026.1/debugger/svf_player` |
| `EFINITY_USER_DIR` | `<工程根>/.scratch/efuser` |
| `EFINITY_USER_DIR_INI` | `<工程根>/.scratch/efuser/efinity.ini` |
| `PYTHONHOME` | `C:\Efinity\2026.1\python311` |
| `PYTHONPATH` | `C:\Efinity\2026.1\debugger\bin;C:\Efinity\2026.1\pgm\bin` |
| `QT_PLUGIN_PATH` | `C:/Efinity/2026.1/python311` |
| `EFX_HIFTDI_ENABLE` | `1`（**仅 `flash_hiftdi.sh` 需要**，它让下载器走 D2XX 后端） |

### 10.3 另外两条路（一般不用）

- **官方命令行，只做 JTAG 易失下载**，约 14 s：
  ```bat
  cd /d D:\VF-Ti60F225_HDK_V2.1_20251009\FpgaCar
  C:\Efinity\2026.1\bin\efx_run.bat FpgaCar.xml --flow program --pgm_opts mode=jtag
  ```
  **design 位置参数必须在最前**，`--flow` 放后面。这条路不需要 `jtag_program.py` 补丁，
  但**不写 Flash**，掉电就丢。

- **官方 FlashShell（`pgm\flashshell\flashshell.py`）：在本机不可用。**
  `auto_config -t jtag` 报 `'FlashJtagManager' object has no attribute 'add_debug_profile'`（安装包内部版本不一致）；
  `spi` 分支要求 FTDI 直连 CCK/CS，本板排针没有。

---

## 11. 一页速查

```text
# 1) 改了 RTL 就先重综合（必须从 map 起）
C:\Efinity\2026.1\bin\efx_run.bat --flow map FpgaCar.xml
C:\Efinity\2026.1\bin\efx_run.bat --flow pnr FpgaCar.xml
C:\Efinity\2026.1\bin\efx_run.bat --flow pgm FpgaCar.xml

# 2) 烧进 Flash
cd tools && cmd.exe /c flash.bat        # 报 No USB target 就改用下面这条
bash tools/flash_hiftdi.sh

# 3) 确认
#    日志必须有：Flash verify successful
cmd.exe /c "mon.bat COM12 5"           # 串口有遥测 = 应用位流在跑
```
