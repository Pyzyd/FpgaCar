
# -*- coding: utf-8 -*-
"""45 度斜切拐角。修正终点判据：赛道到 y = L + EXIT 结束，不能等 y>1000。"""
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S

LEAD = 400.0
EXIT = 500.0

def make_chamfer(L, dphase=0.0):
    pts = []
    x = 0.0
    while x < LEAD:
        pts.append((x, dphase)); x += 2.0
    a = (LEAD, dphase); b = (LEAD + L, dphase + L); c = (LEAD + L, dphase + L + EXIT)
    for p, q in ((a, b), (b, c)):
        n = max(2, int(math.hypot(q[0]-p[0], q[1]-p[1]) / 2.0))
        for i in range(1, n + 1):
            pts.append((p[0] + (q[0]-p[0]) * i / n, p[1] + (q[1]-p[1]) * i / n))
    return pts

def run(pts, dphase=0.0, mode='freeze', t_end=25.0, k=None):
    if k is not None: S.K_MMS = k
    L = max(p[1] for p in pts) - dphase - EXIT
    endy = dphase + L + EXIT
    sens = S.Sensor(pts)
    x, y, th = 0.0, dphase, 0.0
    pos_d = 0; i_acc = 0; t = 0.0
    P = 72.0; D = 40.0; base = 480.0
    max_lat = 0.0; last_pos = 0
    while t < t_end:
        r = sens.sample(x, y, th)
        cnt, pos, lost, wide = r['cnt'], r['pos'], r['lost'], r['wide']
        if cnt > 0 and pos != 0: last_pos = pos
        if lost and mode == 'pivot':
            sgn = -1.0 if last_pos >= 0 else 1.0
            dl, dr = base - 260*sgn, base + 260*sgn
        else:
            err = pos; errd = err - pos_d
            s = max(-base, min(base, err*P + (i_acc>>5) + errd*D))
            dl, dr = base + s, base - s
            if not lost:
                pos_d = err; i_acc = max(-640, min(640, i_acc+err))
        dl = max(0.0, min(1200.0, dl)); dr = max(0.0, min(1200.0, dr))
        vl, vr = S.K_MMS*dl, S.K_MMS*dr
        v = (vl+vr)/2.0; w = (vr-vl)/S.WHEEL_BASE
        for _ in range(10):
            dt = S.TICK_DT/10
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        lat = S.track_dist(x, y, pts)
        max_lat = max(max_lat, lat)
        t += S.TICK_DT
        if lat > 150: return dict(ok=False, max_lat=max_lat, t=t)
        if y > endy - 100: return dict(ok=max_lat < 45, max_lat=max_lat, t=t)
    return dict(ok=max_lat < 45, max_lat=max_lat, t=t)

print("45 度斜切拐角（斜边水平投影 L）")
print("  L(mm)   maxLat  结果  t       pivot修法")
for L in (250, 200, 150, 120, 100, 80, 60, 50, 40, 30, 20):
    a = run(make_chamfer(L), 0.0, 'freeze')
    b = run(make_chamfer(L), 0.0, 'pivot')
    print("%6d  %7.1f  %s  %5.2f   %s %5.1f" % (L, a['max_lat'], "Y" if a['ok'] else "N", a['t'], "Y" if b['ok'] else "N", b['max_lat']))
