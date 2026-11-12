# -*- coding: utf-8 -*-
"""从系统字库生成 OLED 点阵 ROM，输出 src/oled_font.v。

用途：0.96" SSD1306 (128x64 单色) 上显示"红/绿/蓝/黄"四个 32x32 汉字，
      按识别出的颜色顺序从左到右排列（槽位 i 占列 i*32..i*32+31）。

点阵打包（SSD1306 页格式）：
  每个字形 128 字节 = 4 个 page（每 page 8 行）x 32 列
  byte[p*32 + c] 的 bit b = 像素(行 = p*8+b, 列 = c)
ROM 地址：addr = (color-1)*128 + page*32 + col   color: 1=红 2=绿 3=蓝 4=黄
"""
import sys

from PIL import Image, ImageDraw, ImageFont

CHARS = "\u7ea2\u7eff\u84dd\u9ec4"   # 1=红 2=绿 3=蓝 4=黄
FONT = "C:/Windows/Fonts/simhei.ttf"
SIZE = 30
BOX = 32
THRESH = 100
OUT = "src/oled_font.v"
TIMESCALE = chr(96) + "timescale 1ns/1ns"


def render(ch):
    img = Image.new("L", (BOX, BOX), 0)
    font = ImageFont.truetype(FONT, SIZE)
    d = ImageDraw.Draw(img)
    l, t, r, b = d.textbbox((0, 0), ch, font=font)
    w, h = r - l, b - t
    d.text(((BOX - w) // 2 - l, (BOX - h) // 2 - t), ch, font=font, fill=255)
    px = img.load()
    out = bytearray()
    for p in range(4):
        for c in range(BOX):
            byte = 0
            for bit in range(8):
                if px[c, p * 8 + bit] > THRESH:
                    byte |= 1 << bit
            out.append(byte)
    return out


def art(data):
    lines = []
    for p in range(4):
        for bit in range(8):
            row = ""
            for c in range(32):
                row += "#" if (data[p * 32 + c] >> bit) & 1 else "."
            lines.append(row)
    return "\n".join(lines)


def emit_v():
    data = bytearray()
    for ch in CHARS:
        data += render(ch)
    n = len(data)
    L = []
    L.append("// " + "=" * 77)
    L.append("// oled_font.v - 32x32 汉字点阵 ROM (自动生成，勿手改)")
    L.append("// " + "-" * 77)
    L.append("// 生成器: tools/gen_oled_font.py   字体: simhei.ttf   字号: %d" % SIZE)
    L.append("// 字形: 1=红 2=绿 3=蓝 4=黄，共 %d 字形 x 128 字节 = %d 字节" % (len(CHARS), n))
    L.append("// 打包: 每字形 4 page x 32 col，byte[p*32+c] 的 bit b = 像素(行 p*8+b, 列 c)")
    L.append("// 地址: addr = (color-1)*128 + page*32 + col")
    L.append("// " + "=" * 77)
    L.append(TIMESCALE)
    L.append("")
    L.append("module oled_font (")
    L.append("    input  wire [8:0] addr,")
    L.append("    output reg  [7:0] q")
    L.append(");")
    L.append("    always @(*) begin")
    L.append("        case (addr)")
    for i, b in enumerate(data):
        L.append("        9'd%-3d: q = 8'h%02X;" % (i, b))
    L.append("        default: q = 8'h00;")
    L.append("        endcase")
    L.append("    end")
    L.append("endmodule")
    L.append("")
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L))
    return n


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "emit"
    if mode == "art":
        for i, ch in enumerate(CHARS):
            print("=== %d U+%04X" % (i + 1, ord(ch)))
            print(art(render(ch)))
        return
    n = emit_v()
    print("wrote %s : %d bytes of glyph data" % (OUT, n))


if __name__ == "__main__":
    main()
