# -*- coding: utf-8 -*-
import math
import corner_poly_sim as S

def trace90():
    p = dict(BASE=480, P=72, D=40, ISHIFT=5, ILIM=640)
    pts = S.make_track(90.0, 'L')
    sens = S.Sensor(pts)
    x = y = 0.0; th = 0.0
    pos_d = 0; i_acc = 0; lost_d = False
    duty_l = duty_r = 0; lost_ms = 0
    state = 'RUN'; search_ms = 0; turn_ms = 0
    t = 0.0
    print("%6s %-6s %3s %4s %5s %5s %5s %6s %6s %6s" % ("t","state","cnt","pos","wide","lost","lat","x","y","th"))
    while t < 5.0:
        r = sens.sample(x, y, th)
        cnt, pos, lost = r['cnt'], r['pos'], r['lost']
        lat = S.track_dist(x, y, pts)
        if 1.5 < t < 3.6:
            print("%6.3f %-6s %3d %4d %5d %5d %5.1f %6.1f %6.1f %6.1f" % (
                t, state, cnt, pos, r['wide'], lost, lat, x, y, math.degrees(th)))
        if state == 'RUN':
            if lost:
                lost_ms += 10
                if lost_ms >= S.LOST_HOLD_MS:
                    state = 'TURN'; turn_ms = 0
            else:
                lost_ms = 0
        elif state == 'TURN':
            turn_ms += 10
            if turn_ms >= 1100:
                state = 'SEARCH'; search_ms = 0
        elif state == 'SEARCH':
            search_ms += 10
            if r['on_line'] and not lost and not r['wide']:
                state = 'RUN'; lost_ms = 0
            elif search_ms >= S.SEARCH_MS:
                state = 'STOP'
        if state == 'RUN':
            if lost:
                dl, dr = duty_l, duty_r
            else:
                err = pos
                err_d = 0 if lost_d else (err - pos_d)
                sraw = err*72 + (i_acc >> 5) + err_d*40
                lim = 480
                sl = lim if sraw > lim else (-lim if sraw < -lim else sraw)
                dl, dr = 480 + sl, 480 - sl
                pos_d = pos
                i_acc = max(-640, min(640, i_acc + err))
            lost_d = lost
        elif state == 'TURN':
            dl, dr = 245, 700
        elif state == 'SEARCH':
            dl, dr = 500, 500
        else:
            dl, dr = 0, 0
        duty_l, duty_r = dl, dr
        for _ in range(10):
            dt = 0.001
            vl, vr = dl*0.5, dr*0.5
            v = (vl+vr)/2.0; w = (vr-vl)/160.0
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        t += 0.010

trace90()
