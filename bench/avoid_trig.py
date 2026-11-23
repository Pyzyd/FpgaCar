
import math
B_WHEEL=16.0; CMPS=40.0/600.0
FRONT,REAR,HALF_W,CUBE_H=3.0,-17.0,9.25,5.0
def outline(x,y,th,n=24):
    pts=[]
    for sx in (-HALF_W,HALF_W):
        for k in range(n+1):
            fy=REAR+(FRONT-REAR)*k/n; pts.append((sx,fy))
    for fy in (FRONT,REAR):
        for k in range(n+1):
            sx=-HALF_W+2*HALF_W*k/n; pts.append((sx,fy))
    return [(x+sx*math.cos(th)-fy*math.sin(th), y+sx*math.sin(th)+fy*math.cos(th)) for sx,fy in pts]
def clear(x,y,th,d0):
    b=1e9
    for px,py in outline(x,y,th):
        b=min(b,math.hypot(max(abs(px)-CUBE_H,0.0),max(abs(py-d0)-CUBE_H,0.0)))
    return b
def step(st,o,i,t,d0,dt=0.0005):
    x,y,th,mc=st; vc=(o+i)/2*CMPS; w=(o-i)*CMPS/B_WHEEL
    for _ in range(max(1,int(round(t/dt)))):
        x+=vc*math.sin(th)*dt; y+=vc*math.cos(th)*dt; th+=w*dt
        mc=min(mc,clear(x,y,th,d0))
    return [x,y,th,mc]
def go(trig,o,i,deg,passms=900,rejoin_ms=120):
    d0=trig+8.0
    vc=(o+i)/2*CMPS; w=(o-i)*CMPS/B_WHEEL; R=vc/w
    ta=(R*math.radians(deg))/vc
    st=[0.0,0.0,0.0,1e9]
    st=step(st,o,i,ta,d0)                       # OUT 外弧
    st=step(st,i,o,ta,d0)                       # ALIGN 反弧摆正
    latA,fwdA=st[0],st[1]
    st=step(st,(o+i)//2,(o+i)//2,passms/1000.0,d0)   # PASS
    st=step(st,i,o,ta,d0)                       # TURN_IN 反弧
    st=step(st,int((o+i)/2),int((o+i)/2*0.8),rejoin_ms/1000.0,d0)
    return dict(clr=st[3],latA=latA,fwdA=fwdA,fwd=st[1],lat_end=st[0],head=math.degrees(st[2]))
print(f"{'trig':>5} {'duty':>9} {'deg':>4} {'clr':>7} {'latA':>6} {'fwdA':>6} {'fwd':>6} {'head':>6}")
for trig in (25,30,35,40):
    for (o,i) in [(860,380),(900,420)]:
        for deg in (55,60,65,70):
            m=go(trig,o,i,deg)
            flag='HIT' if m['clr']<0.5 else ('tight' if m['clr']<2 else 'OK')
            print(f"{trig:>5} {o:>4}/{i:<4} {deg:>4} {m['clr']:>7.2f} {m['latA']:>6.1f} {m['fwdA']:>6.1f} {m['fwd']:>6.1f} {m['head']:>6.1f} {flag}")
