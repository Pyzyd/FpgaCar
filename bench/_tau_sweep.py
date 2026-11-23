
# -*- coding: utf-8 -*-
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S
exec(open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/round_corner_sim.py", encoding="utf-8").read().split('print("R(mm)')[0])
exec(open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/_nonideal_sweep.py", encoding="utf-8").read().split('cases = [')[0].split('exec(open')[1].split(chr(10), 1)[1])

print("一阶滞后 tau（s）对圆角弯的影响；k=0.5 (v=240mm/s)")
print("tau      R=250      R=200      R=150      R=100")
for tau in (0.0, 0.03, 0.06, 0.09, 0.12, 0.15, 0.20, 0.30, 0.40):
    row = []
    for R in (250, 200, 150, 100):
        ok, ml = runx(R, tau=tau)
        row.append("%s%6.1f" % ("Y" if ok else "N", ml))
    print("%.2f   %s" % (tau, "  ".join(row)))

print()
print("同样的 tau，但探头前移到 60mm：")
print("tau      R=250      R=200      R=150      R=100")
for tau in (0.0, 0.06, 0.12, 0.20, 0.30, 0.40):
    row = []
    for R in (250, 200, 150, 100):
        ok, ml = runx(R, tau=tau, fwd=60.0)
        row.append("%s%6.1f" % ("Y" if ok else "N", ml))
    print("%.2f   %s" % (tau, "  ".join(row)))
