# -*- coding: utf-8 -*-
"""带前馈 trim=-148 的选型：扫 P/D，看横向误差与抖动。"""
import math, sys, random
sys.path.insert(0,'bench')
from fast_corner import track_dist, sample, WHEEL_BASE, TICK_DT

KL, KR = 0.30, 0.165

def run(R, P, D, ilim, trim=0.0, ish=5, base=480.0, dp=0.0, flick=0.20, seed=1,
        t_end=40.0, lost_hold=0.30):
    rnd = random.Random(seed)
    x, y, th = 0.0, dp, 0.0
    pos_d = 0.0; i_acc = 0.0
    max_lat = 0.0; t = 0.0; lost_ms = 0
    flips = 0; last = 0; corrs = []
    while t < t_end:
        cnt, pos = sample(x, y, th, R, dp)
        if cnt and rnd.random() < flick:
            pos = max(-7, min(7, pos + rnd.choice((-1,1))))
        lost = (cnt == 0)
        lost_ms = lost_ms + 10 if lost else 0
        if lost_ms >= int(lost_hold*1000.0):
            dl = dr = 0.0
        else:
            err = float(pos)
            errd = 0.0 if lost else (err - pos_d)
            corr = trim + err*P + i_acc/(2.0**ish) + errd*D
            corr = max(-base, min(base, corr))
            dl = max(0.0, min(1200.0, base + corr))
            dr = max(0.0, min(1200.0, base - corr))
            if abs(corr) > 80:
                s = 1 if corr > 0 else -1
                if last and s != last: flips += 1
                last = s
            if not lost:
                pos_d = err
                i_acc = max(-ilim, min(ilim, i_acc + err))
            corrs.append(corr)
        vL, vR = KL*dl, KR*dr
        v = (vL+vR)/2.0; w = (vR-vL)/WHEEL_BASE
        for _ in range(10):
            dt = TICK_DT/10
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        max_lat = max(max_lat, track_dist(x, y, R, dp))
        t += TICK_DT
        if max_lat > 120: return False, max_lat, flips, t, 0.0
        if y > dp + R + 500 - 60: break
    sd = 0.0
    if corrs:
        m = sum(corrs)/len(corrs)
        sd = math.sqrt(sum((c-m)**2 for c in corrs)/len(corrs))
    return max_lat < 45, max_lat, flips, t, sd

RADII = [4000.0, 400.0, 300.0, 200.0, 160.0]
print('%-26s %s'%('cfg',' '.join('R=%-4d'%r for r in RADII)))
for trim in (0.0, -148.0):
    for P, D, ilim in [(120,220,640),(120,40,640),(120,40,6400),(96,40,6400),
                       (80,40,6400),(80,20,6400),(64,30,6400),(120,60,6400)]:
        row='%-26s'%('trim%-5.0f P%-3d D%-3d i%-5d'%(trim,P,D,ilim))
        for R in RADII:
            ok,lat,fl,tt,sd = run(R,P,D,ilim,trim=trim)
            row += ' %5.1f/%3d'%(lat,fl) if ok else ' OUT/%3d'%fl
        print(row)
    print()
