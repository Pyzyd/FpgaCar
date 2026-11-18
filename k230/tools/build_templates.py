"""Desktop: regenerate shape templates from the supplied sign photographs."""
import argparse
import hashlib
import pathlib
import sys
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from arrow_core import extract_mask, normalize


def blue_box(img):
    # Desktop fixture locator; deployment uses CanMV LAB find_blobs instead.
    points = [(x, y) for y in range(0, img.height, 3) for x in range(0, img.width, 3)
              if (lambda c: c[2] > c[0]*1.3 and c[2] > c[1]*1.15 and c[2] > 40)(img.getpixel((x,y))) ]
    x0, x1 = min(x for x,y in points), max(x for x,y in points)
    y0, y1 = min(y for x,y in points), max(y for x,y in points)
    return x0, y0, x1-x0+1, y1-y0+1


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--left", required=True)
    p.add_argument("--right", required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()
    text = ['# Generated from user-provided reference photos; not an AI model.', 'TEMPLATES = {']
    for label in ("left", "right"):
        source = pathlib.Path(getattr(args, label))
        img = Image.open(source).convert("RGB")
        mask, count = extract_mask(lambda x,y: img.getpixel((x,y)), blue_box(img))
        norm = normalize(mask)
        if norm is None or count < 25:
            raise ValueError("No arrow in " + label)
        text.append('    # %s SHA256 %s' % (label, hashlib.sha256(source.read_bytes()).hexdigest()))
        text.append('    "%s": [[' % label)
        for row in norm:
            text.append('        bytearray(%r),' % list(row))
        text.append('    ]],')
    text.append('}\n')
    pathlib.Path(args.output).write_text('\n'.join(text), encoding='utf-8')


if __name__ == '__main__':
    main()
