# -*- coding: utf-8 -*-
"""加 pos 抖动（线边缘 flicker）后的 P/D/积分容量扫描。
实车证据：pos 长期 ±1/±3 台阶、C 每 300ms 翻符号 45%。
"""
import math, sys, random
sys.path.insert(0,'bench')
from fast_corner import track_dist, sample, WHEEL_BASE, TICK_DT

def run(R, dp=0.0, P=120.0, D=220.0, ish=5, ilim=640, base=480.0,
        KL=0.30, KR=0.165, trim=0.0, t_end=32.0, lost_hold=0.30,
        flick=0.0, seed=1, dmax=1200.0):
    rnd = random.Random(seed)
    x, y, th = 0.0, dp, 0.0
    pos_d = 0.0; i_acc = 0.0
    vL = vR = 0.0
    max_lat = 0.0; t = 0.0; lost_ms = 0
    flips = 0; last_sign = 0
    while t < t_end:
        cnt, pos = sample(x, y, th, R, dp)
        if cnt and flick > 0 and rnd.random() < flick:
            pos += rnd.choice((-1, 1))
            pos = max(-7, min(7, pos))
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
            dr = max(0.0, min(dmax, base - corr + trim))
            if abs(corr) > 60:
                s = 1 if corr > 0 else -1
                if last_sign and s != last_sign: flips += 1
                last_sign = s
            if not lost:
                pos_d = err
                i_acc = max(-ilim, min(ilim, i_acc + err))
        vL, vR = KL*dl, KR*dr
        v = (vL+vR)/2.0
        w = (vR-vL)/WHEEL_BASE
        for _ in range(10):
            dt = TICK_DT/10
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        lat = track_dist(x, y, R, dp)
        max_lat = max(max_lat, lat)
        t += TICK_DT
        if lat > 150: return False, max_lat, flips
        if y > dp + R + 500 - 60: return max_lat < 45, max_lat, flips
    return max_lat < 45, max_lat, flips

if __name__ == '__main__':
    RADII = [4000.0, 300.0, 160.0]
    cases = [
        ('current P120 D220 ilim640', dict(P=120,D=220,ilim=640)),
        ('P120 D40  ilim640',        dict(P=120,D=40, ilim=640)),
        ('P120 D20  ilim640',        dict(P=120,D=20, ilim=640)),
        ('P120 D40  ilim8000',       dict(P=120,D=40, ilim=8000)),
        ('P120 D40  ilim16000',      dict(P=120,D=40, ilim=16000)),
        ('P60  D20  ilim16000',      dict(P=60, D=20, ilim=16000)),
        ('P80  D30  ilim16000',      dict(P=80, D=30, ilim=16000)),
        ('P120 D40  ilim16000 trim=0',dict(P=120,D=40,ilim=16000,trim=0)),
    ]
    for flick in (0.0, 0.20):
        print('='*70)
        print('flicker=%.2f  (pos ±1 random flip probability)'%flick)
        hdr = '%-30s'%'config'
        for R in RADII: hdr += ' R=%-5d'%R
        print(hdr)
        for name, kw in cases:
            line = '%-30s'%name
            for R in RADII:
                ok, lat, fl = run(R, dp=0.0, flick=flick, seed=1, **kw)
                line += ' %s%5.1f(%2d)'%('Y' if ok else 'N', lat, fl)
            print(line)
