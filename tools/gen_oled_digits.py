
# -*- coding: utf-8 -*-
"""gen_oled_digits.py -- 生成 OLED 数字点阵 ROM (src/oled_digits.v) 与预览图

布局: 16x16 点阵，每个字形 2 page x 16 col = 32 字节
  addr = glyph*32 + page*16 + col,  byte 的 bit b = 像素(行 page*8+b, 列 col)
字形 0..9 = 数字 '0'-'9'，10 = '-'，11 = 空白
另附两个 8x8 小字形 'c'/'m'，从 addr 384 起，每个 8 字节。
"""
from PIL import Image, ImageDraw, ImageFont

W, H = 16, 16
FONTS = [r"C:/Windows/Fonts/msyhbd.ttc", r"C:/Windows/Fonts/msyh.ttc"]
GLYPHS = "0123456789- "

def render(ch):
    img = Image.new("1", (W, H), 0)
    d = ImageDraw.Draw(img)
    if ch != " ":
        f = ImageFont.truetype(FONTS[0], 15)
        bb = d.textbbox((0, 0), ch, font=f)
        d.text(((W - (bb[2] - bb[0])) // 2 - bb[0], (H - (bb[3] - bb[1])) // 2 - bb[1]),
               ch, font=f, fill=1)
    return img

def bytes_of(img):
    out = []
    for page in range(2):
        for col in range(W):
            v = 0
            for b in range(8):
                if img.getpixel((col, page * 8 + b)):
                    v |= (1 << b)
            out.append(v)
    return out

def small(ch):
    img = Image.new("1", (8, 8), 0)
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(FONTS[0], 8)
    bb = d.textbbox((0, 0), ch, font=f)
    d.text(((8 - (bb[2] - bb[0])) // 2 - bb[0], (8 - (bb[3] - bb[1])) // 2 - bb[1]),
           ch, font=f, fill=1)
    out = []
    for col in range(8):
        v = 0
        for b in range(8):
            if img.getpixel((col, b)):
                v |= (1 << b)
        out.append(v)
    return out

big = [bytes_of(render(c)) for c in GLYPHS]
sml = [small("c"), small("m")]

names = {"0":"数字 0","1":"1","2":"2","3":"3","4":"4","5":"5","6":"6","7":"7",
         "8":"8","9":"9","-":"负号/无数据"," ":"空白"}

L = []
L.append("// =============================================================================")
L.append("// oled_digits.v - 16x16 数字点阵 ROM (自动生成，勿手改)")
L.append("// -----------------------------------------------------------------------------")
L.append("// 生成器: tools/gen_oled_digits.py   字体: msyhbd.ttc   字号: 15")
L.append("// 布局: 16x16，每字形 2 page x 16 col = 32 字节")
L.append("//   addr = glyph*32 + page*16 + col")
L.append("//   byte 的 bit b = 像素(行 page*8+b, 列 col)")
L.append("// 字形 0..9 = '0'..'9'，10 = '-'，11 = 空白")
L.append("// addr 384..391 = 'c'，392..399 = 'm'（8x8 小字）")
L.append("// =============================================================================")
L.append("BTIMES")
L.append("")
L.append("module oled_digits (")
L.append("    input  wire [9:0] addr,")
L.append("    output reg  [7:0] q")
L.append(");")
L.append("    always @(*) begin")
L.append("        case (addr)")
for gi, name in enumerate(GLYPHS):
    for k, v in enumerate(big[gi]):
        L.append("        10'd%-4d: q = 8'h%02X;%s" % (gi*32+k, v,
                 "" if k else "   // " + names[name]))
for si, s in enumerate(sml):
    for k, v in enumerate(s):
        L.append("        10'd%-4d: q = 8'h%02X;%s" % (384+si*8+k, v,
                 "" if k else "   // '" + "cm"[si] + "'"))
L.append("        default: q = 8'h00;")
L.append("        endcase")
L.append("    end")
L.append("endmodule")

txt = "\n".join(L).replace("BTIMES", "BTCHARtimescale 1ns/1ns").replace("BTCHAR", chr(96))
open("FpgaCar/src/oled_digits.v", "w", encoding="utf-8", newline="\n").write(txt + "\n")
print("WROTE src/oled_digits.v bytes=%d" % len(txt))

SC = 6
prev = Image.new("RGB", (len(GLYPHS)*W*SC + 40, H*SC + 60), (18, 18, 22))
for gi, c in enumerate(GLYPHS):
    img = render(c)
    x0 = 20 + gi*W*SC
    for y in range(H):
        for x in range(W):
            if img.getpixel((x, y)):
                prev.paste((120, 220, 255), (x0+x*SC, 20+y*SC, x0+x*SC+SC, 20+y*SC+SC))
f = ImageFont.truetype(FONTS[0], 18)
d = ImageDraw.Draw(prev)
for gi, c in enumerate(GLYPHS):
    d.text((20 + gi*W*SC + 30, 20 + H*SC + 8), c, font=f, fill=(200, 200, 210))
prev.save("FpgaCar/docs/OLED数字点阵预览.png")
print("WROTE preview")
