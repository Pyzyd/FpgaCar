# -*- coding: utf-8 -*-
"""避障航向剖面几何验证（v1.23：参考角爬坡 + REJOIN 保持斜切 + PASS 每轮里程）

出口语义严格对齐 RTL：
  PASS  arc_sum >= PASS_SUM_TARGET*2  == 两轮各自都走满 AVOID_PASS_MM
"""
import math

B_WHEEL, HALF_W, CUBE_H = 160.0, 92.5, 50.0
NOSE, REAR = 75.0, 75.0 - 200.0
CPM = 2532.0 / 212.0
TRIG = 280.0
NEED_LAT = HALF_W + CUBE_H
DT = 0.001

ARC_T = 1999            # 60° 基准（每度 33.3 计数）
PASS_SUM = 2388         # 200mm 每轮
DEAD, SHIFT, SMAX, SMIN, DMIN, DMAX = 10, 3, 600, 60, 120, 1200
RAMP = 2.0              # 参考角爬坡 cnt/ms

# 真实顶层超时上限（AVOID_*_MS × AVOID_ENC_MULT=4）
CEIL = {'out': 3120, 'align': 3400, 'pass': 2880, 'turn': 6400, 'rejoin': 2500}

def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)

def steer_of(err):
    if err > DEAD:    dz = err - DEAD
    elif err < -DEAD: dz = err + DEAD
    else:             return 0
    st = clamp(int(dz) >> SHIFT, -SMAX, SMAX)
    if 0 < st < SMIN:  st = SMIN
    if 0 > st > -SMIN: st = -SMIN
    return st

def outline(x, y, th, n=8):
    c, s = math.cos(th), math.sin(th)
    pts = []
    for sx in (-HALF_W, HALF_W):
        for i in range(n + 1):
            fy = REAR + (NOSE - REAR) * i / n
            pts.append((x + sx*c - fy*s, y + sx*s + fy*c))
    for fy in (NOSE, REAR):
        for i in range(n + 1):
            sx = -HALF_W + 2*HALF_W*i/n
            pts.append((x + sx*c - fy*s, y + sx*s + fy*c))
    return pts

def clearance(x, y, th, cy):
    best = 1e9
    for px, py in outline(x, y, th):
        dx = max(abs(px) - CUBE_H, 0.0)
        dy = max(abs(py - cy) - CUBE_H, 0.0)
        v = math.hypot(dx, dy)
        if v < best: best = v
    return best

def simulate(KL, KR, arc_deg=70.0, pass_mm=300.0, turn_deg=70.0,
             dt=DT, line_x=30.0, ramp=RAMP, ceil=None, trigger=TRIG,
             i_shift=99, i_max=400.0, i_on=None):
    ceil = ceil or CEIL
    cy = NOSE + trigger + CUBE_H
    arc_t  = arc_deg  / 60.0 * ARC_T
    turn_t = turn_deg / 60.0 * ARC_T
    pass_s = pass_mm  / 200.0 * PASS_SUM * 2.0     # 两轮各自走满 pass_mm
    segs = [(860, 380, 'out'), (400, 840, 'align'), (620, 620, 'pass'),
            (420, 860, 'turn'), (430, 640, 'rejoin')]
    x = y = th = 0.0
    g_l = g_r = 0.0
    integ = 0.0
    min_clr = clearance(x, y, th, cy)
    rows, total = [], 0.0
    for (nl, nr, smode) in segs:
        if   smode == 'out':   tgt = -arc_t
        elif smode in ('turn', 'rejoin'): tgt = +turn_t
        else:                  tgt = 0.0
        ref = (g_r - g_l) * CPM      # 段起点参考角钉到实测角
        seg_l0, seg_r0 = g_l, g_r
        seg_ms, done = 0.0, False
        while seg_ms < ceil[smode] and not done:
            if ref < tgt:   ref = min(ref + ramp, tgt)
            elif ref > tgt: ref = max(ref - ramp, tgt)
            err_raw = ref - (g_r - g_l) * CPM
            if i_shift < 30 and (i_on is None or smode in i_on):
                integ = clamp(integ + err_raw / (2.0 ** i_shift), -i_max, i_max)
            st = clamp(steer_of(err_raw) + integ, -SMAX, SMAX)
            dl = clamp(nl - st, DMIN, DMAX)
            dr = clamp(nr + st, DMIN, DMAX)
            vl, vr = KL*dl, KR*dr
            g_l += vl*dt; g_r += vr*dt
            x += (vl+vr)/2.0*math.sin(th)*dt
            y += (vl+vr)/2.0*math.cos(th)*dt
            th += (vr-vl)/B_WHEEL*dt
            seg_ms += dt*1000.0
            total += dt*1000.0
            c = clearance(x, y, th, cy)
            if c < min_clr: min_clr = c
            turn_abs = (g_r - g_l)*CPM
            seg_sum  = ((g_l-seg_l0)+(g_r-seg_r0))*CPM
            if smode == 'out':      done = turn_abs <= -arc_t
            elif smode == 'align':  done = turn_abs >= 0
            elif smode == 'pass':   done = seg_sum >= pass_s
            elif smode == 'turn':   done = turn_abs >= turn_t
            elif smode == 'rejoin': done = abs(x) <= line_x
        rows.append(dict(seg=smode, ms=seg_ms, x=x, y=y, th=math.degrees(th), done=done))
        if total > 40000: break
    return dict(min_clr=min_clr, x=x, y=y, th=math.degrees(th), ms=total, rows=rows)

KRS = (1.00, 0.85, 0.75, 0.65, 0.55, 0.50)

def main():
    print('PASS 语义 = 两轮各自走满 pass_mm（对齐 RTL arc_sum >= 2*PASS_SUM_TARGET）')
    print('%-4s %-5s %-5s | %s' % ('arc','pass','ramp', ' '.join('%-6.2f'%k for k in KRS)))
    rows = []
    for arc in (65, 70, 75):
        for pm in (200, 250, 300, 350, 400):
            for ramp in (2.0, 3.0):
                clrs, bad = [], 0
                for kk in KRS:
                    r = simulate(0.30, 0.30*kk, arc, pm, arc, ramp=ramp)
                    clrs.append(r['min_clr'])
                    if any(not row['done'] for row in r['rows']): bad += 1
                rows.append((min(clrs), -bad, arc, pm, ramp, clrs))
    for w, nbad, a, p, ramp, clrs in sorted(rows, reverse=True)[:18]:
        print('%-4d %-5d %-5.1f | %s  worst=%5.1f  TO=%d' % (
            a, p, ramp, ' '.join('%6.1f'%c for c in clrs), w, -nbad))
    print()
    print('--- 逐段（arc=70 pass=300 ramp=2.0）---')
    for kk in (1.00, 0.75, 0.55):
        r = simulate(0.30, 0.30*kk, 70, 300, 70)
        print('KR/KL=%.2f minClr=%5.1f endX=%6.1f endTh=%5.0f total=%5.0fms' % (
            kk, r['min_clr'], r['x'], r['th'], r['ms']))
        print('   ' + '  '.join('%s:%5.0f/%5.0f°/%4.0fms/%s' % (
            row['seg'][:6], row['x'], row['th'], row['ms'], 'ok' if row['done'] else 'TO') for row in r['rows']))

if __name__ == '__main__':
    main()
