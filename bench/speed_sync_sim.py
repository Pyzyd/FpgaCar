# -*- coding: utf-8 -*-
"""同步环（speed_pid）对循迹的影响：真实编码器分辨率 + 50ms 窗口。
   spd = 每 50ms 窗口净步数；3840 cnt/rev, 232mm/rev -> 16.55 cnt/mm
"""
import math
from fast_corner import (seg_dist, track_dist, sample, LEAD, EXIT,
                         WHEEL_BASE, SENSOR_PITCH, LINE_HW, TICK_DT)

CNT_PER_MM = 3840.0 / 232.0
WIN = 0.050           # 50 ms 窗口
K_SYNC, SYNC_MAX, I_SHIFT, I_LIMIT = 12.0, 180.0, 4, 400.0

def clampi(v, lo, hi):
    return lo if v < lo else hi if v > hi else v

def run2(R, dp=0.0, P=120.0, D=220.0, ish=5, ilim=640, base=480.0,
         tau=0.0, k=0.5, fwd=None, t_end=28.0, lost_hold=0.30,
         sync="off", gate=120.0, mis=0.0):
    """sync: off / always / gate"""
    x, y, th = 0.0, dp, 0.0
    pos_d = 0.0
    i_acc = 0.0
    i_sync = 0.0
    sync_corr = 0.0
    vL = vR = 0.0
    max_lat = 0.0
    t = 0.0
    lost_ms = 0
    dl = dr = base
    win_t = 0.0
    while t < t_end:
        cnt, pos = sample(x, y, th, R, dp, fwd)
        lost = (cnt == 0)
        lost_ms = lost_ms + 10 if lost else 0
        if lost_ms >= int(lost_hold * 1000.0):
            dl = dr = 0.0
        else:
            err = pos
            errd = 0.0 if lost else (err - pos_d)
            corr = err * P + int(i_acc) / (2.0 ** ish) + errd * D
            corr = max(-base, min(base, corr))
            cmd_l = max(0.0, min(1200.0, base + corr))
            cmd_r = max(0.0, min(1200.0, base - corr))
            if not lost:
                pos_d = err
                i_acc = max(-ilim, min(ilim, i_acc + err))
            # ---- 同步环：只在窗口结束时更新 ----
            win_t += TICK_DT
            if win_t >= WIN - 1e-9 and sync != "off":
                win_t = 0.0
                s_l = round(vL * WIN * CNT_PER_MM)
                s_r = round(vR * WIN * CNT_PER_MM)
                dcmd = cmd_l - cmd_r
                if sync == "always":
                    ok = True
                else:
                    ok = abs(dcmd) <= gate
                if ok:
                    diff = s_l - s_r
                    sum_raw = diff * K_SYNC + i_sync / (2.0 ** I_SHIFT)
                    sum_lim = clampi(sum_raw, -SYNC_MAX, SYNC_MAX)
                    i_sync = clampi(i_sync + diff, -I_LIMIT, I_LIMIT)
                    sync_corr = sum_lim
                else:
                    i_sync = 0.0
                    sync_corr = 0.0
            dl = clampi(cmd_l - sync_corr, 0.0, 1200.0)
            dr = clampi(cmd_r + sync_corr, 0.0, 1200.0)
        if tau > 0:
            vL += (k * (1.0 - mis) * dl - vL) * (TICK_DT / tau)
            vR += (k * (1.0 + mis) * dr - vR) * (TICK_DT / tau)
        else:
            vL, vR = k * (1.0 - mis) * dl, k * (1.0 + mis) * dr
        v = (vL + vR) / 2.0
        w = (vR - vL) / WHEEL_BASE
        for _ in range(10):
            dt = TICK_DT / 10
            x += v * math.cos(th) * dt
            y += v * math.sin(th) * dt
            th += w * dt
        lat = track_dist(x, y, R, dp)
        max_lat = max(max_lat, lat)
        t += TICK_DT
        if lat > 150:
            return False, max_lat
        if y > dp + R + EXIT - 60:
            return max_lat < 45, max_lat
    return max_lat < 45, max_lat


def straight(mis=0.10, sync="off", gate=120.0, P=120.0, D=220.0, base=480.0,
             tau=0.0, k=0.5, t_end=6.0, fwd=None, y0=0.0):
    x, y, th = 0.0, y0, 0.0
    pos_d = 0.0
    i_acc = 0.0
    i_sync = 0.0
    sync_corr = 0.0
    vL = vR = 0.0
    t = 0.0
    win_t = 0.0
    ymax = 0.0
    while t < t_end:
        cnt, pos = sample(x, y, th, None, 0.0, fwd)
        lost = (cnt == 0)
        err = pos
        errd = 0.0 if lost else (err - pos_d)
        corr = err * P + int(i_acc) / (2.0 ** 5) + errd * D
        corr = max(-base, min(base, corr))
        cmd_l = max(0.0, min(1200.0, base + corr))
        cmd_r = max(0.0, min(1200.0, base - corr))
        if not lost:
            pos_d = err
            i_acc = max(-640.0, min(640.0, i_acc + err))
        win_t += TICK_DT
        if win_t >= WIN - 1e-9 and sync != "off":
            win_t = 0.0
            s_l = round(vL * WIN * CNT_PER_MM)
            s_r = round(vR * WIN * CNT_PER_MM)
            dcmd = abs(cmd_l - cmd_r)
            ok = True if sync == "always" else (dcmd <= gate)
            if ok:
                diff = s_l - s_r
                sum_raw = diff * K_SYNC + i_sync / (2.0 ** I_SHIFT)
                sync_corr = clampi(sum_raw, -SYNC_MAX, SYNC_MAX)
                i_sync = clampi(i_sync + diff, -I_LIMIT, I_LIMIT)
            else:
                i_sync = 0.0
                sync_corr = 0.0
        dl = clampi(cmd_l - sync_corr, 0.0, 1200.0)
        dr = clampi(cmd_r + sync_corr, 0.0, 1200.0)
        if tau > 0:
            vL += (k * (1.0 - mis) * dl - vL) * (TICK_DT / tau)
            vR += (k * (1.0 + mis) * dr - vR) * (TICK_DT / tau)
        else:
            vL, vR = k * (1.0 - mis) * dl, k * (1.0 + mis) * dr
        v = (vL + vR) / 2.0
        w = (vR - vL) / WHEEL_BASE
        for _ in range(10):
            dt = TICK_DT / 10
            x += v * math.cos(th) * dt
            y += v * math.sin(th) * dt
            th += w * dt
        ymax = max(ymax, abs(y))
        t += TICK_DT
    return y, th, ymax
