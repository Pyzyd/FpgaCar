
import math
B=160.0
def R_of(o,i): return B*(o+i)/(2*(o-i))
def deg(o,i,ms,K): 
    v=(o+i)/2*K; w=(i-o)*K/B
    return abs(math.degrees(w*ms/1000.0))
# 无编码器/速度环不介入
for name,(o,i,ms) in [("BY_OUT",(860,380,780)),("BY_ALIGN",(840,400,850)),("BY_PASS",(620,620,720)),("TURN_IN",(860,420,1600))]:
    print("%-9s o=%3d i=%3d R=%6.1f  60deg采用ms=%.0f" % (name,o,i,R_of(o,i) if o!=i else 1e9, 0))
print()
# 速度环把差速拉平 180 后
for clamp in (0,90,120,180,205):
    print("--- SYNC_MAX applied = %d ---" % clamp)
    for name,(o,i,ms) in [("BY_OUT",(860,380,780)),("BY_ALIGN",(840,400,850))]:
        o2, i2 = o-clamp, i+clamp
        o2=max(o2,0); i2=min(i2,1200)
        d0 = o-i
        d2 = o2-i2
        print("  %-8s %3d/%3d -> %3d/%3d  R %6.1f -> %7.1f  差速 %d -> %d (%.0f%%)" % (
            name,o,i,o2,i2,R_of(o,i),R_of(o2,i2),d0,d2,100.0*d2/d0))
    # 同样 ms 下的转角
    K=0.5
    for name,(o,i,ms) in [("BY_OUT",(860,380,780)),("BY_ALIGN",(840,400,850))]:
        o2, i2 = max(o-clamp,0), min(i+clamp,1200)
        a0 = deg(o,i,ms,K); a2 = deg(o2,i2,ms,K)
        print("      %-8s 转角 %.1f deg -> %.1f deg" % (name,a0,a2))
