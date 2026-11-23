# -*- coding: utf-8 -*-
"""弯道闭环仿真 v2：完整复刻 track_line 的宽黑/丢线判据。

硬件链路：
  track_line  1 kHz 采样，cnt>=WIDE_CNT_TH 记 wide 并计时，
              wide 持续 WIDE_MS 就降级成 lost；lost 时 on_line=0。
  track_pid   100 Hz，lost 时冻结 duty / pos_d / 积分。
  car_fsm     line_visible = on_line && !lost && !wide；
              LOST 保持 300 ms -> SEARCH 两轮 500 直行。

这个脚本的目的只有一个：量出"宽黑降级"到底是不是弯道失效的主因。
"""
import math

# ---------------- 车体几何（mm） ----------------
WHEEL_BASE = 160.0
SENSOR_PITCH = 11.0
SENSOR_FWD = 30.0
LINE_HW = 6.5
K_MMS = 0.5

# ---------------- 控制器 ----------------
TICK_DT = 0.010
DUTY_MAX = 1200
WIDE_TICKS = 200
LOST_HOLD_MS = 300
SEARCH_DUTY = 500
SEARCH_MS = 1500

WEIGHTS = [-7, -5, -3, -1, 1, 3, 5, 7]

def sensor_lats():
    return [(3.5 - i) * SENSOR_PITCH for i in range(8)]

def pid_params(base, p, dg, ishift, ilim):
    return dict(BASE=base, P=p, D=dg, ISHIFT=ishift, ILIM=ilim)

def build_track(R, lead=600.0, exit_len=900.0, step=2.0):
    """沿 +x 直道 lead -> 左弯 R 90 度 -> 直道。R=None 表示纯直道。"""
    pts = []
    n = int(lead / step)
    for k in range(n + 1):
        pts.append((k * step, 0.0))
    if R is None:
        for k in range(1, int(exit_len / step) + 1):
            pts.append((lead + k * step, 0.0))
        return pts
    cx, cy = lead, R
    na = max(8, int(R * math.pi / 2 / step))
    for k in range(1, na + 1):
        a = -math.pi / 2 + (math.pi / 2) * k / na
        pts.append((cx + R * math.cos(a), cy + R * math.sin(a)))
    ex, ey = cx + R, cy
    for k in range(1, int(exit_len / step) + 1):
        pts.append((ex, ey + k * step))
    return pts

class Tracker:
    """滑动窗口最近点搜索，避免每拍全表扫描。"""
    def __init__(self, pts):
        self.pts = pts
        self.i = 0
    def dist(self, px, py, win=200):
        pts = self.pts
        lo = max(0, self.i - win)
        hi = min(len(pts), self.i + win)
        best = 1e18
        bi = self.i
        for k in range(lo, hi):
            tx, ty = pts[k]
            dx, dy = px - tx, py - ty
            dd = dx * dx + dy * dy
            if dd < best:
                best = dd
                bi = k
        self.i = bi
        return math.sqrt(best)

class LineSensor:
    """按 1 kHz 采样 + 硬件宽黑判据。"""
    def __init__(self, tracker, wide_cnt_th=5, wide_ms=200):
        self.tr = tracker
        self.WIDE_TH = 9 if wide_cnt_th == 0 else wide_cnt_th
        self.WIDE_TICKS = wide_ms  # 1 kHz -> ticks == ms
        self.wide_tmr = 0
        self.prev_pos = 0

    def sample(self, x, y, th):
        c, s = math.cos(th), math.sin(th)
        seen = []
        for lat in sensor_lats():
            px = x + SENSOR_FWD * c - lat * s
            py = y + SENSOR_FWD * s + lat * c
            seen.append(1 if self.tr.dist(px, py) <= LINE_HW else 0)
        cnt = sum(seen)
        wsum = sum(WEIGHTS[i] * seen[i] for i in range(8))
        wide_now = cnt >= self.WIDE_TH
        if not wide_now:
            self.wide_tmr = 0
        else:
            self.wide_tmr += 1
        wide_lost = self.wide_tmr >= self.WIDE_TICKS
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
        lost = (cnt == 0) or wide_lost
        on_line = (cnt != 0) and (not wide_lost)
        return dict(cnt=cnt, pos=pos, wsum=wsum, wide=wide_now,
                    wide_lost=wide_lost, lost=lost, on_line=on_line)

def read_1khz(sens, x, y, th, n=10):
    """一个 PID tick 内 1 kHz 采样 n 次，返回末次结果与是否曾宽黑。"""
    r = None
    for _ in range(n):
        r = sens.sample(x, y, th)
    return r

def shaper(dl, dr, follow, diff_shift):
    if not follow:
        return dl, dr
    mid = (dl + dr) // 2
    diff = (dl - dr) // 2
    return mid + (diff >> diff_shift), mid - (diff >> diff_shift)

MISMATCH = 0.0
K_SCALE = 1.0

def run(p, R=300.0, diff_shift=1, shape_en=True, t_end=25.0,
        wide_cnt_th=5, wide_ms=200, k_mms=None, mismatch=None, step=2.0):
    global MISMATCH, K_MMS
    old_mm = MISMATCH
    if mismatch is not None:
        MISMATCH = mismatch
    km = K_MMS if k_mms is None else k_mms
    pts = build_track(R)
    tr = Tracker(pts)
    sens = LineSensor(tr, wide_cnt_th, wide_ms)
    x = y = 0.0
    th = 0.0
    pos_d = 0
    i_acc = 0
    lost_d = 0
    duty_l = duty_r = 0
    lost_ms = 0
    state = 'RUN'
    search_ms = 0
    t = 0.0
    max_lat = 0.0
    lost_events = 0
    wide_events = 0
    wide_lost_events = 0
    prev_lost = 0
    prev_wide_lost = 0
    trace = []
    try:
        while t < t_end:
            r = read_1khz(sens, x, y, th, 10)
            cnt, pos, lost, wide, wide_lost = r['cnt'], r['pos'], r['lost'], r['wide'], r['wide_lost']
            if lost and not prev_lost:
                lost_events += 1
            if wide and not prev_wide_lost:
                wide_events += 1
            prev_lost = lost
            prev_wide_lost = wide_lost
            if wide_lost and (wide_lost != prev_wide_lost):
                wide_lost_events += 1

            line_visible = r['on_line'] and (not lost) and (not wide)

            if state == 'RUN':
                if lost:
                    lost_ms += int(TICK_DT * 1000)
                    if lost_ms >= LOST_HOLD_MS:
                        state = 'SEARCH'
                        search_ms = 0
                else:
                    lost_ms = 0
            elif state == 'SEARCH':
                search_ms += int(TICK_DT * 1000)
                if line_visible:
                    state = 'RUN'
                    lost_ms = 0
                elif search_ms >= SEARCH_MS:
                    state = 'STOP'

            if state == 'RUN':
                err = pos
                err_d = 0 if lost_d else (err - pos_d)
                if lost:
                    dl, dr = duty_l, duty_r
                else:
                    sraw = err * p['P'] + (i_acc >> p['ISHIFT']) + err_d * p['D']
                    lim = p['BASE']
                    sl = lim if sraw > lim else (-lim if sraw < -lim else sraw)
                    dl, dr = p['BASE'] + sl, p['BASE'] - sl
                    pos_d = pos
                    i_acc = max(-p['ILIM'], min(p['ILIM'], i_acc + err))
                lost_d = lost
            elif state == 'SEARCH':
                dl, dr = SEARCH_DUTY, SEARCH_DUTY
            else:
                dl, dr = 0, 0

            if shape_en:
                fl, fr = shaper(dl, dr, True, diff_shift)
            else:
                fl, fr = dl, dr
            duty_l = max(0, min(DUTY_MAX, fl))
            duty_r = max(0, min(DUTY_MAX, fr))

            vl = duty_l * km * (1.0 - MISMATCH)
            vr = duty_r * km * (1.0 + MISMATCH)
            v = (vl + vr) / 2.0
            w = (vr - vl) / WHEEL_BASE
            for _ in range(10):
                dt = TICK_DT / 10
                x += v * math.cos(th) * dt
                y += v * math.sin(th) * dt
                th += w * dt

            lat = tr.dist(x, y)
            max_lat = max(max_lat, lat)
            if len(trace) < 3000:
                trace.append((round(t, 3), state, cnt, pos, duty_l, duty_r,
                              round(lat, 1), round(math.degrees(th), 1), lost_ms, r['wide']))
            t += TICK_DT

            if lat > 150:
                return dict(ok=False, why='off-track', t=t, max_lat=max_lat,
                            lost_events=lost_events, wide_events=wide_events,
                            wide_lost=wide_lost_events, trace=trace, x=x, y=y,
                            th=math.degrees(th))
            if R is not None and y > 850.0:
                return dict(ok=True, why='finished', t=t, max_lat=max_lat,
                            lost_events=lost_events, wide_events=wide_events,
                            wide_lost=wide_lost_events, trace=trace, x=x, y=y,
                            th=math.degrees(th))
            if R is None and x > 1400.0:
                return dict(ok=True, why='finished', t=t, max_lat=max_lat,
                            lost_events=lost_events, wide_events=wide_events,
                            wide_lost=wide_lost_events, trace=trace, x=x, y=y,
                            th=math.degrees(th))
        return dict(ok=False, why='timeout', t=t, max_lat=max_lat,
                    lost_events=lost_events, wide_events=wide_events,
                    wide_lost=wide_lost_events, trace=trace, x=x, y=y,
                    th=math.degrees(th))
    finally:
        MISMATCH = old_mm

if __name__ == '__main__':
    p = pid_params(480, 72, 40, 5, 640)
    print("sensor array half width = %.1f mm, line half width = %.1f mm" % (
        3.5 * SENSOR_PITCH, LINE_HW))
    print()
    print("=== WIDE 判据：弯道半径 x WIDE_CNT_TH（WIDE_MS=200, current PID）===")
    print("%-8s %-10s %5s %7s %8s %7s %8s" % ("R(mm)","WIDE_TH","ok","t(s)","maxLat","lost","wideLost"))
    for R in [400.0, 300.0, 250.0, 200.0, 150.0]:
        for wt in [5, 7, 9]:
            r = run(p, R=R, wide_cnt_th=wt)
            print("%-8.0f %-10d %5s %7.1f %8.1f %7d %8d" % (
                R, wt, "Y" if r['ok'] else "N", r['t'], r['max_lat'],
                r['lost_events'], r['wide_lost']))
        print()
