"""Read the board debug UART and summarise the telemetry fields.

FpgaCar top level emits two ASCII lines per HC-SR04 frame (every 60 ms):

    D=123cm T=00011000 P=+02 O=0 M=01          (35 bytes)
    L=00000123 R=FFFFFFF0 VL=0005 VR=FFF0 X=00011000 C=+036 DL=27C DR=234   (71 bytes)

  D   ultrasonic distance in cm, "---" when no echo / out of range
  T   track_line 8-channel bitmap, bit7..bit0 = track[7]..track[0], 1 = on tape
  P   weighted line position, -16..+16, positive = line is to the right
  O   obstacle flag (ultrasonic too close OR either E18-D80NK triggered)
  M   car_fsm state, two decimal digits:
        00 IDLE  01 RUN  02 LOST  03 SEARCH  04 STOP
  L/R left/right encoder accumulated position, 8 hex digits, two's complement
  VL/VR left/right speed = net steps in the last 50 ms window, 4 hex digits,
        two's complement
  X   track_line RAW debounced levels BEFORE the ACTIVE_HIGH inversion, same
        bit order as T.  T tells you which channels "see tape" after polarity
        is applied; if ACTIVE_HIGH is wrong T reads 11111111 and you cannot
        tell that apart from "the module really sees black everywhere".
        X is the mirror: compare X with T, they should be bitwise complements.
  C   track_pid correction term, signed decimal. Positive = turn right.
        Saturates at +/-BASE_DUTY (600). This is the number to watch while
        tuning P_GAIN / D_GAIN; T and P cannot show you what the PID did.
  DL/DR  left/right duty actually handed to the motors, 3 hex digits
        (0..4B0 = 0..1200). DL = BASE + C and DR = BASE - C when the FSM is
        passing the PID straight through; a mismatch means LOST-hold, SEARCH
        or TURN has taken over the duty.

Both of the last two groups are hex on purpose: a 32-bit signed value would
need eight cascaded div10 stages in fabric, which costs far more than the
convenience is worth. Decode them here instead.

Usage:
    python uart_mon.py [PORT] [SECONDS]

PORT may be omitted, in which case the first CH340 (VID_1A86/PID_7523) port
from the registry is used.
"""
import re
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

STATE_NAME = {0: "IDLE", 1: "RUN", 2: "LOST", 3: "SEARCH", 4: "STOP"}

# line 1 全是十进制；line 2 全是十六进制二补码
FIELDS1 = (
    ("D", re.compile(r"D=(-{3}|\d+)cm")),
    ("T", re.compile(r"T=([01]{8})")),
    ("P", re.compile(r"P=([+-]\d+)")),
    ("O", re.compile(r"O=(\d)")),
    ("M", re.compile(r"M=(\d{2})")),
)
# 前面用 (?:^|\s) 锚住，否则 "VR=FFF0" 里的 "R=" 会被误当成里程 R=
FIELDS2 = (
    ("L", re.compile(r"(?:^|\s)L=([0-9A-Fa-f]{8})")),
    ("R", re.compile(r"(?:^|\s)R=([0-9A-Fa-f]{8})")),
    ("VL", re.compile(r"(?:^|\s)VL=([0-9A-Fa-f]{4})")),
    ("VR", re.compile(r"(?:^|\s)VR=([0-9A-Fa-f]{4})")),
)
# 第二行的循迹调试段：X= 原始电平、C= PID 修正量（带符号十进制）、DL/DR= 实际占空比
FIELDS3 = (
    ("X",  re.compile(r"(?:^|\s)X=([01]{8})")),
    ("C",  re.compile(r"(?:^|\s)C=([+-]\d{3})")),
    ("DL", re.compile(r"(?:^|\s)DL=([0-9A-Fa-f]{3})")),
    ("DR", re.compile(r"(?:^|\s)DR=([0-9A-Fa-f]{3})")),
)


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


def s32(text):
    """8 位十六进制 -> 有符号 32 位整数。"""
    v = int(text, 16)
    return v - (1 << 32) if v >= (1 << 31) else v


def s16(text):
    """4 位十六进制 -> 有符号 16 位整数。"""
    v = int(text, 16)
    return v - (1 << 16) if v >= (1 << 15) else v


def collect(lines, patterns):
    """返回 {字段: [出现过的值]}，保持首次出现顺序。"""
    seen = {}
    for ln in lines:
        for key, pat in patterns:
            m = pat.search(ln)
            if m:
                seen.setdefault(key, []).append(m.group(1))
    return seen


def show_uniq(key, vals):
    uniq = sorted(set(vals))
    shown = uniq if len(uniq) <= 6 else uniq[:6] + ["..."]
    print("  %-3s = %s" % (key, " ".join(shown)))
    return uniq


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
    line2 = [ln for ln in lines if re.search(r"(?:^|\s)L=[0-9A-Fa-f]{8}", ln)]
    if not line1:
        print("--- no line 1 (D=...) seen; bitstream too old or REPORT_EN=0 ? ---")
        return 5

    f1 = collect(line1, FIELDS1)
    print("--- line 1 summary (values seen, %d lines) ---" % len(line1))
    for key, _ in FIELDS1:
        vals = f1.get(key)
        if not vals:
            print("  %-3s = (field missing)" % key)
            continue
        uniq = show_uniq(key, vals)
        if key == "M":
            names = [STATE_NAME.get(int(v), "?") for v in uniq]
            print("        -> %s" % " ".join("%s %s" % (v, n) for v, n in zip(uniq, names)))
        elif key == "T":
            ones = [sum(b == "1" for b in v) for v in uniq]
            print("        -> 压线数 %s" % ones)

    if line2:
        f2 = collect(line2, FIELDS2)
        print("--- line 2 summary (hex -> signed) ---")
        for key, _ in FIELDS2:
            vals = f2.get(key)
            if not vals:
                print("  %-3s = (field missing)" % key)
                continue
            uniq = show_uniq(key, vals)
            dec = [s32(v) if key in ("L", "R") else s16(v) for v in uniq]
            print("        -> %s" % dec)
        # 左右里程差是循迹跑偏的直接证据；速度差则是 PID 是否在修的直接证据
        if f2.get("L") and f2.get("R"):
            dl = s32(f2["L"][-1]) - s32(f2["L"][0])
            dr = s32(f2["R"][-1]) - s32(f2["R"][0])
            print("  window delta  L=%+d  R=%+d  (差 %+d 步)" % (dl, dr, dl - dr))
            if dl or dr:
                print("  注意：这里只说明左右走了多少步；换算成距离要先标定每米脉冲数。")
        if f2.get("VL") and f2.get("VR"):
            vl = [s16(v) for v in f2["VL"]]
            vr = [s16(v) for v in f2["VR"]]
            print("  speed window  VL %d..%d  VR %d..%d  (每 50 ms 净步数)"
                  % (min(vl), max(vl), min(vr), max(vr)))
        # ---- 循迹调试段：X= / C= / DL= / DR= ----
        f3 = collect(line2, FIELDS3)
        if f3.get("X") or f3.get("C"):
            print("--- 循迹调试段 ---")
            if f3.get("X"):
                uniq = show_uniq("X", f3["X"])
                print("        -> X 原始电平压线数 %s"
                      % [sum(b == "0" for b in v) for v in uniq])
            if f3.get("C"):
                cs = [int(v) for v in f3["C"]]
                print("  C= 修正量 %+d..%+d（限幅 ±600）  均值 %+.1f"
                      % (min(cs), max(cs), sum(cs) / len(cs)))
            if f3.get("DL") and f3.get("DR"):
                dls = [int(v, 16) for v in f3["DL"]]
                drs = [int(v, 16) for v in f3["DR"]]
                print("  DL %d..%d   DR %d..%d  (BASE=600)"
                      % (min(dls), max(dls), min(drs), max(drs)))
                print("        -> 若某一侧恒为 0 或恒为 1200，说明状态机在接管（LOST/SEARCH/TURN）")
            # X 与 T 应逐位互补：X = ~T（ACTIVE_HIGH=0 时）
            pair = []
            for ln in line2:
                mx = re.search(r"T=([01]{8})", ln)
                mxx = re.search(r"(?:^|\s)X=([01]{8})", ln)
                if mx and mxx:
                    pair.append((mx.group(1), mxx.group(1)))
            if pair:
                same = sum(1 for t, x in pair if t == x)
                comp = sum(1 for t, x in pair if all((a == "1") != (b == "1")
                                                    for a, b in zip(t, x)))
                print("  X 与 T 关系：完全相同 %d 帧 / 逐位互补 %d 帧 / 共 %d 帧"
                      % (same, comp, len(pair)))
                if same == len(pair):
                    print("        注意：T 与 X 完全相同说明 ACTIVE_HIGH 可能没生效，"
                          "或模块输出恒为某一电平（先量 X1 对 GND）")
                elif comp == len(pair):
                    print("        正常：X 是消抖后的原始电平，T 已经过 ACTIVE_HIGH 取反")
                else:
                    print("        异常：T 与 X 既不完全相同也不互补，检查是否有些位在抖")
    else:
        print("--- no line 2 (L=/R=/VL=/VR=) yet; bitstream too old? ---")

    if "---" in f1.get("D", []):
        print("  D=--- 出现过：超声波没收到回波（超量程或探头坏了），不是 0 cm。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
