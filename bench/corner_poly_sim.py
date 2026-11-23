# -*- coding: utf-8 -*-
"""弯道闭环仿真 v4：折线赛道（直角/锐角拐角），含 track_line 宽黑判据 + car_fsm 丢线/找线。

前几版用平滑圆弧，仿真全通过；但代码注释一直提"菱形锐角"，
真实赛道是折线。锐角拐角处出线方向与车身垂直，8 路探头会同时压线
（cnt=8 >= WIDE_CNT_TH=5），触发 wide -> 200ms 后 wide_lost -> lost。
"""
import math

WHEEL_BASE = 160.0
SENSOR_PITCH = 11.0
SENSOR_FWD = 30.0
LINE_HW = 6.5
K_MMS = 0.5
LEAD = 600.0
EXIT = 900.0

TICK_DT = 0.010
DUTY_MAX = 1200
WIDE_CNT_TH = 5
WIDE_MS = 200
LOST_HOLD_MS = 300
SEARCH_DUTY = 500
SEARCH_MS = 1500
WEIGHTS = [-7, -5, -3, -1, 1, 3, 5, 7]


def sensor_lats():
    return [(3.5 - i) * SENSOR_PITCH for i in range(8)]


def seg_dist(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    L2 = vx * vx + vy * vy
    if L2 <= 1e-12:
        return math.hypot(wx, wy)
    t = (wx * vx + wy * vy) / L2
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    return math.hypot(px - (ax + t * vx), py - (ay + t * vy))


def make_track(turn_deg=90.0, turn='L'):
    """入口直道 -> 单拐角 -> 出口直道（垂直于入口）。"""
    pts = [(0.0, 0.0), (LEAD, 0.0)]
    s = -1.0 if turn == 'L' else 1.0
    a = math.radians(turn_deg) * s
    # 出口方向：从 +x 旋 a
    dx, dy = math.cos(a), math.sin(a)
    pts.append((LEAD + EXIT * dx, EXIT * dy))
    return pts


def track_dist(px, py, pts):
    best = 1e18
    for k in range(len(pts) - 1):
        ax, ay = pts[k]
        bx, by = pts[k + 1]
        dd = seg_dist(px, py, ax, ay, bx, by)
        if dd < best:
            best = dd
    return best


class Sensor:
    def __init__(self, pts, wide_cnt_th=WIDE_CNT_TH, wide_ms=WIDE_MS):
        self.pts = pts
        self.WIDE_TH = 9 if wide_cnt_th == 0 else wide_cnt_th
        self.wide_tmr = 0
        self.prev_pos = 0
        self.wide_lost = False
        self.wide_ms = wide_ms

    def sample(self, x, y, th):
        c, s = math.cos(th), math.sin(th)
        cnt = 0
        wsum = 0
        for i in range(8):
            lat = (3.5 - i) * SENSOR_PITCH
            px = x + SENSOR_FWD * c - lat * s
            py = y + SENSOR_FWD * s + lat * c
            if track_dist(px, py, self.pts) <= LINE_HW:
                cnt += 1
                wsum += WEIGHTS[i]
        wide_now = cnt >= self.WIDE_TH
        if not wide_now:
            self.wide_tmr = 0
        else:
            self.wide_tmr += 1
        self.wide_lost = self.wide_tmr >= self.wide_ms
        if cnt == 0:
            pos = 0
        elif wide_now:
            pos = self.prev_pos
        else:
            wabs = abs(wsum)
            prod = wabs * (1024 // cnt) + 512
            pmag = prod >> 10
            pos = -pmag if wsum < 0 else pmag
        self.prev_pos = pos
        lost = (cnt == 0) or self.wide_lost
        on_line = (cnt != 0) and (not self.wide_lost)
        return dict(cnt=cnt, pos=pos, wide=wide_now, wide_lost=self.wide_lost,
                    lost=lost, on_line=on_line)


def run(turn_deg=90.0, turn='L', p=None, k=K_MMS, t_end=20.0,
        wide_cnt_th=WIDE_CNT_TH, wide_ms=WIDE_MS,
        turn_mode='lost', default_turn_left=True):
    """turn_mode:
       'none'  -> S_LOST 后直行（-SEARCH_FAIL 前的 300ms 保持后直走）
       'lost'  -> S_LOST 按 DEFAULT_TURN_LEFT 原地转
    """
    if p is None:
        p = dict(BASE=480, P=72, D=40, ISHIFT=5, ILIM=640)
    pts = make_track(turn_deg, turn)
    sens = Sensor(pts, wide_cnt_th, wide_ms)
    x = y = 0.0
    th = 0.0
    pos_d = 0
    i_acc = 0
    lost_d = False
    duty_l = duty_r = 0
    lost_ms = 0
    state = 'RUN'
    search_ms = 0
    turn_ms = 0
    t = 0.0
    max_lat = 0.0
    events = dict(lost=0, wide=0, wide_lost=0)
    prev_lost = False
    prev_wide = False
    prev_wl = False
    TURN_DUTY = 700
    TURN_MS = 1100
    turn_sign = -1.0 if default_turn_left else 1.0

    while t < t_end:
        r = sens.sample(x, y, th)
        cnt, pos, lost = r['cnt'], r['pos'], r['lost']
        if lost and not prev_lost:
            events['lost'] += 1
        if r['wide'] and not prev_wide:
            events['wide'] += 1
        if r['wide_lost'] and not prev_wl:
            events['wide_lost'] += 1
        prev_lost, prev_wide, prev_wl = lost, r['wide'], r['wide_lost']
        line_visible = r['on_line'] and not lost and not r['wide']

        if state == 'RUN':
            if lost:
                lost_ms += 10
                if lost_ms >= LOST_HOLD_MS:
                    state = 'LOST' if turn_mode == 'none' else 'TURN'
                    turn_ms = 0
            else:
                lost_ms = 0
        elif state == 'LOST':
            # 保持 300ms 后转 SEARCH：两轮同向直行
            state = 'SEARCH'
            search_ms = 0
        elif state == 'TURN':
            turn_ms += 10
            if turn_ms >= TURN_MS:
                state = 'SEARCH'
                search_ms = 0
        elif state == 'SEARCH':
            search_ms += 10
            if line_visible:
                state = 'RUN'
                lost_ms = 0
            elif search_ms >= SEARCH_MS:
                state = 'STOP'

        if state == 'RUN':
            if lost:
                dl, dr = duty_l, duty_r
            else:
                err = pos
                err_d = 0 if lost_d else (err - pos_d)
                sraw = err * p['P'] + (i_acc >> p['ISHIFT']) + err_d * p['D']
                lim = p['BASE']
                sl = lim if sraw > lim else (-lim if sraw < -lim else sraw)
                dl, dr = p['BASE'] + sl, p['BASE'] - sl
                pos_d = pos
                i_acc = max(-p['ILIM'], min(p['ILIM'], i_acc + err))
            lost_d = lost
        elif state == 'TURN':
            if turn_sign < 0:   # 左转：右轮快
                dl, dr = int(TURN_DUTY * 0.35), TURN_DUTY
            else:
                dl, dr = TURN_DUTY, int(TURN_DUTY * 0.35)
        elif state == 'SEARCH':
            dl, dr = SEARCH_DUTY, SEARCH_DUTY
        else:
            dl, dr = 0, 0

        dl = max(0, min(DUTY_MAX, dl))
        dr = max(0, min(DUTY_MAX, dr))
        duty_l, duty_r = dl, dr

        for _ in range(10):
            dt = TICK_DT / 10
            vl = dl * k
            vr = dr * k
            v = (vl + vr) / 2.0
            w = (vr - vl) / WHEEL_BASE
            x += v * math.cos(th) * dt
            y += v * math.sin(th) * dt
            th += w * dt

        lat = track_dist(x, y, pts)
        max_lat = max(max_lat, lat)
        t += TICK_DT
        if lat > 150:
            return dict(ok=False, why='off-track', t=t, max_lat=max_lat, state=state, **events)
        # 完成：沿出口方向投影超过拐角 400mm（用投影，不能用"离拐角超过400"，
        # 否则起点离拐角 600mm 会立刻判完成）
        corner = pts[1]
        ex, ey = pts[2][0] - corner[0], pts[2][1] - corner[1]
        el = math.hypot(ex, ey)
        ex, ey = ex / el, ey / el
        proj = (x - corner[0]) * ex + (y - corner[1]) * ey
        if proj > 400:
            return dict(ok=True, why='finished', t=t, max_lat=max_lat, state=state, **events)
    return dict(ok=False, why='timeout', t=t, max_lat=max_lat, state=state, **events)


if __name__ == '__main__':
    print("=== 折线拐角：现在实车配置（BASE=480 P=72 D=40）===")
    print("%-6s %-4s %-6s %5s %8s %6s %6s %6s %6s" % (
        "角度", "方向", "找线", "ok", "maxLat", "t", "lost", "wide", "wlost"))
    for deg in [90.0, 75.0, 60.0, 45.0]:
        for mode in ['nodir', 'lost']:
            tm = 'none' if mode == 'nodir' else 'lost'
            for turn in ['L', 'R']:
                r = run(turn_deg=deg, turn=turn, turn_mode=tm)
                print("%-6.0f %-4s %-6s %5s %8.1f %6.1f %6d %6d %6d" % (
                    deg, turn, mode, "Y" if r['ok'] else "N", r['max_lat'], r['t'],
                    r['lost'], r['wide'], r['wide_lost']))
        print()
