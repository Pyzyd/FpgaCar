# -*- coding: utf-8 -*-
"""圆角弯道（解析版）：直线 + 相切 90 度圆弧 + 出弯直线。
相比 round_corner_sim.py 的点云 track_dist，这里用解析几何算点到线距离，
单次仿真快两个数量级，才扫得动 PID 参数网格。"""
import math

LEAD = 400.0
EXIT = 500.0
WHEEL_BASE = 160.0
SENSOR_PITCH = 11.0
SENSOR_FWD = 75.0
LINE_HW = 6.5
WEIGHTS = (-7, -5, -3, -1, 1, 3, 5, 7)
TICK_DT = 0.010
K_MMS = 0.5

def seg_dist(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    L2 = vx * vx + vy * vy
    if L2 <= 0.0:
        return math.hypot(wx, wy)
    t = max(0.0, min(1.0, (wx * vx + wy * vy) / L2))
    return math.hypot(wx - t * vx, wy - t * vy)

def track_dist(x, y, R, dphase):
    """点到整条赛道的最近距离。"""
    cx, cy = LEAD, dphase + R
    d1 = seg_dist(x, y, 0.0, dphase, LEAD, dphase)
    d2 = seg_dist(x, y, LEAD + R, dphase + R, LEAD + R, dphase + R + EXIT)
    dx, dy = x - cx, y - cy
    rho = math.hypot(dx, dy)
    ang = math.atan2(dy, dx)
    if -math.pi / 2.0 <= ang <= 0.0:
        d3 = abs(rho - R)
    else:
        d3 = min(math.hypot(x - LEAD, y - dphase),
                 math.hypot(x - (LEAD + R), y - (dphase + R)))
    return min(d1, d2, d3)

def sample(x, y, th, R, dphase, fwd=None):
    f = SENSOR_FWD if fwd is None else fwd
    ca, sa = math.cos(th), math.sin(th)
    sxs = x + f * ca
    sys_ = y + f * sa
    lx, ly = -sa, ca
    cnt = 0
    wsum = 0
    mags = [0] * 8
    for i, w in enumerate(WEIGHTS):
        lat = (3.5 - i) * SENSOR_PITCH
        px = sxs + lat * lx
        py = sys_ + lat * ly
        if track_dist(px, py, R, dphase) <= LINE_HW:
            cnt += 1
            mags[i] = abs(w)
            wsum += w
    if cnt == 0:
        return 0, 0.0
    tot = sum(mags)
    sign = -1.0 if wsum < 0 else 1.0
    pmag = int((tot * 1024 // cnt + 512) >> 10) if cnt else 0
    return cnt, sign * pmag

def run(R, dp=0.0, P=72.0, D=40.0, ish=5, ilim=640, base=480.0,
        tau=0.0, k=None, fwd=None, t_end=28.0, lost_hold=0.30):
    global K_MMS
    if k is not None:
        K_MMS = k
    x, y, th = 0.0, dp, 0.0
    pos_d = 0.0
    i_acc = 0.0
    vL = vR = 0.0
    max_lat = 0.0
    t = 0.0
    lost_ms = 0
    last_dl = last_dr = base
    dl = dr = base
    while t < t_end:
        cnt, pos = sample(x, y, th, R, dp, fwd)
        lost = (cnt == 0)
        if lost:
            lost_ms += 10
        else:
            lost_ms = 0
        if lost_ms >= int(lost_hold * 1000.0):
            # 丢失保持后停转（判出线）
            dl = dr = 0.0
        else:
            err = pos
            errd = 0.0 if lost else (err - pos_d)
            corr = err * P + int(i_acc) / (2.0 ** ish) + errd * D
            corr = max(-base, min(base, corr))
            dl = max(0.0, min(1200.0, base + corr))
            dr = max(0.0, min(1200.0, base - corr))
            if not lost:
                pos_d = err
                i_acc = max(-ilim, min(ilim, i_acc + err))
        last_dl, last_dr = dl, dr
        if tau > 0:
            vL += (K_MMS * dl - vL) * (TICK_DT / tau)
            vR += (K_MMS * dr - vR) * (TICK_DT / tau)
        else:
            vL, vR = K_MMS * dl, K_MMS * dr
        v = (vL + vR) / 2.0
        w = (vR - vL) / WHEEL_BASE
        for _ in range(10):
            dt = TICK_DT / 10
            x += v * math.cos(th) * dt
            y += v * math.sin(th) * dt
            th += w * dt
        lat = track_dist(x, y, R, dp)
        max_lat = max(max_lat, lat)
        t += TICK_DT
        if lat > 150:
            return False, max_lat
        if y > dp + R + EXIT - 60:
            return max_lat < 45, max_lat
    return max_lat < 45, max_lat
