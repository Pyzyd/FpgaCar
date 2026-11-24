
import csv, math, sys
CPM = 2532.0/212.0
WB  = 160.0

def load(path):
    rows=[]
    with open(path, newline='', encoding='utf-8', errors='replace') as f:
        for r in csv.DictReader(f): rows.append(r)
    frames=[]; cur=[]; last=None
    for r in rows:
        try: t=float(r['t'])
        except: continue
        if last is None or t-last<0.02: cur.append(r)
        else: frames.append(cur); cur=[r]
        last=t
    if cur: frames.append(cur)
    return [c[-1] for c in frames]

def h2i(s,bits):
    try: v=int(s,16)
    except: return 0
    if v>=1<<(bits-1): v-=1<<bits
    return v

def g(r,k,b): return h2i(r.get(k,'0'),b)

# 占空比指纹 -> 段名（右绕与左绕各一套）
FP = {
 (860,380):'OUT(右绕)',  (380,860):'OUT(左绕)',
 (400,840):'ALIGN(右绕)',(840,400):'ALIGN(左绕)',
 (620,620):'PASS',
 (420,860):'TURN_IN(右绕)',(860,420):'TURN_IN(左绕)',
 (430,640):'REJOIN(右绕)',(640,430):'REJOIN(左绕)',
}
def seg(dl,dr):
    return FP.get((dl,dr), '?%d/%d'%(dl,dr))

def ang(dl_mm, dr_mm):
    return (dl_mm-dr_mm)/WB*180.0/math.pi

def main(path):
    fr=load(path)
    print("逻辑帧 %d   时间 %.2f..%.2f s"%(len(fr),float(fr[0]['t']),float(fr[-1]['t'])))
    av=[i for i,r in enumerate(fr) if r.get('M','').strip() in ('05','06','07')]
    if not av:
        print("没有避障帧（M=05/06/07 均未出现）")
        for i,r in enumerate(fr):
            if r.get('O','')=='1': print("  但 O=1 出现在 t=%.2f"%float(r['t']))
        return
    lo=max(0,av[0]-2); hi=min(len(fr)-1,av[-1]+2)
    print("避障窗口 idx %d..%d (t=%.2f..%.2f)"%(av[0],av[-1],float(fr[av[0]]['t']),float(fr[av[-1]]['t'])))
    print()
    print(" idx    t      M  O  DL/DR     段            过弯角_deg  弧长_mm  中位速度mm/s")
    prev=None
    tot=0.0; totd=0.0
    for i in range(lo,hi+1):
        r=fr[i]; dl,dr=g(r,'DL',12),g(r,'DR',12)
        a=-99.0; d=0.0; v=0.0
        if prev is not None:
            try: dt=float(r['t'])-float(prev['t'])
            except: dt=0
            dLm=(g(r,'L',32)-g(prev,'L',32))/CPM
            dRm=(g(r,'R',32)-g(prev,'R',32))/CPM
            a=ang(dLm,dRm); d=((dLm+dRm)/2)
            if dt>0: v=abs(d)/dt
            tot+=a; totd+=d
        print("%4d %6.2f  %s  %s  %4d/%-4d  %-14s  %8.1f  %8.1f  %8.1f"%(
            i,float(r['t']),r.get('M','').strip(),r.get('O','?'),dl,dr,seg(dl,dr),a,d,v))
        prev=r
    print()
    print("整段避障：累计转角 %.1f deg，累计弧长 %.1f mm"%(tot,totd))
    # 退出方式
    tail=fr[hi] if hi<len(fr) else None
    if tail is not None:
        print("窗口末尾状态 M=%s DL/DR=%d/%d"%(tail.get('M','').strip(),g(tail,'DL',12),g(tail,'DR',12)))
    # 与目标比较
    print()
    print("对照：AVOID_ARC_DEG=60 每段目标；OUT 应 +60、ALIGN 应 -60、TURN_IN 应 -60")
    print("换算：每毫米差 = %.4f deg；60 deg 需两轮弧长差 %.1f mm（编码器 %d counts）"%(
        180.0/(WB*math.pi), WB*math.pi/3, int(WB*math.pi/3*CPM)))

if __name__=='__main__':
    main(sys.argv[1] if len(sys.argv)>1 else '.scratch/run_track3.csv')
