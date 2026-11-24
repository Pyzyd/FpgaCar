# -*- coding: utf-8 -*-
"""避障实车轨迹复盘：把串口 csv 变成里程计轨迹图 + 每段里程/转角表。
用法: python bench/avoid_run_plot.py .scratch/run_avoid2.csv [out.png]
"""
import csv, math, sys, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager

CPM = 2532.0 / 212.0          # 计数/mm（实测：每圈 2532，轮周长 212 mm）
WB  = 160.0                   # 轮距 mm
DEG = 1.0 / CPM / WB * 180.0 / math.pi   # 每 1 个计数差 = ? 度

PHASE = {(860, 380): ("OUT",     -60.0),
         (400, 840): ("ALIGN",   +60.0),
         (480, 760): ("PASS",     0.0),
         (420, 860): ("TURN_IN", +90.0),
         (430, 640): ("REJOIN",   0.0)}
COLOR = {"OUT": "tab:orange", "ALIGN": "tab:blue", "PASS": "tab:green",
         "TURN_IN": "tab:red", "REJOIN": "tab:purple"}
STATE = {0: "IDLE", 1: "RUN", 2: "LOST", 3: "SEARCH", 4: "STOP",
         5: "AVOID_BACK", 6: "AVOID_TURN", 7: "AVOID_PROBE"}


def i32(v):
    v = int(v, 16)
    return v - (1 << 32) if v >= (1 << 31) else v


def load(path):
    rows = list(csv.DictReader(open(path, newline="")))
    cl = []
    for r in rows:
        t = float(r["t"])
        if not cl or t - cl[-1][-1][0] > 0.09:
            cl.append([(t, r)])
        else:
            cl[-1].append((t, r))
    F = []
    for c in cl:
        t, r = c[-1]
        F.append(dict(t=t, L=i32(r["L"]), R=i32(r["R"]),
                      DL=int(r["DL"], 16), DR=int(r["DR"], 16),
                      M=int(r["M"]), T=r.get("T", ""), O=int(r.get("O", 0) or 0)))
    x = y = th = 0.0
    for i, f in enumerate(F):
        if i == 0:
            f["dl"] = f["dr"] = 0.0; f["dth"] = 0.0
        else:
            f["dl"] = -(f["L"] - F[i-1]["L"]) / CPM
            f["dr"] = -(f["R"] - F[i-1]["R"]) / CPM
            f["dth"] = (f["L"] - F[i-1]["L"] - f["R"] + F[i-1]["R"]) * DEG
        th += math.radians(f["dth"])
        x += (f["dl"] + f["dr"]) / 2 * math.sin(th)
        y += (f["dl"] + f["dr"]) / 2 * math.cos(th)
        f["x"], f["y"], f["th"] = x, y, math.degrees(th)
        f["ds"] = math.hypot(f["dl"], f["dr"]) if i else 0.0
    return F


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else ".scratch/run_avoid2.csv"
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(path)[0] + "_path.png"
    F = load(path)

    # --- 找绕障事件（连续 M=7）---
    eps, cur = [], None
    for i, f in enumerate(F):
        if f["M"] == 7:
            cur = [i, i] if cur is None else [cur[0], i]
        elif cur:
            eps.append(tuple(cur)); cur = None
    if cur: eps.append(tuple(cur))

    fig, ax = plt.subplots(figsize=(9, 8))
    ax.plot([f["x"] for f in F], [f["y"] for f in F], "-", lw=1.0,
            color="0.75", zorder=1, label="whole run")
    for k, (a, b) in enumerate(eps, 1):
        runs = []
        for i in range(a, b + 1):
            nm = PHASE.get((F[i]["DL"], F[i]["DR"]), ("?", 0))[0]
            if runs and runs[-1][0] == nm: runs[-1][2] = i
            else: runs.append([nm, i, i])
        for nm, i0, i1 in runs:
            seg = F[i0:i1+1]
            ax.plot([s["x"] for s in seg], [s["y"] for s in seg], "-", lw=3.0,
                    color=COLOR.get(nm, "k"), alpha=0.9,
                    label=nm if k == 1 else None)
            ax.plot(seg[0]["x"], seg[0]["y"], "o", ms=4, color=COLOR.get(nm, "k"))
        ax.annotate("avoid #%d" % k, (F[a]["x"], F[a]["y"]), textcoords="offset points",
                    xytext=(6, 6), fontsize=9, fontweight="bold")
    ax.plot(F[0]["x"], F[0]["y"], "ks", ms=9, label="start")
    ax.plot(F[-1]["x"], F[-1]["y"], "k*", ms=14, label="end")
    ax.set_aspect("equal"); ax.grid(alpha=0.3)
    ax.set_xlabel("x (mm)"); ax.set_ylabel("y (mm)")
    ax.set_title("avoidance run odometry (from UART encoders)")
    ax.legend(loc="best", fontsize=8)
    fig.tight_layout(); fig.savefig(out, dpi=130)
    print("wrote", out)

    # --- 每段表 ---
    print("\n%-11s %-15s %5s %8s %8s %8s %8s %9s %9s" % (
        "phase", "time", "frames", "dist_l", "dist_r", "r/l", "travel", "dth", "target"))
    for k, (a, b) in enumerate(eps, 1):
        runs = []
        for i in range(a, b + 1):
            nm = PHASE.get((F[i]["DL"], F[i]["DR"]), ("?", 0))
            if runs and runs[-1][0] == nm[0]: runs[-1][2] = i
            else: runs.append([nm[0], i, i, nm[1]])
        tot = 0.0
        for nm, i0, i1, tgt in runs:
            dl = sum(abs(F[j]["dl"]) for j in range(i0, i1+1))
            dr = sum(abs(F[j]["dl"]) for j in range(i0, i1+1))
            dr = sum(abs(F[j]["dr"]) for j in range(i0, i1+1))
            d = sum(F[j]["dth"] for j in range(i0, i1+1))
            tm = sum(max(0.0, F[j]["t"] - F[j-1]["t"]) for j in range(i0+1, i1+1)) if i1 > i0 else 0.3
            tr = dl + dr
            tot += tr
            print("#%d %-9s %5.2f..%5.2fs %5d %8.0f %8.0f %8.2f %8.0f %+8.1f %+8.1f" % (
                k, nm, F[i0]["t"], F[i1]["t"], i1-i0+1, dl, dr, dr/dl if dl else 0, tr, d, tgt))
        print("   #%d 合计行驶 %.0f mm，净转角 %+.1f°（设计 +90）" % (
            k, tot, sum(F[j]["dth"] for j in range(a, b+1))))


main()
