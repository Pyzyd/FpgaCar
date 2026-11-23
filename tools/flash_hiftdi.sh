#!/bin/bash
# 用 HiFTDI(D2XX) 后端把位流烧进 SPI Flash —— FT232H 没绑定 libusbK 时的备用路径。
#
# 为什么需要：dl.bat / flash.bat 走 pyftdi + libusb，要求 FT232H 绑定 libusbK。
# 若被 FTDI 官方 ftdibus.inf 抢到，一律报 ERROR: No USB target detected, aborting!。
# 这里改用 Efinity 自带的 D2XX 后端（ftd2xx.dll），不需要管理员权限装驱动。
#
# 用法：
#   bash tools/flash_hiftdi.sh                       # 烧 outflow/FpgaCar.hex
#   bash tools/flash_hiftdi.sh path/to/other.hex     # 烧指定文件
#
# 成功判据：日志出现 Flash verify successful。第一遍 mismatch 是正常的，
# 工具会自动重试一轮，不要只看退出码。
set -u
cd "$(dirname "$0")/.." || exit 1

export EFINITY_HOME='C:/Efinity/2026.1'
export EFXPT_HOME='C:/Efinity/2026.1/pt'
export EFXPGM_HOME='C:/Efinity/2026.1/pgm'
export EFXDBG_HOME='C:/Efinity/2026.1/debugger'
export EFXSVF_HOME='C:/Efinity/2026.1/debugger/svf_player'
export EFINITY_USER_DIR='D:\VF-Ti60F225_HDK_V2.1_20251009\FpgaCar\.scratch\efuser'
export EFINITY_USER_DIR_INI='D:\VF-Ti60F225_HDK_V2.1_20251009\FpgaCar\.scratch\efuser\efinity.ini'
export PYTHONHOME='C:\Efinity\2026.1\python311'
export PYTHONPATH='C:\Efinity\2026.1\debugger\bin;C:\Efinity\2026.1\pgm\bin'
export QT_PLUGIN_PATH='C:/Efinity/2026.1/python311'
export EFX_HIFTDI_ENABLE=1

PY='C:/Efinity/2026.1/python311/bin/python.exe'
RUNNER=tools/hiftdi_runner.py
# 【2026-11-23 踩坑：不要显式传 -u】
# 原来这里写 hiftdi://0x0403:0x6014/-1。某天开始两种写法都会报
#   ERROR: Specified FTDI URL could not be matched to any connected USB targets
# 而设备本身是好的（Get-PnpDevice 能看到 USB\VID_0403&PID_6014，libusbK 正常）。
# 实测：**不传 -u，让后端自己枚举，反而稳定可用**。日志里会打出
#   INFO: usb_targets=1, raw url_list=['ftdi://0x0403:0x6014:0:ff/1']
# 所以 UARG 默认留空。只有机器上插了多个 FT232H、需要指定某一个时，才填：
#   URL='ftdi://0x0403:0x6014:0:ff/1'   （从上面那行 INFO 里抄）
# 型号/序列号不同（例如 FT2232H、有序列号）时更要从日志里抄。
URL=''
UARG=()
[ -n "$URL" ] && UARG=(-u "$URL")
BOARD='Generic Board Profile Using FT232H'
JCF=_jtag.jcf
BRIDGE='C:/Efinity/2026.1/pgm/fli/titanium/u10660A79.bit'
IMAGE="${1:-outflow/FpgaCar.hex}"
BASE="${IMAGE%.*}"
BIT="$BASE.bit"
LOG=.scratch/flash_hiftdi.log

mkdir -p .scratch

echo '[1/3] 装 JTAG 桥镜像'
"$PY" "$RUNNER" -m jtag -b "$BOARD" "${UARG[@]}" -x "$JCF" -n 1 "$BRIDGE" 2>&1 | tail -3

echo '[2/3] 写 Flash 并校验'
"$PY" "$RUNNER" -m jtag_bridge --jtag_bridge_mode all \
    --verify_method onchipx1 --jtag_clock_freq 1500000 \
    -b "$BOARD" "${UARG[@]}" -x "$JCF" -n 1 "$IMAGE" > "$LOG" 2>&1
grep -E 'Flash device|Erasing|Writing|Reading|Finished|verify successful|ERROR' "$LOG" | tail -16

if grep -q 'Flash verify successful' "$LOG"; then
    echo '[2/3] 校验通过'
else
    echo '[2/3] 校验失败：Flash 里内容不对，断电重启不会起'
    exit 1
fi

echo '[3/3] 回烧应用位流（本次上电立即生效）'
if [ -f "$BIT" ]; then
    "$PY" "$RUNNER" -m jtag -b "$BOARD" "${UARG[@]}" -x "$JCF" -n 1 "$BIT" 2>&1 | tail -3
else
    echo "跳过：找不到 $BIT"
fi

echo 'FLASH DONE'