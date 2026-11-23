# -*- coding: utf-8 -*-
"""验证"积分项被钳死"假设。

track_pid 里：i_term = i_acc >> I_SHIFT，i_acc 钳在 +-I_LIMIT。
所以积分能输出的最大值 = I_LIMIT >> I_SHIFT。

稳态绕圈需要多大的 corr？
  两轮速度差 = w * WHEEL_BASE
  占空比差  = 2*corr  -> 速度差 = 2*corr*K
  => corr = w * WHEEL_BASE / (2*K)
  R=300mm, v=240mm/s -> w=0.8rad/s -> corr=128

当前 I_LIMIT=640, I_SHIFT=5 -> 积分最多只能给 20。
剩下的 108 必须由 P 提供：err = 108/72 = 1.5 个 pos 单位。
pos 单位约等于 pitch/2 = 5.5mm -> 稳态误差约 8mm。
这和仿真里 maxLat=10.2mm 对得上。
"""
import corner_loop_sim2 as S2

def corr_needed(v_mms, R, k):
    w = v_mms / R
    return w * S2.WHEEL_BASE / (2.0 * k)

def run_cfg(p, R, k=0.5):
    # 关闭整形器，单独看积分的作用
    return S2.run(p, R=R, diff_shift=1, shape_en=False, t_end=25.0, k_mms=k)

if __name__ == '__main__':
    print("=== 稳态绕圈需要的 corr（K=0.5）===")
    for R in [400.0, 300.0, 250.0, 200.0]:
        for v in [240.0, 300.0, 360.0]:
            print("  R=%-6.0f v=%-6.0f -> corr_need=%6.1f" % (R, v, corr_needed(v, R, 0.5)))
        print()
    print("=== 当前积分上限 I_LIMIT>>I_SHIFT ===")
    for ilim, ish in [(640,5),(640,3),(640,2),(1200,3),(2000,3),(2000,2),(4000,3),(8000,4)]:
        print("  I_LIMIT=%-5d I_SHIFT=%d -> i_term_max = %d" % (ilim, ish, ilim >> ish))
    print()
    print("=== 弯道表现：I_SHIFT / I_LIMIT 扫描（整形器关，R=300）===")
    print("%-22s %-6s %5s %8s %7s" % ("config", "R", "ok", "maxLat", "lost"))
    cases = [
        ("I=640 s5 (current)", 640, 5),
        ("I=640 s3", 640, 3),
        ("I=640 s2", 640, 2),
        ("I=1200 s3", 1200, 3),
        ("I=2000 s3", 2000, 3),
        ("I=2000 s2", 2000, 2),
        ("I=4000 s3", 4000, 3),
        ("I=640 s2 P=40 D=20", 640, 2),
    ]
    for R in [400.0, 300.0, 250.0, 200.0]:
        for name, ilim, ish in cases:
            p = S2.pid_params(480, 72, 40, ish, ilim)
            r = run_cfg(p, R)
            print("%-22s %-6.0f %5s %8.1f %7d" % (
                name, R, "Y" if r['ok'] else "N", r['max_lat'], r['lost_events']))
        print()
