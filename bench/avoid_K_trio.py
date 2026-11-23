# -*- coding: utf-8 -*-
import math
B_WHEEL=160.0; HALF_W=92.5; CUBE_H=50.0; TRIG=280.0
def outline(x,y,th,f,r,n=20):
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
    for o,i,tms in ((860,380,t1),(400,840,t2),(620,620,t3)):
        vc=(o+i)/2.0*K; w=(o-i)*K/B_WHEEL
        for _ in range(max(1,int(round(tms/1000.0/dt)))):
            x+=vc*math.sin(th)*dt; y+=vc*math.cos(th)*dt; th+=w*dt
            mc=min(mc,clr(x,y,th,f,r,cy))
    return mc,y,math.degrees(th)

def need_ms(K,duty):
    return 60*math.pi/180/((duty*K)/B_WHEEL)*1000

Ks=(0.30,0.35,0.40,0.45,0.50,0.55,0.60,0.667,0.75,0.80)
print("按 K=0.30（最慢）定超时，再看高速端会不会转过头")
for Kref in (0.30,0.35,0.40,0.45):
    t1=round(need_ms(Kref,480)/50)*50; t2=round(need_ms(Kref,440)/50)*50
    # BY_PASS: 200mm at 620*Kref
    t3=round(200/(620*Kref)*1000/50)*50
    print()
    print("trio(%d/%d/%d) 按 K=%.2f 标定：" % (t1,t2,t3,Kref))
    for K in Ks:
        mc,ey,deg=run(75.0,-125.0,t1,t2,t3,K)
        flag="OK " if mc>=10 else "**擦**"
        print("   K=%.3f 间隙 %5.1f mm 终点y %5.0f 累计转角 %6.1f  %s" % (K,mc,ey,deg,flag))
