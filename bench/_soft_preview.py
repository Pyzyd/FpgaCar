
# -*- coding: utf-8 -*-
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S
exec(open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/round_corner_sim.py", encoding="utf-8").read().split('print("R(mm)')[0])

def runp(R, K=0.0, tau=0.30, k=0.5, P=72.0, D=40.0, t_end=25.0):
    S.K_MMS = k
    pts = make_round(R)
    sens = S.Sensor(pts)
    x = y = th = 0.0
    pos_d = 0.0; i_acc = 0; t = 0.0
    base = 480.0
    vL = vR = 0.0; max_lat = 0.0
    while t < t_end:
        r = sens.sample(x, y, th)
        cnt, pos, lost = r['cnt'], r['pos'], r['lost']
        pos = float(pos)
        pred = pos + (pos - pos_d) * K if K > 0 else pos
        pred = max(-8.0, min(8.0, pred))
        err = pred; errd = err - pos_d
        s = max(-base, min(base, err*P + int(i_acc >> 5) + errd*D))
        dl = max(0.0, min(1200.0, base + s)); dr = max(0.0, min(1200.0, base - s))
        if not lost:
            pos_d = err; i_acc = max(-640, min(640, i_acc + int(round(err))))
        tl, tr = k*dl, k*dr
        vL += (tl - vL)*(S.TICK_DT/tau); vR += (tr - vR)*(S.TICK_DT/tau)
        v = (vL+vR)/2.0; w = (vR-vL)/S.WHEEL_BASE
        for _ in range(10):
            dt = S.TICK_DT/10
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        lat = S.track_dist(x, y, pts)
        max_lat = max(max_lat, lat)
        t += S.TICK_DT
        if lat > 150: return (False, max_lat)
        if y > R + 400: return (max_lat < 45, max_lat)
    return (max_lat < 45, max_lat)

print("软件预瞄 K（tau=0.30, k=0.5）  Y=过 N=出线")
print("K      R=300      R=250      R=200      R=150")
for K in (0, 1, 2, 3, 4, 6, 8, 12):
    row = []
    for R in (300, 250, 200, 150):
        ok, ml = runp(R, K=K)
        row.append("%s%6.1f" % ("Y" if ok else "N", ml))
    print("%-4d %s" % (K, "  ".join(row)))

print()
print("K=4 跨 tau：")
print("tau     R=300      R=250      R=200      R=150")
for tau in (0.06, 0.10, 0.20, 0.30, 0.40, 0.60):
    row = []
    for R in (300, 250, 200, 150):
        ok, ml = runp(R, K=4, tau=tau)
        row.append("%s%6.1f" % ("Y" if ok else "N", ml))
    print("%.2f   %s" % (tau, "  ".join(row)))
