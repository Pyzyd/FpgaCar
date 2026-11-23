# -*- coding: utf-8 -*-
"""串口采集/标定工具（默认 COM12, 115200, 8N1）

固件每 60 ms 打两行：
  D=030cm T=00011000 P=+00 O=1 M=00
  L=FFFFFF76 R=FFFFFF5B VL=0000 VR=0000 X=11100111 C=+000 DL=000 DR=000 W=0 S=0

子命令
  ports                          列出串口
  watch   --sec N                原样打印
  log     --sec N --csv F        全字段落 CSV，供之后 analyze 回放
  analyze --csv F [--turns N]    切出运动段，报 dL/dR，反推每圈计数与减速比
  speed   --sec N                统计 (DL,DR) → (VL,VR)，算 duty→车速常数 K
  dist    --sec N                打印 D= / O= 的变化沿（测超声滞回）
  avoid   --sec N                打印 M= 状态迁移（测状态机时序）

标定常数（换轮/换编码器改这里，与 src/FpgaCar.v 保持一致）
  ENC_CNT_PER_REV = 3840   20 线四倍频 80 × 减速 48
  WHEEL_CIRC_MM   = 232
  WHEEL_BASE_MM   = 160
"""
import sys, time, re, os, argparse
import serial
from serial.tools import list_ports

ENC_CNT_PER_REV = 3840
WHEEL_CIRC_MM = 232.0
WHEEL_BASE_MM = 160.0
WIN_S = 0.050
DUTY_MAX = 1200
COLS = ["t", "L", "R", "VL", "VR", "DL", "DR", "M", "D", "O",
        "X", "T", "P", "C", "W", "S"]


def ports():
    for p in list_ports.comports():
        print("%s\t%s\t%s" % (p.device, p.description, p.hwid))


def parse(line):
    d = {}
    for m in re.finditer(r"([A-Z]{1,2})=([^ ]+)", line):
        d[m.group(1)] = m.group(2)
    return d


def hex2s(v, bits=32):
    if v is None:
        return None
    try:
        n = int(v, 16)
    except Exception:
        return None
    if n >= 1 << (bits - 1):
        n -= 1 << bits
    return n


def open_port(port, baud, tries=15):
    # 上一个采集进程可能还没释放端口，重试等它退出
    last = None
    for i in range(tries):
        try:
            ser = serial.Serial(port, baud, timeout=0.2)
            ser.reset_input_buffer()
            return ser
        except serial.SerialException as ex:
            last = ex
            time.sleep(0.4)
    raise SystemExit("打开 %s 失败（端口被占用？先关掉别的串口助手）: %s" % (port, last))


def raw_frames(ser, sec):
    t0 = time.time()
    buf = b""
    while time.time() - t0 < sec:
        buf += ser.read(512)
        while b"\n" in buf:
            ln, buf = buf.split(b"\n", 1)
            s = ln.decode("ascii", "replace").strip()
            f = parse(s)
            if f:
                yield time.time() - t0, f


def merged(ser, sec):
    """两行合并：第二行为准，D=/O=/M= 缺失时沿用上一条第一行"""
    last1 = {}
    for t, f in raw_frames(ser, sec):
        if "D" in f or "O" in f:
            last1 = f
        if "L" in f:
            g = dict(last1)
            g.update(f)
            yield t, g


def cmd_watch(a):
    ser = open_port(a.port, a.baud)
    n = 0
    for t, f in raw_frames(ser, a.sec):
        print(f)
        n += 1
    ser.close()
    print("# lines=%d in %.1fs" % (n, a.sec))


def cmd_log(a):
    ser = open_port(a.port, a.baud)
    n = 0
    with open(a.csv, "w", encoding="utf-8") as fh:
        fh.write(",".join(COLS) + "\n")
        for t, f in merged(ser, a.sec):
            row = [("%.4f" % t)]
            for c in COLS[1:]:
                row.append(f.get(c, ""))
            fh.write(",".join(row) + "\n")
            n += 1
    ser.close()
    print("# 写入 %d 帧 -> %s (%.1fs)" % (n, a.csv, a.sec))


def _load(csv):
    rows = []
    with open(csv, encoding="utf-8") as fh:
        hdr = fh.readline().strip().split(",")
        for ln in fh:
            v = ln.strip().split(",")
            if len(v) != len(hdr):
                continue
            r = dict(zip(hdr, v))
            r["t"] = float(r["t"])
            r["L"] = hex2s(r.get("L"))
            r["R"] = hex2s(r.get("R"))
            rows.append(r)
    return rows


def cmd_analyze(a):
    rows = [r for r in _load(a.csv) if r["L"] is not None and r["R"] is not None]
    if not rows:
        print("# 没有有效帧")
        return
    span = rows[-1]["t"] - rows[0]["t"]
    print("# 帧数 %d，时长 %.2f s" % (len(rows), span))

    def tot(key):
        s = 0
        for i in range(1, len(rows)):
            s += rows[i][key] - rows[i - 1][key]
        return s

    print("# 总变化 dL=%d dR=%d" % (tot("L"), tot("R")))

    # 切运动段：相邻帧任一路变化即视为运动中，静默 >=0.6s 断开
    segs = []
    cur = None
    last_move_t = None
    for i in range(1, len(rows)):
        p, q = rows[i - 1], rows[i]
        dL = q["L"] - p["L"]
        dR = q["R"] - p["R"]
        if dL != 0 or dR != 0:
            if cur is None:
                cur = {"t0": p["t"], "L0": p["L"], "R0": p["R"],
                       "t1": q["t"], "L1": q["L"], "R1": q["R"]}
            else:
                cur["t1"] = q["t"]; cur["L1"] = q["L"]; cur["R1"] = q["R"]
            last_move_t = q["t"]
        else:
            if cur is not None and (q["t"] - last_move_t) >= 0.6:
                segs.append(cur); cur = None
    if cur is not None:
        segs.append(cur)

    print("# ---- 运动段 ----")
    for s in segs:
        dL = s["L1"] - s["L0"]
        dR = s["R1"] - s["R0"]
        dur = s["t1"] - s["t0"]
        print("t=%6.2f..%6.2f (%4.2fs)  dL=%7d  dR=%7d" % (s["t0"], s["t1"], dur, dL, dR))

    if a.turns:
        n = float(a.turns)
        print("# ---- 每圈计数（用户报告转了 %g 圈）----" % n)
        print("# 左轮: %d 计数 / %g 圈 = %.1f 计数/圈（标定值 %d）"
              % (abs(tot("L")), n, abs(tot("L")) / n, ENC_CNT_PER_REV))
        print("# 右轮: %d 计数 / %g 圈 = %.1f 计数/圈（标定值 %d）"
              % (abs(tot("R")), n, abs(tot("R")) / n, ENC_CNT_PER_REV))
        cpr = abs(tot("L")) / n
        if cpr > 0:
            print("# 反推减速比 = %.1f/80 = %.1f（标定 48）" % (cpr, cpr / 80.0))
            print("# 反推轮周长  = %.1f mm（标定 %.1f）" % (WHEEL_CIRC_MM, WHEEL_CIRC_MM))


def cmd_speed(a):
    ser = open_port(a.port, a.baud)
    buckets = {}
    for t, f in merged(ser, a.sec):
        try:
            dl = int(f["DL"], 16); dr = int(f["DR"], 16)
            vl = hex2s(f["VL"], 16); vr = hex2s(f["VR"], 16)
        except Exception:
            continue
        if vl is None or vr is None or (vl == 0 and vr == 0):
            continue
        key = (dl + dr) // 2
        b = buckets.setdefault(key, [0, 0.0, 0.0])
        b[0] += 1; b[1] += vl; b[2] += vr
    ser.close()
    if not buckets:
        print("# 没有非零速度帧 —— 车要真的在跑（压线 + K1）")
        return
    mm_per_cnt = WHEEL_CIRC_MM / ENC_CNT_PER_REV
    print("# duty均值  样本  VL均值  VR均值  车速mm/s   K(mm/s per duty)")
    for k in sorted(buckets):
        b = buckets[k]
        vl = b[1] / b[0]; vr = b[2] / b[0]
        v = (vl + vr) / 2.0 * mm_per_cnt / WIN_S
        print("%9d  %5d  %6.2f  %6.2f  %8.1f  %14.4f"
              % (k, b[0], vl, vr, v, (v / k) if k else 0.0))


def cmd_dist(a):
    ser = open_port(a.port, a.baud)
    prev = None
    for t, f in merged(ser, a.sec):
        D, O = f.get("D"), f.get("O")
        if D is None:
            continue
        cur = (D, O)
        if prev is None or prev[1] != O:
            print("t=%6.3f  D=%8s O=%s" % (t, D, O))
        prev = cur
    ser.close()


STATE = {"00": "IDLE", "01": "RUN", "02": "LOST", "03": "SEARCH", "04": "STOP",
         "05": "AVOID_BACK", "06": "AVOID_TURN", "07": "AVOID_PROBE"}


def cmd_avoid(a):
    ser = open_port(a.port, a.baud)
    prev = None
    t0 = None
    for t, f in merged(ser, a.sec):
        m = f.get("M")
        if m is None:
            continue
        if t0 is None:
            t0 = t
        try:
            dl = int(f.get("DL", "0") or "0", 16)
            dr = int(f.get("DR", "0") or "0", 16)
        except Exception:
            dl = dr = -1
        if prev != m:
            print("t=%6.3f  M=%s %-11s D=%s O=%s DL=%4d DR=%4d VL=%s VR=%s"
                  % (t - t0, m, STATE.get(m, "?"), f.get("D"), f.get("O"),
                     dl, dr, f.get("VL"), f.get("VR")))
            prev = m
    ser.close()


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ports")
    for name in ("watch", "log", "speed", "dist", "avoid"):
        p = sub.add_parser(name)
        p.add_argument("--port", default="COM12")
        p.add_argument("--baud", type=int, default=115200)
        p.add_argument("--sec", type=float, default=10.0)
        if name == "log":
            p.add_argument("--csv", default=".scratch/serial.csv")
    p = sub.add_parser("analyze")
    p.add_argument("--csv", default=".scratch/serial.csv")
    p.add_argument("--turns", type=float, default=0)
    a = ap.parse_args()
    if a.cmd == "ports":
        ports(); return
    {"watch": cmd_watch, "log": cmd_log, "speed": cmd_speed,
     "dist": cmd_dist, "avoid": cmd_avoid, "analyze": cmd_analyze}[a.cmd](a)


if __name__ == "__main__":
    main()
