
# -*- coding: utf-8 -*-
"""弯道自动降速：基础占空比随位置偏差绝对值和修正量增大而降低。
   base = BASE_MAX - (BASE_MAX-BASE_MIN)*min(|pos|,4)/4   —— 纯 RTL 可实现（移位+比较）"""
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S
exec(open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/round_corner_sim.py", encoding="utf-8").read().split('print("R(mm)')[0])

def runa(R, tau=0.30, k=0.5, P=72.0, D=40.0, bmax=480.0, bmin=480.0, t_end=28.0):
    S.K_MMS = k
    pts = make_round(R)
    sens = S.Sensor(pts)
    x = y = th = 0.0
    pos_d = 0.0; i_acc = 0; t = 0.0
    vL = vR = 0.0; max_lat = 0.0
    while t < t_end:
        r = sens.sample(x, y, th)
        cnt, pos, lost = r['cnt'], r['pos'], r['lost']
        pos = float(pos)
        base = bmax - (bmax - bmin) * min(abs(pos), 4.0) / 4.0
        err = pos; errd = err - pos_d
        s = max(-base, min(base, err*P + int(i_acc>>5) + errd*D))
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
        if lat > 150: return (False, max_lat, t)
        if y > R + 400: return (max_lat < 45, max_lat, t)
    return (max_lat < 45, max_lat, t)

print("弯道自动降速：base 从 480 线性降到 bmin（|pos|>=4 时）")
print("配置(tau=0.30)          R=300      R=250      R=200      R=150")
for bmin in (480, 420, 360, 300, 240, 180):
    row = []
    for R in (300, 250, 200, 150):
        ok, ml, tt = runa(R, bmin=bmin)
        row.append("%s%6.1f" % ("Y" if ok else "N", ml))
    print("bmin=%-3d (%.0f%% speed)  %s" % (bmin, 100.0*bmin/480, "  ".join(row)))

print()
print("选 bmin=300，再跨 tau 验证：")
print("tau     R=300      R=250      R=200      R=150")
for tau in (0.06, 0.10, 0.20, 0.30, 0.40):
    row = []
    for R in (300, 250, 200, 150):
        ok, ml, tt = runa(R, tau=tau, bmin=300)
        row.append("%s%6.1f" % ("Y" if ok else "N", ml))
    print("%.2f   %s" % (tau, "  ".join(row)))
