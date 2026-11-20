# tools/ 索引

这里的脚本分四类。**不要给 `tools/` 建子目录**：`.bat` 靠 `%~dp0` 找同目录的 `env.bat`，
`pre-push` 钩子靠 `git config core.hooksPath tools/hooks` 定位，文档和脚本里有 80 多处 `tools/xxx` 路径，
换目录会一次性全部打断。按下面四类找就行。

## 1. 烧录 / 下载（双击可用）

| 脚本 | 作用 | 成功判据 |
| --- | --- | --- |
| `dl.bat [file.bit]` | JTAG 临时配置，**掉电即失**，不碰 Flash | `Device ID read from JTAG: 0x10660A79` + `PROGRAMMING DONE` |
| `flash.bat [file.hex]` | 固化进 SPI Flash，**掉电保留**。三步：桥镜像 → 写 Flash 并读回校验 → 回烧应用 | `Flash verify successful` + `FLASH DONE`（只看退出码不算） |
| `flash_official.cmd` | Efinity 官方 FlashShell 的命令脚本，**本板实测不可用**，仅留作参考 | — |

两者默认镜像都是 `outflow/FpgaCar.bit` / `outflow/FpgaCar.hex`；想烧别的文件就把文件拖到 `.bat` 图标上（读 `%~1`）。

**`flash.bat` 不要改成 `--jtag_bridge_mode erase_and_write`**：该分支在 `ftdi_program.py` 里硬编码
`verify_method='none'`，会打印 `PROGRAMMING DONE`、退出码 0，但完全没校验。2026-11-18 已因此让坏镜像
静默进 Flash，断电重启后黑屏。

## 2. 串口监视 / 数据采集

| 脚本 | 作用 |
| --- | --- |
| `mon.bat [COM12] [秒]` | 读调试串口并汇总各字段（115200-8-N-1） |
| `uart_mon.py` | `mon.bat` 的实现，两行报文的解析逻辑都在这里 |
| `cap.bat [PORT] [秒] [OUT.csv]` | 把遥测抓成 CSV 供离线分析，输出默认落 `data/` |
| `cap.py` | `cap.bat` 的实现 |
| `snap.bat [COM12] [前缀]` | 抓 `frame_snap.v` 的 40×30 缩略图，落 `data/_frame.bmp` / `.csv` |
| `grab_frame.py` | `snap.bat` 的实现。板子只在复位后 1.5 s 发三帧，跑这个时按一下复位键 |

**同一个 COM 口不能被两个进程同时打开**，否则双方都读不到完整报文（表现为 `FRAMES=0`）。

## 3. 点阵 / 图纸生成器

这些脚本的产物是**已入库的源文件**，改参数后要重新生成并一起提交。

| 脚本 | 产物 |
| --- | --- |
| `gen_oled_font.py` | `src/oled_font.v`（30 号中文点阵 ROM） |
| `gen_oled_digits.py` | `src/oled_digits.v`（16×16 数字点阵，`oled_driver` 例化） |
| `gen_pinout_diagram.py` | `docs/引脚分配图.png`，真源是 `docs/引脚分配表.md`，不手抄引脚 |
| `gen_wiring_diagrams.py` | `docs/TB6612接线图.png`、`docs/YB-MUX04接线图.png` |

## 4. 颜色门限离线分析（当前不带摄像头，备用）

| 脚本 | 作用 |
| --- | --- |
| `tune_color.py` | 逐位复刻 `color_detect` 的判定，对门限做网格搜索 |
| `webimg_to_frame.py` | 网图转 CSV，喂给 `tune_color.py` |

只对**像素级**门限（`SAT_MIN` / `YEL_*` / `GRN_DR`）有意义；**帧级**门限（`MIN_PIX` / `DOM_DIV`）
取决于目标占画面大小和背景残留，只能上板抓，用网图搜必然过拟合。

## 5. 基础设施

| 脚本 | 作用 |
| --- | --- |
| `env.bat` | Efinity 2026.1 全套环境变量 + `PYEXE`。所有 `.bat` 都先 `call` 它，手敲命令时别漏 |
| `jtag_program.py` | 修掉 Efinity 自带下载器 `set_up_urls()` 越界 bug 的封装；支持 `jtag` / `jtag_bridge` 等六种模式 |
| `run_regression.sh` | 全量仿真回归门禁，当前 23 个 tb。**改 `src/` 必跑** |
| `hooks/pre-push` | 推送门禁：回归不过不许 push。用 `git config core.hooksPath tools/hooks` 启用 |

## 临时脚本的约定

`tools/_*.py` 是一次性探测脚本，已被 `.gitignore` 排除，**不入库**。用完就删，不要留在目录里；
确实要长期保留的，去掉下划线改成正式名字并补进本索引。