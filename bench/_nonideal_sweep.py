
# -*- coding: utf-8 -*-
"""圆角弯道下，把仿真里没建模的物理量逐个加上去，看哪一个会把 R=200/150/100 的弯弄崩。
   tau: 电机+车体一阶滞后(s)   dz: 起转死区(duty)   mis: 右轮/左轮增益失配   fwd: 探头到驱动轴距离(mm)"""
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S
exec(open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/round_corner_sim.py", encoding="utf-8").read().split('print("R(mm)')[0])

def runx(R, tau=0.0, dz=0.0, mis=1.0, fwd=None, t_end=22.0, k=0.5):
    if fwd is not None: S.SENSOR_FWD = fwd
    S.K_MMS = k
    pts = make_round(R)
    sens = S.Sensor(pts)
    x = y = th = 0.0
    pos_d = 0; i_acc = 0; t = 0.0
    P = 72.0; D = 40.0; base = 480.0
    vL = vR = 0.0
    max_lat = 0.0
    def target(duty):
        return 0.0 if duty <= dz else S.K_MMS * (duty - dz) * (dz > 0 and 1.0 or 1.0)
    endy = R + 500.0
    while t < t_end:
        r = sens.sample(x, y, th)
        cnt, pos, lost = r['cnt'], r['pos'], r['lost']
        err = pos; errd = err - pos_d
        s = max(-base, min(base, err*P + (i_acc>>5) + errd*D))
        dl, dr = base + s, base - s
        dl = max(0.0, min(1200.0, dl)); dr = max(0.0, min(1200.0, dr))
        if not lost:
            pos_d = err; i_acc = max(-640, min(640, i_acc+err))
        tl, tr = target(dl), target(dr) * mis
        if tau > 0:
            vL += (tl - vL) * (S.TICK_DT / tau); vR += (tr - vR) * (S.TICK_DT / tau)
        else:
            vL, vR = tl, tr
        v = (vL + vR) / 2.0; w = (vR - vL) / S.WHEEL_BASE
        for _ in range(10):
            dt = S.TICK_DT / 10
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        lat = S.track_dist(x, y, pts)
        max_lat = max(max_lat, lat)
        t += S.TICK_DT
        if lat > 150: return (False, max_lat)
        if y > endy - 100: return (max_lat < 45, max_lat)
    return (max_lat < 45, max_lat)

cases = [("基准", {}),
         ("tau=0.05", {"tau": 0.05}), ("tau=0.10", {"tau": 0.10}), ("tau=0.20", {"tau": 0.20}),
         ("dz=120", {"dz": 120.0}), ("dz=240", {"dz": 240.0}), ("dz=360", {"dz": 360.0}),
         ("mis=1.05", {"mis": 1.05}), ("mis=1.10", {"mis": 1.10}), ("mis=1.20", {"mis": 1.20}),
         ("fwd=15", {"fwd": 15.0}), ("fwd=45", {"fwd": 45.0}), ("fwd=60", {"fwd": 60.0}),
         ("tau.1+mis.1", {"tau": 0.10, "mis": 1.10})]
print("工况            R=200      R=150      R=100")
for name, kw in cases:
    row = []
    for R in (200, 150, 100):
        ok, ml = runx(R, **kw)
        row.append("%s%6.1f" % ("Y" if ok else "N", ml))
    print("%-14s %s" % (name, "  ".join(row)))
