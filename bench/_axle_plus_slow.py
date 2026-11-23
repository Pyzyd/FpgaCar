
# -*- coding: utf-8 -*-
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S
exec(open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/round_corner_sim.py", encoding="utf-8").read().split('print("R(mm)')[0])

def runz(R, s=75.0, tau=0.30, k=0.5, bmin=480.0, t_end=28.0):
    S.SENSOR_FWD = s; S.K_MMS = k
    pts = make_round(R); sens = S.Sensor(pts)
    x = y = th = 0.0; pos_d = 0.0; i_acc = 0; t = 0.0
    vL = vR = 0.0; max_lat = 0.0
    while t < t_end:
        r = sens.sample(x, y, th)
        cnt, pos, lost = r['cnt'], float(r['pos']), r['lost']
        base = 480.0 - (480.0 - bmin) * min(abs(pos), 4.0) / 4.0
        err = pos; errd = err - pos_d
        corr = max(-base, min(base, err*72.0 + int(i_acc>>5) + errd*40.0))
        dl = max(0.0, min(1200.0, base + corr)); dr = max(0.0, min(1200.0, base - corr))
        if not lost:
            pos_d = err; i_acc = max(-640, min(640, i_acc + int(round(err))))
        vL += (k*dl - vL)*(S.TICK_DT/tau); vR += (k*dr - vR)*(S.TICK_DT/tau)
        v = (vL+vR)/2.0; w = (vR-vL)/S.WHEEL_BASE
        for _ in range(10):
            dt = S.TICK_DT/10
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        lat = S.track_dist(x, y, pts); max_lat = max(max_lat, lat); t += S.TICK_DT
        if lat > 150: return (False, max_lat)
        if y > R + 400: return (max_lat < 45, max_lat)
    return (max_lat < 45, max_lat)

print("tau=0.30，组合「驱动轮后移(S) + 弯道降速(bmin)」")
print("S     bmin    R=300   R=250   R=200   R=150   R=100")
for s in (75, 90):
    for bmin in (480, 420, 360, 300):
        row = []
        for R in (300, 250, 200, 150, 100):
            ok, ml = runz(R, s=s, bmin=bmin)
            row.append("%s%6.1f" % ("Y" if ok else "N", ml))
        print("%-4d %-6d %s" % (s, bmin, "  ".join(row)))
    print()
