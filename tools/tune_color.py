"""用 grab_frame.py 抓到的缩略图离线复现 color_detect(v6) 的判定，并对门限做网格搜索。

设计原则：**逐位复刻 RTL**，包括
  - RGB565 量化后的 6 位空间（px_r = {r5,1'b0}，px_b = {b5,1'b0}，px_g = g6）
  - sat = max(R,G,B) - min(R,G,B)（7 位），< SAT_MIN 记中性 0
  - 相对判黄 YEL_DR / YEL_DB（不再有绝对亮度地板 YEL_RG 下界之外的东西）
  - 绿色要求 G >= R + GRN_DR，否则记中性（防"偏绿白平衡下的黄纸"变假绿）
  - 帧末：MIN_PIX 与"占本帧最大色 1/DOM_DIV"双门限
    （v6：基数从"鲜艳总量"换成"最大色"，因为总量口径没有绝对锚点，
      画面里固定亮度的小残留只要占总量够比例就能帧帧入选）
  - 多帧之间 rr 轮询起点递增，和 color_seq 看到的一致

用法
    python tune_color.py data/_frame.csv:yellow
    python tune_color.py _red.csv:red _green.csv:green _wall.csv:none
标签：red green blue yellow none     none = 中性/背景，期望 0

输出
  1) 当前 RTL 参数下每张图的逐帧判定（含轮询序列）
  2) 网格搜索 DOM_DIV / MIN_PIX，按"帧级命中率"打分
  3) 可直接粘回 src/color_detect.v 的 parameter 行
"""
import itertools
import sys

# ---- 与 src/color_detect.v 第 48~70 行保持一致 ----
RTL = dict(SAT_MIN=16, YEL_RG=8, GRN_DR=16, YEL_DR=24, YEL_DB=8,
           MIN_PIX=200, DOM_DIV=5)

LABELS = {"none": 0, "red": 1, "green": 2, "blue": 3, "yellow": 4}
NAMES = {0: "中性", 1: "红", 2: "绿", 3: "蓝", 4: "黄"}


def load_frame(path):
    """grab_frame.py 的 _frame.csv 是**一张** 40x30 的缩略图：
    30 行、每行 40 个 RRGGBB。整张图展平成一个像素列表 = 一帧。"""
    px = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            for cell in line.split(","):
                px.append((int(cell[0:2], 16), int(cell[2:4], 16), int(cell[4:6], 16)))
    return px


def quant6(r, g, b):
    """RGB888 -> RTL 的 6 位空间（低位补 0，与 px_r/px_b 一致）。"""
    r5 = r >> 3
    g6 = g >> 2
    b5 = b >> 3
    return (r5 << 1, g6, b5 << 1)


FRAME_PX = 1280 * 720          # RTL 面对的真实帧，MIN_PIX 就是按它标定的


def scale_params(p, npix):
    """缩略图只有 40x30 像素时，MIN_PIX 必须按面积同比例缩放，
    否则任何颜色都过不了 200px 这道按整帧标定的门槛（表现为全部判中性）。"""
    k = npix / FRAME_PX
    q = dict(p)
    q["MIN_PIX"] = max(1, int(round(p["MIN_PIX"] * k)))
    return q


def classify(r, g, b, p):
    """逐位复刻 color_detect.v:145-166。"""
    R, G, B = quant6(r, g, b)
    mx = max(R, G, B)
    mn = min(R, G, B)
    sat = mx - mn
    if sat < p["SAT_MIN"]:
        return 0                                   # 中性色
    rg_min = min(R, G)
    rg_diff = abs(R - G)
    is_yel = (rg_min >= p["YEL_RG"]) and (rg_diff <= p["YEL_DR"]) and (rg_min >= B + p["YEL_DB"])
    if is_yel:
        return 4
    if mx == R:
        return 1
    if mx == G:
        return 2 if G >= R + p["GRN_DR"] else 0
    return 3


def frame_counts(row, p):
    cnt = [0] * 5
    for (r, g, b) in row:
        cnt[classify(r, g, b, p)] += 1
    return cnt


def pick(cnt, rr, p):
    """复刻 color_detect.v:205-225 的轮询选择，返回 (颜色, 最大色, 门限)。

    门限用"总计数 × DOM_DIV 后与最大色比大小"，与 RTL 的 cnt*5 >= cnt_mx
    完全等价（避免整除截断在边界上的抖动）。"""
    cnt_mx = max(cnt[1], cnt[2], cnt[3], cnt[4])
    div = p["DOM_DIV"]
    # 位序与 RTL 的 elig 一致：下标 0..3 = 红绿蓝黄
    elig = [cnt[c] >= p["MIN_PIX"] and cnt[c] * div >= cnt_mx for c in (1, 2, 3, 4)]
    for k in range(4):
        idx = (rr + k) % 4
        if elig[idx]:
            return idx + 1, cnt_mx, cnt_mx / div
    return 0, cnt_mx, cnt_mx / div


def run_frames(frames, lab, p):
    """frames 里每个元素是一帧（一帧 = 像素列表）。返回 [(颜色, 计数, 总量, 门限)]。"""
    out = []
    rr = 0
    if frames:
        p = scale_params(p, len(frames[0]))
    for row in frames:
        cnt = frame_counts(row, p)
        c, tot, lim = pick(cnt, rr, p)
        out.append((c, cnt, tot, lim))
        if c:
            rr = c % 4                             # 与 RTL 相同：下一个颜色起轮
    return out


def grid_search(samples):
    best = None
    for dd, mp in itertools.product(range(3, 9), (100, 150, 200, 300, 400)):
        p = dict(RTL, DOM_DIV=dd, MIN_PIX=mp)
        # run_frames 内部会按帧面积再缩放 MIN_PIX
        hit = 0
        total = 0
        for path, lab, frames in samples:
            for c, _, _, _ in run_frames(frames, lab, p):
                total += 1
                hit += (c == lab)
        if best is None or hit / total > best[0]:
            best = (hit / total, dd, mp, hit, total)
    return best


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1

    samples = []
    for a in args:
        path, lab = a.rsplit(":", 1) if ":" in a else (a, "none")
        lab = lab.lower()
        if lab not in LABELS:
            print(f"unknown label '{lab}', use one of {list(LABELS)}")
            return 1
        frames = [load_frame(path)]
        samples.append((path, LABELS[lab], frames))
        print(f"loaded {path}: 1 帧 x {len(frames[0])} px  label={lab}")

    print(f"\n=== 当前 RTL 参数 {RTL} ===")
    for path, lab, frames in samples:
        res = run_frames(frames, lab, RTL)
        seq = "".join(str(c) for c, _, _, _ in res)
        hit = sum(1 for c, _, _, _ in res if c == lab)
        c0, cnt0, tot0, lim0 = res[0]
        print(f"  {path:16s} 期望={NAMES[lab]:2s} 轮询序列={seq} 命中 {hit}/{len(res)}")
        print(f"       首帧 计数 R/G/B/Y={cnt0[1]}/{cnt0[2]}/{cnt0[3]}/{cnt0[4]} "
              f"总量={tot0} 门限={lim0} 判定={NAMES[c0]}")

    labels = {lab for _, lab, _ in samples}
    if len(labels) < 3 or labels == {LABELS["none"]}:
        print("\n=== 网格搜索（DOM_DIV / MIN_PIX）===")
        print(f"  [跳过] 只有 {len(labels)} 种标签、{len(samples)} 个样本——"
              "单色样本下门限永远不会起作用，搜出的值会退化到最小值，没有参考意义。")
        print("  至少给 3 类样本（如 red/green/yellow，或真实场景 none 图）再搜。")
        return 0

    print("\n=== 网格搜索（DOM_DIV / MIN_PIX）===")
    acc, dd, mp, hit, total = grid_search(samples)
    print(f"  最优: DOM_DIV={dd}(1/{dd})  MIN_PIX={mp}  帧级命中 {hit}/{total} = {acc * 100:.1f}%")
    print("\n=== 粘回 src/color_detect.v ===")
    print(f"    parameter [19:0] MIN_PIX   = 20'd{mp},")
    print(f"    parameter [3:0]  DOM_DIV   = 4'd{dd}      // 占本帧最大色 1/{dd}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
