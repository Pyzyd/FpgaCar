# -*- coding: utf-8 -*-
"""S=75mm 下的 PID 参数扫描。解析仿真 fast_corner，单点约 3 ms。"""
import sys, itertools
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import fast_corner as F

F.SENSOR_FWD = 75.0
RS = (300, 220, 160)
DPS = (-15.0, -8.0, 0.0, 8.0, 15.0)
TAUS = (0.0, 0.15, 0.30)

def score(P, D, ish, ilim, base):
    fails = 0; worst = 0.0; per_r = {}
    for tau in TAUS:
        for R in RS:
            w = 0.0
            for dp in DPS:
                ok, ml = F.run(R, dp=dp, P=P, D=D, ish=ish, ilim=ilim,
                               base=base, tau=tau)
                w = max(w, ml)
                if not ok:
                    fails += 1
            per_r[(tau, R)] = w
            worst = max(worst, w)
    return fails, worst, per_r

P_GRID = (40, 56, 72, 96, 128, 168, 220)
D_GRID = (0, 40, 80, 140, 200)
ISH_GRID = (5, 4)
BASE_GRID = (480, 420, 360)

rows = []
for P, D, ish, base in itertools.product(P_GRID, D_GRID, ISH_GRID, BASE_GRID):
    fails, worst, per_r = score(P, D, ish, 640, float(base))
    rows.append(dict(P=P, D=D, ish=ish, base=base, fails=fails,
                     worst=worst, per_r=per_r))

rows.sort(key=lambda r: (r['fails'], r['worst']))
print("P    D   ish base  fails  worst  R300(t0/t15/t30) R220  R160")
for r in rows[:25]:
    g = lambda R: "%5.1f/%5.1f/%5.1f" % tuple(r['per_r'][(t, R)] for t in TAUS)
    print("%3d %4d  %d  %4d  %2d/45  %6.1f  %s  %s  %s" % (
        r['P'], r['D'], r['ish'], r['base'], r['fails'], r['worst'],
        g(300), g(220), g(160)))

print()
print("=== 当前参数 (P=72 D=40 ish=5 base=480) 定位 ===")
for r in rows:
    if (r['P'], r['D'], r['ish'], r['base']) == (72, 40, 5, 480):
        print("fails=%d worst=%.1f" % (r['fails'], r['worst']))
        for t in TAUS:
            print("  tau=%.2f: " % t + " ".join(
                "R%d=%.1f" % (R, r['per_r'][(t, R)]) for R in RS))
