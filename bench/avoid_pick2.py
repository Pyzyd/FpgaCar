# -*- coding: utf-8 -*-
import math
exec(open("bench/avoid_timeout_pick.py", encoding="utf-8").read().split("ta=arc_ms")[0])
ta=arc_ms(860,380); tb=arc_ms(400,840); tp=200.0/(620*K)*1000.0
print("nominal OUT=%.0f ALIGN=%.0f PASS=%.0f" % (ta,tb,tp))
print("%-16s %6s %6s %6s | %5s %5s | %6s %6s | %5s %7s" % ("配置","OUT","ALIGN","PASS","横移","转角","摆正横移","转角","间隙","终点y"))
for label,t1,t2,t3 in (("780/850/720",780,850,720),("800/880/730",800,880,730),("760/830/710",760,830,710)):
    r=run(75.0,-125.0,t1,t2,t3)
    print("%-16s %6.0f %6.0f %6.0f | %5.0f %5.1f | %6.0f %6.1f | %5.1f %7.0f" %
          (label,t1,t2,t3,r[0],r[1],r[2],r[3],r[4],r[5]))
