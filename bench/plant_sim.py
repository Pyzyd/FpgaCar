# -*- coding: utf-8 -*-
"""弯道闭环仿真 v3：加真实电机模型（起转死区 + 一阶滞后）。

v2 的结论是运动学层面过弯没问题（shift0 全通）。但实车还不行，
差异只可能在执行器：直流减速电机有起转死区，低于某个占空比直接堵转；
而弯道恰好把内侧轮压到低占空比，一旦堵转，车就绕内侧轮原地打转。

赛道用解析距离（直道/圆弧/直道三段），比 v2 的逐点搜索快 3 个数量级。
"""
import math

# ---------------- 车体几何（mm） ----------------
WHEEL_BASE = 160.0
SENSOR_PITCH = 11.0
SENSOR_FWD = 30.0
LINE_HW = 6.5
K_MMS = 0.5
LEAD = 600.0

TICK_DT = 0.010
DUTY_MAX = 1200
LOST_HOLD_MS = 300
SEARCH_DUTY = 500
SEARCH_MS = 1500
WEIGHTS = [-7, -5, -3, -1, 1, 3, 5, 7]


def sensor_lats():
    return [(3.5 - i) * SENSOR_PITCH for i in range(8)]


def track_dist(x, y, R):
    """到赛道中心线的无符号距离。R=None 为纯直道。"""
    # 段1：y=0, x in [0, LEAD]
    dx1 = 0.0 if 0.0 <= x <= LEAD else (x if x < 0 else x - LEAD)
    d1 = math.hypot(dx1, y)
    if R is None:
        return d1
    # 段2：圆弧，圆心 (LEAD, R)
    cx, cy = LEAD, R
    vx, vy = x - cx, y - cy
    a = math.atan2(vy, vx)
    if -math.pi / 2 <= a <= 0.0:
        d2 = abs(math.hypot(vx, vy) - R)
    else:
        d2 = min(math.hypot(x - LEAD, y), math.hypot(x - (LEAD + R), y - R))
    # 段3：x=LEAD+R, y>=R
    if y >= R:
        d3 = abs(x - (LEAD + R))
    else:
        d3 = math.hypot(x - (LEAD + R), R - y)
    return min(d1, d2, d3)


class Sensor:
    def __init__(self, R):
        self.R = R
        self.prev_pos = 0

    def sample(self, x, y, th):
        c, s = math.cos(th), math.sin(th)
        cnt = 0
        wsum = 0
        for i in range(8):
            lat = (3.5 - i) * SENSOR_PITCH
            px = x + SENSOR_FWD * c - lat * s
            py = y + SENSOR_FWD * s + lat * c
            if track_dist(px, py, self.R) <= LINE_HW:
                cnt += 1
                wsum += WEIGHTS[i]
        if cnt == 0:
            pos = 0
        else:
            wabs = abs(wsum)
            prod = wabs * (1024 // cnt) + 512
            pmag = prod >> 10
            pos = -pmag if wsum < 0 else pmag
        return cnt, pos


class Plant:
    """直流减速电机：死区内堵转，死区外按 (duty-DZ) 成正比，一阶滞后。"""
    def __init__(self, dz=0.0, tau=0.0, k=K_MMS):
        self.dz = dz
        self.tau = tau
        self.k = k
        self.vl = 0.0
        self.vr = 0.0

    def target(self, duty, comp=0.0):
        # comp: 叠加补正（占空比补偿量，见 compensate()）
        d = duty + (comp if duty > 0 else 0.0)
        if d <= 0:
            return 0.0
        if d <= self.dz:
            return 0.0
        return self.k * (d - self.dz)

    def step(self, dl, dr, dt, comp=0.0):
        tl = self.target(dl, comp)
        tr = self.target(dr, comp)
        if self.tau <= 1e-9:
            self.vl, self.vr = tl, tr
        else:
            a = dt / self.tau
            a = 1.0 if a > 1.0 else a
            self.vl += (tl - self.vl) * a
            self.vr += (tr - self.vr) * a
        return self.vl, self.vr


def compensate(duty, dz):
    """死区补偿：把 0..1200 线性映射到 dz..1200。duty=0 仍为 0。"""
    if dz <= 0 or duty <= 0:
        return duty
    return dz + duty * (DUTY_MAX - dz) / DUTY_MAX


def run(R=300.0, dz=0.0, tau=0.0, comp=False, p=None, k=K_MMS,
        t_end=30.0, diff_shift=0, shape_en=False):
    if p is None:
        p = dict(BASE=480, P=72, D=40, ISHIFT=5, ILIM=640)
    sens = Sensor(R)
    plant = Plant(dz, tau, k)
    x = y = 0.0
    th = 0.0
    pos_d = 0
    i_acc = 0
    lost_d = False
    duty_l = duty_r = 0
    lost_ms = 0
    state = 'RUN'
    search_ms = 0
    t = 0.0
    max_lat = 0.0
    lost_events = 0
    stall_ticks = 0
    sample_cnt = 0

    while t < t_end:
        cnt, pos = sens.sample(x, y, th)
        lost = (cnt == 0)
        if lost:
            lost_events += 1

        if state == 'RUN':
            if lost:
                lost_ms += 10
                if lost_ms >= LOST_HOLD_MS:
                    state = 'SEARCH'
                    search_ms = 0
            else:
                lost_ms = 0
        elif state == 'SEARCH':
            search_ms += 10
            if cnt > 0:
                state = 'RUN'
                lost_ms = 0
            elif search_ms >= SEARCH_MS:
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
        elif state == 'SEARCH':
            dl, dr = SEARCH_DUTY, SEARCH_DUTY
        else:
            dl, dr = 0, 0

        if shape_en:
            mid = (dl + dr) // 2
            diff = (dl - dr) // 2
            dl, dr = mid + (diff >> diff_shift), mid - (diff >> diff_shift)
        dl = max(0, min(DUTY_MAX, dl))
        dr = max(0, min(DUTY_MAX, dr))
        duty_l, duty_r = dl, dr

        if comp:
            dl_c, dr_c = compensate(dl, dz), compensate(dr, dz)
        else:
            dl_c, dr_c = dl, dr

        # 低速轮堵转统计（只统计同向直行/循迹工况）
        if state == 'RUN':
            sample_cnt += 1
            for dd in (dl_c, dr_c):
                if 0 < dd <= dz:
                    stall_ticks += 1

        for _ in range(10):
            dt = TICK_DT / 10
            vl, vr = plant.step(dl_c, dr_c, dt)
            v = (vl + vr) / 2.0
            w = (vr - vl) / WHEEL_BASE
            x += v * math.cos(th) * dt
            y += v * math.sin(th) * dt
            th += w * dt

        lat = track_dist(x, y, R)
        max_lat = max(max_lat, lat)
        t += TICK_DT

        if lat > 150:
            return dict(ok=False, why='off-track', t=t, max_lat=max_lat,
                        lost_events=lost_events, stall=stall_ticks, x=x, y=y)
        if R is not None and y > 850.0:
            return dict(ok=True, why='finished', t=t, max_lat=max_lat,
                        lost_events=lost_events, stall=stall_ticks, x=x, y=y)
        if R is None and x > 1400.0:
            return dict(ok=True, why='finished', t=t, max_lat=max_lat,
                        lost_events=lost_events, stall=stall_ticks, x=x, y=y)
    return dict(ok=False, why='timeout', t=t, max_lat=max_lat,
                lost_events=lost_events, stall=stall_ticks, x=x, y=y)


if __name__ == '__main__':
    print("=== 电机起转死区对弯道的影响（无极补偿, tau=0）===")
    print("%-6s %-6s %5s %8s %8s %7s %s" % ("R", "DZ", "ok", "maxLat", "t(s)", "lost", "why"))
    for R in [400.0, 300.0, 250.0, 200.0, 175.0]:
        for dz in [0.0, 120.0, 180.0, 240.0, 300.0]:
            r = run(R=R, dz=dz, tau=0.0, comp=False)
            print("%-6.0f %-6.0f %5s %8.1f %8.1f %7d %s" % (
                R, dz, "Y" if r['ok'] else "N", r['max_lat'], r['t'],
                r['lost_events'], r['why']))
        print()

    print("=== 一阶滞后（DZ=0, tau 扫描）===")
    for R in [300.0, 200.0]:
        for tau in [0.0, 0.03, 0.06, 0.10, 0.15]:
            r = run(R=R, dz=0.0, tau=tau, comp=False)
            print("R=%-5.0f tau=%-5.2f %5s maxLat=%7.1f t=%5.1f lost=%d" % (
                R, tau, "Y" if r['ok'] else "N", r['max_lat'], r['t'], r['lost_events']))
        print()

    print("=== 死区+补偿（comp=True）===")
    for R in [400.0, 300.0, 250.0, 200.0, 175.0]:
        for dz in [120.0, 180.0, 240.0, 300.0]:
            a = run(R=R, dz=dz, tau=0.0, comp=False)
            b = run(R=R, dz=dz, tau=0.0, comp=True)
            print("R=%-5.0f DZ=%-4.0f  无补偿 %s lat=%6.1f  |  有补偿 %s lat=%6.1f" % (
                R, dz, "Y" if a['ok'] else "N", a['max_lat'],
                "Y" if b['ok'] else "N", b['max_lat']))
        print()
