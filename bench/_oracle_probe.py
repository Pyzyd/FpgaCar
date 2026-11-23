
# -*- coding: utf-8 -*-
"""对照组：把真实横向误差直接换算成 pos 喂给同一个 PID（oracle）。
   若它能过 90 度拐角，说明控制律本身没问题，问题在「测出来的偏差被置零」。"""
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S

def signed_lat(px, py, pts):
    best = (1e9, 1.0)
    for i in range(len(pts) - 1):
        (x1, y1), (x2, y2) = pts[i], pts[i + 1]
        dx, dy = x2 - x1, y2 - y1
        L2 = dx * dx + dy * dy
        if L2 <= 0: continue
        t = ((px - x1) * dx + (py - y1) * dy) / L2
        t = max(0.0, min(1.0, t))
        qx, qy = x1 + t * dx, y1 + t * dy
        dd = math.hypot(px - qx, py - qy)
        if dd < best[0]:
            cross = dx * (py - y1) - dy * (px - x1)
            best = (dd, 1.0 if cross > 0 else -1.0)
    return best[0] * best[1]

def run(mode='sensor', turn_deg=90.0, turn='L', t_end=16.0, sgn=1.0, mm_per_pos=5.3):
    pts = S.make_track(turn_deg, turn)
    sens = S.Sensor(pts)
    x = y = th = 0.0
    pos_d = 0; i_acc = 0; duty = (480, 480); t = 0.0
    P = 72.0; D = 40.0; base = 480.0
    max_lat = 0.0; zero_ms = 0; total_ms = 0
    while t < t_end:
        r = sens.sample(x, y, th)
        cnt, pos, lost, wide = r['cnt'], r['pos'], r['lost'], r['wide']
        lat = S.track_dist(x, y, pts)
        max_lat = max(max_lat, lat)
        if mode == 'sensor':
            pin = pos
            if cnt > 0 or wide: total_ms += 1
            if (cnt > 0 and pos == 0) or wide: zero_ms += 1
        else:
            e = signed_lat(x, y, pts) * sgn
            if cnt > 0 or wide: total_ms += 1
            if (cnt > 0 and pos == 0) or wide: zero_ms += 1
            pin = int(round(e / mm_per_pos))
            pin = max(-7, min(7, pin))
        err = pin; errd = err - pos_d
        sraw = err * P + (i_acc >> 5) + errd * D
        s = max(-base, min(base, sraw))
        dl, dr = base + s, base - s
        dl = max(0, min(1200, dl)); dr = max(0, min(1200, dr))
        pos_d = err; i_acc = max(-640, min(640, i_acc + err))
        vl, vr = S.K_MMS * dl, S.K_MMS * dr
        v = (vl + vr) / 2.0; w = (vr - vl) / S.WHEEL_BASE
        for _ in range(10):
            dt = S.TICK_DT / 10
            x += v * math.cos(th) * dt; y += v * math.sin(th) * dt; th += w * dt
        t += S.TICK_DT
        if lat > 150:
            return dict(ok=False, max_lat=max_lat, t=t, zero_pct=100.0 * zero_ms / max(1, total_ms))
    return dict(ok=max_lat < 60, max_lat=max_lat, t=t, zero_pct=100.0 * zero_ms / max(1, total_ms))

print("mode        sign  90L              75L              60L")
for mode, sgn in (('sensor', 1.0), ('oracle', 1.0), ('oracle', -1.0)):
    row = []
    for ang in (90.0, 75.0, 60.0):
        r = run(mode, ang, 'L', sgn=sgn)
        row.append("%s %5.1f" % ("Y" if r['ok'] else "N", r['max_lat']))
    r90 = run(mode, 90.0, 'L', sgn=sgn)
    print("%-11s %+4.0f  %s   (偏差输入被置零 %4.1f%% of 有线条的毫秒)" % (mode, sgn, "  ".join(row), r90['zero_pct']))
