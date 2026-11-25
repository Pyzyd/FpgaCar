# -*- coding: utf-8 -*-
"""两轮失配 KR/KL=0.55 + 不同积分容量：位置环能否自己撑住需要的补偿量。
实车证据：稳定态 C=-140、pos=-1、积分顶死在 I_LIMIT>>I_SHIFT=20。
需要的补偿 = K 差导致的直行偏移。"""
import math, sys, random
sys.path.insert(0,'bench')
from fast_corner import track_dist, sample, WHEEL_BASE, TICK_DT

KL, KR = 0.30, 0.165   # 实车反推：右轮约 0.55 倍

def run(R, dp=0.0, P=120.0, D=220.0, ish=5, ilim=640, base=480.0,
        trim=0.0, t_end=34.0, lost_hold=0.30, flick=0.0, seed=1,
        dmax=1200.0, rmult=1.0):
    rnd = random.Random(seed)
    x, y, th = 0.0, dp, 0.0
    pos_d = 0.0; i_acc = 0.0
    vL = vR = 0.0
    max_lat = 0.0; t = 0.0; lost_ms = 0
    flips = 0; last_sign = 0
    csum = 0.0; cn = 0
    while t < t_end:
        cnt, pos = sample(x, y, th, R, dp)
        if cnt and flick > 0 and rnd.random() < flick:
            pos = max(-7, min(7, pos + rnd.choice((-1,1))))
        lost = (cnt == 0)
        if lost: lost_ms += 10
        else: lost_ms = 0
        if lost_ms >= int(lost_hold*1000.0):
            dl = dr = 0.0
        else:
            err = float(pos)
            errd = 0.0 if lost else (err - pos_d)
            corr = err*P + int(i_acc)/(2.0**ish) + errd*D
            corr = max(-base, min(base, corr))
            dl = max(0.0, min(dmax, base + corr))
            dr = max(0.0, min(dmax, (base - corr)*rmult + trim))
            if abs(corr) > 100:
                s = 1 if corr > 0 else -1
                if last_sign and s != last_sign: flips += 1
                last_sign = s
            if not lost:
                pos_d = err
                i_acc = max(-ilim, min(ilim, i_acc + err))
            csum += corr; cn += 1
        vL, vR = KL*dl, KR*dr
        v = (vL+vR)/2.0
        w = (vR-vL)/WHEEL_BASE
        for _ in range(10):
            dt = TICK_DT/10
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        lat = track_dist(x, y, R, dp)
        max_lat = max(max_lat, lat)
        t += TICK_DT
        if lat > 150: return False, max_lat, flips, csum/max(1,cn)
        if y > dp + R + 500 - 60: return max_lat < 45, max_lat, flips, csum/max(1,cn)
    return max_lat < 45, max_lat, flips, csum/max(1,cn)

if __name__ == '__main__':
    RADII=[4000.0, 300.0, 160.0]
    cases=[
        ('ilim640  (i_max=20)   现状', dict(ilim=640)),
        ('ilim3200 (i_max=100)',      dict(ilim=3200)),
        ('ilim6400 (i_max=200)',      dict(ilim=6400)),
        ('ilim16000(i_max=500)',      dict(ilim=16000)),
        ('ilim6400 + ish=4(i_max=400)',dict(ilim=6400, ish=4)),
        ('ilim6400 + D=40',           dict(ilim=6400, D=40)),
        ('ilim6400 + D=40 + P=80',    dict(ilim=6400, D=40, P=80)),
        ('trim=145 (静态)',            dict(ilim=640, trim=145)),
        ('rmult=1.82 (乘性trim)',      dict(ilim=640, rmult=1.82)),
    ]
    for flick in (0.0, 0.20):
        print('='*78)
        print('flicker=%.2f'%flick)
        print('%-32s'%'config' + ''.join(' R=%-4d(lat/flip/Cavg)'%R for R in RADII))
        for name,kw in cases:
            line='%-32s'%name
            for R in RADII:
                ok,lat,fl,ca = run(R, flick=flick, seed=1, **kw)
                line += ' %s%5.1f/%4d/%+6.0f'%('Y' if ok else 'N', lat, fl, ca)
            print(line)
