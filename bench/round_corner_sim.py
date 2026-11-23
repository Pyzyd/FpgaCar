
# -*- coding: utf-8 -*-
"""圆角弯道：直线 + 与两直线相切的 90 度圆弧 + 出弯直线。
   修正出弯直道的 x 坐标（应为 LEAD+R，之前误写成 LEAD 导致赛道自交）。"""
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S

LEAD = 400.0
EXIT = 500.0

def make_round(R, dphase=0.0):
    pts = []
    x = 0.0
    while x < LEAD:
        pts.append((x, dphase)); x += 2.0
    cx, cy = LEAD, dphase + R
    n = max(8, int(R))          # 弧上采样点：每 1 mm 一个
    for i in range(n + 1):
        a = -math.pi / 2.0 + (math.pi / 2.0) * i / n
        pts.append((cx + R * math.cos(a), cy + R * math.sin(a)))
    y = dphase + R
    while y <= dphase + R + EXIT:
        pts.append((cx + R, y)); y += 2.0
    return pts

def run(R, dphase=0.0, mode='freeze', t_end=20.0, k=None):
    if k is not None: S.K_MMS = k
    pts = make_round(R, dphase)
    sens = S.Sensor(pts)
    x = 0.0; y = dphase; th = 0.0
    pos_d = 0; i_acc = 0; t = 0.0
    P = 72.0; D = 40.0; base = 480.0
    max_lat = 0.0; last_pos = 0; end_y = dphase + R + EXIT
    while t < t_end:
        r = sens.sample(x, y, th)
        cnt, pos, lost, wide = r['cnt'], r['pos'], r['lost'], r['wide']
        if cnt > 0 and pos != 0: last_pos = pos
        if lost and mode == 'pivot':
            sgn = -1.0 if last_pos >= 0 else 1.0
            dl, dr = base - 260 * sgn, base + 260 * sgn
        else:
            err = pos; errd = err - pos_d
            sraw = err * P + (i_acc >> 5) + errd * D
            s = max(-base, min(base, sraw))
            dl, dr = base + s, base - s
            if not lost:
                pos_d = err; i_acc = max(-640, min(640, i_acc + err))
        dl = max(0.0, min(1200.0, dl)); dr = max(0.0, min(1200.0, dr))
        vl, vr = S.K_MMS * dl, S.K_MMS * dr
        v = (vl + vr) / 2.0; w = (vr - vl) / S.WHEEL_BASE
        for _ in range(10):
            dt = S.TICK_DT / 10
            x += v * math.cos(th) * dt; y += v * math.sin(th) * dt; th += w * dt
        lat = S.track_dist(x, y, pts)
        max_lat = max(max_lat, lat)
        t += S.TICK_DT
        if lat > 150:
            return dict(ok=False, max_lat=max_lat, why='脱轨 t=%.2f' % t)
        if y > end_y - 60:
            return dict(ok=max_lat < 45, max_lat=max_lat, why='跑完 t=%.2f' % t)
    return dict(ok=max_lat < 45, max_lat=max_lat, why='超时')

print("R(mm)   maxLat  结果   t      ±12mm 入弯偏差")
for R in (400, 320, 280, 240, 200, 180, 160, 140, 120, 100, 80):
    r0 = run(R)
    offs = []
    for dp in (-12.0, 12.0):
        ro = run(R, dp)
        offs.append("%s%5.1f" % ("Y" if ro['ok'] else "N", ro['max_lat']))
    print("%4d  %6.1f  %s  %5s   %s" % (R, r0['max_lat'], "Y" if r0['ok'] else "N", r0['why'][-5:], "  ".join(offs)))
