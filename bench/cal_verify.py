# -*- coding: utf-8 -*-
"""编码器标定换算：把 (每圈计数, 轮周长, 轮距) 换成 car_fsm 里的里程判据真值。

用法：python bench/cal_verify.py [每圈计数] [轮周长mm] [轮距mm]

2026-11-23 实测值：每圈 2532 计数、周长 212 mm、轮距 160 mm。
输出与 Verilog 整数运算逐位一致（全部用 // 整除，不走浮点），
可以直接和 sim 里 $display 出的 ARC_DIFF_TARGET / PASS_SUM_TARGET 对照。
"""

cpr=2532; circ=212; base=160; deg=60; pmm=200
arc=cpr*base//circ
mrad=(deg*31416+900)//1800
tgt=(mrad*arc)//1000
import math
print("Verilog 整数运算（真值）：")
print("ARC_CNT_PER_RAD   = (%d*%d)/%d = %d  (%.2f)"%(cpr,base,circ,arc,cpr*base/circ))
print("ARC_MRAD          = (60*31416+900)/1800 = %d"%mrad)
print("ARC_DIFF_TARGET   = (%d*%d)/1000 = %d"%(mrad,arc,tgt))
print("  -> 实际转角 %.2f°"%(tgt/(cpr*base/circ)*180/math.pi))
print("PASS_SUM_TARGET   = (%d*%d)/%d = %d"%(pmm,cpr,circ,(pmm*cpr)//circ))
cpm=cpr/circ
print("  -> 实际直线 %.1f mm"%(((pmm*cpr)//circ)/cpm))
print()
print("每毫米计数 %.3f（原 16.552）"%cpm)

print()
print("换算表（每毫米 %.3f 计数）：" % cpm)
# 距离表用与固件相同的整数除法（mm*cpr//circ），这样抄进 AVOID_PASS_MM 就是真值
for mm in (100, 150, 200, 250, 300):
    print("  %d mm -> %d 计数" % (mm, (mm * cpr) // circ))
for deg in (30, 60, 90, 180):
    m = (deg * 31416 + 900) // 1800
    print("  %d deg -> %d 计数差" % (deg, (m * arc) // 1000))
