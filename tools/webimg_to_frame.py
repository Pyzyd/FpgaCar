"""把网上下载的图片转成 grab_frame.py 的 CSV 格式（40x30 "RRGGBB"），供 tune_color.py 直接吃。

背景：color_detect 的门限分两层，"能不能用网图训练"对两层答案完全不同。

  - 像素级（SAT_MIN / YEL_RG / YEL_DR / YEL_DB / GRN_DR，以及 R/G/B 谁最大）
    只取决于颜色本身，**网图可以验、可以扩大样本**：换个色相、换个明度，
    规则还成不成立，网图能回答。

  - 帧级（MIN_PIX / DOM_DIV）
    取决于"目标占画面多大、背景残留多少、传感器噪声多强"，**只能上板抓**。
    网图的构图、光照、背景跟小车看到的画面毫无关系，拿它搜这两个值必然过拟合
    （单色样本下门限根本不起作用，搜出来会退化到边界值）。

所以本工具只服务第一层：把任意图片降采样成 40x30（与 frame_snap.v 的 GW=40 /
GH=30 同构，同样是格内面积平均），写成 tune_color.py 认识的 CSV。

两个必须知道的差异（工具不替你消除，只提示）：

  1. 白平衡偏置。OV5640 走固定白平衡，实测同一张黄纸在板上是 **G>R**
     （6 位 28/34/18），而网图里的黄基本是 R>G（#E8C33A）。
     `--wb board` 只做**白锚定**的一阶白平衡（把中性色拉回中性），
     **不**尝试复现板上的饱和色相 —— 两锚点解出的增益互相矛盾，
     用黄锚定会把白墙推成青绿。默认不拉：先看原图结果，
     "像素级规则能否跨白平衡成立"本身就是要验的东西。

  2. 动态范围。板子 RGB565 每通道只剩 5/6 位且没有 gamma 校正，暗部会直接
     掉进中性（实测同色相 V=60 判中性）。网图暗部细节丰富，转换后自己看一眼
     那些像素是否本来就该判中性，别把"传感器压暗"当成"阈值判错"。

用法（需要 Pillow，走**系统 Python**，不要用 Efinity 的 python311）：

    python tools/webimg_to_frame.py photo.jpg data/_web_yellow.csv
    python tools/webimg_to_frame.py photo.jpg data/_web_yellow.csv --wb board
    python tools/webimg_to_frame.py photo.jpg out.csv --label yellow   # 只用来打印下一步命令

然后：

    python tools/tune_color.py data/_frame_1.csv:yellow data/_web_yellow.csv:yellow
"""
import argparse
import sys

GW, GH = 40, 30          # 与 src/frame_snap.v 的 GW/GH 一致

# 白锚定的一阶增益：板上的中性色实测 8 位 (131,142,111)，
# sRGB 中性取 (240,240,235) → 增益 = (131/240, 142/240, 111/235)。
# 只保证"中性色进去还是中性色"，**不试图复现板上的饱和色相** —— 原因见下。
WB_WHITE = (0.546, 0.592, 0.472)

# 为什么不做"从黄纸反解增益"：两个锚点解出来的增益互相矛盾。
#   白锚定 (0.546, 0.592, 0.472) → 黄变 (126,115,27)，板上实测 (110,138,72)
#   黄锚定 (0.474, 0.708, 1.241) → 白变 (113,169,255) 青蓝，板上实测 (131,142,111)
# 即 OV5640 固定白平衡下的响应不是每通道线性增益（黄纸在板上 R/G=0.80，
# sRGB 黄 R/G=1.19，大小关系是反的）。用黄锚定增益去变换，白墙会被推成青绿 ——
# 实测 1200 px 里有 735 px 被判成绿。所以这里只提供白锚定这一种，且明说不复现饱和色相。


def load_rgb(path):
    from PIL import Image
    im = Image.open(path)
    if im.mode != "RGB":
        im = im.convert("RGB")
    return im


def to_thumb(im):
    """面积平均降采样到 GWxGH —— frame_snap.v 每格是 32x24 像素取平均，
    PIL 的 BOX 滤波器就是区域平均，两者同构。"""
    from PIL import Image
    return im.resize((GW, GH), Image.BOX)


def apply_wb(im, gains):
    """按通道一阶增益缩放，夹到 0..255。"""
    from PIL import Image
    r_g, g_g, b_g = gains
    lut_r = [min(255, int(v * r_g)) for v in range(256)]
    lut_g = [min(255, int(v * g_g)) for v in range(256)]
    lut_b = [min(255, int(v * b_g)) for v in range(256)]
    px = im.load()
    out = Image.new("RGB", im.size)
    op = out.load()
    for y in range(im.size[1]):
        for x in range(im.size[0]):
            r, g, b = px[x, y]
            op[x, y] = (lut_r[r], lut_g[g], lut_b[b])
    return out


def write_csv(path, im):
    px = im.load()
    rows = []
    for y in range(GH):
        rows.append(",".join("%02X%02X%02X" % px[x, y] for x in range(GW)))
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(rows) + "\n")


def main():
    ap = argparse.ArgumentParser(description="网图 -> 40x30 RRGGBB CSV（tune_color.py 的输入格式）")
    ap.add_argument("image")
    ap.add_argument("out")
    ap.add_argument("--wb", choices=("none", "board"), default="none",
                    help="none=保持原样（默认）；board=白锚定一阶白平衡，只保证中性色仍中性")
    ap.add_argument("--label", default="yellow",
                    help="只用于打印下一步 tune_color.py 命令，不写进 CSV")
    a = ap.parse_args()

    try:
        im = load_rgb(a.image)
    except ImportError:
        print("需要 Pillow：pip install pillow（或改用系统 Python 运行本脚本）")
        return 1
    except Exception as e:
        print("读图失败 %s: %s" % (a.image, e))
        return 1

    thumb = to_thumb(im)
    if a.wb == "board":
        thumb = apply_wb(thumb, WB_WHITE)

    write_csv(a.out, thumb)

    px = thumb.load()
    n = GW * GH
    ar = sum(px[x, y][0] for y in range(GH) for x in range(GW)) // n
    ag = sum(px[x, y][1] for y in range(GH) for x in range(GW)) // n
    ab = sum(px[x, y][2] for y in range(GH) for x in range(GW)) // n
    print("saved %s  (%dx%d, wb=%s)" % (a.out, GW, GH, a.wb))
    print("  mean R/G/B = %d/%d/%d" % (ar, ag, ab))
    print("  next: python tools/tune_color.py %s:%s" % (a.out, a.label))
    return 0


if __name__ == "__main__":
    sys.exit(main())
