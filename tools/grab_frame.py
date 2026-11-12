"""Grab the 40x30 thumbnail that frame_snap.v dumps on power-up.

The FPGA sends, right after reset + 1.5 s, three frames of:
    'S' + GW*4 hex chars (RGB565, high byte first) + CR + LF      x GH lines

Outputs:
    _frame.bmp    24-bit BMP, upscaled 8x so it is viewable
    _frame.csv    one line per row: 40 x "RRGGBB" (decoded RGB888)

Usage:  python grab_frame.py [PORT] [OUT_PREFIX]
        python grab_frame.py COM12
        python grab_frame.py COM12 _red

No third-party imaging library is used (BMP is written by hand), so this runs
under Efinity's bundled Python as well as any system Python.
"""
import os
import re
import sys
import time

import serial

GW, GH = 40, 30
SCALE = 8

HEX = re.compile(r"^S([0-9A-Fa-f]+)\s*$")


def rgb565_to_888(b0, b1):
    """b0/b1 are the two raw bytes as the sensor sent them (high byte first)."""
    r5 = (b0 >> 3) & 0x1F
    g6 = ((b0 & 0x07) << 3) | ((b1 >> 5) & 0x07)
    b5 = b1 & 0x1F
    r = (r5 << 3) | (r5 >> 2)
    g = (g6 << 2) | (g6 >> 4)
    b = (b5 << 3) | (b5 >> 2)
    return r, g, b


def write_bmp(path, rows):
    """rows[y][x] = (r,g,b); BMP is bottom-up, 24-bit, BGR."""
    h = len(rows)
    w = len(rows[0])
    pad = (4 - (w * 3) % 4) % 4
    data = bytearray()
    for y in range(h - 1, -1, -1):
        line = bytearray()
        for (r, g, b) in rows[y]:
            line += bytes((b, g, r))
        line += b"\x00" * pad
        data += line
    size = 54 + len(data)
    hdr = bytearray()
    hdr += b"BM"
    hdr += size.to_bytes(4, "little")
    hdr += (0).to_bytes(4, "little")
    hdr += (54).to_bytes(4, "little")
    hdr += (40).to_bytes(4, "little")          # DIB header size
    hdr += w.to_bytes(4, "little", signed=True)
    hdr += h.to_bytes(4, "little", signed=True)
    hdr += (1).to_bytes(2, "little")           # planes
    hdr += (24).to_bytes(2, "little")          # bpp
    hdr += (0).to_bytes(4, "little")           # no compression
    hdr += len(data).to_bytes(4, "little")
    hdr += (2835).to_bytes(4, "little")
    hdr += (2835).to_bytes(4, "little")
    hdr += (0).to_bytes(4, "little")
    hdr += (0).to_bytes(4, "little")
    with open(path, "wb") as f:
        f.write(hdr + data)


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "COM12"
    prefix = sys.argv[2] if len(sys.argv) > 2 else "_frame"
    # 缩略图数据统一放到工程根的 data/ 下（只给文件名、不给目录时）
    if not os.path.isabs(prefix) and os.sep not in prefix and "/" not in prefix:
        data_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")
        os.makedirs(data_dir, exist_ok=True)
        prefix = os.path.join(data_dir, prefix)

    ser = serial.Serial(port, 115200, timeout=3)
    print(f"listening on {port}, waiting for thumbnail frames (reset the board if nothing comes)...")

    frames = []
    rows = []
    t0 = time.time()

    while time.time() - t0 < 20:
        raw = ser.readline()
        if not raw:
            continue
        try:
            line = raw.decode("ascii", "ignore").strip()
        except Exception:
            continue
        m = HEX.match(line)
        if not m:
            continue                      # 正常的 D=/R= 统计行，跳过
        hexs = m.group(1)
        if len(hexs) != GW * 4:
            continue
        row = []
        for i in range(GW):
            b0 = int(hexs[i * 4:i * 4 + 2], 16)
            b1 = int(hexs[i * 4 + 2:i * 4 + 4], 16)
            row.append(rgb565_to_888(b0, b1))
        rows.append(row)
        if len(rows) == GH:
            frames.append(rows)
            print(f"  frame {len(frames)} captured")
            rows = []
            if len(frames) >= 3:
                break

    ser.close()

    if not frames:
        print("ERROR: no complete frame received. Check COM port / reset the board.")
        return 1

    for idx, fr in enumerate(frames, 1):
        suffix = "" if len(frames) == 1 else f"_{idx}"
        bmp = f"{prefix}{suffix}.bmp"
        csv = f"{prefix}{suffix}.csv"
        write_bmp(bmp, fr)
        with open(csv, "w", encoding="utf-8") as f:
            for row in fr:
                f.write(",".join(f"{r:02X}{g:02X}{b:02X}" for (r, g, b) in row) + "\n")
        print(f"  saved {bmp} ({GW}x{GH} x{SCALE}) and {csv}")

    # 打印中心几行的均值，便于快速判断
    fr = frames[0]
    print("\n--- frame 1 quick look ---")
    for y in range(0, GH, 6):
        row = fr[y]
        ar = sum(p[0] for p in row) // GW
        ag = sum(p[1] for p in row) // GW
        ab = sum(p[2] for p in row) // GW
        bar = "#" * (ar // 16) + "-" * (ag // 16) + "." * (ab // 16)
        print(f"  y={y:2d}  R={ar:3d} G={ag:3d} B={ab:3d}  {bar}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
