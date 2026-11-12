"""Capture the two debug-UART lines per frame into a CSV and summarise them.

Line 1 (decimal):  D=---cm T=00000000 P=+00 O=0 V=03 C=1 W=2560 H=720 Q=0 XY=0882
Line 2 (hex):      R=00000 G=00000 B=00065 Y=00000 S=14 SB=6C17 LB=CF3E

Usage:  python cap.py [PORT] [SECONDS] [OUT.csv]
"""
import os
import re
import sys
import time

# 抓包数据统一放在工程根的 data/ 下，避免根目录被 _cap*.csv 堆满
DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

RE1 = re.compile(r"D=(-{0,3}|\d+)cm .*?Q=(\d) XY=([0-9A-Fa-f]{4})")
RE2 = re.compile(r"R=([0-9A-Fa-f]{5}) G=([0-9A-Fa-f]{5}) B=([0-9A-Fa-f]{5})"
                 r" Y=([0-9A-Fa-f]{5}) S=([0-9A-Fa-f]{2}) SB=([0-9A-Fa-f]{4})"
                 r" LB=([0-9A-Fa-f]{4})")


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


def rgb565(hb, lb):
    """Two raw DVP bytes -> 6-bit R/G/B, same arithmetic as color_detect.v."""
    r = (hb >> 3) << 1
    g = ((hb & 0x07) << 3) | (lb >> 5)
    b = (lb & 0x1F) << 1
    return r, g, b


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
    rows, q_seen, pending1 = [], [], None
    for ln in text.split("\n"):
        ln = ln.strip()
        m1 = RE1.search(ln)
        if m1:
            pending1 = m1
            continue
        m2 = RE2.search(ln)
        if m2 and pending1:
            r, g, b, y = (int(m2.group(i), 16) for i in (1, 2, 3, 4))
            s = int(m2.group(5), 16)
            rows.append((pending1.group(1), int(pending1.group(2)),
                         pending1.group(3), r, g, b, y, s,
                         m2.group(6), m2.group(7)))
            q_seen.append(int(pending1.group(2)))
            pending1 = None

    if not rows:
        print("No paired frames decoded (lines=%d)." % len(text.split("\n")))
        print(text[-500:])
        return 4

    print("--- %d frames ---" % len(rows))
    print("  D       Q   R     G     B     Y     S   SB    LB")
    for row in rows[-12:]:
        print("  %-6s  %d  %-5d %-5d %-5d %-5d %-3d %s %s"
              % (row[0], row[1], row[3], row[4], row[5], row[6], row[7], row[8], row[9]))

    print("--- max over window ---")
    for i, name in ((3, "R"), (4, "G"), (5, "B"), (6, "Y")):
        vals = [r[i] for r in rows]
        print("  %s max = %d px (threshold 200)  mean = %.1f"
              % (name, max(vals), sum(vals) / len(vals)))
    smax = max(r[7] for r in rows)
    print("  S max = %d / 63  (SAT_MIN = 16)  -> %s"
          % (smax, "有饱和像素" if smax >= 16 else "整帧几乎无饱和色"))
    print("  Q values seen = %s" % sorted(set(q_seen)))

    # 中心像素 XY 是原始 DVP 两字节，直接解出来看"镜头正对着什么颜色"
    xy_last = rows[-1][2]
    hb, lb = int(xy_last[0:2], 16), int(xy_last[2:4], 16)
    print("  last XY %s -> R=%d G=%d B=%d (center pixel)"
          % (xy_last, *rgb565(hb, lb)))

    # SB/LB 两字节按 RGB565 解出来，看"最饱和/最亮"的像素到底是什么颜色
    for idx, tag in ((8, "SB"), (9, "LB")):
        hb, lb = int(rows[-1][idx][0:2], 16), int(rows[-1][idx][2:4], 16)
        print("  last %s %s -> R=%d G=%d B=%d" % (tag, rows[-1][idx], *rgb565(hb, lb)))

    if csv_path and not os.path.isabs(csv_path) and os.sep not in csv_path and "/" not in csv_path:
        csv_path = os.path.join(DATA_DIR, csv_path)   # 只给文件名 -> 落到 data/
    if csv_path:
        with open(csv_path, "w", encoding="utf-8") as fp:
            fp.write("D,Q,R,G,B,Y,S,SB,LB\n")
            for row in rows:
                fp.write("%s,%d,%d,%d,%d,%d,%d,%s,%s\n"
                         % (row[0], row[1], row[3], row[4], row[5], row[6], row[7],
                            row[8], row[9]))
        print("CSV -> %s" % csv_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
