# -*- coding: utf-8 -*-
"""弯道闭环运动学仿真：8 路探头 + track_pid + duty_shaper + 差速车体。
目的：定量回答"弯道为什么跟不住"，而不是继续猜参数。

坐标：x 右、y 前，th 为航向（逆时针正），车体原点在驱动轴中心。
赛道上先直道后接 R 圆弧左弯，再直道。
"""
import math
import sys

# ---------------- 车体 ----------------
WHEEL_BASE = 160.0      # mm 轮距
SENSOR_PITCH = 11.0     # mm 探头间距（现场实测 10~12）
SENSOR_FWD = 30.0       # mm 探头阵列在驱动轴前方的距离
LINE_HW = 6.5           # mm 线半宽（线宽 13 mm）
K_MMS = 0.5             # mm/s per duty 计数（duty 600 -> 300 mm/s）

# ---------------- track_pid ----------------
def pid_params(base, p, dg, ishift, ilim):
    return dict(BASE=base, P=p, D=dg, ISHIFT=ishift, ILIM=ilim)

TICK_DT = 0.010         # 100 Hz
DUTY_MAX = 1200

def build_track(R):
    """直道 600mm -> 左弯 R (90 度) -> 直道；返回中心线采样点。"""
    pts = []
    for x in range(0, 600):
        pts.append((float(x), 0.0))
    if R is not None:
        cx, cy = 600.0, float(R)
        n = max(8, int(R * math.pi / 2))
        for k in range(n + 1):
            a = -math.pi / 2 + (math.pi / 2) * k / n
            pts.append((cx + R * math.cos(a), cy + R * math.sin(a)))
        # 出弯直道：切点为 (cx+R, cy)，方向 +y
        ex, ey = cx + R, cy
        for yy in range(0, 600):
            pts.append((ex, ey + yy))
    else:
        for x in range(600, 1200):
            pts.append((float(x), 0.0))
    return pts

def nearest_dist(track, px, py):
    best = 1e9
    for (tx, ty) in track:
        dx, dy = px - tx, py - ty
        dd = dx * dx + dy * dy
        if dd < best:
            best = dd
    return math.sqrt(best)

def sensor_lats():
    # track[0] = 车体最左，权重 -7 ... track[7] = 最右，权重 +7
    return [(3.5 - i) * SENSOR_PITCH for i in range(8)]

WEIGHTS = [-7, -5, -3, -1, 1, 3, 5, 7]

def read_line(track, x, y, th):
    c, s = math.cos(th), math.sin(th)
    seen = []
    for lat in sensor_lats():
        px = x + SENSOR_FWD * c - lat * s
        py = y + SENSOR_FWD * s + lat * c
        dd = nearest_dist(track, px, py)
        seen.append(1 if dd <= LINE_HW else 0)
    cnt = sum(seen)
    wsum = sum(WEIGHTS[i] * seen[i] for i in range(8))
    if cnt == 0:
        return 0, 0, 0
    wabs = abs(wsum)
    # 照搬 track_line：prod = wabs*(1024/cnt) + 512; pmag = prod >> 10
    prod = wabs * (1024 // cnt) + 512
    pmag = prod >> 10
    pos = -pmag if wsum < 0 else pmag
    return cnt, pos, wsum

def shaper(dl, dr, follow, diff_shift):
    if not follow:
        return dl, dr
    mid = (dl + dr) // 2
    diff = (dl - dr) // 2
    diff_s = diff >> diff_shift
    return mid + diff_s, mid - diff_s

MISMATCH = 0.0   # 右轮增益 = 1+eps, 左轮 = 1-eps

def run(p, R=300.0, diff_shift=1, shape_en=True, t_end=30.0, verbose=False, mismatch=None):
    global MISMATCH
    old_mm = MISMATCH
    if mismatch is not None:
        MISMATCH = mismatch
    track = build_track(R)
    x = y = 0.0
    th = 0.0
    # 起点对齐：把车放在线正上方
    y = 0.0
    pos_d = 0
    i_acc = 0
    lost_d = 0
    duty_l = duty_r = 0
    lost_ms = 0
    state = 'RUN'
    search_ms = 0
    log = []
    t = 0.0
    max_lat = 0.0
    lost_events = 0
    prev_lost = 0
    run_ms = 0
    while t < t_end:
        cnt, pos, wsum = read_line(track, x, y, th)
        lost = 1 if cnt == 0 else 0
        wide = 1 if cnt >= 5 else 0
        if wide and verbose:
            log.append((t, 'WIDE', cnt, pos))
        if lost and not prev_lost:
            lost_events += 1
        prev_lost = lost

        # 状态机（简化 car_fsm）
        if state == 'RUN':
            if lost:
                lost_ms += int(TICK_DT * 1000)
                if lost_ms >= 300:
                    state = 'SEARCH'
                    search_ms = 0
            else:
                lost_ms = 0
        elif state == 'SEARCH':
            search_ms += int(TICK_DT * 1000)
            cnt2, pos2, _ = read_line(track, x, y, th)
            if cnt2 > 0 and not wide:
                state = 'RUN'
                lost_ms = 0

        if state == 'RUN':
            err = pos
            # D 项：丢线时清零
            err_d = 0 if lost_d else (err - pos_d)
            if lost:
                dd_l, dd_r = duty_l, duty_r
                # 冻结积分与 pos_d
            else:
                p_term = err * p['P']
                d_term = err_d * p['D']
                i_term = i_acc >> p['ISHIFT']
                sraw = p_term + i_term + d_term
                lim = p['BASE']
                sl = lim if sraw > lim else (-lim if sraw < -lim else sraw)
                dl = p['BASE'] + sl
                dr = p['BASE'] - sl
                pos_d = pos
                i_next = i_acc + err
                i_acc = max(-p['ILIM'], min(p['ILIM'], i_next))
                dd_l, dd_r = dl, dr
            lost_d = lost
        elif state == 'SEARCH':
            dd_l, dd_r = 500, 500
        else:
            dd_l, dd_r = 0, 0

        if shape_en:
            fl, fr = shaper(dd_l, dd_r, True, diff_shift)
        else:
            fl, fr = dd_l, dd_r
        duty_l, duty_r = fl, fr
        duty_l = max(0, min(DUTY_MAX, duty_l))
        duty_r = max(0, min(DUTY_MAX, duty_r))

        # 运动学积分（1 ms 子步）
        vl = duty_l * K_MMS * (1.0 - MISMATCH)
        vr = duty_r * K_MMS * (1.0 + MISMATCH)
        v = (vl + vr) / 2.0
        w = (vr - vl) / WHEEL_BASE
        sub = 10
        for _ in range(sub):
            dt = TICK_DT / sub
            x += v * math.cos(th) * dt
            y += v * math.sin(th) * dt
            th += w * dt
        # 横向误差
        lat = nearest_dist(track, x, y)
        max_lat = max(max_lat, lat)
        if verbose and 0 <= len(log) < 400:
            log.append((round(t, 3), state, cnt, pos, duty_l, duty_r, round(lat, 1)))
        t += TICK_DT
        run_ms += int(TICK_DT * 1000)
        if y > 880.0:
            return dict(ok=True, reason='finished', t=t, max_lat=max_lat,
                        lost_events=lost_events, log=log, x=x, y=y, th=math.degrees(th))
        if lat > 120:
            return dict(ok=False, reason='off-track', t=t, max_lat=max_lat,
                        lost_events=lost_events, log=log, x=x, y=y)
    # 终点判据：走完弯道并前进足够远
    done = (math.hypot(x, y) > 600)
    MISMATCH = old_mm
    return dict(ok=done, reason='end', t=t, max_lat=max_lat, lost_events=lost_events,
                log=log, x=x, y=y, th=math.degrees(th))



def run2(p, R=300.0, diff_shift=1, shape_en=True, t_end=40.0, k_mms=None, base=None, mismatch=None):
    global K_MMS
    old_k = K_MMS
    if k_mms is not None:
        K_MMS = k_mms
    pp = dict(p)
    if base is not None:
        pp['BASE'] = base
    try:
        return run(pp, R=R, diff_shift=diff_shift, shape_en=shape_en, t_end=t_end, mismatch=mismatch)
    finally:
        K_MMS = old_k

def fmt(px):
    return "x=%6.1f y=%6.1f" % (px['x'], px['y'])

if __name__ == '__main__':
    p = pid_params(480, 72, 40, 5, 640)
    print("=== 电机左右不对称 vs 弯道（R=300，K=0.5，整形器开）===")
    print("%-10s %-8s %5s %6s %8s %6s %8s" % ("mismatch","R(mm)","ok","t(s)","maxLat","lost","直道偏移"))
    for mm in [0.0, 0.02, 0.05, 0.08, 0.12, 0.15, 0.20]:
        for R in [None, 300.0]:
            rr = R if R else 100000.0
            r = run2(p, R=rr, k_mms=0.5, mismatch=mm)
            print("%-10.2f %-8s %5s %6.1f %8.1f %6d %8.1f" % (
                mm, "直道" if R is None else "%.0f" % R,
                "Y" if r['ok'] else "N", r['t'], r['max_lat'], r['lost_events'],
                0 if R is None else 0))