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
def run(f,r,t1,t2,t3,K,dt=1.5e-3):
    cy=f+TRIG+CUBE_H; x=y=th=0.0; mc=1e9; mx=0.0
    for o,i,tms in ((860,380,t1),(400,840,t2),(620,620,t3)):
        vc=(o+i)/2.0*K; w=(o-i)*K/B_WHEEL
        for _ in range(max(1,int(round(tms/1000.0/dt)))):
            x+=vc*math.sin(th)*dt; y+=vc*math.cos(th)*dt; th+=w*dt
            mc=min(mc,clr(x,y,th,f,r,cy)); mx=max(mx,abs(x))
    return mc,mx

Ks=[0.30,0.33,0.36,0.40,0.45,0.50,0.55,0.60,0.667,0.72,0.767]
print("t1   t2   | 整段最小间隙 | K=0.767时横移 | K=0.30时横移")
best=None
for t1 in range(800,1251,25):
    t2=t1+100
    mcs=[]; mxs={}
    for K in Ks:
        mc,mx=run(75.0,-125.0,t1,t2,800,K)
        mcs.append((mc,K)); mxs[K]=mx
    mn=min(mcs)
    lat_fast=mxs[0.767]; lat_slow=mxs[0.30]
    mark=""
    if mn[0]>=15 and lat_fast<=560: mark="  <== 可用"
    print("%4d %4d | %5.1f mm @K=%.3f | %5.0f | %5.0f%s"%(t1,t2,mn[0],mn[1],lat_fast,lat_slow,mark))
