# -*- coding: utf-8 -*-
"""trim 灵敏度 + P/D 微调：确认 trim 不需要精确值，且 P/D 选点稳健。"""
import math, sys, random
sys.path.insert(0,'bench')
from fast_corner import track_dist, sample, WHEEL_BASE, TICK_DT

RPT = 30
def run(R, P, D, trim, dp, flick, seed, KL=0.30, KR=0.165, ilim=1024, ish=5,
        base=480.0, t_end=45.0):
    rnd = random.Random(seed)
    x,y,th = 0.0, dp, 0.0
    pos_d=0.0; i_acc=0.0; lost_ms=0; t=0.0
    max_lat=0.0; lat2=0.0; n=0; hist=[]; step=0
    while t < t_end:
        cnt,pos = sample(x,y,th,R,dp)
        if cnt and rnd.random()<flick:
            pos = max(-7,min(7,pos+rnd.choice((-1,1))))
        lost = (cnt==0)
        lost_ms = lost_ms+10 if lost else 0
        if lost_ms>=300:
            dl=dr=0.0
        else:
            err=float(pos); errd=0.0 if lost else (err-pos_d)
            corr = trim + err*P + i_acc/(2.0**ish) + errd*D
            corr = max(-base,min(base,corr))
            dl=max(0.0,min(1200.0,base+corr)); dr=max(0.0,min(1200.0,base-corr))
            if not lost:
                pos_d=err; i_acc=max(-ilim,min(ilim,i_acc+err))
            step+=1
            if step%RPT==0: hist.append(corr)
        vL,vR = KL*dl, KR*dr
        v=(vL+vR)/2.0; w=(vR-vL)/WHEEL_BASE
        for _ in range(10):
            dt=TICK_DT/10
            x+=v*math.cos(th)*dt; y+=v*math.sin(th)*dt; th+=w*dt
        lat=track_dist(x,y,R,dp); max_lat=max(max_lat,lat)
        if t>8.0: lat2+=lat*lat; n+=1
        t+=TICK_DT
        if max_lat>120: return False,max_lat,0,0
        if y > dp+R+500-60: break
    ds=sorted(abs(hist[i+1]-hist[i]) for i in range(len(hist)-1))
    return max_lat<45, max_lat, (math.sqrt(lat2/n) if n else 0), (ds[len(ds)//2] if ds else 0)

CASES=[(R,dp,f,s) for R in (4000.,600.,400.,300.,240.,200.,160.)
       for dp in (-15.,-8.,0.,8.,15.) for f in (0.0,0.20) for s in (1,2)]

def sweep(label, P, D, trim, KR=0.165):
    fails=0; worst=0.0; rms=[]
    for (R,dp,f,s) in CASES:
        ok,lat,r2,dc = run(R,P,D,trim,dp,f,s,KR=KR)
        if not ok: fails+=1
        worst=max(worst,lat)
        if ok: rms.append(r2)
    rms.sort()
    print('%-40s fail %2d/%d worst %5.1f rms_med %4.2f rms_p90 %5.2f'%(
        label,fails,len(CASES),worst,rms[len(rms)//2] if rms else -1,
        rms[int(len(rms)*0.9)] if rms else -1))

print('== trim 灵敏度（P80 D30, 真实 KR=0.165）==')
for trim in (0,-60,-100,-120,-140,-160,-180,-220,-260):
    sweep('trim %d'%trim, 80, 30, float(trim))
print()
print('== P/D 微调（trim=-140）==')
for P,D in ((120,220),(120,40),(96,30),(80,30),(80,20),(80,10),(64,30),(60,20)):
    sweep('P%-3d D%-3d'%(P,D), P, D, -140.0)
print()
print('== trim=-140 在真实不对称偏离时的鲁棒性（P80 D30）==')
for kr in (0.140,0.150,0.165,0.180,0.195,0.210):
    sweep('真实 KR=%.3f'%kr, 80, 30, -140.0, KR=kr)
