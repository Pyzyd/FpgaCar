"""Capture the debug-UART telemetry into a CSV for offline analysis.

FpgaCar emits two ASCII lines per HC-SR04 frame (every 60 ms):

    D=123cm T=00011000 P=+02 O=0 M=01          (35 bytes)
    L=00000123 R=FFFFFFF0 VL=0005 VR=FFF0      (39 bytes)

  D   ultrasonic distance in cm, "---" when no echo / out of range
  T   track_line 8-channel bitmap, bit7..bit0 = track[7]..track[0], 1 = on tape
  P   weighted line position, -16..+16, positive = line is to the right
  O   obstacle flag (ultrasonic too close OR either E18-D80NK triggered)
  M   car_fsm state: 00 IDLE 01 RUN 02 LOST 03 SEARCH 04 STOP
  L/R left/right encoder position, 8 hex digits, two's complement
  VL/VR left/right speed, net steps per 50 ms window, 4 hex digits, two's
        complement

【这个脚本现在的用途】
原来是"抓两行、解 RGB565、看镜头对着什么颜色"。OV5640 停用后那部分没有数据源，
改成纯遥测记录器，正好服务于两件必须靠数据的事：

  1. 标定每米脉冲数  —— L/R 累积里程差 / 卷尺量的实际距离
  2. 复盘状态机与 PID —— M 什么时候从 RUN 掉到 LOST、VL/VR 差多少才纠回来

CSV 列：t, D, T, P, O, M, L, R, VL, VR
  t 是相对第一个配对的秒数（主机时钟），不是板载时间戳。

Usage:  python cap.py [PORT] [SECONDS] [OUT.csv]
"""
import os
import re
import sys
import time

# 抓包数据统一放在工程根的 data/ 下，避免根目录被 _cap*.csv 堆满
DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

RE1 = re.compile(r"D=(-{3}|\d+)cm T=([01]{8}) P=([+-]\d+) O=(\d) M=(\d{2})")
# 前面锚 \s，否则 "VR=FFF0" 里的 "R=" 会被当成里程 R=
RE2 = re.compile(r"(?:^|\s)L=([0-9A-Fa-f]{8}) R=([0-9A-Fa-f]{8})"
                 r" VL=([0-9A-Fa-f]{4}) VR=([0-9A-Fa-f]{4})")

STATE_NAME = {0: "IDLE", 1: "RUN", 2: "LOST", 3: "SEARCH", 4: "STOP"}


def find_port():
    import winreg
    key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DEVICEMAP\SERIALCOMM")
    ports, i = {}, 0
    while True:
        try:
            name, value, _ = winreg.EnumValue(key, i)
        except OSError:
            break
        ports[name] = value
        i += 1
    winreg.CloseKey(key)
    for name, value in ports.items():
        if "VCP" in name or "USBSER" in name:
            return value
    return next(iter(ports.values()), None)


def s32(text):
    v = int(text, 16)
    return v - (1 << 32) if v >= (1 << 31) else v


def s16(text):
    v = int(text, 16)
    return v - (1 << 16) if v >= (1 << 15) else v


def main():
    import serial
    args = sys.argv[1:]
    numeric = [a for a in args if re.fullmatch(r"[0-9.]+", a)]
    named = [a for a in args if not re.fullmatch(r"[0-9.]+", a)]
    csv_path = None
    os.makedirs(DATA_DIR, exist_ok=True)
    if named and re.fullmatch(r".+\.csv", named[-1], re.I):
        csv_path = named.pop()
    port = named[0] if named else find_port()
    seconds = float(numeric[0]) if numeric else 8.0
    if not port:
        print("ERROR: no serial port found")
        return 3

    ser = serial.Serial(port, 115200, timeout=0.3)
    print("Listening on %s @115200 for %.1f s ..." % (port, seconds))
    buf, deadline = b"", time.time() + seconds
    while time.time() < deadline:
        chunk = ser.read(512)
        if chunk:
            buf += chunk
    ser.close()

    text = buf.decode("utf-8", errors="replace").replace("\r", "\n")
    rows, pending1, t0 = [], None, None
    for ln in text.split("\n"):
        ln = ln.strip()
        m1 = RE1.search(ln)
        if m1:
            pending1 = m1
            continue
        m2 = RE2.search(ln)
        if m2 and pending1:
            now = time.time()
            if t0 is None:
                t0 = now
            rows.append((now - t0,
                         pending1.group(1), pending1.group(2), pending1.group(3),
                         int(pending1.group(4)), int(pending1.group(5)),
                         s32(m2.group(1)), s32(m2.group(2)),
                         s16(m2.group(3)), s16(m2.group(4))))
            pending1 = None

    if not rows:
        print("No paired frames decoded (lines=%d)." % len(text.split("\n")))
        print(text[-500:])
        return 4

    print("--- %d frames ---" % len(rows))
    print("    t      D        T        P    O  M        L          R       VL    VR")
    for r in rows[-12:]:
        print("  %5.2f  %-6s  %s  %+3s  %d  %s  %+9d  %+9d  %+5d %+5d"
              % (r[0], r[1], r[2], r[3], r[4],
                 "%02d %-6s" % (r[5], STATE_NAME.get(r[5], "?")),
                 r[6], r[7], r[8], r[9]))

    print("--- summary ---")
    states = sorted({r[5] for r in rows})
    print("  M values seen = %s"
          % " ".join("%02d %s" % (s, STATE_NAME.get(s, "?")) for s in states))
    if len(states) > 1:
        # 状态跳变序列是复盘"为什么停了"的第一手材料
        trans = [(i, rows[i - 1][5], rows[i][5])
                 for i in range(1, len(rows)) if rows[i][5] != rows[i - 1][5]]
        print("  跳变 %d 次：" % len(trans))
        for i, a, b in trans[:10]:
            print("    第 %d 帧  %s -> %s" % (i, STATE_NAME.get(a, a), STATE_NAME.get(b, b)))
    o_cnt = sum(1 for r in rows if r[4])
    print("  O=1 占比 %.0f%% (%d/%d)  —— 若远高于实际障碍时间，查红外阈值/超声抖动"
          % (100.0 * o_cnt / len(rows), o_cnt, len(rows)))

    dl = rows[-1][6] - rows[0][6]
    dr = rows[-1][7] - rows[0][7]
    span = rows[-1][0] - rows[0][0]
    print("  里程变化  L=%+d  R=%+d  (差 %+d 步)" % (dl, dr, dl - dr))
    if span > 0.2:
        print("  平均速度  L=%+.1f  R=%+.1f 步/秒（%d 帧 / %.2f s）"
              % (dl / span, dr / span, len(rows), span))
    print("  标定提示：让车直行已知距离 S 米，取 |L| 或 |R|，每米脉冲数 = 步数 / S。")

    if csv_path and not os.path.isabs(csv_path) and os.sep not in csv_path and "/" not in csv_path:
        csv_path = os.path.join(DATA_DIR, csv_path)   # 只给文件名 -> 落到 data/
    if csv_path:
        with open(csv_path, "w", encoding="utf-8") as fp:
            fp.write("t,D,T,P,O,M,L,R,VL,VR\n")
            for r in rows:
                fp.write("%.3f,%s,%s,%s,%d,%d,%d,%d,%d,%d\n" % r)
        print("CSV -> %s" % csv_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
