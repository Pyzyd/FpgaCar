# -*- coding: utf-8 -*-
import math
exec(open("bench/avoid_timeout_pick.py").read().split("ta=arc_ms")[0])
ta=arc_ms(860,380); tb=arc_ms(400,840); tp=200.0/(620*K)*1000.0
print("OUT=%.0f ALIGN=%.0f 固定，扫描 PASS 时长" % (ta,tb))
print("%8s | %7s %7s | %5s %7s" % ("PASSms","摆正横移","终点y","间隙","终点角"))
for t3 in (600,645,700,750,800,900):
    r=run(75.0,-125.0,ta,tb,t3)
    print("%8.0f | %7.0f %7.0f | %5.1f %7.1f" % (t3,r[2],r[5],r[4],r[6]))
print()
print("BY_OUT/BY_ALIGN 扫描（PASS 固定 700ms）:")
print("%6s %6s | %6s %6s | %7s %6s | %5s %7s" % ("OUT","ALIGN","横移","转角","摆正横移","转角","间隙","终点y"))
for t1,t2 in ((698,762),(730,800),(770,840),(800,880),(850,930)):
    r=run(75.0,-125.0,t1,t2,700)
    print("%6.0f %6.0f | %6.0f %6.1f | %7.0f %6.1f | %5.1f %7.0f" %
          (t1,t2,r[0],r[1],r[2],r[3],r[4],r[5]))
