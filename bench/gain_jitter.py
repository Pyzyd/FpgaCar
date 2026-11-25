# -*- coding: utf-8 -*-
"""更好的指标：每 300ms 报文间 |dcorr| 的中位/p90，以及横向误差 RMS。
   对比三条路线：
   A 积分自适应（只放大积分容量/加快），trim=0
   B 前馈 trim 固定 -148
   C 前馈 + 小积分"""
import math, sys, random
sys.path.insert(0,'bench')
from fast_corner import track_dist, sample, WHEEL_BASE, TICK_DT

KL, KR = 0.30, 0.165
REPORT_EVERY = 30   # 10ms tick x30 = 300ms

def run(R, P, D, ilim, ish, trim=0.0, base=480.0, dp=0.0, flick=0.20, seed=1,
        t_end=45.0, lost_hold=0.30):
    rnd = random.Random(seed)
    x, y, th = 0.0, dp, 0.0
    pos_d = 0.0; i_acc = 0.0
    max_lat = 0.0; t = 0.0; lost_ms = 0
    lat_sum = 0.0; n = 0
    hist = []; step = 0
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
            if not lost:
                pos_d = err
                i_acc = max(-ilim, min(ilim, i_acc + err))
            step += 1
            if step % REPORT_EVERY == 0:
                hist.append(corr)
        vL, vR = KL*dl, KR*dr
        v = (vL+vR)/2.0; w = (vR-vL)/WHEEL_BASE
        for _ in range(10):
            dt = TICK_DT/10
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        lat = track_dist(x, y, R, dp)
        max_lat = max(max_lat, lat)
        if t > 8.0:
            lat_sum += lat; n += 1
        t += TICK_DT
        if max_lat > 120: return False, max_lat, 0, 0, 0
        if y > dp + R + 500 - 60: break
    ds = [abs(hist[i+1]-hist[i]) for i in range(len(hist)-1)]
    ds.sort()
    med = ds[len(ds)//2] if ds else 0
    p90 = ds[int(len(ds)*0.9)] if ds else 0
    rms = math.sqrt(lat_sum/n) if n else 0
    return max_lat < 45, max_lat, med, p90, rms

RADII = [4000.0, 400.0, 300.0, 160.0]
cfgs = [
    ('A 积分自适应 640/5 ', 120, 40,  640, 5, 0.0),
    ('A 积分自适应 4096/4', 120, 40, 4096, 4, 0.0),
    ('A 积分自适应 8192/3', 120, 40, 8192, 3, 0.0),
    ('A 积分自适应P80 8192/3', 80, 20, 8192, 3, 0.0),
    ('B trim-148 P120 D40', 120, 40,  640, 5, -148.0),
    ('B trim-148 P80 D20 ',  80, 20,  640, 5, -148.0),
    ('C trim-148 P80 D20 i2048/4', 80, 20, 2048, 4, -148.0),
    ('C trim-148 P96 D40 i2048/4', 96, 40, 2048, 4, -148.0),
]
print('%-30s %s'%('cfg',' '.join('R=%-4d'%r for r in RADII)))
print('%-30s %s'%('',' '.join('lat/dc_med/dc_p90/rms' for r in RADII)))
for name,P,D,ilim,ish,trim in cfgs:
    row='%-30s'%name
    for R in RADII:
        ok,lat,med,p90,rms = run(R,P,D,ilim,ish,trim=trim)
        row += (' %5.1f/%4.0f/%4.0f/%4.1f'%(lat,med,p90,rms)) if ok else '   OUT(%5.1f)'%lat
    print(row)
