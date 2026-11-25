# -*- coding: utf-8 -*-
"""避障几何重算：把「左右轮效率不对称」和「驱动轴后移到 75mm」一起算进去。

坐标系：x 横向（右为正）、y 纵向（前为正），原点在驱动轴中心，车头朝 +y。
当前硬件（v1.15 起）：车长 200mm，驱动轴在车头后 75mm（前 +75、后 -125），
含轮总宽 185mm（半宽 92.5），轮距 160mm，方块 100mm 见方（半宽 50）。
超声波与车头齐平：读数 = 车头到方块近面的距离。

左右轮效率用 KL / KR（mm/s per duty）。编码器测的是真实轮子转角，
所以「转 60 度」这条闭环判据与效率无关，永远准；效率只影响等效半径 R，
而横移量 = R(1-cos(Δθ)) 由 R 决定 —— 这正是要算的东西。
"""
import math

B_WHEEL = 160.0
HALF_W = 92.5
CUBE_H = 50.0
NOSE = 75.0
REAR = NOSE - 200.0
CPM = 2532.0 / 212.0          # 11.943 计数/mm
TRIG = 280.0
NEED_LAT = HALF_W + CUBE_H    # 142.5mm
DT = 0.001


def outline(x, y, th, n=16):
    c, s = math.cos(th), math.sin(th)
    pts = []
    for sx in (-HALF_W, HALF_W):
        for k in range(n + 1):
            fy = REAR + (NOSE - REAR) * k / n
            pts.append((x + sx * c - fy * s, y + sx * s + fy * c))
    for fy in (NOSE, REAR):
        for k in range(n + 1):
            sx = -HALF_W + 2 * HALF_W * k / n
            pts.append((x + sx * c - fy * s, y + sx * s + fy * c))
    return pts


def clearance(x, y, th, cy):
    b = 1e9
    for px, py in outline(x, y, th):
        dx = max(abs(px) - CUBE_H, 0.0)
        dy = max(abs(py - cy) - CUBE_H, 0.0)
        v = math.hypot(dx, dy)
        if v < b:
            b = v
    return b


def sim(segs, KL, KR, trigger=TRIG, dt=DT, want_trace=False):
    """segs: [(dl, dr, mode, target, ceil_ms)]  mode: 'deg'(带符号航向增量) / 'sum'(两轮里程和 mm) / 'ms'
    返回 dict：最小间隙、逐段实际转角、横向偏移。"""
    cy = NOSE + trigger + CUBE_H     # 方块中心相对驱动轴
    x = y = th = 0.0
    mc = clearance(x, y, th, cy)
    rows = []
    for (dl, dr, mode, target, ceil_ms) in segs:
        vl, vr = KL * dl, KR * dr
        s_l = s_r = 0.0
        t = 0.0
        th0 = th
        x0, y0 = x, y
        done = False
        while t < ceil_ms / 1000.0:
            x += (vl + vr) / 2.0 * math.sin(th) * dt
            y += (vl + vr) / 2.0 * math.cos(th) * dt
            th += (vr - vl) / B_WHEEL * dt
            s_l += vl * dt
            s_r += vr * dt
            t += dt
            c = clearance(x, y, th, cy)
            if c < mc:
                mc = c
            if mode == 'deg':
                if abs(s_l - s_r) / B_WHEEL >= abs(math.radians(target)):
                    done = True
                    break
            elif mode == 'sum':
                if (s_l + s_r) >= target:
                    done = True
                    break
        rows.append(dict(mode=mode, target=target, want=target,
                         got=math.degrees(th - th0) if mode == 'deg' else (s_l + s_r),
                         ms=t * 1000.0, hit=done,
                         lat=x - x0, fwd=y - y0, R=arc_R(vl, vr)))
    return dict(mc=mc, rows=rows, x=x, y=y, th=math.degrees(th),
                lat=x, fwd=y)


def arc_R(vl, vr):
    if abs(vl - vr) < 1e-9:
        return float('inf')
    return B_WHEEL * (vl + vr) / (2.0 * (vr - vl))


# v1.20 实际下发的五段（顶层取值）
SEGS = [
    (860, 380, 'deg', -60, 3120),   # BY_OUT  右弧 60
    (400, 840, 'deg', +60, 3120),   # BY_ALIGN 左弧回正
    (480, 760, 'sum', 399.9, 2880), # BY_PASS 两轮里程和 4776 计数
    (420, 860, 'deg', +90, 6400),   # BY_TURN_IN 左弧 90
    (430, 640, 'ms', 0, 2500),      # BY_REJOIN 小差速
]

KL = 0.30
print("=== 一、各段在不对称下的实际几何（KL=%.2f）" % KL)
print("%-10s %8s %8s %9s %9s %9s %8s" % ("段", "KR/KL", "等效R(mm)", "要求转角", "实际转角", "用时ms", "横移mm"))
for ratio in (1.00, 0.75, 0.55, 0.50):
    KR = KL * ratio
    r = sim(SEGS, KL, KR)
    for i, seg in enumerate(SEGS):
        row = r['rows'][i]
        name = ['BY_OUT', 'BY_ALIGN', 'BY_PASS', 'BY_TURN_IN', 'BY_REJOIN'][i]
        rr = row['R']
        print("%-10s %8.2f %8s %9.1f %9.1f %9.0f %8.1f" % (
            name, ratio, ("%.0f" % rr) if abs(rr) < 9e4 else "近直",
            row['want'], row['got'], row['ms'], row['lat']))
    print("  -> 最小间隙 %.1f mm（需 >=0），全程横移 %.1f mm，终点航向 %.1f 度\n" % (r['mc'], r['lat'], r['th']))

print("=== 二、要拿到设计几何，各段占空比应该改成多少（KL=0.30, KR=0.165）")
KR = 0.165


def duty_for_R(vc, R, KL, KR):
    """给定平均车速 vc 与目标带符号半径 R（+左转），反解 (dl, dr)。"""
    w = vc / R
    vl = vc - w * B_WHEEL / 2.0
    vr = vc + w * B_WHEEL / 2.0
    dl = max(0.0, min(1200.0, vl / KL))
    dr = max(0.0, min(1200.0, vr / KR))
    return dl, dr


targets = [
    ("BY_OUT", 186.0, -206.7),
    ("BY_ALIGN", 186.0, +225.0),
    ("BY_PASS", 186.0, 1e9),
    ("BY_TURN_IN", 186.0, +232.7),
    ("BY_REJOIN", 160.5, +407.6),
]
print("%-11s %18s %18s %10s" % ("段", "对称占空比", "不对称应给", "差"))
for nm, vc, R in targets:
    if R > 1e8:
        dl = vc / KL
        dr = vc / KR
    else:
        dl, dr = duty_for_R(vc, R, KL, KR)
    print("%-11s %18s %18s" % (nm, "-", "%.0f / %.0f" % (dl, dr)))

print()
print("=== 三、把占空比按不对称重算后，再跑一遍完整五段")
SEGS2 = [
    (860, 691, 'deg', -60, 3120),
    (220, 840, 'deg', +60, 3120),
    (367, 667, 'sum', 399.9, 2880),
    (215, 843, 'deg', +90, 6400),
    (205, 546, 'ms', 0, 2500),
]
for label, segs, kl, kr in (("v1.20 现状(860/380 等)", SEGS, 0.30, 0.165),
                            ("按不对称重算占空比", SEGS2, 0.30, 0.165)):
    r = sim(segs, kl, kr)
    print("%-22s 最小间隙 %6.1f mm  终点横移 %6.1f mm  终点航向 %6.1f 度" % (label, r['mc'], r['lat'], r['th']))
    for i, row in enumerate(r['rows']):
        nm = ['BY_OUT', 'BY_ALIGN', 'BY_PASS', 'BY_TURN_IN', 'BY_REJOIN'][i]
        print("    %-10s 要 %7.1f 得 %7.1f  用时 %5.0f ms  %s" % (
            nm, row['want'], row['got'], row['ms'], "到时" if row['hit'] else "超时截断"))
