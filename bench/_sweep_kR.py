
# -*- coding: utf-8 -*-
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S
src = open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/round_corner_sim.py", encoding="utf-8").read()
exec(compile(src.split("print(\"R(mm)")[0], "rcs", "exec"), globals())

def run2(R, k, mode='freeze', t_end=20.0):
    return run(R, 0.0, mode, t_end, k)

print("maxLat (mm)  /  是否出线(脱轨或 >45mm)")
print("k\\R     ", "".join("%8d" % R for R in (200, 150, 120, 100, 90, 80, 70, 60)))
for k in (0.35, 0.5, 0.7, 1.0, 1.4, 2.0, 2.8):
    row = []
    for R in (200, 150, 120, 100, 90, 80, 70, 60):
        r = run2(R, k)
        row.append("%s%6.1f" % ("Y" if r['ok'] else "N", r['max_lat']))
    print("k=%.2f " % k, "".join(row))

print()
print("对应基础速度 v=BASE*k = 480*k mm/s:")
for k in (0.35, 0.5, 0.7, 1.0, 1.4, 2.0, 2.8):
    print("  k=%.2f  v=%.0f mm/s  (%.2f m/s)" % (k, 480 * k, 480 * k / 1000.0))
