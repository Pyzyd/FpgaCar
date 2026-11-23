# -*- coding: utf-8 -*-
"""无编码器兜底超时取值扫描（修正单位）。"""
import math
B_WHEEL=160.0; HALF_W=92.5; CUBE_H=50.0; K=0.5; TRIG=280.0

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

def arc_ms(o,i,deg=60.0):
    return math.radians(deg)/abs((o-i)*K/B_WHEEL)*1000.0

def run(f,r,t1_ms,t2_ms,t3_ms,dt=5e-4):
    cy=f+TRIG+CUBE_H; x=y=th=0.0; mc=1e9
    lat1=d1=lat2=d2=None
    for o,i,tms in ((860,380,t1_ms),(400,840,t2_ms),(620,620,t3_ms)):
        vc=(o+i)/2.0*K; w=(o-i)*K/B_WHEEL
        for _ in range(max(1,int(round(tms/1000.0/dt)))):
            x+=vc*math.sin(th)*dt; y+=vc*math.cos(th)*dt; th+=w*dt
            mc=min(mc,clr(x,y,th,f,r,cy))
        if o==860: lat1,d1=x,math.degrees(th)
        elif o==400: lat2,d2=x,math.degrees(th)
    return lat1,d1,lat2,d2,mc,y,math.degrees(th),x

ta=arc_ms(860,380); tb=arc_ms(400,840); tp=200.0/(620*K)*1000.0
print("理论弧长: OUT %.0f ms / ALIGN %.0f ms / PASS(200mm) %.0f ms" % (ta,tb,tp))
print("理想(有编码器): 横移 103, 摆正后横移 216, 转角 0, 间隙 43.9, 终点y 574")
print()
print("%-24s %6s %6s %6s | %6s %6s | %7s %6s | %5s %7s" %
      ("配置","OUT","ALIGN","PASS","横移","转角","摆正横移","转角","间隙","终点y"))
for label,t1,t2,t3 in (
    ("现状 2500/2500/900",2500,2500,900),
    ("旧版 524/524/900",524,524,900),
    ("理论值",ta,tb,tp),
    ("理论 +10%",ta*1.1,tb*1.1,tp*1.1),
    ("整 770/840/710",770,840,710),
    ("整 800/880/720",800,880,720),
    ("整 900/950/750",900,950,750),
):
    r=run(75.0,-125.0,t1,t2,t3)
    print("%-24s %6.0f %6.0f %6.0f | %6.0f %6.0f | %7.0f %6.1f | %5.1f %7.0f" %
          (label,t1,t2,t3,r[0],r[1],r[2],r[3],r[4],r[5]))
