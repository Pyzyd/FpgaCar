# -*- coding: utf-8 -*-
"""量 cnt：弯道上 8 路探头到底能压到几路？wide(WIDE_CNT_TH=5) 会不会触发？
以及几何参数（pitch/fwd/线宽）敏感性。
"""
import math
import corner_loop_sim2 as S2

def probe_track(p, R=300.0, pitch=None, fwd=None, line_hw=None, wide_th=5):
    if pitch is not None:
        S2.SENSOR_PITCH = pitch
    if fwd is not None:
        S2.SENSOR_FWD = fwd
    if line_hw is not None:
        S2.LINE_HW = line_hw
    pts = S2.build_track(R)
    tr = S2.Tracker(pts)
    sens = S2.LineSensor(tr, wide_th, 200)
    x = y = 0.0
    th = 0.0
    pos_d = 0; i_acc = 0; lost_d = 0
    duty_l = duty_r = 0; lost_ms = 0
    state = 'RUN'; search_ms = 0
    t = 0.0
    cmax = 0; cmax_at = 0.0
    hist = {}
    wide_ms_total = 0
    prev = 0
    while t < 25.0:
        r = S2.read_1khz(sens, x, y, th, 10)
        cnt, pos, lost, wide = r['cnt'], r['pos'], r['lost'], r['wide']
        hist[cnt] = hist.get(cnt, 0) + 1
        if cnt > cmax:
            cmax = cnt; cmax_at = t
        if wide:
            wide_ms_total += 10
        line_visible = r['on_line'] and (not lost) and (not wide)
        if state == 'RUN':
            if lost:
                lost_ms += 10
                if lost_ms >= 300:
                    state = 'SEARCH'; search_ms = 0
            else:
                lost_ms = 0
        elif state == 'SEARCH':
            search_ms += 10
            if line_visible:
                state = 'RUN'; lost_ms = 0
            elif search_ms >= 1500:
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
            dl, dr = 500, 500
        else:
            dl, dr = 0, 0
        fl, fr = S2.shaper(dl, dr, True, 1)
        duty_l = max(0, min(1200, fl)); duty_r = max(0, min(1200, fr))
        vl = duty_l * 0.5 * 1.0; vr = duty_r * 0.5 * 1.0
        v = (vl + vr) / 2.0; w = (vr - vl) / S2.WHEEL_BASE
        for _ in range(10):
            dt = 0.001
            x += v * math.cos(th) * dt; y += v * math.sin(th) * dt; th += w * dt
        lat = tr.dist(x, y)
        t += 0.010
        if lat > 150 or (R is not None and y > 850.0):
            break
    return dict(cmax=cmax, cmax_at=cmax_at, hist=hist, wide_ms=wide_ms_total,
                t=t, lat=lat, ok=(lat <= 150))

if __name__ == '__main__':
    p = S2.pid_params(480, 72, 40, 5, 640)
    print("=== 弯道上 cnt 分布（R=300，pitch=11，fwd=30，lineHW=6.5）===")
    r = probe_track(p, R=300.0)
    print("cmax=%d at t=%.2fs  wide_total=%dms  ok=%s" % (r['cmax'], r['cmax_at'], r['wide_ms'], r['ok']))
    print("cnt histogram:", dict(sorted(r['hist'].items())))
    print()
    print("=== 几何敏感性：只看 cmax 与能否压到 5 路 ===")
    print("%-8s %-8s %-8s %-8s %6s %8s %8s" % ("R","pitch","fwd","lineHW","cmax","wideMs","ok"))
    for R in [400.0, 300.0, 250.0, 200.0]:
        for pitch in [10.0, 11.0, 12.0, 14.0]:
            r = probe_track(p, R=R, pitch=pitch)
            print("%-8.0f %-8.1f %-8.1f %-8.1f %6d %8d %8s" % (
                R, pitch, 30.0, 6.5, r['cmax'], r['wide_ms'], r['ok']))
    print()
    for lw in [6.5, 8.0, 10.0, 12.0]:
        r = probe_track(p, R=300.0, line_hw=lw)
        print("lineHW=%-5.1f cmax=%d wide=%dms ok=%s hist=%s" % (
            lw, r['cmax'], r['wide_ms'], r['ok'], dict(sorted(r['hist'].items()))))
    for fw in [10.0, 30.0, 50.0, 70.0]:
        r = probe_track(p, R=300.0, fwd=fw)
        print("fwd=%-5.1f cmax=%d wide=%dms ok=%s" % (fw, r['cmax'], r['wide_ms'], r['ok']))
