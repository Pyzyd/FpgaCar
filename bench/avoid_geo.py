# -*- coding: utf-8 -*-
"""避障几何核算（按 m03213 实测几何）。
坐标系：x 横向、y 纵向，原点在驱动轴中心，车头朝 +y。
  车长 20 cm（驱动轴在车头后 3 cm、车尾在后 17 cm）
  车身宽 13 cm，含轮总宽 18.5 cm，轮宽 2.5 cm -> 轮距 16.0 cm
  轮半径 3.7 cm -> 周长 23.25 cm
  超声波与车头齐平 -> 读数 = 车头到方块近面的空隙
  方块 10x10x10 -> 半宽 5 cm
"""
import math

B_WHEEL = 16.0
FRONT, REAR = 3.0, -17.0
HALF_W = 9.25
CUBE_H = 5.0
WHEEL_R = 3.7
CIRC = 2 * math.pi * WHEEL_R

NEED_LAT = CUBE_H + HALF_W   # 轴心需横移 14.25 cm 才刚好擦过


def outline(x, y, th, n=20):
    pts = []
    for sx in (-HALF_W, HALF_W):
        for k in range(n + 1):
            pts.append((sx, REAR + (FRONT - REAR) * k / n))
    for fy in (FRONT, REAR):
        for k in range(n + 1):
            pts.append((-HALF_W + 2 * HALF_W * k / n, fy))
    out = []
    for sx, fy in pts:
        out.append((x + sx * math.cos(th) - fy * math.sin(th),
                    y + sx * math.sin(th) + fy * math.cos(th)))
    return out


def clearance(x, y, th, d0):
    b = 1e9
    for px, py in outline(x, y, th):
        dx = max(abs(px) - CUBE_H, 0.0)
        dy = max(abs(py - d0) - CUBE_H, 0.0)
        b = min(b, math.hypot(dx, dy))
    return b


def step(st, o, i, t, d0, k, dt=0.0005):
    x, y, th, mc = st
    vc = (o + i) / 2.0 * k
    w = (o - i) * k / B_WHEEL
    n = max(1, int(round(t / dt)))
    for _ in range(n):
        x += vc * math.sin(th) * dt
        y += vc * math.cos(th) * dt
        th += w * dt
        mc = min(mc, clearance(x, y, th, d0))
    return [x, y, th, mc]


def arc_R(o, i):
    if o == i:
        return float("inf")
    return B_WHEEL * (o + i) / (2.0 * (o - i))


def arc_ms(o, i, deg, k):
    """走 deg 度所需毫秒（k = cm/s per duty unit）"""
    w = (o - i) * k / B_WHEEL
    if abs(w) < 1e-9:
        return 0.0
    return math.radians(deg) / abs(w) * 1000.0


def maneuver(d0, o, i, deg, pass_ms, k, dt=0.0005):
    ta = arc_ms(o, i, deg, k) / 1000.0
    st = [0.0, 0.0, 0.0, 1e9]
    st = step(st, o, i, ta, d0, k, dt)
    lat_out = st[0]
    st = step(st, i, o, ta, d0, k, dt)          # 反向弧摆正
    lat_align, y_align = st[0], st[1]
    st = step(st, (o + i) // 2, (o + i) // 2, pass_ms / 1000.0, d0, k, dt)
    y_pass = st[1]
    return dict(clr=st[3], lat_out=lat_out, lat_align=lat_align,
                y_align=y_align, y_pass=y_pass, end_x=st[0], end_y=st[1],
                ta_ms=ta * 1000.0)


print("轮距 %.1f cm | 轮周长 %.3f cm | 通过障碍需轴心横移 %.2f cm" % (B_WHEEL, CIRC, NEED_LAT))
print("原地转 90 度时：车尾角扫出半径 %.1f cm，车头角 %.1f cm" % (
    math.hypot(HALF_W, abs(REAR)), math.hypot(HALF_W, FRONT)))
print()

O, I, DEG = 860, 380, 60.0
print("=== A. 现有参数 (860/380, 60度, 524ms) 在不同车速标定下的实际转角与横移 ===")
print("%8s %8s %7s %9s %9s %9s" % ("v600(cm/s)", "k(cm/s/d)", "R(cm)", "524ms转角", "两弧横移", "是否够过"))
for v600 in (18, 22, 26, 30, 34, 40, 46):
    k = v600 / 600.0
    w = (O - I) * k / B_WHEEL
    deg_524 = math.degrees(w * 0.524)
    R = arc_R(O, I)
    lat = 2 * R * (1 - math.cos(w * 0.524))
    print("%8d %8.4f %8.2f %8.1f度 %9.2f %9s" % (
        v600, k, R, deg_524, lat, "OK" if lat >= NEED_LAT + 1.0 else "**不够**"))

print()
print("=== B. 达到目标转角 60 度所需的弧时长随车速变化 ===")
print("%8s %10s" % ("v600", "OUT_MS"))
for v600 in (18, 22, 26, 30, 34, 40, 46):
    k = v600 / 600.0
    print("%8d %10.0f" % (v600, arc_ms(O, I, DEG, k)))

print()
print("=== C. 触发距离与车速联合扫描（判据：最小间隙 >= 2.0 cm，回到原线附近）===")
rows = []
for v600 in (22, 26, 30, 34, 40):
    k = v600 / 600.0
    for trig in (18, 21, 25, 30, 35):
        d0 = trig + FRONT + CUBE_H      # 超声读数 = 车头到近面
        for (o, i) in [(860, 380), (800, 340), (900, 420), (940, 460)]:
            R = arc_R(o, i)
            # 选角度：让两弧横移 = NEED_LAT + 4 cm 余量
            lat_target = NEED_LAT + 4.0
            cos_t = 1 - lat_target / (2 * R)
            if cos_t <= -1 or cos_t >= 1:
                continue
            deg = math.degrees(math.acos(cos_t))
            if deg > 90:
                continue
            for pass_ms in (700, 900, 1100):
                m = maneuver(d0, o, i, deg, pass_ms, k)
                rows.append((v600, trig, o, i, deg, pass_ms, m))

best = {}
for v600, trig, o, i, deg, pass_ms, m in rows:
    if m["clr"] >= 2.0 and abs(m["end_x"]) < 6.0:
        key = (v600, trig)
        if key not in best or m["clr"] > best[key][0]["clr"]:
            best[key] = (m, o, i, deg, pass_ms)

print("%8s %6s %11s %7s %6s %8s %8s" % ("v600", "trig", "duty", "deg", "pass", "最小间隙", "末端x"))
for key in sorted(best):
    m, o, i, deg, pass_ms = best[key]
    print("%8d %6d %5d/%-5d %6.1f %6d %8.2f %8.2f" % (
        key[0], key[1], o, i, deg, pass_ms, m["clr"], m["end_x"]))

print()
print("=== D. 现有固定 524ms 是否在所有车速下都安全（trig=25）===")
for v600 in (18, 22, 26, 30, 34, 40, 46):
    k = v600 / 600.0
    d0 = 25 + FRONT + CUBE_H
    m = maneuver(d0, O, I, DEG, 900, k)
    print("  v600=%2d -> 最小间隙 %6.2f cm %s" % (v600, m["clr"], "OK" if m["clr"] >= 1.5 else "**碰撞**"))
