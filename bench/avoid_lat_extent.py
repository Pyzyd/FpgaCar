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
    cy=f+TRIG+CUBE_H; x=y=th=0.0; mc=1e9; maxx=0.0
    for o,i,tms in ((860,380,t1),(400,840,t2),(620,620,t3)):
        vc=(o+i)/2.0*K; w=(o-i)*K/B_WHEEL
        for _ in range(max(1,int(round(tms/1000.0/dt)))):
            x+=vc*math.sin(th)*dt; y+=vc*math.cos(th)*dt; th+=w*dt
            mc=min(mc,clr(x,y,th,f,r,cy)); maxx=max(maxx,abs(x))
    return mc,maxx,y

Ks=(0.30,0.35,0.40,0.45,0.50,0.60,0.667,0.80)
cands=(("780/850/720 已落地",780,850,720),("850/950/800",850,950,800),
       ("1000/1100/900",1000,1100,900),("1150/1250/1100",1150,1250,1100),
       ("524/571/484 旧",524,571,484))
for label,t1,t2,t3 in cands:
    print("== "+label)
    for K in Ks:
        mc,mx,ey=run(75.0,-125.0,t1,t2,t3,K)
        warn=""
        if mc<10: warn+=" **擦方块**"
        if mx>500: warn+=" **出避让区(>50cm)**"
        print("   K=%.3f 间隙%5.1f 最大横移%5.0f 终点y%5.0f%s" % (K,mc,mx,ey,warn))
    print()
