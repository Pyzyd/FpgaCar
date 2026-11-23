
# -*- coding: utf-8 -*-
"""丢线期间「控制器还修不修」的对照：freeze / hold_last_pos / pivot"""
import math, sys
sys.path.insert(0, r"D:/VF-Ti60F225_HDK_V2.1_20251009/FpgaCar/bench")
import corner_poly_sim as S

def run(mode='freeze', turn_deg=90.0, turn='L', t_end=16.0, fwd=None):
    if fwd is not None: S.SENSOR_FWD = fwd
    pts = S.make_track(turn_deg, turn)
    sens = S.Sensor(pts)
    x=y=th=0.0; pos_d=0; i_acc=0; duty=(480,480); t=0.0
    P=72.0; D=40.0; base=480.0
    max_lat=0.0; last_pos=0; trace=[]
    while t < t_end:
        r = sens.sample(x,y,th)
        cnt,pos,lost,wide = r['cnt'],r['pos'],r['lost'],r['wide']
        if cnt>0: last_pos=pos
        if mode=='freeze':
            if lost: dl,dr = duty
            else:
                err=pos; errd=err-pos_d
                sraw=err*P+(i_acc>>5)+errd*D
                s=max(-base,min(base,sraw)); dl,dr=base+s,base-s
                pos_d=err; i_acc=max(-640,min(640,i_acc+err))
        elif mode=='hold_last_pos':
            # 丢线时沿用最后一个非零 pos，PID 继续算
            if lost and last_pos==0:
                dl,dr = duty
            else:
                err = pos if not lost else last_pos
                errd = 0 if lost else (err-pos_d)
                sraw=err*P+(i_acc>>5)+errd*D
                s=max(-base,min(base,sraw)); dl,dr=base+s,base-s
                if not lost: pos_d=err; i_acc=max(-640,min(640,i_acc+err))
        elif mode=='pivot':
            if lost:
                sgn = -1.0 if last_pos>=0 else 1.0   # 线在右(pos>0)->右转
                dl,dr = base-260*sgn, base+260*sgn
                dl,dr = 220 if dl<220 else dl, 740 if dr>740 else dr
            else:
                err=pos; errd=err-pos_d
                sraw=err*P+(i_acc>>5)+errd*D
                s=max(-base,min(base,sraw)); dl,dr=base+s,base-s
                pos_d=err; i_acc=max(-640,min(640,i_acc+err))
        dl=max(0,min(1200,dl)); dr=max(0,min(1200,dr)); duty=(dl,dr)
        vl,vr=S.K_MMS*dl, S.K_MMS*dr
        v=(vl+vr)/2.0; w=(vr-vl)/S.WHEEL_BASE
        for _ in range(10):
            dt=S.TICK_DT/10
            x+=v*math.cos(th)*dt; y+=v*math.sin(th)*dt; th+=w*dt
        lat=S.track_dist(x,y,pts)
        max_lat=max(max_lat,lat)
        if 2.40<=t<=2.56 and abs(t*100-int(t*100)-0.0)<0.05:
            trace.append((round(t,2),cnt,pos,round(lat,1)))
        t+=S.TICK_DT
        if lat>150: return dict(ok=False,max_lat=max_lat,t=t,trace=trace)
    return dict(ok=max_lat<60,max_lat=max_lat,t=t,trace=trace)

print("%-16s %10s %8s   %s" % ("模式","maxLat(mm)","结局","丢线期间 (t,cnt,pos,lat)"))
for m in ('freeze','hold_last_pos','pivot'):
    r=run(m)
    trs=" ".join("%.2f/%d/%d/%.0f"%x for x in r['trace'][:6])
    print("%-16s %10.1f %8s   %s" % (m, r['max_lat'], "过" if r['ok'] else "出线", trs))
