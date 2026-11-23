
# -*- coding: utf-8 -*-
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S
exec(open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/round_corner_sim.py", encoding="utf-8").read().split('print("R(mm)')[0])

print("圆角半径 R(mm)  maxLat  结果  freeze/pivot")
for R in (100, 90, 80, 75, 70, 65, 60, 55, 50, 45, 40, 30):
    a = run(R, 0.0, 'freeze')
    b = run(R, 0.0, 'pivot')
    print("%6d        %7.1f  %s     %s %5.1f  (lat>45 = 出线)" % (R, a['max_lat'], "Y" if a['ok'] else "N", "Y" if b['ok'] else "N", b['max_lat']))
