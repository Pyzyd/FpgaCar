# -*- coding: utf-8 -*-
"""聚焦对照：base 固定 480（不靠降速取巧），看增益对弯道与直道抖动的影响。"""
import sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import fast_corner as F

F.SENSOR_FWD = 75.0
RS = (320, 250, 200, 160, 130)
DPS = (-15.0, -8.0, 0.0, 8.0, 15.0)
TAUS = (0.0, 0.15, 0.30)

CANDS = [
    (72, 40, 5, "现状"),
    (72, 80, 5, "只加 D"),
    (56, 40, 5, "降 P"),
    (56, 120, 5, "降 P 加 D"),
    (56, 160, 5, "降 P 大 D"),
    (64, 120, 5, "折中"),
    (72, 140, 5, "只大 D"),
    (96, 120, 5, "加 P 加 D"),
]

def straight_jitter(P, D, ish, base=480.0, tau=0.0, n=600):
    """直道：给一点初始横向偏移，看收敛后残余摆动的峰峰值（mm）。"""
    x, y, th = 0.0, 6.0, 0.0
    pos_d = 0.0; i_acc = 0.0; t = 0.0
    vL = vR = 0.0
    hist = []
    while t < 3.0:
        cnt, pos = F.sample(x, y, th, 10 ** 9, 0.0)
        lost = (cnt == 0)
        err = pos
        errd = 0.0 if lost else (err - pos_d)
        corr = err * P + int(i_acc) / (2.0 ** ish) + errd * D
        corr = max(-base, min(base, corr))
        dl = max(0.0, min(1200.0, base + corr))
        dr = max(0.0, min(1200.0, base - corr))
        if not lost:
            pos_d = err
            i_acc = max(-640, min(640, i_acc + err))
        if tau > 0:
            vL += (F.K_MMS * dl - vL) * (F.TICK_DT / tau)
            vR += (F.K_MMS * dr - vR) * (F.TICK_DT / tau)
        else:
            vL, vR = F.K_MMS * dl, F.K_MMS * dr
        v = (vL + vR) / 2.0; w = (vR - vL) / F.WHEEL_BASE
        for _ in range(10):
            dt = F.TICK_DT / 10
            x += v * __import__('math').cos(th) * dt
            y += v * __import__('math').sin(th) * dt
            th += w * dt
        t += F.TICK_DT
        if t > 1.5:
            hist.append(y)
    return max(hist) - min(hist)

print("配置              fails  worst  R320   R250   R200   R160   R130   直道抖动(mm)")
for P, D_, ish, name in CANDS:
    fails = 0; worst = 0.0; byR = {}
    for tau in TAUS:
        for R in RS:
            w = 0.0
            for dp in DPS:
                ok, ml = F.run(R, dp=dp, P=P, D=D_, ish=ish, ilim=640,
                               base=480.0, tau=tau)
                w = max(w, ml)
                if not ok: fails += 1
            byR[R] = max(byR.get(R, 0.0), w)
            worst = max(worst, w)
    j0 = straight_jitter(P, D_, ish, tau=0.0)
    j3 = straight_jitter(P, D_, ish, tau=0.30)
    print("%-14s  %2d/75  %6.1f  %5.1f  %5.1f  %5.1f  %5.1f  %5.1f   %.2f / %.2f" % (
        name, fails, worst, byR[320], byR[250], byR[200], byR[160], byR[130], j0, j3))
