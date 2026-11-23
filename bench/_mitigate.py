
# -*- coding: utf-8 -*-
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S
exec(open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/round_corner_sim.py", encoding="utf-8").read().split('print("R(mm)')[0])

def runy(R, tau=0.30, k=0.5, P=72.0, D=40.0, fwd=None, t_end=25.0):
    if fwd is not None: S.SENSOR_FWD = fwd
    S.K_MMS = k
    pts = make_round(R)
    sens = S.Sensor(pts)
    x = y = th = 0.0
    pos_d = 0; i_acc = 0; t = 0.0
    base = 480.0
    vL = vR = 0.0; max_lat = 0.0
    while t < t_end:
        r = sens.sample(x, y, th)
        cnt, pos, lost = r['cnt'], r['pos'], r['lost']
        err = pos; errd = err - pos_d
        s = max(-base, min(base, err*P + (i_acc>>5) + errd*D))
        dl = max(0.0, min(1200.0, base + s)); dr = max(0.0, min(1200.0, base - s))
        if not lost:
            pos_d = err; i_acc = max(-640, min(640, i_acc+err))
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

print("tau=0.30 下各种缓解手段 (R=250/200/150)")
print("手段                        R=250      R=200      R=150")
cases = [("基准 P72 D40 k0.5", {}),
         ("降速 k=0.35", {"k": 0.35}),
         ("降速 k=0.25", {"k": 0.25}),
         ("D 加到 100", {"D": 100.0}),
         ("D 加到 200", {"D": 200.0}),
         ("D=150 + k0.35", {"D": 150.0, "k": 0.35}),
         ("探头 fwd=60", {"fwd": 60.0}),
         ("fwd=60 + k0.35", {"fwd": 60.0, "k": 0.35}),
         ("fwd=60 + D100", {"fwd": 60.0, "D": 100.0})]
for name, kw in cases:
    row = []
    for R in (250, 200, 150):
        ok, ml = runy(R, **kw)
        row.append("%s%6.1f" % ("Y" if ok else "N", ml))
    print("%-24s %s" % (name, "  ".join(row)))
