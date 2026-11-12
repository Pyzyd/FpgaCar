"""Read the board debug UART and optionally summarise the telemetry fields.

The FpgaCar top level emits one ASCII line per 60 ms:

    D=123cm T=00011000 P=+02 O=0 V=03 C=1 W=2560 H=720 Q=1 XY=0861\\r\\n

  D  HC-SR04 distance, "---" when no echo
  T  track_line 8-channel bitmap, left..right
  P  line position, -16..+16
  O  obstacle flag (ultrasonic near OR either E18-D80NK triggered)
  V  VSYNC count observed in the last 100 ms window (proves XCLK/DVP alive)
  C  SCCB (OV5640 register load) done flag
  W  measured frame width in PCLK (16-bit-per-pixel -> expect 2*active_width)
  H  measured frame height in HREF rows
  Q  dominant colour class: 0 neutral, 1 red, 2 green, 3 blue, 4 yellow
  XY two raw centre bytes from the DVP bus (debug only)

followed immediately by a second, shorter hex line (v4 frame statistics):

    R=00300 G=00000 B=00000 Y=00000 S=3F SB=F800 LB=F800\r\n

  R/G/B/Y  pixels classified as red/green/blue/yellow in the frame just ended
           (hex, 0..4B000). MNI_PIX is 200, so anything below 200 (C8) never
           wins the election -> Q stays 0.
  S        largest saturation (max-min) seen anywhere in that frame, 6 bit hex
  SB       the two raw DVP bytes of the most saturated pixel
  LB       the two raw DVP bytes of the brightest pixel (by green)

Usage:
    python uart_mon.py [PORT] [SECONDS]

PORT may be omitted, in which case the first CH340 (VID_1A86/PID_7523) port from
the registry is used.
"""
import re
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def find_port():
    try:
        import winreg
    except ImportError:
        return None
    try:
        key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DEVICEMAP\SERIALCOMM")
    except OSError:
        return None
    ports = {}
    i = 0
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


def main():
    try:
        import serial
    except ImportError:
        print("ERROR: pyserial not installed for this interpreter")
        return 2

    args = [a for a in sys.argv[1:]]
    port = None
    seconds = 5.0
    numeric = [a for a in args if re.fullmatch(r"[0-9.]+", a)]
    named = [a for a in args if not re.fullmatch(r"[0-9.]+", a)]
    if named:
        port = named[0]
    if numeric:
        seconds = float(numeric[0])
    if not port:
        port = find_port()
    if not port:
        print("ERROR: no serial port found, pass one explicitly (e.g. COM12)")
        return 3

    try:
        ser = serial.Serial(port, 115200, timeout=0.3)
    except Exception as exc:
        print("ERROR: cannot open %s: %s" % (port, exc))
        return 3

    print("Listening on %s @115200 for %.1f s ..." % (port, seconds))
    buf = b""
    deadline = time.time() + seconds
    while time.time() < deadline:
        chunk = ser.read(256)
        if chunk:
            buf += chunk
    ser.close()

    text = buf.decode("utf-8", errors="replace")
    lines = [ln.strip() for ln in text.replace("\r", "\n").split("\n") if ln.strip()]
    if not lines:
        print("No data received (wrong port? board not configured? UART tx pin?)")
        return 4

    print("--- %d lines ---" % len(lines))
    for ln in lines[-20:]:
        print(ln)

    line1 = [ln for ln in lines if ln.startswith("D=")]
    line2 = [ln for ln in lines if ln.startswith("R=")]
    fields = {"D": r"D=(-{0,3}|\d+)cm", "T": r"T=([01]{8})", "P": r"P=([+-]\d+)",
              "O": r"O=(\d)", "V": r"V=(\d+)", "C": r"C=(\d)", "W": r"W=(\d+)",
              "H": r"H=(\d+)", "Q": r"Q=(\d)", "XY": r"XY=([0-9A-Fa-f]{4})"}
    print("--- line 1 summary (last value seen) ---")
    for key, pat in fields.items():
        vals = [m.group(1) for m in (re.search(pat, ln) for ln in line1) if m]
        if vals:
            uniq = sorted(set(vals))
            shown = uniq if len(uniq) <= 4 else uniq[:4] + ["..."]
            print("  %-2s = %s" % (key, " ".join(shown)))

    if line2:
        print("--- line 2 frame statistics (hex) ---")
        fields2 = {"R": r"R=([0-9A-Fa-f]{5})", "G": r"G=([0-9A-Fa-f]{5})",
                   "B": r"B=([0-9A-Fa-f]{5})", "Y": r"Y=([0-9A-Fa-f]{5})",
                   "S": r"S=([0-9A-Fa-f]{2})", "SB": r"SB=([0-9A-Fa-f]{4})",
                   "LB": r"LB=([0-9A-Fa-f]{4})"}
        for key, pat in fields2.items():
            vals = [m.group(1) for m in (re.search(pat, ln) for ln in line2) if m]
            if not vals:
                continue
            count = {"R": 0, "G": 1, "B": 2, "Y": 3}.get(key)
            if count is None:
                uniq = sorted(set(vals))
                shown = uniq if len(uniq) <= 4 else uniq[:4] + ["..."]
                print("  %-2s = %s" % (key, " ".join(shown)))
            else:
                # 计数是十六进制，但"有没有超过 200 像素门槛"看十进制才直观
                dec = [int(v, 16) for v in vals]
                print("  %-2s = %s   (%d..%d dec, max %s = %d)"
                      % (key, " ".join(sorted(set(vals))), min(dec), max(dec),
                         hex(max(dec)), max(dec)))
        # 四色计数全为 0 而 S 却很高 -> 分类/阈值问题；S 也低 -> 画面本来就没饱和色
        print("  verdict: 若 S 明显 >0（例如 >=16）且四色都 <200，说明饱和色存在但"
              "分类或 MIN_PIX 门槛卡住了；若 S 只有个位数，是镜头/曝光/数据位序问题。")
    else:
        print("--- no line-2 telemetry yet (bitstream too old?) ---")
    return 0


if __name__ == "__main__":
    sys.exit(main())
