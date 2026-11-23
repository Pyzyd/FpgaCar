# -*- coding: utf-8 -*-
"""验证两个候选修法能否救回直角/锐角拐角。

修法A（拐角方向锁存）：wide 那一拍用质心符号判定拐角往哪边，锁存。
        质心在 wide 时的偏移方向，正是多压出来的那段出弯线的方向。
修法B（拐角短保持）：丢线时若刚过拐角(corner_cnt!=0)，不等 LOST_HOLD_MS(300ms)，
        改用很短的 CORNER_HOLD_MS 立刻原地转。
"""
import math
import corner_poly_sim as S

PIVOT = 500


def run(turn_deg, turn, corner_hold_ms=300, latch_dir=False,
        wide_centroid=False, p=None, k=0.5, t_end=20.0, trace=False):
    if p is None:
        p = dict(BASE=480, P=72, D=40, ISHIFT=5, ILIM=640)
    pts = S.make_track(turn_deg, turn)
    sens = S.Sensor(pts)
    x = y = 0.0
    th = 0.0
    pos_d = 0
    i_acc = 0
    lost_d = False
    duty_l = duty_r = 0
    lost_ms = 0
    state = 'RUN'
    search_ms = 0
    corner_cnt = 0
    corner_left = True
    t = 0.0
    max_lat = 0.0
    pivoted = 0
    tr = []

    while t < t_end:
        r = sens.sample(x, y, th)
        cnt, pos, lost = r['cnt'], r['pos'], r['lost']
        # wide 判定 + 质心
        wide_now = cnt >= sens.WIDE_TH
        wsum = 0
        if wide_now:
            c, s = math.cos(th), math.sin(th)
            for i in range(8):
                lat = (3.5 - i) * S.SENSOR_PITCH
                px = x + S.SENSOR_FWD * c - lat * s
                py = y + S.SENSOR_FWD * s + lat * c
                if S.track_dist(px, py, pts) <= S.LINE_HW:
                    wsum += S.WEIGHTS[i]

        # 修法A：wide 时用质心方向（正值=拐角在右）
        if wide_now and state == 'RUN' and not lost:
            corner_cnt = 200
            if latch_dir and wsum != 0:
                corner_left = (wsum < 0)
        elif corner_cnt > 0:
            corner_cnt -= 10

        if wide_centroid and wide_now and cnt > 0:
            wabs = abs(wsum)
            prod = wabs * (1024 // cnt) + 512
            pmag = prod >> 10
            pos = -pmag if wsum < 0 else pmag

        if state == 'RUN':
            if lost:
                lost_ms += 10
                hold = corner_hold_ms if corner_cnt > 0 else S.LOST_HOLD_MS
                if lost_ms >= hold:
                    state = 'TURN'
                    search_ms = 0
                    pivoted += 1
            else:
                lost_ms = 0
        elif state == 'TURN':
            search_ms += 10
            visible = r['on_line'] and not lost and not wide_now
            if visible and search_ms >= 100:
                state = 'RUN'
                lost_ms = 0
                corner_cnt = 0
            elif search_ms >= S.SEARCH_MS:
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
            # 原地转：两轮反向、同占空比
            if corner_left:
                dl, dr = -PIVOT, PIVOT
            else:
                dl, dr = PIVOT, -PIVOT
        else:
            dl, dr = 0, 0

        duty_l, duty_r = dl, dr
        for _ in range(10):
            dt = 0.001
            vl, vr = dl * k, dr * k
            v = (vl + vr) / 2.0
            w = (vr - vl) / S.WHEEL_BASE
            x += v * math.cos(th) * dt
            y += v * math.sin(th) * dt
            th += w * dt

        lat = S.track_dist(x, y, pts)
        max_lat = max(max_lat, lat)
        if len(tr) < 400:
            tr.append((round(t, 2), state, cnt, pos, round(lat, 1)))
        t += 0.010
        corner = pts[1]
        ex, ey = pts[2][0] - corner[0], pts[2][1] - corner[1]
        el = math.hypot(ex, ey)
        proj = (x - corner[0]) * ex / el + (y - corner[1]) * ey / el
        if proj > 400:
            return dict(ok=True, max_lat=max_lat, t=t, pivot=pivoted, tr=tr)
        if lat > 150:
            return dict(ok=False, why='off', max_lat=max_lat, t=t, pivot=pivoted, tr=tr)
    return dict(ok=False, why='timeout', max_lat=max_lat, t=t, pivot=pivoted, tr=tr)


if __name__ == '__main__':
    configs = [
        ("现状(hold=300,兜底左转)", dict(corner_hold_ms=300, latch_dir=False)),
        ("A:方向锁存", dict(corner_hold_ms=300, latch_dir=True)),
        ("B:短保持100", dict(corner_hold_ms=100, latch_dir=False)),
        ("A+B:锁存+100", dict(corner_hold_ms=100, latch_dir=True)),
        ("A+B:锁存+30", dict(corner_hold_ms=30, latch_dir=True)),
        ("A+B:锁存+0", dict(corner_hold_ms=0, latch_dir=True)),
    ]
    print("%-24s %-4s %-4s %5s %8s %6s" % ("方案", "角度", "方向", "ok", "maxLat", "pivot"))
    for name, cfg in configs:
        for deg in [90.0, 75.0, 60.0]:
            for turn in ['L', 'R']:
                r = run(deg, turn, **cfg)
                print("%-24s %-4.0f %-4s %5s %8.1f %6d" % (
                    name, deg, turn, "Y" if r['ok'] else "N", r['max_lat'], r['pivot']))
        print()
