
# -*- coding: utf-8 -*-
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S
exec(open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/round_corner_sim.py", encoding="utf-8").read().split('print("R(mm)')[0])

def runr(R, s=30.0, tau=0.30, k=0.5, dp=0.0, t_end=28.0):
    S.SENSOR_FWD = s; S.K_MMS = k
    pts = make_round(R, dp); sens = S.Sensor(pts)
    x, y, th = 0.0, dp, 0.0
    pos_d = 0.0; i_acc = 0; t = 0.0
    vL = vR = 0.0; max_lat = 0.0
    while t < t_end:
        r = sens.sample(x, y, th)
        cnt, pos, lost = r['cnt'], float(r['pos']), r['lost']
        err = pos; errd = err - pos_d
        corr = max(-480.0, min(480.0, err*72.0 + int(i_acc>>5) + errd*40.0))
        dl = max(0.0, min(1200.0, 480.0 + corr)); dr = max(0.0, min(1200.0, 480.0 - corr))
        if not lost:
            pos_d = err; i_acc = max(-640, min(640, i_acc + int(round(err))))
        vL += (k*dl - vL)*(S.TICK_DT/tau); vR += (k*dr - vR)*(S.TICK_DT/tau)
        v = (vL+vR)/2.0; w = (vR-vL)/S.WHEEL_BASE
        for _ in range(10):
            dt = S.TICK_DT/10
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        lat = S.track_dist(x, y, pts); max_lat = max(max_lat, lat); t += S.TICK_DT
        if lat > 150: return (False, max_lat)
        if y > dp + R + 400: return (max_lat < 45, max_lat)
    return (max_lat < 45, max_lat)

print("tau=0.30 下，带 ±15mm 入弯偏差的鲁棒性（R=300/200/150）")
print("S(mm)        R=300            R=200            R=150")
for s in (30, 60, 75, 90, 100, 110):
    cells = []
    for R in (300, 200, 150):
        worst = 0.0; fails = 0
        for dp in (-15.0, -8.0, 0.0, 8.0, 15.0):
            ok, ml = runr(R, s=s, dp=dp)
            worst = max(worst, ml)
            if not ok: fails += 1
        cells.append("%d/5失败 最差%5.1f" % (fails, worst))
    print("%5d   %s" % (s, "  ".join(cells)))

print()
print("原地转身时车尾角扫出半径（车身 200mm 长、65mm 半宽，探头在车头）")
for nose_to_axle in (30, 60, 75, 90, 100, 120):
    over = 200.0 - nose_to_axle
    print("  驱动轴距车头 %3d mm  -> 车尾悬伸 %3d mm, 尾角扫出半径 %5.1f mm" % (
        nose_to_axle, over, math.hypot(over, 65.0)))
