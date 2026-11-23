# -*- coding: utf-8 -*-
"""超时取值 vs 真实车速常数 K 的敏感性：选一个 K 未知时也安全的 trio。"""
import math
B_WHEEL=160.0; HALF_W=92.5; CUBE_H=50.0; TRIG=280.0

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

def seg_angle(o,i,ms,K):   # 该段实际转过的角度（度）
    return abs((o-i)*K/B_WHEEL)*(ms/1000.0)*180/math.pi

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

# 各 K 下"正好 60 度"的理论毫秒
print("各 K 下 60 度所需毫秒：")
for K in (0.40,0.50,0.60,0.667,0.80):
    a=60*math.pi/180/((480*K)/B_WHEEL)*1000
    b=60*math.pi/180/((440*K)/B_WHEEL)*1000
    print("  K=%.3f (%4.0f mm/s @duty600)  OUT=%4.0f ms  ALIGN=%4.0f ms" % (K, K*600, a, b))
print()
print("候选 trio × 真实 K 的后果（新轴 front=75）：")
print("%-14s %5s | %6s %6s | %7s %6s | %6s" % ("trio(ms)","K","横移","转角","摆正横移","转角","间隙"))
for label,t1,t2,t3 in (("524/524/900",524,524,900),("524/571/484",524,571,484),
                       ("600/650/550",600,650,550),("698/762/645",698,762,645),
                       ("780/850/720",780,850,720),("2500/2500/900",2500,2500,900)):
    for K in (0.50,0.67):
        r=run(75.0,-125.0,t1,t2,t3,K)
        print("%-14s %5.2f | %6.0f %6.1f | %7.0f %6.1f | %6.1f" %
              (label if K==0.50 else "",K,r[0],r[1],r[2],r[3],r[4]))
    print()
