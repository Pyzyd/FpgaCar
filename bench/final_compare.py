# -*- coding: utf-8 -*-
"""最终对照：整形器 shift1 (当前实车) vs shift0 (回退)，多半径 x 多车速。"""
import corner_loop_sim2 as S2

p = S2.pid_params(480, 72, 40, 5, 640)

print("=== 回退验证：shift1(当前) vs shift0(回退) ===")
print("%-6s %-8s %-6s %5s %8s %8s %7s" % ("R","k(mm/s per duty)","shape","ok","maxLat","t(s)","lost"))
rows = []
for R in [400.0, 300.0, 250.0, 200.0, 175.0, 160.0]:
    for k in [0.35, 0.5, 0.65, 0.8]:
        for tag, shift in [("shift1", 1), ("shift0", 0)]:
            r = S2.run(p, R=R, diff_shift=shift, shape_en=True, t_end=25.0, k_mms=k)
            rows.append((R, k, tag, r))
            print("%-6.0f %-8.2f %-6s %5s %8.1f %8.1f %7d" % (
                R, k, tag, "Y" if r['ok'] else "N", r['max_lat'], r['t'], r['lost_events']))
    print()

print("=== 汇总 ===")
for tag in ["shift1", "shift0"]:
    sub = [x for x in rows if x[2] == tag]
    fails = sum(1 for x in sub if not x[3]['ok'])
    avg = sum(x[3]['max_lat'] for x in sub) / len(sub)
    worst = max(x[3]['max_lat'] for x in sub)
    print("%-8s fails=%d/%d  avgLat=%.1fmm  worstLat=%.1fmm" % (tag, fails, len(sub), avg, worst))
