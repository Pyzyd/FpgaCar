
# -*- coding: utf-8 -*-
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S
exec(open(r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench/chamfer_corner_sim.py", encoding="utf-8").read().split("print(\"45")[0])

pts = make_chamfer(100.0)
print("pts head:", pts[:3], "corner:", [(round(p[0],1),round(p[1],1)) for p in pts if 395<p[0]<520][:6])
sens = S.Sensor(pts)
x, y, th = 0.0, 0.0, 0.0
pos_d = 0; i_acc = 0; t = 0.0
P=72.0; D=40.0; base=480.0
n = 0
while t < 8.0:
    r = sens.sample(x, y, th)
    cnt, pos, lost, wide = r['cnt'], r['pos'], r['lost'], r['wide']
    err = pos; errd = err - pos_d
    s = max(-base, min(base, err*P + (i_acc>>5) + errd*D))
    dl, dr = base+s, base-s
    if not lost:
        pos_d = err; i_acc = max(-640, min(640, i_acc+err))
    dl=max(0.0,min(1200.0,dl)); dr=max(0.0,min(1200.0,dr))
    lat = S.track_dist(x, y, pts)
    if 2.2 < t < 6.0 and n % 6 == 0:
        print("t=%.2f x=%6.1f y=%6.1f th=%6.1f cnt=%d pos=%2d lost=%d wide=%d lat=%5.1f DL=%4.0f DR=%4.0f" % (t,x,y,math.degrees(th),cnt,pos,lost,wide,lat,dl,dr))
    vl, vr = S.K_MMS*dl, S.K_MMS*dr
    v=(vl+vr)/2.0; w=(vr-vl)/S.WHEEL_BASE
    for _ in range(10):
        dt=S.TICK_DT/10
        x+=v*math.cos(th)*dt; y+=v*math.sin(th)*dt; th+=w*dt
    t+=S.TICK_DT; n+=1
    if lat>150:
        print("OFF at t=%.2f x=%.1f y=%.1f lat=%.1f" % (t,x,y,lat)); break
