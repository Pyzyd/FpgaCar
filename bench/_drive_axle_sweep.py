
# -*- coding: utf-8 -*-
"""把驱动轮后移 = 增大「探头到驱动轴中点」的距离 S（等价 SENSOR_FWD）。
   在圆角弯道上扫 S，分别看 tau=0（理想电机）与 tau=0.30（有滞后）。"""
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S
exec(open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/round_corner_sim.py", encoding="utf-8").read().split('print("R(mm)')[0])

def runs(R, s=30.0, tau=0.0, k=0.5, t_end=28.0, P=72.0, D=40.0):
    S.SENSOR_FWD = s
    S.K_MMS = k
    pts = make_round(R)
    sens = S.Sensor(pts)
    x = y = th = 0.0
    pos_d = 0.0; i_acc = 0; t = 0.0
    base = 480.0
    vL = vR = 0.0; max_lat = 0.0
    while t < t_end:
        r = sens.sample(x, y, th)
        cnt, pos, lost = r['cnt'], float(r['pos']), r['lost']
        err = pos; errd = err - pos_d
        corr = max(-base, min(base, err*P + int(i_acc>>5) + errd*D))
        dl = max(0.0, min(1200.0, base + corr)); dr = max(0.0, min(1200.0, base - corr))
        if not lost:
            pos_d = err; i_acc = max(-640, min(640, i_acc + int(round(err))))
        tl, tr = k*dl, k*dr
        if tau > 0:
            vL += (tl - vL)*(S.TICK_DT/tau); vR += (tr - vR)*(S.TICK_DT/tau)
        else:
            vL, vR = tl, tr
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

for tau in (0.0, 0.30):
    print("=== tau=%.2f（%s） ===" % (tau, "理想电机" if tau == 0 else "有明显滞后"))
    print("S(mm)  R=300      R=250      R=200      R=150      R=100")
    for s in (30, 45, 60, 75, 90, 110, 130, 150, 170):
        row = []
        for R in (300, 250, 200, 150, 100):
            ok, ml = runs(R, s=s, tau=tau)
            row.append("%s%6.1f" % ("Y" if ok else "N", ml))
        print("%5d  %s" % (s, "  ".join(row)))
    print()
