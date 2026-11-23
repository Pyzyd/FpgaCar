# -*- coding: utf-8 -*-
"""避障几何仿真（语义修正版）
坐标：x = 前进方向，y = 车体左侧，th = 航向（逆时针为正）。原点在驱动轴中心。
  车长 20 cm：驱动轴在车头后 3 cm，车尾在轴后 17 cm
  含轮总宽 18.5 cm，轮距 16 cm，轮半径 3.7 cm（周长 23.248 cm）
  超声波与车头齐平，方块 10x10x10（半宽 5 cm）
段定义：(duty_l, duty_r, kind, target)；kind='deg' 按角度停，'cm' 按平均里程停。
"""
import math

NOSE, HALF_W = 3.0, 9.25
B_WHEEL, CUBE_H, WHEEL_R = 16.0, 5.0, 3.7
Y_FRONT = NOSE + max(0.0, WHEEL_R - NOSE)   # 3.7：轮子最前
Y_REAR = NOSE - 20.0                        # -17
CIRC = 2 * math.pi * WHEEL_R
NEED_LAT = HALF_W + CUBE_H                  # 14.25


def boundary(x, y, th, step=0.5):
    c, s = math.cos(th), math.sin(th)
    pts = []
    n1 = max(2, int(2 * HALF_W / step))
    for fy in (Y_REAR, Y_FRONT):
        for k in range(n1 + 1):
            sy = -HALF_W + 2 * HALF_W * k / n1
            pts.append((x + c * fy - s * sy, y + s * fy + c * sy))
    n2 = max(2, int((Y_FRONT - Y_REAR) / step))
    for sx in (-HALF_W, HALF_W):
        for k in range(n2 + 1):
            fy = Y_REAR + (Y_FRONT - Y_REAR) * k / n2
            pts.append((x + c * fy - s * sx, y + s * fy + c * sx))
    return pts


def clearance(x, y, th, d0):
    best = 1e9
    for px, py in boundary(x, y, th):
        dx = max(abs(px - d0) - CUBE_H, 0.0)
        dy = max(abs(py) - CUBE_H, 0.0)
        if dx == 0.0 and dy == 0.0:
            return -1.0
        v = math.hypot(dx, dy)
        if v < best:
            best = v
    return best


def sim(segs, reading, v600, dt=0.002, show=False):
    """返回 (最小间隙, 末端x, 末端y, 末端航向deg)"""
    d0 = reading + NOSE + CUBE_H
    x = y = th = 0.0
    mc = clearance(x, y, th, d0)
    k = v600 / 600.0
    trace = []
    for (dl, dr, kind, target) in segs:
        vl, vr = dl * k, dr * k
        vc = (vl + vr) / 2.0
        w = (vr - vl) / B_WHEEL          # 右轮快 -> 逆时针（左转）
        if kind == 'deg':
            if abs(w) < 1e-9:
                continue
            t_end = abs(math.radians(target) / w)
        else:
            if abs(vc) < 1e-9:
                continue
            t_end = abs(target / vc)
        t = 0.0
        while t < t_end:
            x += vc * math.cos(th) * dt
            y += vc * math.sin(th) * dt
            th += w * dt
            t += dt
            c = clearance(x, y, th, d0)
            if c < mc:
                mc = c
        trace.append((kind, target, round(x, 1), round(y, 1), round(math.degrees(th), 1)))
    return mc, x, y, math.degrees(th), trace


R = B_WHEEL * (860 + 380) / (2.0 * (860 - 380))
print("860/380 弧半径 R = %.2f cm" % R)
print("单弧 60 度：横移 %.2f cm，前进 %.2f cm" % (R * (1 - math.cos(math.radians(60))), R * math.sin(math.radians(60))))
print("两弧(左右反向)：横移 %.2f cm（需 >= %.2f），前进 %.2f cm" % (
    2 * R * (1 - math.cos(math.radians(60))), NEED_LAT, 2 * R * math.sin(math.radians(60))))
print()

print("=== 修正后：左绕 = 右轮快先左转 60 度，再左轮快右转 60 度摆正 ===")
for reading in (18, 21, 25, 28):
    print("触发读数 %d cm（车头到方块 %.1f cm）:" % (reading, reading))
    for v600 in (20, 30, 40):
        segs = [(380, 860, 'deg', 60), (860, 380, 'deg', 60), (620, 620, 'cm', 20)]
        mc, xe, ye, the, tr = sim(segs, reading, v600)
        print("   v600=%2d -> 最小间隙 %6.2f cm 末端y=%6.2f 航向=%5.1f %s" % (
            v600, mc, ye, the, "OK" if mc >= 2.0 else "**危险**"))
print()

print("=== 角度-触发距离联合扫描（要求 v600 ∈ [20,40] 全部安全）===")
print("%6s %6s %8s %9s %8s" % ("角度", "读数", "最差间隙", "两弧横移", "弧间前进"))
rows = []
for Aa in (50, 55, 60, 65, 70, 75, 80):
    for reading in (15, 18, 21, 25, 28, 32):
        worst = 9e9
        for v600 in (18, 22, 26, 30, 34, 40, 46):
            segs = [(380, 860, 'deg', Aa), (860, 380, 'deg', Aa), (620, 620, 'cm', 20)]
            mc, xe, ye, the, tr = sim(segs, reading, v600)
            worst = min(worst, mc)
        lat = 2 * R * (1 - math.cos(math.radians(Aa)))
        rows.append((worst, Aa, reading, lat, 2 * R * math.sin(math.radians(Aa))))
rows.sort(reverse=True)
for w, Aa, reading, lat, fwd in rows[:14]:
    print("%5.0f度 %5dcm %8.2f %9.2f %8.2f" % (Aa, reading, w, lat, fwd))
print()
print("结论：只要角度按里程闭环、读数选在最优档，最小间隙与车速无关。")
