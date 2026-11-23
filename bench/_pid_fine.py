# -*- coding: utf-8 -*-
"""细化扫描：P 96~220 × D 100~260，base 固定 480。"""
import sys, itertools, math
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import fast_corner as F

F.SENSOR_FWD = 75.0
RS = (320, 250, 200, 160, 130, 100)
DPS = (-15.0, -8.0, 0.0, 8.0, 15.0)
TAUS = (0.0, 0.15, 0.30)

def jitter(P, D_, ish=5, base=480.0, tau=0.0):
    x, y, th = 0.0, 6.0, 0.0
    pos_d = 0.0; i_acc = 0.0; t = 0.0; vL = vR = 0.0; hist = []
    while t < 3.0:
        cnt, pos = F.sample(x, y, th, 10 ** 9, 0.0)
        lost = (cnt == 0)
        err = pos
        errd = 0.0 if lost else (err - pos_d)
        corr = max(-base, min(base, err * P + int(i_acc) / (2.0 ** ish) + errd * D_))
        dl = max(0.0, min(1200.0, base + corr)); dr = max(0.0, min(1200.0, base - corr))
        if not lost:
            pos_d = err; i_acc = max(-640, min(640, i_acc + err))
        if tau > 0:
            vL += (F.K_MMS * dl - vL) * (F.TICK_DT / tau)
            vR += (F.K_MMS * dr - vR) * (F.TICK_DT / tau)
        else:
            vL, vR = F.K_MMS * dl, F.K_MMS * dr
        v = (vL + vR) / 2.0; w = (vR - vL) / F.WHEEL_BASE
        for _ in range(10):
            dt = F.TICK_DT / 10
            x += v * math.cos(th) * dt; y += v * math.sin(th) * dt; th += w * dt
        t += F.TICK_DT
        if t > 1.5: hist.append(y)
    return max(hist) - min(hist)

P_GRID = (96, 120, 144, 168, 200)
D_GRID = (100, 140, 180, 220, 260)
rows = []
for P, D_ in itertools.product(P_GRID, D_GRID):
    fails = 0; worst = 0.0; byR = {}
    for tau in TAUS:
        for R in RS:
            w = 0.0
            for dp in DPS:
                ok, ml = F.run(R, dp=dp, P=P, D=D_, ish=5, ilim=640, base=480.0, tau=tau)
                w = max(w, ml)
                if not ok: fails += 1
            byR[R] = max(byR.get(R, 0.0), w); worst = max(worst, w)
    rows.append((fails, worst, P, D_, byR, jitter(P, D_), jitter(P, D_, tau=0.30)))

rows.sort(key=lambda r: (r[0], r[1]))
print("P    D   fails worst  R320 R250 R200 R160 R130 R100   抖动 t0/t30")
for fails, worst, P, D_, byR, j0, j3 in rows:
    print("%3d %4d  %2d/90 %6.1f  %5.1f%5.1f%5.1f%5.1f%5.1f%5.1f   %.2f/%.2f" % (
        P, D_, fails, worst, byR[320], byR[250], byR[200], byR[160], byR[130], byR[100], j0, j3))
