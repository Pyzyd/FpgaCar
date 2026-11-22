"""Recognize a white P on the blue parking sign, including oblique views."""

from turn_shape import iou, largest_component, normalize


P_SHAPE = tuple(tuple(c == '#' for c in row) for row in (
    '..##########....',
    '.##############.',
    '#####....######.',
    '####......######',
    '####.......#####',
    '####.......#####',
    '####.......#####',
    '####......######',
    '###############.',
    '#############...',
    '#####...........',
    '####............',
    '####............',
    '####............',
    '####............',
    '####............',
))


def glyph_mask(get_pixel, box):
    x, y, w, h = box
    cols, rows = min(26, w), min(32, h)
    mask = [bytearray(cols) for _ in range(rows)]
    # Ignore the white border. Sampling into the same grid removes horizontal foreshortening.
    for row in range(rows//8, rows-rows//8):
        py = y+(2*row+1)*h//(2*rows)
        for col in range((cols+4)//9, cols-(cols+4)//9):
            px = x+(2*col+1)*w//(2*cols)
            rgb = get_pixel(px, py)
            if rgb is not None:
                lo = min(rgb)
                mask[row][col] = lo>=86 and max(rgb)-lo<=70
    glyph, area = largest_component(mask)
    if .09<=area/(cols*rows)<=.42:
        return normalize(glyph, size=16)
    return None


def select(width, height, get_pixel, blue_regions):
    candidates = []
    for x, y, w, h, pixels in blue_regions:
        if w<14 or h<36 or not .26<=w/h<=1.05:
            continue
        if x<2 or y<2 or x+w>width-2 or y+h>height-2:
            continue
        if .38<=pixels/(w*h)<=.86:
            candidates.append((x, y, w, h))
    candidates.sort(key=lambda box: box[2]*box[3], reverse=True)

    best = {'label':'unknown', 'box':None, 'score':0., 'present':False}
    for box in candidates[:4]:
        glyph = glyph_mask(get_pixel, box)
        if glyph is None:
            continue
        # The upper loop has white strokes on both sides of the blue opening.
        loop_rows = sum(any(row[:4]) and not any(row[6:10]) and any(row[11:])
                        for row in glyph[3:8])
        if loop_rows<2:
            continue
        score = iou(glyph, P_SHAPE)
        if score>=.68 and score>best['score']:
            best = {'label':'P', 'box':box, 'score':score, 'present':True}
    return best
