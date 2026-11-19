"""Generate the P4 numbered diagram from docs/引脚分配表.md (no hand-copied pin list)."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parents[1]
rows={}
for line in (ROOT/'docs/引脚分配表.md').read_text(encoding='utf-8').splitlines():
    if not line.startswith('|'): continue
    cells=[s.strip().replace('**','').replace('`','') for s in line.strip('|').split('|')]
    if len(cells)!=6 or not cells[0].isdigit(): continue
    rows[int(cells[0])]=cells
assert set(rows)==set(range(1,41))
im=Image.new('RGB',(1500,1290),'#f5f7fa')
d=ImageDraw.Draw(im)
def font(size,bold=False):
    return ImageFont.truetype('C:/Windows/Fonts/msyh%s.ttc'%('bd' if bold else ''),size)
def text(x,y,s,size=20,color='#243447',bold=False): d.text((x,y),s,font=font(size,bold),fill=color)
text(55,30,'Ti60 P4 固定接线与 LCD 预留',36,bold=True)
text(55,85,'2026-11-17 · 按工程约束核对；示意编号不代表实物朝向，以 pin1 丝印为准',21)
text(55,122,'K230：D0=28 / D1=33 / D2=34 / STB=39；GND=30（K230 排针 pin4）',23,'#12638c',True)
text(55,160,'LCD：SCLK=35 / MOSI=36 / DC=37 / RST=38 / CS=40（仅预留，尚未实现）',23,'#8b5c00',True)
text(55,200,'排针 User_IO 外侧3.3V，FPGA侧1.8V；K230输出电平首次接线前须实测',22,'#b33b36')
text(72,248,'奇数列',24,bold=True);text(823,248,'偶数列',24,bold=True)
for n in range(1,41):
    row=rows[n]
    x=55 if n%2 else 805
    y=292+((n-1)//2)*44
    is_comm=n in (28,33,34,39)
    is_lcd=n in (35,36,37,38,40)
    is_power=n in (11,12,29,30)
    bg='#dff1fc' if is_comm else '#fff0c9' if is_lcd else '#fbe7e5' if is_power else 'white'
    d.rounded_rectangle((x,y,x+640,y+39),radius=6,fill=bg,outline='#d8dfe6')
    text(x+10,y+5,'%02d'%n,21,bold=True)
    text(x+58,y+6,row[1],18)
    signal=row[4]
    if signal=='—': signal='KEY复用 / 不外接'
    text(x+190,y+6,signal,18,bold=is_comm or is_lcd)
    if is_comm: note={28:'K230 GPIO42',33:'K230 GPIO43',34:'K230 GPIO34',39:'K230 GPIO35'}[n]
    elif is_lcd: note='SPI屏预留'
    elif n==2: note='核心板 K1 复位'
    else: note=row[2].split()[-1] if not is_power else '电源 / 地'
    text(x+420,y+6,note,17,'#586775')
text(55,1205,'蓝：K230通信　黄：SPI屏预留　红：电源/地；User_IO14–17保留给编码器。',21)
text(55,1240,'真源：FpgaCar.peri.xml + docs/引脚分配表.md；P4-1/2 与板载 K2/K1 复用。',19)
output=ROOT/'docs/引脚分配图.png'
im.save(output)
print(output)
