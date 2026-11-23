# -*- coding: utf-8 -*-
"""避障几何：方块距离以【车头探头】为基准（超声装车头），驱动轴位置改变会同时挪探头。"""
import math

B_WHEEL = 160.0; HALF_W = 92.5; CUBE_H = 50.0; K = 0.5
TRIG_MM = 280.0     # 超声波触发阈值（探头到方块表面）

def outline(x, y, th, front, rear, n=24):
    pts = []
    for sx in (-HALF_W, HALF_W):
        for k in range(n + 1):
            pts.append((sx, rear + (front - rear) * k / n))
    for fy in (front, rear):
        for k in range(n + 1):
            pts.append((-HALF_W + 2 * HALF_W * k / n, fy))
    return [(x + sx*math.cos(th) - fy*math.sin(th),
             y + sx*math.sin(th) + fy*math.cos(th)) for sx, fy in pts]

def clearance(x, y, th, front, rear, cube_cy):
    b = 1e9
    for px, py in outline(x, y, th, front, rear):
        dx = max(abs(px) - CUBE_H, 0.0)
        dy = max(abs(py - cube_cy) - CUBE_H, 0.0)
        b = min(b, math.hypot(dx, dy))
    return b

def arc_t(o, i, deg=60.0):
    w = (o - i) * K / B_WHEEL
    return math.radians(deg) / abs(w) if abs(w) > 1e-9 else 0.0

def run(front, rear, t_out, t_align, t_pass, dt=5e-4):
    cube_cy = front + TRIG_MM + CUBE_H      # 探头在车头 front，阈值到方块表面
    x = y = th = 0.0; mc = 1e9
    def seg(o, i, t):
        nonlocal x, y, th, mc
        vc = (o+i)/2.0*K; w = (o-i)*K/B_WHEEL
        for _ in range(max(1, int(round(t/dt)))):
            x += vc*math.sin(th)*dt; y += vc*math.cos(th)*dt; th += w*dt
            mc = min(mc, clearance(x, y, th, front, rear, cube_cy))
    seg(860, 380, t_out);   lat1, d1 = x, math.degrees(th)
    seg(400, 840, t_align); lat2, d2 = x, math.degrees(th)
    seg(620, 620, t_pass)
    return lat1, d1, lat2, d2, mc, y

ta, tb = arc_t(860, 380), arc_t(400, 840)
print("60 度差速弧理论时长: BY_OUT %.0f ms, BY_ALIGN %.0f ms" % (ta*1000, tb*1000))
print("超时设计值(顶层): BY_OUT 2500 ms, BY_ALIGN 2500 ms, BY_PASS 900 ms")
print()
for label, (t_out, t_align, t_pass) in (
    ("有编码器(里程闭环, 理论时长)", (ta, tb, 200.0/(620*K))),
    ("无编码器(现状 2500/2500/900)", (2.5, 2.5, 0.9)),
    ("无编码器(建议 900/950/750)",   (0.900, 0.950, 0.750)),
    ("无编码器(旧设计 524/-/900)",   (0.524, tb, 0.9)),
):
    print("=== %s ===" % label)
    for front, rear, name in ((30.0, -170.0, "旧:驱动轴距车头 30mm"), (75.0, -125.0, "新:驱动轴距车头 75mm")):
        r = run(front, rear, t_out, t_align, t_pass)
        print("  %-22s 横移=%7.1f 转角=%7.1f | 摆正后横移=%7.1f 转角=%7.1f | 最小间隙=%6.1f 终点y=%7.1f"
              % (name, r[0], r[1], r[2], r[3], r[4], r[5]))
    print()
