
import math
B_WHEEL=16.0; CMPS=40.0/600.0
FRONT,REAR,HALF_W,CUBE_H=3.0,-17.0,9.25,5.0

def outline(x,y,th,n=28):
    pts=[]
    # 车身矩形四边等距采样（相对驱动轴坐标：x=横向,y=纵向）
    for sx in (-HALF_W,HALF_W):
        for k in range(n+1):
            fy=REAR+(FRONT-REAR)*k/n
            pts.append((sx,fy))
    for fy in (FRONT,REAR):
        for k in range(n+1):
            sx=-HALF_W+2*HALF_W*k/n
            pts.append((sx,fy))
    out=[]
    for sx,fy in pts:
        out.append((x+sx*math.cos(th)-fy*math.sin(th), y+sx*math.sin(th)+fy*math.cos(th)))
    return out

def clear(x,y,th,d0):
    b=1e9
    for px,py in outline(x,y,th):
        dx=max(abs(px)-CUBE_H,0.0); dy=max(abs(py-d0)-CUBE_H,0.0)
        b=min(b,math.hypot(dx,dy))
    return b

def step(st,o,i,t,d0,dt=0.0005):
    x,y,th,mc=st; vc=(o+i)/2*CMPS; w=(o-i)*CMPS/B_WHEEL
    n=max(1,int(round(t/dt)))
    for _ in range(n):
        x+=vc*math.sin(th)*dt; y+=vc*math.cos(th)*dt; th+=w*dt
        mc=min(mc,clear(x,y,th,d0))
    return [x,y,th,mc]

def arc_R(o,i):
    return ((o+i)/2*CMPS)/((o-i)*CMPS/B_WHEEL)

def arc_t(o,i,deg):
    return (arc_R(o,i)*math.radians(deg))/((o+i)/2*CMPS)

def maneuver(d0,o,i,deg,pass_ms,dt=0.0005):
    ta=arc_t(o,i,deg)
    st=[0.0,0.0,0.0,1e9]
    st=step(st,o,i,ta,d0,dt)             # OUT 外弧
    lat_out=st[0]
    st=step(st,i,o,ta,d0,dt)             # ALIGN 反向弧摆正
    lat_align=st[0]; fwd_align=st[1]; head2=math.degrees(st[2])
    st=step(st,(o+i)//2,(o+i)//2,pass_ms/1000.0,d0,dt)   # PASS 直线超越
    fwd_pass=st[1]
    st=step(st,i,o,ta,d0,dt)             # TURN_IN 反向弧切回
    st=step(st,int((o+i)/2*0.85),int((o+i)/2*0.7),0.12,d0,dt)
    return dict(clr=st[3],lat_align=lat_align,fwd_align=fwd_align,head2=head2,
                fwd_total=st[1],end_lat=st[0],end_head=math.degrees(st[2]),ta=ta*1000)

print(f"{'trig':>5} {'duty':>9} {'deg':>4} {'pass':>5} {'clr':>6} {'latA':>6} {'fwdA':>6} {'fwdTot':>7} {'endLat':>7} {'endH':>6}")
best=None
for trig in (35,40,45):
    d0=trig+8.0
    for (o,i) in [(820,360),(860,380),(900,420),(940,460),(800,350)]:
        for deg in (45,55,65):
            for pass_ms in (600,900,1200,1500,1800):
                m=maneuver(d0,o,i,deg,pass_ms)
                ok = m['clr']>=2.0
                if ok and (best is None or m['fwd_total']<best['fwd_total']):
                    best=dict(m,o=o,i=i,deg=deg,pass_ms=pass_ms,trig=trig)
                if ok:
                    print(f"{trig:>5} {o:>4}/{i:<4} {deg:>4} {pass_ms:>5} {m['clr']:>6.2f} {m['lat_align']:>6.1f} {m['fwd_align']:>6.1f} {m['fwd_total']:>7.1f} {m['end_lat']:>7.1f} {m['end_head']:>6.1f}")
print("\nBEST:", best)
