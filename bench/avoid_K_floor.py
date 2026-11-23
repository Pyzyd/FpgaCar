# -*- coding: utf-8 -*-
import math
B_WHEEL=160.0; HALF_W=92.5; CUBE_H=50.0; TRIG=280.0
NEED_LAT = 2*CUBE_H + 2*HALF_W - 2*HALF_W  # unused
def outline(x,y,th,f,r,n=24):
    p=[]
    for sx in (-HALF_W,HALF_W):
        for k in range(n+1): p.append((sx, r+(f-r)*k/n))
    for fy in (f,r):
        for k in range(n+1): p.append((-HALF_W+2*HALF_W*k/n, fy))
    return [(x+sx*math.cos(th)-fy*math.sin(th), y+sx*math.sin(th)+fy*math.cos(th)) for sx,fy in p]
def clr(x,y,th,f,r,cy):
    b=1e9
    for px,py in outline(x,y,th,f,r):
        b=min(b, math.hypot(max(abs(px)-CUBE_H,0.0), max(abs(py-cy)-CUBE_H,0.0)))
    return b
def run(f,r,t1,t2,t3,K,dt=5e-4):
    cy=f+TRIG+CUBE_H; x=y=th=0.0; mc=1e9
    lat1=d1=lat2=d2=None
    for o,i,tms in ((860,380,t1),(400,840,t2),(620,620,t3)):
        vc=(o+i)/2.0*K; w=(o-i)*K/B_WHEEL
        for _ in range(max(1,int(round(tms/1000.0/dt)))):
            x+=vc*math.sin(th)*dt; y+=vc*math.cos(th)*dt; th+=w*dt
            mc=min(mc,clr(x,y,th,f,r,cy))
        if o==860: lat1,d1=x,math.degrees(th)
        elif o==400: lat2,d2=x,math.degrees(th)
    return lat1,d1,lat2,d2,mc,y,math.degrees(th)

print("无编码器：超时即实际时长。各 K 下 trio 780/850/720 的真实表现")
print("%6s %8s %6s %6s %8s %6s %6s %8s" % ("K","v600mm/s","横移","转角","摆正横移","转角","间隙","终点y"))
for K in (0.30,0.35,0.40,0.45,0.50,0.55,0.60,0.667,0.70,0.80):
    r=run(75.0,-125.0,780,850,720,K)
    print("%6.3f %8.0f %6.0f %6.1f %8.0f %6.1f %6.1f %8.0f" % (K,K*600,r[0],r[1],r[2],r[3],r[4],r[5]))
print()
print("对比：60 度理论毫秒 vs 780 是否够")
for K in (0.30,0.35,0.40,0.45,0.50,0.667):
    need=60*math.pi/180/((480*K)/B_WHEEL)*1000
    print("  K=%.3f 需要 %4.0f ms  -> 780ms 可达 %.1f 度" % (K,need,min(780,need)/need*60))
