# -*- coding: utf-8 -*-
"""v5：直角拐角失效的最小修法扫描。

三个正交维度：
  wide_th     5(现状) / 6 / 7 / 8 / 9(=关闭宽黑)
  wide_pos    'hold' 宽黑时冻结 pos（现状） / 'calc' 宽黑时照算质心
  corner_dir  'left' 拐角兜底一律左转（现状） / 'last' 用丢线前最后的 pos 符号
"""
import math
import corner_poly_sim as S

PIVOT = 500
KP, KD, KI, IL = 72, 40, 5, 640
BASE = 480


def run(turn_deg, turn, wide_th=5, wide_pos='hold', corner_dir='left',
        corner_hold_ms=300, k=0.5, t_end=20.0, x0=0.0, y0=0.0, th0=0.0):
    pts = S.make_track(turn_deg, turn)
    sens = S.Sensor(pts, wide_cnt_th=wide_th)
    x = x0
    y = y0
    th = th0
    pos_d = 0
    i_acc = 0
    lost_d = False
    duty_l = duty_r = 0
    lost_ms = 0
    state = 'RUN'
    search_ms = 0
    corner_cnt = 0
    corner_left = True
    last_pos = 0
    t = 0.0
    max_lat = 0.0
    pivots = 0

    while t < t_end:
        c, s = math.cos(th), math.sin(th)
        wsum = 0
        cnt = 0
        seen = []
        for i in range(8):
            lat = (3.5 - i) * S.SENSOR_PITCH
            px = x + S.SENSOR_FWD * c - lat * s
            py = y + S.SENSOR_FWD * s + lat * c
            hit = 1 if S.track_dist(px, py, pts) <= S.LINE_HW else 0
            seen.append(hit)
            if hit:
                cnt += 1
                wsum += S.WEIGHTS[i]
        wide_now = cnt >= sens.WIDE_TH
        # track_line 的 pos
        if cnt == 0:
            pos = 0
        elif wide_now and wide_pos == 'hold':
            pos = last_pos
        else:
            wabs = abs(wsum)
            prod = wabs * (1024 // cnt) + 512
            pmag = prod >> 10
            pos = -pmag if wsum < 0 else pmag
        lost = (cnt == 0)
        on_line = (cnt != 0)

        if on_line and not lost:
            last_pos = pos
            if wide_now and state == 'RUN':
                corner_cnt = 200
                corner_left = (pos < 0)
        elif corner_cnt > 0:
            corner_cnt -= 10

        if state == 'RUN':
            if lost:
                lost_ms += 10
                hold = corner_hold_ms if corner_cnt > 0 else S.LOST_HOLD_MS
                if lost_ms >= hold:
                    state = 'TURN'
                    search_ms = 0
                    pivots += 1
                    if corner_dir == 'left':
                        corner_left = True
                    elif corner_dir == 'last':
                        corner_left = (last_pos < 0)
                    elif corner_dir == 'last_or_left':
                        # 线方位明确（pos!=0）才采信；居中/未知时退回默认左转
                        corner_left = (last_pos < 0) if last_pos != 0 else True
            else:
                lost_ms = 0
        elif state == 'TURN':
            search_ms += 10
            if on_line and not wide_now and search_ms >= 100:
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
                sraw = err * KP + (i_acc >> KI) + err_d * KD
                sl = BASE if sraw > BASE else (-BASE if sraw < -BASE else sraw)
                dl, dr = BASE + sl, BASE - sl
                pos_d = pos
                i_acc = max(-IL, min(IL, i_acc + err))
            lost_d = lost
        elif state == 'TURN':
            dl, dr = (-PIVOT, PIVOT) if corner_left else (PIVOT, -PIVOT)
        else:
            dl, dr = 0, 0

        duty_l, duty_r = dl, dr
        for _ in range(10):
            dt = 0.001
            vl, vr = dl * k, dr * k
            v = (vl + vr) / 2.0
            w = (vr - vl) / S.WHEEL_BASE
            x += v * c * dt
            y += v * s * dt
            th += w * dt
            c, s = math.cos(th), math.sin(th)

        lat = S.track_dist(x, y, pts)
        max_lat = max(max_lat, lat)
        t += 0.010
        corner = pts[1]
        ex, ey = pts[2][0] - corner[0], pts[2][1] - corner[1]
        el = math.hypot(ex, ey)
        proj = (x - corner[0]) * ex / el + (y - corner[1]) * ey / el
        if proj > 400:
            return dict(ok=True, max_lat=max_lat, t=t, pivots=pivots)
        if lat > 150:
            return dict(ok=False, max_lat=max_lat, t=t, pivots=pivots)
    return dict(ok=False, max_lat=max_lat, t=t, pivots=pivots)


def sweep(title, cases):
    print("=== %s ===" % title)
    print("%-6s %-4s %5s %8s %6s %s" % ("角度", "方向", "ok", "maxLat", "pivot", "配置"))
    for label, kw in cases:
        rows = []
        for deg in [90.0, 75.0, 60.0, 45.0]:
            for turn in ['L', 'R']:
                r = run(deg, turn, **kw)
                rows.append((deg, turn, r))
        bad = [x for x in rows if not x[2]['ok']]
        print("  [%s] 失败 %d/%d  " % (label, len(bad), len(rows)), end="")
        if bad:
            print("worstLat=%.1f  " % max(x[2]['max_lat'] for x in bad), end="")
            print("失败角: " + ",".join("%.0f%s" % (x[0], x[1]) for x in bad))
        else:
            print("全通过  maxLat=%.1f" % max(x[2]['max_lat'] for x in rows))
            print()
    print()


if __name__ == '__main__':
    sweep("宽黑阈值扫描（wide_pos=hold, corner_dir=left）", [
        ("WT=5 现状", dict(wide_th=5, wide_pos='hold', corner_dir='left')),
        ("WT=6", dict(wide_th=6, wide_pos='hold', corner_dir='left')),
        ("WT=7", dict(wide_th=7, wide_pos='hold', corner_dir='left')),
        ("WT=8", dict(wide_th=8, wide_pos='hold', corner_dir='left')),
        ("WT=9 关闭", dict(wide_th=9, wide_pos='hold', corner_dir='left')),
    ])

    sweep("宽黑时照算质心（WT=5, corner_dir=left）", [
        ("hold 现状", dict(wide_th=5, wide_pos='hold', corner_dir='left')),
        ("calc", dict(wide_th=5, wide_pos='calc', corner_dir='left')),
        ("calc + last", dict(wide_th=5, wide_pos='calc', corner_dir='last')),
    ])

    sweep("拐角方向改用丢线前 pos（WT=5, wide_pos=hold）", [
        ("left 现状", dict(wide_th=5, wide_pos='hold', corner_dir='left')),
        ("last", dict(wide_th=5, wide_pos='hold', corner_dir='last')),
    ])

    sweep("组合：WT=8 + last", [
        ("WT=8 + last", dict(wide_th=8, wide_pos='hold', corner_dir='last')),
        ("WT=6 + last", dict(wide_th=6, wide_pos='hold', corner_dir='last')),
        ("WT=6 calc + last", dict(wide_th=6, wide_pos='calc', corner_dir='last')),
    ])
