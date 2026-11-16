# -*- coding: utf-8 -*-
"""
gen_wiring_diagrams.py —— 生成 docs/ 下的模块接线图。

  1. docs/TB6612接线图.png     TB6612FNG 双路 H 桥模块（16 脚）
  2. docs/YB-MUX04接线图.png   Yahboom YB-MUX04-1.0 八路循迹模块（16 脚单排）

两图都按实物丝印顺序绘制，旁边标注本工程的 FPGA 网络名与 DC3-40 针号，
真源是 docs/引脚分配表.md 与 FpgaCar.peri.xml。改管脚后重跑本脚本即可。
"""
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(os.path.join(HERE, "..", "docs"))

FONT_R = "C:/Windows/Fonts/msyh.ttc"
FONT_B = "C:/Windows/Fonts/msyhbd.ttc"

C_TITLE = "#1a1a1a"
C_SUB = "#666666"
C_NOTE = "#555555"
C_MOTOR = "#ad1457"
C_POWER = "#c0392b"
C_TRACK = "#1f6fd0"
C_OFF = "#9e9e9e"

_FONTS = {}


def F(size, bold=False):
    key = (size, bold)
    if key not in _FONTS:
        _FONTS[key] = ImageFont.truetype(FONT_B if bold else FONT_R, size)
    return _FONTS[key]


_probe = ImageDraw.Draw(Image.new("RGB", (8, 8)))


def wrap(text, size, maxw, bold=False):
    """按实测像素宽度折行（中文按字切，英文/数字按空格优先）。"""
    f = F(size, bold)
    out = []
    for para in text.split("\n"):
        cur = ""
        for ch in para:
            if _probe.textlength(cur + ch, font=f) <= maxw:
                cur += ch
            else:
                out.append(cur)
                cur = ch
        out.append(cur)
    return out


def draw_wrapped(d, xy, text, size, maxw, fill, bold=False, lh=None):
    x, y = xy
    lh = lh or int(size * 1.45)
    for line in wrap(text, size, maxw, bold):
        d.text((x, y), line, font=F(size, bold), fill=fill)
        y += lh
    return y


def panel_items(d, items, x_num, x_text, top, width, head_size=20, body_size=17,
                gap=62, head_col="#4a3d10", body_col="#6b5c33", num_col="#b8860b"):
    """画「① 小标题 / 说明」序列，返回占用到的 y。"""
    y = top
    body_w = width - (x_text - x_num)
    for num, head, body in items:
        d.text((x_num, y), num, font=F(head_size, True), fill=num_col)
        d.text((x_text, y), head, font=F(head_size, True), fill=head_col)
        y2 = y + int(head_size * 1.4)
        y2 = draw_wrapped(d, (x_text, y2), body, body_size, body_w, body_col)
        y = max(y + gap, y2 + 14)
    return y


# =====================================================================
# 图 2：YB-MUX04（先算高度，再画）
# =====================================================================
W = 1720
MARGIN = 56
PANEL_X0, PANEL_X1 = MARGIN, W - MARGIN

MUX_ITEMS = [
    ("①", "X1~X8 是按车头方向从左到右排的，顺序不能反",
     "track[0] 对应 X1 = 最左探头。接反了车会朝反方向修线 —— 现象是「越修越偏」。"),
    ("②", "先量一下 X 脚的高电平，再决定用 5V 还是 D3V3 供电",
     "底板每个 User_IO 都过 TXS0108E，B 侧绝对最大只有 4.6 V。若模块 5 V 供电时 X 输出到 5 V，"
     "直连就超规格；要么改用 D3V3（pin 29）供电，要么每根串电阻分压。空载量 X1 对 GND 的电压即可确认。"),
    ("③", "压线极性用 track_line 的 ACTIVE_HIGH 统一，不要改接线",
     "默认 0 = 低电平压线（TCRT5000 + LM393 最常见）。上板时看串口 T= 位串：把黑线在探头下从左往右推，"
     "那个 1 应当从一端走到另一端；若「压黑线显示 0」就把 ACTIVE_HIGH 改成 1 再重编。"),
]

_probe_img = Image.new("RGB", (W, 4000), "white")
_pd = ImageDraw.Draw(_probe_img)
_panel_top = 600
_end = panel_items(_pd, MUX_ITEMS, PANEL_X0 + 36, PANEL_X0 + 68, _panel_top + 56,
                   PANEL_X1 - PANEL_X0 - 72)
H = _end + 56

img = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(img)

d.text((MARGIN + 4, 42), "Yahboom YB-MUX04-1.0 八路循迹模块 · 引脚配置与接线",
       font=F(44, True), fill=C_TITLE)
d.text((MARGIN + 4, 106),
       "16 脚单排（丝印从左到右）· X1~X8 → track[7:0] · 5V/GND 供电 · TX/RX/SCL/SDA 本工程悬空不接",
       font=F(20), fill=C_SUB)

BAR_Y0, BAR_Y1 = 214, 298
PIN_Y0, PIN_Y1 = 298, 340
BOX_Y0, BOX_Y1 = 394, 500
X0, STEP, BOXW = 108, 100, 86

d.text((MARGIN + 4, 168), "车头方向 →  （X1 在最左）", font=F(18, True), fill=C_TRACK)
d.text((W - MARGIN - 4, 168), "板载 KEY / RESET 按钮与排针同名脚并联，本工程不用",
       font=F(17), fill=C_SUB, anchor="ra")
d.text((W // 2, BAR_Y0 - 22), "YB-MUX04-1.0 排针（丝印顺序，与实物照片一致）",
       font=F(18), fill=C_SUB, anchor="mm")

silk = ["5V", "GND", "KEY", "RESET", "X1", "X2", "X3", "X4",
        "X5", "X6", "X7", "X8", "TX", "RX", "SCL", "SDA"]
net = [None] * 16
io = [None] * 16
pin = [None] * 16
for i in range(8):
    net[4 + i] = "track[%d]" % i
    io[4 + i] = "IO%d" % (2 + i)
    pin[4 + i] = "pin %d" % (3 + i)
net[0], pin[0] = "D5V0", "pin 11"
net[1], pin[1] = "GND", "pin 12"

d.rounded_rectangle((MARGIN, BAR_Y0, W - MARGIN, BAR_Y1), radius=10,
                    fill="#111111", outline="#000000", width=2)

for i, name in enumerate(silk):
    x = X0 + i * STEP
    if i < 2:
        col = C_POWER
    elif 4 <= i <= 11:
        col = C_TRACK
    else:
        col = C_OFF
    d.text((x, (BAR_Y0 + BAR_Y1) // 2), name, font=F(21, True), fill="white", anchor="mm")
    d.rectangle((x - 9, PIN_Y0, x + 9, PIN_Y1), fill=col, outline="#666666", width=1)
    d.line((x, PIN_Y1, x, BOX_Y0), fill=col, width=3)
    d.rounded_rectangle((x - BOXW // 2, BOX_Y0, x + BOXW // 2, BOX_Y1), radius=10,
                        fill="white", outline=col, width=2)
    if net[i]:
        d.text((x, BOX_Y0 + 18), net[i], font=F(17, True), fill=col, anchor="mm")
        if io[i]:
            d.text((x, BOX_Y0 + 46), io[i], font=F(16), fill=C_NOTE, anchor="mm")
            d.text((x, BOX_Y0 + 70), pin[i], font=F(16), fill=C_NOTE, anchor="mm")
        else:
            d.text((x, BOX_Y0 + 50), pin[i], font=F(16), fill=C_NOTE, anchor="mm")
    else:
        d.text((x, BOX_Y0 + 22), "不接", font=F(17, True), fill=C_OFF, anchor="mm")
        tail = "空着即可" if i in (2, 3) else "悬空"
        d.text((x, BOX_Y0 + 56), tail, font=F(15), fill=C_OFF, anchor="mm")

ly = 540
d.text((MARGIN + 4, ly), "图例", font=F(19, True), fill=C_TITLE)
d.rectangle((MARGIN + 74, ly + 5, MARGIN + 96, ly + 22), fill=C_TRACK)
d.text((MARGIN + 104, ly + 2), "循迹输入（进 1A bank，1.8V）", font=F(18), fill=C_NOTE)
d.rectangle((MARGIN + 414, ly + 5, MARGIN + 436, ly + 22), fill=C_POWER)
d.text((MARGIN + 444, ly + 2), "电源 / 地", font=F(18), fill=C_NOTE)
d.rectangle((MARGIN + 564, ly + 5, MARGIN + 586, ly + 22), fill=C_OFF)
d.text((MARGIN + 594, ly + 2), "本工程不用", font=F(18), fill=C_NOTE)

d.rounded_rectangle((PANEL_X0, _panel_top, PANEL_X1, H - 40), radius=14,
                    fill="#eef4fc", outline="#b7cdea", width=2)
d.text((PANEL_X0 + 28, _panel_top + 20), "接 线 要 点", font=F(22, True), fill="#1a4d8f")
panel_items(d, MUX_ITEMS, PANEL_X0 + 36, PANEL_X0 + 68, _panel_top + 56,
            PANEL_X1 - PANEL_X0 - 72, head_col="#123a66", body_col="#33517a",
            num_col="#2e6bb0")

p2 = os.path.join(OUT, "YB-MUX04接线图.png")
img.save(p2)
print("wrote", p2, os.path.getsize(p2))


# =====================================================================
# 图 1：TB6612FNG
# =====================================================================
W = 1720
MARGIN = 56
PANEL_X0, PANEL_X1 = MARGIN, W - MARGIN

TB_ITEMS = [
    ("①", "VCC 接 D3V3（pin 29），绝不能接 D5V0（pin 11）",
     "TB6612 的 VIH = VCC × 0.7。VCC = 5 V 时门限 3.5 V，而排针外侧只有 3.3 V —— 逻辑高不被保证识别；"
     "VCC = 3.3 V 时门限 2.31 V，留约 1 V 余量。"),
    ("②", "STBY 必须接 User_IO24，不能悬空",
     "悬空时芯片状态不定。本设计复位后默认输出 0 = 待机，上电不会乱转，这是安全默认。"),
    ("③", "同侧两电机先各自单独试转向",
     "接反只是反转、不会烧，但两个轮子对打会让循迹彻底失效 —— 先单轮点动确认方向再并联。"),
    ("④", "VM 单独接电池；每通道 1.2 A 连续 / 3.2 A 峰值",
     "单侧两轮并联正常 1 A 以内没事；任一轮卡住时单侧可能越过 3.2 A 触发 175 ℃ 热保护，"
     "现象是「跑着跑着突然不动，凉了又能动」—— 先摸芯片温度，不要先怀疑代码。"),
]

_panel_top = 1252
_probe_img2 = Image.new("RGB", (W, 4000), "white")
_pd2 = ImageDraw.Draw(_probe_img2)
_end2 = panel_items(_pd2, TB_ITEMS, PANEL_X0 + 36, PANEL_X0 + 68, _panel_top + 56,
                    PANEL_X1 - PANEL_X0 - 72)
H = _end2 + 56

img = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(img)

d.text((MARGIN + 4, 42), "TB6612FNG 双路 H 桥模块 · 引脚配置与接线", font=F(46, True), fill=C_TITLE)
d.text((MARGIN + 4, 108),
       "16 脚（每侧 8 脚）· 左侧 = 逻辑控制，右侧 = 电源与电机 · FPGA 侧 1.8V bank，经 TXS0108E 到排针外侧 3.3V",
       font=F(20), fill=C_SUB)

BX0, BX1 = 610, 1110
BY0, BY1 = 210, 1170
PIN_Y0, PIN_STEP = 268, 120

d.text((BX0 - 50, 175), "DC3-40 排针（P4）", font=F(19, True), fill=C_MOTOR, anchor="ra")
d.text((BX1 + 50, 175), "电源 / 电机", font=F(19, True), fill=C_POWER, anchor="la")
d.text(((BX0 + BX1) // 2, BY0 - 26), "TB6612FNG 模块（实物丝印）",
       font=F(19), fill=C_SUB, anchor="mm")

d.rounded_rectangle((BX0, BY0, BX1, BY1), radius=16, fill="#c0392b", outline="#8e2a1e", width=3)

LEFTS = [
    ("PWMA", "ml_pwm", "User_IO20 · J1 · pin 23", C_MOTOR),
    ("AIN2", "ml_in2", "User_IO19 · M1 · pin 22", C_MOTOR),
    ("AIN1", "ml_in1", "User_IO18 · L1 · pin 21", C_MOTOR),
    ("STBY", "motor_stby", "User_IO24 · F2 · pin 27", C_MOTOR),
    ("BIN1", "mr_in1", "User_IO21 · K1 · pin 24", C_MOTOR),
    ("BIN2", "mr_in2", "User_IO22 · G1 · pin 25", C_MOTOR),
    ("PWMB", "mr_pwm", "User_IO23 · H1 · pin 26", C_MOTOR),
    ("GND", "GND", "pin 12 / 30", C_POWER),
]
RIGHTS = [
    ("VM", "电池 +7.4 V（2S 锂电）", "4.5–13.5 V，绝对最大 15 V；不从 D3V3 / D5V0 取", C_POWER),
    ("VCC", "D3V3 · pin 29", "★ 绝不能接 D5V0（pin 11），见下方 ①", C_POWER),
    ("GND", "GND · pin 12 / 30", "与电池负极共地", C_POWER),
    ("AO1", "左电机 M+", "A 通道，同侧两轮并联", C_MOTOR),
    ("AO2", "左电机 M−", "A 通道", C_MOTOR),
    ("BO2", "右电机 M−", "B 通道", C_MOTOR),
    ("BO1", "右电机 M+", "B 通道，同侧两轮并联", C_MOTOR),
    ("GND", "GND", "电机侧地", C_POWER),
]

for i, (sk, nm, info, col) in enumerate(LEFTS):
    y = PIN_Y0 + i * PIN_STEP
    d.line((BX0 - 44, y, BX0, y), fill=col, width=4)
    d.ellipse((BX0 - 9, y - 9, BX0 + 9, y + 9), fill=col)
    d.text((BX0 + 24, y), sk, font=F(24, True), fill="white", anchor="lm")
    d.text((BX0 - 60, y - 14), nm, font=F(27, True), fill=col, anchor="rm")
    d.text((BX0 - 60, y + 16), info, font=F(16), fill=C_NOTE, anchor="rm")

for i, (sk, nm, note, col) in enumerate(RIGHTS):
    y = PIN_Y0 + i * PIN_STEP
    d.line((BX1, y, BX1 + 44, y), fill=col, width=4)
    d.ellipse((BX1 - 9, y - 9, BX1 + 9, y + 9), fill=col)
    d.text((BX1 - 24, y), sk, font=F(24, True), fill="white", anchor="rm")
    d.text((BX1 + 60, y - 14), nm, font=F(24, True), fill=col, anchor="lm")
    d.text((BX1 + 60, y + 16), note, font=F(16), fill=C_NOTE, anchor="lm")

ly = 1215
d.text((MARGIN + 4, ly), "图例", font=F(19, True), fill=C_TITLE)
d.rectangle((MARGIN + 74, ly + 5, MARGIN + 96, ly + 22), fill=C_MOTOR)
d.text((MARGIN + 104, ly + 2), "电机控制 / 电机输出", font=F(18), fill=C_NOTE)
d.rectangle((MARGIN + 314, ly + 5, MARGIN + 336, ly + 22), fill=C_POWER)
d.text((MARGIN + 344, ly + 2), "电源 / 地", font=F(18), fill=C_NOTE)
d.text((MARGIN + 464, ly + 2),
       "方向逻辑：IN1/IN2 互补，永不同时为 1（否则刹车短路）；PWM 由 pwm_gen 出 20 kHz",
       font=F(18), fill=C_NOTE)

d.rounded_rectangle((PANEL_X0, _panel_top, PANEL_X1, H - 40), radius=14,
                    fill="#fdf6e3", outline="#e0cf9a", width=2)
d.text((PANEL_X0 + 28, _panel_top + 20), "接 线 前 必 读", font=F(22, True), fill="#8a6d1f")
panel_items(d, TB_ITEMS, PANEL_X0 + 36, PANEL_X0 + 68, _panel_top + 56,
            PANEL_X1 - PANEL_X0 - 72)

p1 = os.path.join(OUT, "TB6612接线图.png")
img.save(p1)
print("wrote", p1, os.path.getsize(p1))


# =====================================================================
# 图 3：HC-SR04 超声波测距模块（4 脚）
# =====================================================================
W = 1720
MARGIN = 56
PANEL_X0, PANEL_X1 = MARGIN, W - MARGIN

C_HC = "#0f7b6c"

MB_X0, MB_X1 = 560, 940
MB_Y0, MB_Y1 = 200, 700
PIN_YS = [270, 390, 510, 630]

HC_PINS = [
    ("Vcc", "HC-SR04 · Vcc",
     "5 V（车载 DC-DC 那一路）· 约 15 mA 峰值\n接 D3V3 只有 3.3 V，量程会掉到 1 m 以内", C_POWER),
    ("Trig", "hc_trig",
     "User_IO10 · G4 · pin 13 · 1B bank 1.8V\n3.3 V 直驱，脉宽 15 µs（规格要求 ≥10 µs）", C_HC),
    ("Echo", "hc_echo",
     "1 kΩ / 2 kΩ 分压 → User_IO11 · G3 · pin 14\n★ 模块输出 5 V，直连超 TXS0108E 的 4.6 V 绝对最大", C_HC),
    ("Gnd", "GND",
     "pin 12 / 30 · 与 Ti60 板共地\n电机功率地与信号地单点相接", C_POWER),
]

HC_ITEMS = [
    ("①", "先看丝印，别按位置插",
     "本模块自上而下是 Vcc / Trig / Echo / Gnd（照片已确认）。克隆板有把 Trig 和 Echo 对调的版本，"
     "接反不会烧（一个输入一个输出），但串口会一直 D=---cm，很容易误判成模块坏了。"),
    ("②", "Echo 必须分压，1 kΩ 串 + 2 kΩ 下地",
     "5 V × 2 k / (1 k + 2 k) = 3.33 V，正好落在 3.3 V 侧合法区间（高门限约 2.3 V，绝对最大 4.6 V）。"
     "手上只有 2.2 kΩ 的话输出 3.44 V，仍然安全。别用 1 kΩ+1 kΩ（2.5 V 余量太小，"
     "也别用 10 kΩ 级——TXS0108E 靠边沿加速，驱动太弱会让上升沿变慢）。"),
    ("③", "5 V 从车载 DC-DC 取，不要从 D3V3 取",
     "HC-SR04 要 5 V 才能保证 4 m 量程。D5V0（pin 11）在引脚表里标的是「5V 电源输入」，"
     "接之前先用万用表确认本板该脚真的有 5 V 输出，再挂负载；没有就并入 DC-DC 的 5 V。"),
    ("④", "探头装车头正中、离地 8~15 cm、略下倾 5°~10°",
     "hc_sr04.v 每 60 ms 测一次（PERIOD_US = 60_000，约 16.7 Hz），顶层判 obstacle = dist_cm ≤ 25 cm。"
     "锥角约 15°，两侧 25 cm 内的斜墙也算障碍；平装容易收到地面回波，读数会莫名其妙地一直很近。"),
    ("⑤", "串口一直 D=---cm 时按这个顺序查",
     "① 量模块 Vcc 是否 ≥4.6 V；② 量 Trig 是否有 15 µs 高脉冲；③ 量分压节点是否在 3.0~3.4 V；"
     "④ 都正常还不跳数，先并一个 100 nF 到 Vcc-GND 再试，最后才换模块（HC-SR04 批次差异大）。"),
]

_probe_img3 = Image.new("RGB", (W, 4000), "white")
_pd3 = ImageDraw.Draw(_probe_img3)
_panel_top3 = 800
_end3 = panel_items(_pd3, HC_ITEMS, PANEL_X0 + 36, PANEL_X0 + 68, _panel_top3 + 56,
                    PANEL_X1 - PANEL_X0 - 72)
H = _end3 + 56

img = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(img)

d.text((MARGIN + 4, 42), "HC-SR04 超声波测距模块 · 引脚配置与接线", font=F(46, True), fill=C_TITLE)
d.text((MARGIN + 4, 108),
       "4 脚（自上而下 Vcc / Trig / Echo / Gnd）· Trig 3.3 V 直驱 · Echo 5 V 必须 1k/2k 分压到 3.33 V",
       font=F(20), fill=C_SUB)

# ---- 模块本体 ----
d.text(((MB_X0 + MB_X1) // 2, MB_Y0 - 26), "模块实物（丝印顺序）", font=F(19), fill=C_SUB, anchor="mm")
d.rounded_rectangle((MB_X0, MB_Y0, MB_X1, MB_Y1), radius=18, fill="#1f5fa8", outline="#143f72", width=3)
d.text((MB_X0 + 132, MB_Y0 + 36), "HC-SR04", font=F(26, True), fill="white", anchor="mm")
for cy in (340, 570):
    d.ellipse((762, cy - 62, 886, cy + 62), fill="#cbd1d8", outline="#6b737c", width=3)
    d.ellipse((784, cy - 40, 864, cy + 40), fill="#8f979f", outline="#5b626a", width=2)
    d.ellipse((816, cy - 8, 832, cy + 8), fill="#5b626a")

for i, (sk, net, detail, col) in enumerate(HC_PINS):
    y = PIN_YS[i]
    d.line((440, y, MB_X0 - 40, y), fill=col, width=4)
    d.line((MB_X0 - 40, y, MB_X0, y), fill=col, width=6)
    d.ellipse((MB_X0 - 11, y - 11, MB_X0 + 11, y + 11), fill="white", outline=col, width=3)
    d.text((MB_X0 + 26, y), sk, font=F(24, True), fill="white", anchor="lm")
    d.text((60, y - 50), net, font=F(25, True), fill=col)
    draw_wrapped(d, (60, y - 22), detail, 16, 356, C_NOTE)

# ---- Echo 分压小电路 ----
d.rounded_rectangle((1000, 230, 1664, 690), radius=14, fill="#f0f6f4", outline="#a9cfc6", width=2)
d.text((1030, 248), "Echo 分压网络（必须接）", font=F(21, True), fill="#0b5a4f")
d.text((1030, 286), "模块 5 V 输出 → 排针 3.3 V 侧，分压后 3.33 V", font=F(16), fill="#3d6b62")

WIRE_Y = 400
d.line((1040, WIRE_Y, 1128, WIRE_Y), fill=C_HC, width=4)
d.rounded_rectangle((1128, WIRE_Y - 18, 1228, WIRE_Y + 18), radius=6, fill="white", outline=C_HC, width=3)
d.text((1178, WIRE_Y), "1 kΩ", font=F(16, True), fill=C_HC, anchor="mm")
d.line((1228, WIRE_Y, 1640, WIRE_Y), fill=C_HC, width=4)
d.ellipse((1282, WIRE_Y - 7, 1296, WIRE_Y + 7), fill=C_HC)
d.line((1289, WIRE_Y, 1289, 440), fill=C_HC, width=4)
d.rounded_rectangle((1271, 440, 1307, 528), radius=6, fill="white", outline=C_HC, width=3)
d.line((1289, 528, 1289, 566), fill=C_HC, width=4)
for w, yy in ((64, 566), (40, 574), (18, 582)):
    d.line((1289 - w // 2, yy, 1289 + w // 2, yy), fill=C_HC, width=4)
d.text((1318, 452), "R2  2 kΩ", font=F(17, True), fill=C_HC)
d.text((1318, 480), "下地", font=F(15), fill="#3d6b62")
d.text((1040, 356), "Echo（5 V）", font=F(18, True), fill=C_HC)
d.text((1320, 348), "User_IO11 · G3 · pin 14", font=F(18, True), fill=C_HC)
d.text((1320, 420), "分压后 3.33 V", font=F(16), fill="#3d6b62")
d.text((1030, 616), "5 V × 2k/(1k+2k) = 3.33 V　·　TXS0108E B 侧绝对最大 4.6 V", font=F(15), fill="#3d6b62")
d.text((1030, 646), "两个电阻都用 1/4 W 金属膜即可，误差 1% 更稳", font=F(15), fill="#3d6b62")

# ---- 图例 ----
ly = 738
d.text((MARGIN + 4, ly), "图例", font=F(19, True), fill=C_TITLE)
d.rectangle((MARGIN + 74, ly + 5, MARGIN + 96, ly + 22), fill=C_HC)
d.text((MARGIN + 104, ly + 2), "测距信号（Trig 输出 / Echo 输入）", font=F(18), fill=C_NOTE)
d.rectangle((MARGIN + 470, ly + 5, MARGIN + 492, ly + 22), fill=C_POWER)
d.text((MARGIN + 500, ly + 2), "电源 / 地", font=F(18), fill=C_NOTE)
d.text((MARGIN + 660, ly + 2),
       "模块 Vcc 接 5 V、Echo 经 1k/2k 分压 —— 这两条搞错，串口就是永远 D=---cm",
       font=F(18), fill=C_NOTE)

d.rounded_rectangle((PANEL_X0, _panel_top3, PANEL_X1, H - 40), radius=14,
                    fill="#eefaf6", outline="#a9d8c9", width=2)
d.text((PANEL_X0 + 28, _panel_top3 + 20), "接 线 要 点", font=F(22, True), fill="#0b5a4f")
panel_items(d, HC_ITEMS, PANEL_X0 + 36, PANEL_X0 + 68, _panel_top3 + 56,
            PANEL_X1 - PANEL_X0 - 72, head_col="#0b4a41", body_col="#2f6157", num_col="#1a8a75")

p3 = os.path.join(OUT, "HC-SR04接线图.png")
img.save(p3)
print("wrote", p3, os.path.getsize(p3))
