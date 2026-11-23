
# -*- coding: utf-8 -*-
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S
exec(open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/round_corner_sim.py", encoding="utf-8").read().split('print("R(mm)')[0])

def run0(R, s=30.0, tau=0.0, k=0.5, dp=0.0, t_end=28.0):
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
        if tau > 0:
            vL += (k*dl - vL)*(S.TICK_DT/tau); vR += (k*dr - vR)*(S.TICK_DT/tau)
        else:
            vL, vR = k*dl, k*dr
        v = (vL+vR)/2.0; w = (vR-vL)/S.WHEEL_BASE
        for _ in range(10):
            dt = S.TICK_DT/10
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        lat = S.track_dist(x, y, pts); max_lat = max(max_lat, lat); t += S.TICK_DT
        if lat > 150: return (False, max_lat)
        if y > dp + R + 400: return (max_lat < 45, max_lat)
    return (max_lat < 45, max_lat)

for tau, label in ((0.0, "理想电机 tau=0"), (0.15, "轻滞后 tau=0.15"), (0.30, "重滞后 tau=0.30")):
    print("=== %s ===" % label)
    print("S(mm)   R=300 最差   R=200 最差   R=150 最差   失败数")
    for s in (30, 60, 75, 90, 110):
        worst = [0.0, 0.0, 0.0]; fails = 0
        for R in (300, 200, 150):
            i = (300, 200, 150).index(R)
            for dp in (-15.0, -8.0, 0.0, 8.0, 15.0):
                ok, ml = run0(R, s=s, tau=tau, dp=dp)
                worst[i] = max(worst[i], ml)
                if not ok: fails += 1
        print("%5d   %8.1f   %8.1f   %8.1f   %d/15" % (s, worst[0], worst[1], worst[2], fails))
    print()
