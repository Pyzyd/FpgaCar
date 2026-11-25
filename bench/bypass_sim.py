# -*- coding: utf-8 -*-
"""避障五段轨迹仿真（按 src/car_fsm.v 的真实语义）。

段: out -> align -> pass -> turn_in -> rejoin -> [merge] -> run(track_pid)
出口语义同 RTL：
  out     : ta <= -arc_t                (hdg_seg_done, 方向越过)
  align   : ta >= 0
  pass    : 两轮里程和 >= pass_mm 折算
  turn_in : ta >= turn_t
  rejoin  : 扫到线(<line_x 且保持 line_ms) 或 超时
  run     : 交回 track_pid，|x|<=3 且 |th|<0.05
"""
import math

B_WHEEL, HALF_W, CUBE_H = 160.0, 92.5, 50.0
NOSE, REAR = 75.0, -125.0
CPM = 2532.0 / 212.0
ARC_T = 1999.0
PASS_SUM = 2388.0
DEAD, SMAX, SMIN, DMIN, DMAX = 10, 600, 60, 120, 1200
RAMP = 2.0
I_SHIFT, I_LIMIT = 5, 400.0
TOL = 25.0     # 出口容差(计数)，补偿死区 DEAD=10 造成的稳态误差


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def steer_of(err):
    if err > DEAD:
        dz = err - DEAD
    elif err < -DEAD:
        dz = err + DEAD
    else:
        return 0
    st = clamp(int(dz) >> 2, -SMAX, SMAX)
    if 0 < st < SMIN:
        st = SMIN
    if 0 > st > -SMIN:
        st = -SMIN
    return st


def outline(x, y, th, n=5):
    c, s = math.cos(th), math.sin(th)
    pts = []
    for sx in (-HALF_W, HALF_W):
        for i in range(n + 1):
            fy = REAR + (NOSE - REAR) * i / n
            pts.append((x + sx * c - fy * s, y + sx * s + fy * c))
    for fy in (NOSE, REAR):
        for i in range(n + 1):
            sx = -HALF_W + 2 * HALF_W * i / n
            pts.append((x + sx * c - fy * s, y + sx * s + fy * c))
    return pts


def clearance(x, y, th, cy):
    best = 1e9
    for px, py in outline(x, y, th):
        dx = max(abs(px) - CUBE_H, 0.0)
        dy = max(abs(py - cy) - CUBE_H, 0.0)
        v = math.hypot(dx, dy)
        if v < best:
            best = v
    return best


def sim(arc=64.0, turn=40.0, pass_mm=360.0, rej_tgt=None, rej_d=(430, 640),
        rej_mode='line', rej_mm=220.0, rej_ms=5000.0, mer_tgt=0.0,
        mer_d=(400, 840), out_d=(860, 380), ali_d=(400, 840),
        turn_d=(420, 860), pass_d=(620, 620), run_d=(620, 620),
        KL=0.30, KR=0.30, trigger=350.0, line_x=30.0, line_ms=20.0,
        dt=0.001, integ_on=True, klat=15.9, want_path=False,
        fast_ramp=8.0):
    """rej_tgt=None 表示沿用 turn 角（现状 RTL）。"""
    if rej_tgt is None:
        rej_tgt = turn
    cy = NOSE + trigger + CUBE_H
    arc_t = arc / 60.0 * ARC_T
    turn_t = turn / 60.0 * ARC_T
    pass_s = pass_mm / 200.0 * PASS_SUM * 2.0
    mer_t = mer_tgt / 60.0 * ARC_T

    segs = [(out_d, -arc_t, 'out'), (ali_d, 0.0, 'align'),
            (pass_d, 0.0, 'pass'), (turn_d, turn_t, 'turn'),
            (rej_d, rej_tgt / 60.0 * ARC_T, 'rejoin')]
    if rej_mode == 'merge':
        segs.append((mer_d, mer_t, 'merge'))
    segs.append((run_d, None, 'run'))

    x = y = th = g_l = g_r = 0.0
    min_clr = clearance(x, y, th, cy)
    depth = 0.0
    path = [(0.0, 0.0)]
    hand = None
    over = 0.0
    log = []
    line_cnt = 0
    for (duty, tgt, name) in segs:
        nl, nr = duty
        ref = (g_r - g_l) * CPM
        l0, r0 = g_l, g_r
        ms = 0.0
        integ = 0.0
        i_on = integ_on and name in ('pass', 'rejoin', 'merge')
        while ms < 8000.0:
            if name == 'run':
                base = clamp(-klat * x, -1000.0, 1000.0)
            else:
                base = tgt
            ramp = fast_ramp if name == 'merge' else RAMP
            if ref < base:
                ref = min(ref + ramp, base)
            elif ref > base:
                ref = max(ref - ramp, base)
            err = ref - (g_r - g_l) * CPM
            st = steer_of(err)
            if i_on:
                integ = clamp(integ + int(err) // 32, -I_LIMIT, I_LIMIT)
                st += integ
            st = clamp(st, -SMAX, SMAX)
            dl = clamp(nl - st, DMIN, DMAX)
            dr = clamp(nr + st, DMIN, DMAX)
            vl, vr = KL * dl, KR * dr
            g_l += vl * dt
            g_r += vr * dt
            x += (vl + vr) / 2 * math.sin(th) * dt
            y += (vl + vr) / 2 * math.cos(th) * dt
            th += (vr - vl) / B_WHEEL * dt
            ms += dt * 1000.0
            c = clearance(x, y, th, cy)
            if c < min_clr:
                min_clr = c
            if x < depth:
                depth = x
            if want_path:
                path.append((x, y))
            ta = (g_r - g_l) * CPM
            ss = ((g_l - l0) + (g_r - r0)) * CPM
            if name in ('rejoin', 'merge') and hand is None and abs(x) <= line_x:
                hand = (math.degrees(th), y)
            line_cnt = line_cnt + 1 if abs(x) <= line_x else 0
            done = False
            if name == 'out':
                done = ta <= -arc_t + TOL
            elif name == 'align':
                done = ta >= -TOL
            elif name == 'pass':
                done = ss >= pass_s
            elif name == 'turn':
                done = ta >= turn_t - TOL
            elif name == 'rejoin':
                if rej_mode == 'line':
                    done = line_cnt >= line_ms
                elif rej_mode == 'merge':
                    done = ss >= rej_mm / 200.0 * PASS_SUM * 2.0 or ms >= rej_ms
                elif rej_mode == 'flat':
                    done = ta <= 0.0 or ms >= rej_ms
                if ms >= rej_ms:
                    done = True
            elif name == 'merge':
                done = ta <= TOL
            elif name == 'run':
                if hand is not None and x > over:
                    over = x
                done = abs(x) <= 3.0 and abs(th) < 0.05
            if done:
                break
        log.append('%s x=%.1f y=%.0f th=%.1f ms=%.0f' %
                   (name, x, y, math.degrees(th), ms))
    return dict(depth=round(-depth, 1), clr=round(min_clr, 1),
                hand=None if hand is None else (round(hand[0], 1), round(hand[1], 0)),
                over=round(over, 1), x=round(x, 1), y=round(y, 0),
                th=round(math.degrees(th), 1), log=log,
                path=path if want_path else None)
