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

    fields = {"D": r"D=(-{0,3}|\d+)cm", "T": r"T=([01]{8})", "P": r"P=([+-]\d+)",
              "O": r"O=(\d)", "V": r"V=(\d+)", "C": r"C=(\d)", "W": r"W=(\d+)",
              "H": r"H=(\d+)", "Q": r"Q=(\d)", "XY": r"XY=([0-9A-Fa-f]{4})"}
    print("--- summary (last value seen) ---")
    for key, pat in fields.items():
        vals = [m.group(1) for m in (re.search(pat, ln) for ln in lines) if m]
        if vals:
            uniq = sorted(set(vals))
            shown = uniq if len(uniq) <= 4 else uniq[:4] + ["..."]
            print("  %-2s = %s" % (key, " ".join(shown)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
