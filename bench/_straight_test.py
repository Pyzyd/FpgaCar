
import sys, math
sys.path.insert(0,'.')
from fast_corner import seg_dist, WEIGHTS, SENSOR_PITCH, SENSOR_FWD, LINE_HW, TICK_DT, WHEEL_BASE
from speed_sync_sim import CNT_PER_MM, WIN, K_SYNC, SYNC_MAX, I_SHIFT, I_LIMIT, clampi

def sample_straight(x, y, th, fwd=None):
    f = SENSOR_FWD if fwd is None else fwd
    ca, sa = math.cos(th), math.sin(th)
    sxs, sys_ = x + f*ca, y + f*sa
    lx, ly = -sa, ca
    cnt = 0; wsum = 0; mags=[0]*8
    for i,w in enumerate(WEIGHTS):
        lat = (3.5-i)*SENSOR_PITCH
        px, py = sxs + lat*lx, sys_ + lat*ly
        if abs(py) <= LINE_HW:      # 直线 y=0
            cnt += 1; mags[i]=abs(w); wsum += w
    if cnt == 0: return 0, 0.0
    tot = sum(mags)
    sign = -1.0 if wsum < 0 else 1.0
    pmag = int((tot*1024//cnt + 512) >> 10)
    return cnt, sign*pmag

def straight(mis=0.10, sync='off', gate=120.0, P=120.0, D=220.0, base=480.0,
             tau=0.0, k=0.5, t_end=6.0, y0=0.0):
    x, y, th = 0.0, y0, 0.0
    pos_d=0.0; i_acc=0.0; i_sync=0.0; sync_corr=0.0
    vL=vR=0.0; t=0.0; win_t=0.0; ymax=0.0; ysum=0.0; n=0
    while t < t_end:
        cnt, pos = sample_straight(x, y, th)
        lost = (cnt == 0)
        err = pos
        errd = 0.0 if lost else (err - pos_d)
        corr = err*P + int(i_acc)/(2.0**5) + errd*D
        corr = max(-base, min(base, corr))
        cmd_l = max(0.0, min(1200.0, base+corr))
        cmd_r = max(0.0, min(1200.0, base-corr))
        if not lost:
            pos_d = err
            i_acc = max(-640.0, min(640.0, i_acc+err))
        win_t += TICK_DT
        if win_t >= WIN-1e-9 and sync != 'off':
            win_t = 0.0
            s_l = round(vL*WIN*CNT_PER_MM); s_r = round(vR*WIN*CNT_PER_MM)
            dcmd = abs(cmd_l-cmd_r)
            ok = True if sync=='always' else (dcmd <= gate)
            if ok:
                diff = s_l-s_r
                sm = diff*K_SYNC + i_sync/(2.0**I_SHIFT)
                sync_corr = clampi(sm, -SYNC_MAX, SYNC_MAX)
                i_sync = clampi(i_sync+diff, -I_LIMIT, I_LIMIT)
            else:
                i_sync = 0.0; sync_corr = 0.0
        dl = clampi(cmd_l-sync_corr, 0.0, 1200.0)
        dr = clampi(cmd_r+sync_corr, 0.0, 1200.0)
        if tau > 0:
            vL += (k*(1.0-mis)*dl - vL)*(TICK_DT/tau)
            vR += (k*(1.0+mis)*dr - vR)*(TICK_DT/tau)
        else:
            vL, vR = k*(1.0-mis)*dl, k*(1.0+mis)*dr
        v=(vL+vR)/2.0; w=(vR-vL)/WHEEL_BASE
        for _ in range(10):
            dt=TICK_DT/10
            x += v*math.cos(th)*dt; y += v*math.sin(th)*dt; th += w*dt
        ymax=max(ymax,abs(y)); ysum+=abs(y); n+=1
        t += TICK_DT
    return y, th, ymax, ysum/n

print('=== 1) 直道 右轮快 10%, y0=0, 6s ===')
print('%-8s %5s  %10s %12s %10s %10s' % ('mode','gate','终点y','航向deg','峰值|y|','平均|y|'))
for mode,gate in [('off',0),('always',0),('gate',120),('gate',300),('gate',600)]:
    yo,th,ymax,ym=straight(mis=0.10,sync=mode,gate=gate)
    print('%-8s %5d  %10.2f %12.2f %10.2f %10.2f' % (mode,gate,yo,math.degrees(th),ymax,ym))
print()
print('=== 2) 直道 右轮快 10%, y0=10mm, 8s ===')
for mode,gate in [('off',0),('always',0),('gate',120),('gate',300)]:
    yo,th,ymax,ym=straight(mis=0.10,sync=mode,gate=gate,t_end=8.0,y0=10.0)
    print('%-8s %5d  %10.2f %12.2f %10.2f %10.2f' % (mode,gate,yo,math.degrees(th),ymax,ym))
