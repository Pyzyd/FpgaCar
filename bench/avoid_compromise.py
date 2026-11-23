# -*- coding: utf-8 -*-
import math
B_WHEEL=160.0; HALF_W=92.5; CUBE_H=50.0; TRIG=280.0
def outline(x,y,th,f,r,n=16):
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
def run(f,r,t1,t2,t3,K,dt=1e-3):
    cy=f+TRIG+CUBE_H; x=y=th=0.0; mc=1e9
    a1=a2=None
    for o,i,tms in ((860,380,t1),(400,840,t2),(620,620,t3)):
        vc=(o+i)/2.0*K; w=(o-i)*K/B_WHEEL
        for _ in range(max(1,int(round(tms/1000.0/dt)))):
            x+=vc*math.sin(th)*dt; y+=vc*math.cos(th)*dt; th+=w*dt
            mc=min(mc,clr(x,y,th,f,r,cy))
        if o==860: a1=math.degrees(th)
        elif o==400: a2=math.degrees(th)
    return mc,a1,a2,math.degrees(th)

Ks=(0.40,0.45,0.50,0.55,0.60,0.667,0.767)
print("候选：看『最慢时会不会擦』与『最快时转多大（细则禁止大转弯）』")
print("%-14s %6s %8s %8s %8s" % ("trio","最差间隙","OUT角@慢","OUT角@快","净转角@快"))
for label,t1,t2,t3 in (("600/650/570",600,650,570),("650/710/600",650,710,600),
                       ("700/760/650",700,760,650),("700/800/680",700,800,680),
                       ("740/800/680",740,800,680),("780/850/720",780,850,720)):
    worst=1e9; wK=None; a_slow=None; a_fast=None; net=None
    for K in Ks:
        mc,a1,a2,a3=run(75.0,-125.0,t1,t2,t3,K)
        if mc<worst: worst,wK=mc,K
        if K==0.40: a_slow=a1
        if K==0.767: a_fast,net=a1,a3
    print("%-14s %6.1f@%.2f %8.1f %8.1f %8.1f" % (label,worst,wK,a_slow,a_fast,net))
