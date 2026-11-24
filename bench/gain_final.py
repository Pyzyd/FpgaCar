# -*- coding: utf-8 -*-
"""最终验证：候选配置 vs 现状，跨 半径 x 入弯偏移 x 抖动幅度 x 种子。
   输出 失败数 / 最差 lat / 稳态 lat RMS / 报文级 |dcorr| 中位。"""
import math, sys, random
sys.path.insert(0,'bench')
from fast_corner import track_dist, sample, WHEEL_BASE, TICK_DT

KL, KR = 0.30, 0.165
RPT = 30

def run(R, P, D, ilim, ish, trim, dp, flick, seed, base=480.0, t_end=45.0):
    rnd = random.Random(seed)
    x, y, th = 0.0, dp, 0.0
    pos_d = 0.0; i_acc = 0.0; lost_ms = 0; t = 0.0
    max_lat = 0.0; lat2 = 0.0; n = 0; hist = []; step = 0
    while t < t_end:
        cnt, pos = sample(x, y, th, R, dp)
        if cnt and rnd.random() < flick:
            pos = max(-7, min(7, pos + rnd.choice((-1,1))))
        lost = (cnt == 0)
        lost_ms = lost_ms + 10 if lost else 0
        if lost_ms >= 300:
            dl = dr = 0.0
        else:
            err = float(pos)
            errd = 0.0 if lost else (err - pos_d)
            corr = err*P + i_acc/(2.0**ish) + errd*D
            corr = max(-base, min(base, corr)) + trim
            dl = max(0.0, min(1200.0, base + corr))
            dr = max(0.0, min(1200.0, base - corr))
            if not lost:
                pos_d = err
                i_acc = max(-ilim, min(ilim, i_acc + err))
            step += 1
            if step % RPT == 0: hist.append(corr)
        vL, vR = KL*dl, KR*dr
        v = (vL+vR)/2.0; w = (vR-vL)/WHEEL_BASE
        for _ in range(10):
            dt = TICK_DT/10
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        lat = track_dist(x, y, R, dp)
        max_lat = max(max_lat, lat)
        if t > 8.0: lat2 += lat*lat; n += 1
        t += TICK_DT
        if max_lat > 120: return False, max_lat, 0, 0
        if y > dp + R + 500 - 60: break
    ds = sorted(abs(hist[i+1]-hist[i]) for i in range(len(hist)-1))
    return max_lat < 45, max_lat, (math.sqrt(lat2/n) if n else 0), (ds[len(ds)//2] if ds else 0)

CASES = [(R,dp,flick,seed) for R in (4000.0,600.0,400.0,300.0,240.0,200.0,160.0)
         for dp in (-15.0,-8.0,0.0,8.0,15.0) for flick in (0.0,0.20) for seed in (1,2)]
CFGS = [('现状 P120 D220 trim0 i640/5', 120,220,640,5,0.0),
        ('候选 P80 D20 trim-148 i1024/5', 80,20,1024,5,-148.0),
        ('候选 P80 D40 trim-148 i1024/5', 80,40,1024,5,-148.0),
        ('候选 P96 D40 trim-148 i1024/5', 96,40,1024,5,-148.0),
        ('候选 P80 D20 trim0   i8192/3', 80,20,8192,3,0.0)]
for name,P,D,il,ish,tr in CFGS:
    fails=0; worst=0.0; rms=[]; jit=[]
    for (R,dp,flick,seed) in CASES:
        ok,lat,r2,dc = run(R,P,D,il,ish,tr,dp,flick,seed)
        if not ok: fails+=1
        worst=max(worst,lat)
        if ok: rms.append(r2); jit.append(dc)
    rms.sort(); jit.sort()
    print('%-32s fail %2d/%d  worst %5.1f  rms_med %4.2f rms_p90 %5.2f  dc_med %4.0f'%(
        name,fails,len(CASES),worst,
        rms[len(rms)//2] if rms else -1,
        rms[int(len(rms)*0.9)] if rms else -1,
        jit[len(jit)//2] if jit else -1))
