# -*- coding: utf-8 -*-
"""最终对照：含现状基线，R 覆盖到 100mm，并加「pos 量化抖动」鲁棒性测试。"""
import sys, math, random
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import fast_corner as F

F.SENSOR_FWD = 75.0
RS = (320, 250, 200, 160, 130, 100)
DPS = (-15.0, -8.0, 0.0, 8.0, 15.0)
TAUS = (0.0, 0.15, 0.30)

CANDS = [
    (72, 40, "现状基线"),
    (72, 140, "只大 D"),
    (120, 140, "P120 D140"),
    (120, 220, "P120 D220"),
    (120, 260, "P120 D260"),
    (144, 220, "P144 D220"),
    (144, 260, "P144 D260"),
    (168, 260, "P168 D260"),
]

def run_noisy(R, dp, P, D_, ish=5, ilim=640, base=480.0, tau=0.0,
              flick=0.0, seed=1):
    """flick: 每拍 pos 有 flick 概率被扰 ±1（模拟探头边界抖动）。"""
    rnd = random.Random(seed)
    x, y, th = 0.0, dp, 0.0
    pos_d = 0.0; i_acc = 0.0; t = 0.0; vL = vR = 0.0; max_lat = 0.0
    while t < 28.0:
        cnt, pos = F.sample(x, y, th, R, dp)
        lost = (cnt == 0)
        if flick > 0 and cnt > 0 and rnd.random() < flick:
            pos += rnd.choice((-1, 1))
            pos = max(-7, min(7, pos))
        err = pos
        errd = 0.0 if lost else (err - pos_d)
        corr = max(-base, min(base, err * P + int(i_acc) / (2.0 ** ish) + errd * D_))
        dl = max(0.0, min(1200.0, base + corr)); dr = max(0.0, min(1200.0, base - corr))
        if not lost:
            pos_d = err; i_acc = max(-ilim, min(ilim, i_acc + err))
        if tau > 0:
            vL += (F.K_MMS * dl - vL) * (F.TICK_DT / tau)
            vR += (F.K_MMS * dr - vR) * (F.TICK_DT / tau)
        else:
            vL, vR = F.K_MMS * dl, F.K_MMS * dr
        v = (vL + vR) / 2.0; w = (vR - vL) / F.WHEEL_BASE
        for _ in range(10):
            dt = F.TICK_DT / 10
            x += v * math.cos(th) * dt; y += v * math.sin(th) * dt; th += w * dt
        lat = F.track_dist(x, y, R, dp); max_lat = max(max_lat, lat); t += F.TICK_DT
        if lat > 150: return False, max_lat
        if y > dp + R + F.EXIT - 60: return max_lat < 45, max_lat
    return max_lat < 45, max_lat

print("配置         fails  worst  R320  R250  R200  R160  R130  R100   带抖动最差(3种子)")
for P, D_, name in CANDS:
    fails = 0; worst = 0.0; byR = {}
    for tau in TAUS:
        for R in RS:
            w = 0.0
            for dp in DPS:
                ok, ml = F.run(R, dp=dp, P=P, D=D_, ish=5, ilim=640, base=480.0, tau=tau)
                w = max(w, ml)
                if not ok: fails += 1
            byR[R] = max(byR.get(R, 0.0), w); worst = max(worst, w)
    nw = 0.0; nf = 0
    for seed in (1, 2, 3):
        for R in (250, 160):
            for dp in (-8.0, 0.0, 8.0):
                ok, ml = run_noisy(R, dp, P, D_, tau=0.15, flick=0.25, seed=seed)
                nw = max(nw, ml)
                if not ok: nf += 1
    print("%-12s %2d/90 %6.1f  %5.1f %5.1f %5.1f %5.1f %5.1f %5.1f   %6.1f (%d/18)" % (
        name, fails, worst, byR[320], byR[250], byR[200], byR[160], byR[130], byR[100], nw, nf))
