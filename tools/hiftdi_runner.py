# -*- coding: utf-8 -*-
"""HiFTDI(D2XX) 后端启动器：在 FT232H 没有绑定 libusbK 时也能烧录。

背景：Efinity 默认用 pyftdi + libusb，要求 FT232H 绑定 libusbK 驱动。若被 FTDI 官方
ftdibus.inf 抢到（设备管理器显示 USB Serial Port (COMx)），则一律报
ERROR: No USB target detected, aborting!。换 USB 口无效——驱动按 rank 选。

Efinity 自带 HiFTDI 后端（走 C:/Windows/system32/ftd2xx.dll），设 EFX_HIFTDI_ENABLE=1
即可启用，设备 URL 变成 hiftdi://0x0403:0x6014/-1。但该后端在 2026.1 有三处 bug，
这里在运行时 monkeypatch 掉，不改 C:/Efinity 下任何安装文件：

  1. hiftdi/jtag.py:448  configure(self, url) 比调用方少一个参数（jcf.py:795 传 2 个）
  2. efx_hw_common/manager.py:252-253 把 hiftdi 的 JTAGFINEGRAIN 分支注释掉了，
     而 --jtag_bridge_mode 强制走这个类型
  3. 链式引擎会传 0 位 TMS（change_state 到当前态）和裸 bytes，hiftdi 不接受

用法与 tools/jtag_program.py 完全一致，只是把解释器换成这个脚本：

    python hiftdi_runner.py -m jtag -b "Generic Board Profile Using FT232H" \
        -u "hiftdi://0x0403:0x6014/-1" -x _jtag.jcf -n 1 outflow/FpgaCar.bit

环境变量除 tools/env.bat 那 11 个之外，必须再加 EFX_HIFTDI_ENABLE=1。
封装好的整条流程见 tools/flash_hiftdi.sh。
"""
import os
import runpy
import sys

EFINITY_PGM = r'C:\Efinity\2026.1\pgm\bin'
sys.path.insert(0, EFINITY_PGM)

if os.environ.get('EFX_HIFTDI_ENABLE') != '1':
    sys.stderr.write('ERROR: 需要 EFX_HIFTDI_ENABLE=1 才会启用 HiFTDI 后端\n')
    raise SystemExit(2)

import efx_pgm.hiftdi.jtag as hj
import efx_pgm.hiftdi.bits as hbits

# --- 补丁 1：configure 少一个参数 ---
_orig_cfg = hj.JtagEngine.configure


def _patched_configure(self, url, *a, **k):
    return _orig_cfg(self, url)


hj.JtagEngine.configure = _patched_configure

# --- 补丁 3a：0 位 TMS 是空操作，不该报 Invalid TMS length ---
_orig_write_tms = hj.JtagController.write_tms


def _patched_write_tms(self, tms, should_read=False):
    if len(tms) == 0:
        return None
    return _orig_write_tms(self, tms, should_read)


hj.JtagController.write_tms = _patched_write_tms

# --- 补丁 3b：链式引擎传裸 bytes 时按 pyftdi 语义拆成 bit 序列 ---
_orig_write = hj.JtagController.write


def _patched_write(self, out, use_last=True):
    if isinstance(out, (bytes, bytearray)):
        if len(out) > 1:
            self._write_bytes_raw(out[:-1])
            out = out[-1:]
        out = hbits.BitSequence(bytes_=out, length=8)
    return _orig_write(self, out, use_last)


hj.JtagController.write = _patched_write

# --- 补丁 2：把 JTAGFINEGRAIN 的 hiftdi 分支接回来 ---
from efx_pgm.efx_hw_common import manager as mgr

_MGR = mgr.EfxFTDIHwConnectionManager
_orig_get_controller = _MGR.get_controller


def _patched_get_controller(url, conn_type, **kwargs):
    CT = _MGR.ConnectionType
    if (conn_type == CT.JTAGFINEGRAIN
            and url.startswith('hiftdi://')
            and os.environ.get('EFX_HIFTDI_ENABLE') == '1'):
        return hj.JtagEngine(**kwargs)
    return _orig_get_controller(url, conn_type, **kwargs)


_MGR.get_controller = staticmethod(_patched_get_controller)

# --- 交给 tools/jtag_program.py 原有的命令行逻辑 ---
_HERE = os.path.dirname(os.path.abspath(__file__))
_TARGET = os.path.join(_HERE, 'jtag_program.py')

sys.argv = ['jtag_program.py'] + sys.argv[1:]
sys.stderr.write('INFO: HiFTDI 后端已启用（hiftdi://0x0403:0x6014/-1）\n')
runpy.run_path(_TARGET, run_name='__main__')