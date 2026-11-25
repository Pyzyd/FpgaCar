# -*- coding: utf-8 -*-
"""确认实现细节：
   1) trim 放在限幅之前(sum_raw=trim+p+i+d, 再钳 ±BASE) vs 之后 —— 是否等效
   2) 积分容量 I_LIMIT=640 是否够（trim 已在，积分只补残差）
   3) 最终定参 P80 D30 trim-140 的完整验证"""
import math, sys, random
sys.path.insert(0,'bench')
from fast_corner import track_dist, sample, WHEEL_BASE, TICK_DT
RPT=30

def run(R,P,D,ilim,ish,trim,dp,flick,seed,KL=0.30,KR=0.165,order='before',
        base=480.0,t_end=45.0):
    rnd=random.Random(seed)
    x,y,th=0.0,dp,0.0
    pos_d=0.0; i_acc=0.0; lost_ms=0; t=0.0
    max_lat=0.0; lat2=0.0; n=0; hist=[]; step=0
    while t<t_end:
        cnt,pos=sample(x,y,th,R,dp)
        if cnt and rnd.random()<flick:
            pos=max(-7,min(7,pos+rnd.choice((-1,1))))
        lost=(cnt==0)
        lost_ms=lost_ms+10 if lost else 0
        if lost_ms>=300:
            dl=dr=0.0
        else:
            err=float(pos); errd=0.0 if lost else (err-pos_d)
            if order=='before':
                corr=trim+err*P+i_acc/(2.0**ish)+errd*D
                corr=max(-base,min(base,corr))
            else:
                corr=err*P+i_acc/(2.0**ish)+errd*D
                corr=max(-base,min(base,corr))+trim
            dl=max(0.0,min(1200.0,base+corr)); dr=max(0.0,min(1200.0,base-corr))
            if not lost:
                pos_d=err; i_acc=max(-ilim,min(ilim,i_acc+err))
            step+=1
            if step%RPT==0: hist.append(corr)
        vL,vR=KL*dl,KR*dr
        v=(vL+vR)/2.0; w=(vR-vL)/WHEEL_BASE
        for _ in range(10):
            dt=TICK_DT/10
            x+=v*math.cos(th)*dt; y+=v*math.sin(th)*dt; th+=w*dt
        lat=track_dist(x,y,R,dp); max_lat=max(max_lat,lat)
        if t>8.0: lat2+=lat*lat; n+=1
        t+=TICK_DT
        if max_lat>120: return False,max_lat,0,0
        if y>dp+R+500-60: break
    ds=sorted(abs(hist[i+1]-hist[i]) for i in range(len(hist)-1))
    return max_lat<45,max_lat,(math.sqrt(lat2/n) if n else 0),(ds[len(ds)//2] if ds else 0)

CASES=[(R,dp,f,s) for R in (4000.,600.,400.,300.,240.,200.,160.)
       for dp in (-15.,-8.,0.,8.,15.) for f in (0.0,0.20) for s in (1,2)]
def sweep(label,**kw):
    fails=0;worst=0.0;rms=[];jit=[]
    for (R,dp,f,s) in CASES:
        ok,lat,r2,dc=run(R,dp=dp,flick=f,seed=s,**kw)
        if not ok: fails+=1
        worst=max(worst,lat)
        if ok: rms.append(r2); jit.append(dc)
    rms.sort(); jit.sort()
    print('%-46s fail %2d/%d worst %5.1f rms_med %4.2f rms_p90 %5.2f dc_med %4.0f'%(
        label,fails,len(CASES),worst,
        rms[len(rms)//2] if rms else -1, rms[int(len(rms)*0.9)] if rms else -1,
        jit[len(jit)//2] if jit else -1))

print('== trim 位置 ==')
sweep('before clamp  P80 D30 i640 trim-140',  P=80,D=30,ilim=640,ish=5,trim=-140.,order='before')
sweep('after  clamp  P80 D30 i640 trim-140',  P=80,D=30,ilim=640,ish=5,trim=-140.,order='after')
print()
print('== 积分容量（trim 已补偿静态量）==')
for il in (320,640,1024,2048):
    sweep('P80 D30 i%-5d trim-140'%il, P=80,D=30,ilim=il,ish=5,trim=-140.)
print()
print('== I_SHIFT ==')
for ish in (4,5,6):
    sweep('P80 D30 i640 ish%d trim-140'%ish, P=80,D=30,ilim=640,ish=ish,trim=-140.)
print()
print('== 最终候选 vs 旧值 ==')
sweep('旧 P120 D220 i640 trim0', P=120,D=220,ilim=640,ish=5,trim=0.)
sweep('新 P80 D30 i640 trim-140', P=80,D=30,ilim=640,ish=5,trim=-140.)
sweep('新 P80 D20 i640 trim-140', P=80,D=20,ilim=640,ish=5,trim=-140.)
sweep('新 P96 D30 i640 trim-140', P=96,D=30,ilim=640,ish=5,trim=-140.)
