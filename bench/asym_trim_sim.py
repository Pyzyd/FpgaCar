# -*- coding: utf-8 -*-
"""带两轮增益失配 + trim 补偿的闭环仿真。
复刻 RTL：pos 来自 track_line 量化、track_pid 的 P/D/I 与钳位、BASE/CORR 限幅。"""
import math, sys
sys.path.insert(0,'bench')
from fast_corner import track_dist, sample, WHEEL_BASE, TICK_DT

def run(R, dp=0.0, P=120.0, D=220.0, ish=5, ilim=640, base=480.0,
        KL=0.30, KR=0.165, trim=0.0, tau=0.0, t_end=30.0, lost_hold=0.30,
        dmax=1200.0):
    x, y, th = 0.0, dp, 0.0
    pos_d = 0.0; i_acc = 0.0
    vL = vR = 0.0
    max_lat = 0.0; t = 0.0; lost_ms = 0
    while t < t_end:
        cnt, pos = sample(x, y, th, R, dp)
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
            if not lost:
                pos_d = err
                i_acc = max(-ilim, min(ilim, i_acc + err))
        if tau > 0:
            vL += (KL*dl - vL)*(TICK_DT/tau)
            vR += (KR*dr - vR)*(TICK_DT/tau)
        else:
            vL, vR = KL*dl, KR*dr
        v = (vL+vR)/2.0
        w = (vR-vL)/WHEEL_BASE
        for _ in range(10):
            dt = TICK_DT/10
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        lat = track_dist(x, y, R, dp)
        max_lat = max(max_lat, lat)
        t += TICK_DT
        if lat > 150: return False, max_lat
        if y > dp + R + 500 - 60: return max_lat < 45, max_lat
    return max_lat < 45, max_lat

if __name__ == '__main__':
    RADII = [4000.0, 300.0, 220.0, 160.0]   # 4000 ~ straight
    print('KR/KL=%.2f  (right wheel weaker)'%(0.165/0.30))
    print('%-28s %s'%('config', '  '.join('R=%-5d'%r for r in RADII)))
    cases = [
        ('current (no trim, D220, ilim640)', dict(D=220, ilim=640, trim=0)),
        ('trim=140', dict(D=220, ilim=640, trim=140)),
        ('trim=145', dict(D=220, ilim=640, trim=145)),
        ('trim=150', dict(D=220, ilim=640, trim=150)),
        ('trim=140 + D=60', dict(D=60, ilim=640, trim=140)),
        ('trim=140 + D=20', dict(D=20, ilim=640, trim=140)),
        ('trim=140 + ilim=8000', dict(D=220, ilim=8000, trim=140)),
        ('no trim + ilim=8000', dict(D=220, ilim=8000, trim=0)),
        ('no trim + D=60', dict(D=60, ilim=640, trim=0)),
    ]
    for name, kw in cases:
        cells = []
        for R in RADII:
            ok, lat = run(R, dp=0.0, **kw)
            cells.append('%s%5.1f'%('Y' if ok else 'N', lat))
        print('%-28s %s'%(name, '  '.join('%-7s'%c for c in cells)))
