# -*- coding: utf-8 -*-
"""S=75mm（驱动轮后移后）下的 PID 参数扫描。
对比 P/D/I_SHIFT/I_LIMIT/BASE 在 tau=0（理想）与 tau=0.30（重滞后）下的表现。"""
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S
exec(open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/round_corner_sim.py", encoding="utf-8").read().split('print("R(mm)')[0])

def run1(R, dp, P, D, ish, ilim, base, s=75.0, tau=0.0, k=0.5, t_end=28.0):
    S.SENSOR_FWD = s; S.K_MMS = k
    pts = make_round(R, dp); sens = S.Sensor(pts)
    x, y, th = 0.0, dp, 0.0
    pos_d = 0.0; i_acc = 0; t = 0.0
    vL = vR = 0.0; max_lat = 0.0
    while t < t_end:
        r = sens.sample(x, y, th)
        pos, lost = float(r['pos']), r['lost']
        err = pos; errd = err - pos_d
        corr = max(-base, min(base, err * P + int(i_acc >> ish) + errd * D))
        dl = max(0.0, min(1200.0, base + corr)); dr = max(0.0, min(1200.0, base - corr))
        if not lost:
            pos_d = err; i_acc = max(-ilim, min(ilim, i_acc + int(round(err))))
        if tau > 0:
            vL += (k * dl - vL) * (S.TICK_DT / tau); vR += (k * dr - vR) * (S.TICK_DT / tau)
        else:
            vL, vR = k * dl, k * dr
        v = (vL + vR) / 2.0; w = (vR - vL) / S.WHEEL_BASE
        for _ in range(10):
            dt = S.TICK_DT / 10
            x += v * math.cos(th) * dt; y += v * math.sin(th) * dt; th += w * dt
        lat = S.track_dist(x, y, pts); max_lat = max(max_lat, lat); t += S.TICK_DT
        if lat > 150: return (False, max_lat)
        if y > dp + R + 400: return (max_lat < 45, max_lat)
    return (max_lat < 45, max_lat)

P_GRID = (56, 72, 96, 128, 168)
D_GRID = (0, 40, 80, 140)
TAUS = (0.0, 0.30)
RS = (250, 180)
DPS = (-12.0, 0.0, 12.0)

rows = []
for tau in TAUS:
    for P in P_GRID:
        for D in D_GRID:
            fails = 0; worst = 0.0; worstby = {}
            for R in RS:
                w = 0.0
                for dp in DPS:
                    ok, ml = run1(R, dp, P, D, 5, 640, 480.0, tau=tau)
                    w = max(w, ml); worst = max(worst, ml)
                    if not ok: fails += 1
                worstby[R] = w
            rows.append((tau, P, D, fails, worst, worstby))

print("tau    P     D    fails  worstLat  R250    R180")
for tau, P, D, fails, worst, wb in sorted(rows, key=lambda r: (r[0], r[3], r[4])):
    print("%.2f  %4d  %4d   %d/6    %6.1f  %6.1f  %6.1f" % (tau, P, D, fails, worst, wb[250], wb[180]))
print()
print("=== 每档 tau 最优前 3 ===")
for tau in TAUS:
    sub = sorted([r for r in rows if r[0] == tau], key=lambda r: (r[3], r[4]))[:3]
    for tau2, P, D, fails, worst, wb in sub:
        print("tau=%.2f P=%d D=%d fails=%d/6 worst=%.1f" % (tau, P, D, fails, worst))
