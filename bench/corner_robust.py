# -*- coding: utf-8 -*-
"""入弯位姿鲁棒性：横向偏移 × 车头偏角 × 四种拐角方向策略。"""
import corner_fix_sim2 as F

DY = [-30, -20, -10, 0, 10, 20, 30]
TH = [-3.0, 0.0, 3.0]
POL = [
    ("left 现状",     dict(corner_dir='left')),
    ("last",          dict(corner_dir='last')),
    ("last_or_left",  dict(corner_dir='last_or_left')),
    ("calc+last_or_l", dict(corner_dir='last_or_left', wide_pos='calc')),
]

print("%-16s %10s %9s %9s  %s" % ("策略", "失败", "最差Lat", "平均Lat", "失败样本"))
for name, kw in POL:
    rows = []
    for deg in [90.0, 75.0, 60.0]:
        for turn in ['L', 'R']:
            for dy in DY:
                for th in TH:
                    r = F.run(deg, turn, t_end=16.0, y0=float(dy),
                              th0=th * 3.141592653589793 / 180.0, **kw)
                    rows.append((deg, turn, dy, th, r))
    bad = [x for x in rows if not x[4]['ok']]
    ok = [x for x in rows if x[4]['ok']]
    avg = sum(x[4]['max_lat'] for x in ok) / max(1, len(ok))
    worst = max((x[4]['max_lat'] for x in rows), default=0)
    print("%-16s %4d/%-4d %9.1f %9.1f  %s" % (
        name, len(bad), len(rows), worst, avg,
        ",".join("%.0f%s dy%+d th%+.0f" % (b[0], b[1], b[2], b[3]) for b in bad[:5]) or "-"))
