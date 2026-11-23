# -*- coding: utf-8 -*-
"""差速整形配置对比：DIFF_SHIFT 减半 vs SHAPE_MIN_DUTY 下限。

硬件里 duty_shaper.v 的两步：
  diff_s = follow ? (diff >>> DIFF_SHIFT) : diff
  tgt = mid +- diff_s
  再对非零的 cl/cr 抬到 MIN_DUTY（地板）
目的：找"既不让内侧轮刹车、又不砍掉转弯能力"的配置。
"""
import corner_loop_sim2 as S2

MG = {'min_duty': 0, 'diff_shift': 1, 'shape_en': True}

def shaper2(dl, dr, follow, diff_shift):
    if not follow:
        return dl, dr
    mid = (dl + dr) // 2
    diff = (dl - dr) // 2
    ds = diff >> diff_shift
    tl = mid + ds
    tr = mid - ds
    md = MG['min_duty']
    if md:
        if tl > 0 and tl < md:
            tl = md
        if tr > 0 and tr < md:
            tr = md
    return tl, tr

S2.shaper = shaper2

def cfg(shift, md, shape_en=True):
    MG['diff_shift'] = shift
    MG['min_duty'] = md
    MG['shape_en'] = shape_en

def R_of(o, i):
    if o == i:
        return float('inf')
    return S2.WHEEL_BASE * (o + i) / (2.0 * (o - i))

def run_cfg(p, R, k=0.5, t_end=25.0):
    return S2.run(p, R=R, diff_shift=MG['diff_shift'], shape_en=MG['shape_en'],
                  t_end=t_end, k_mms=k)

if __name__ == '__main__':
    p = S2.pid_params(480, 72, 40, 5, 640)
    print("=== 饱和输出 960/0 在各配置下的实际输出与最小转弯半径 ===")
    print("%-22s %-14s %8s" % ("config", "out(960/0)", "R_min(mm)"))
    for name, shift, md in [
        ("off (no shaper)", 0, 0),
        ("shift1 md0 (current)", 1, 0),
        ("shift0 md120", 0, 120),
        ("shift0 md240", 0, 240),
        ("shift0 md300", 0, 300),
        ("shift0 md360", 0, 360),
        ("shift1 md240", 1, 240),
    ]:
        cfg(shift, md, shape_en=(name != "off (no shaper)"))
        tl, tr = shaper2(960, 0, True, shift) if name != "off (no shaper)" else (960, 0)
        md_txt = "%d/%d" % (tl, tr)
        r = R_of(None if tl == 0 else tl, None if tr == 0 else tr) if not (tl == 0 or tr == 0) else float('inf')
        if tr == 0:
            r = S2.WHEEL_BASE / 2.0
        print("%-22s %-14s %8.1f" % (name, md_txt, r))
    print()
    print("=== 弯道表现：R x 配置（K=0.5，maxLat 越小越好，传感器半幅 38.5mm）===")
    cfgs = [
        ("off", 0, 0, False),
        ("shift1 md0 (current)", 1, 0, True),
        ("shift0 md120", 0, 120, True),
        ("shift0 md240", 0, 240, True),
        ("shift0 md300", 0, 300, True),
        ("shift0 md360", 0, 360, True),
    ]
    print("%-22s %-6s %5s %8s %8s %7s" % ("config", "R", "ok", "maxLat", "t(s)", "lost"))
    for R in [400.0, 300.0, 250.0, 200.0, 175.0, 160.0]:
        for name, shift, md, en in cfgs:
            cfg(shift, md, shape_en=en)
            r = run_cfg(p, R)
            print("%-22s %-6.0f %5s %8.1f %8.1f %7d" % (
                name, R, "Y" if r['ok'] else "N", r['max_lat'], r['t'], r['lost_events']))
        print()
