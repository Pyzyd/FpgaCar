"""Plot manually measured OV5640 garage landmarks and replay the stop window."""

import argparse
import csv
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


WIDTH, HEIGHT = 1280, 720
CENTER_X, X_TOLERANCE = 640, 24
MIN_WIDTH, MAX_WIDTH = 980, 1160
MIN_MID_Y, MAX_MID_Y = 530, 605
MIN_SLOPE_DY, MAX_SLOPE_DY = 70, 145
EDGE_MARGIN = 32

# Hand-marked intersections of the tape centerlines, in the source image.
# A missing corner is outside the frame. This table is specific to this album.
LANDMARKS = (
    (None, (508, 534)),
    (None, (653, 542)),
    (None, (695, 547)),
    (None, (800, 548)),
    (None, (875, 555)),
    (None, (965, 563)),
    (None, (1062, 583)),
    ((100, 502), (1196, 610)),
    ((108, 505), (1205, 605)),
    ((70, 519), (1168, 631)),
    ((130, 519), (1222, 625)),
    ((235, 528), None),
    ((268, 537), None),
    ((351, 536), None),
    ((383, 536), None),
    ((497, 546), None),
    ((576, 557), None),
    ((170, 342), (1252, 399)),
)

COLORS = {
    "L": "#ffae61",
    "R": "#72dffc",
    "M": "#9ce985",
}
STATUS_COLORS = {
    "CENTER": "#9ce985",
    "OFF CENTER": "#ffcc73",
    "ONE CORNER": "#ced6e1",
    "GEOMETRY": "#ffc1a9",
}


def classify(left, right):
    if left is None or right is None:
        return "ONE CORNER"
    xl, yl = left
    xr, yr = right
    if not (
        EDGE_MARGIN <= xl < xr < WIDTH - EDGE_MARGIN
        and MIN_WIDTH <= xr - xl <= MAX_WIDTH
        and 2 * MIN_MID_Y <= yl + yr <= 2 * MAX_MID_Y
        and MIN_SLOPE_DY <= yr - yl <= MAX_SLOPE_DY
    ):
        return "GEOMETRY"
    if abs(xl + xr - 2 * CENTER_X) > 2 * X_TOLERANCE:
        return "OFF CENTER"
    return "CENTER"


def annotation(photo, left, right):
    # Draw on a new figure and keep the acquired image untouched.
    figure = photo.convert("RGBA")
    marks = Image.new("RGBA", figure.size)
    draw = ImageDraw.Draw(marks)
    draw.rectangle(
        (CENTER_X - X_TOLERANCE, 0, CENTER_X + X_TOLERANCE, HEIGHT - 1),
        fill=(156, 233, 133, 40),
    )
    for x in (CENTER_X - X_TOLERANCE, CENTER_X + X_TOLERANCE):
        draw.line((x, 0, x, HEIGHT - 1), fill=(156, 233, 133, 140), width=2)
    for y in range(0, HEIGHT, 30):
        draw.line((CENTER_X, y, CENTER_X, y + 15), fill=COLORS["M"], width=2)

    points = [("L", left), ("R", right)]
    if left is not None and right is not None:
        midpoint = tuple((a + b) / 2 for a, b in zip(left, right))
        draw.line((left, right), fill=(240, 248, 255, 160), width=3)
        points.append(("M", midpoint))

    font = ImageFont.load_default(size=28)
    for name, point in points:
        if point is None:
            continue
        x, y = point
        draw.ellipse((x - 11, y - 11, x + 11, y + 11), outline=COLORS[name], width=4)
        draw.point((round(x), round(y)), fill=COLORS[name])
        label = f"{name} ({x:g}, {y:g})"
        tw = draw.textlength(label, font=font)
        tx = max(8, min(x - tw / 2, WIDTH - tw - 14))
        draw.text((tx, y - 44), label, font=font, fill=COLORS[name],
                  stroke_width=2, stroke_fill="#14181c")
    return Image.alpha_composite(figure, marks).convert("RGB")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("album", type=Path, help="parking-calibration album with 01.png to 18.png")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    tile_w, tile_h = 420, 236
    column_gap, row_gap, label_h = 10, 10, 30
    index = Image.new("RGB", (3 * (tile_w + column_gap) + column_gap,
                             6 * (tile_h + label_h + row_gap) + row_gap), "#182028")
    labels = ImageDraw.Draw(index)
    font = ImageFont.load_default(size=19)

    with (args.output / "landmarks.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(("frame", "left_x", "left_y", "right_x", "right_y",
                         "mid_x", "mid_y", "width_x", "single_frame_result"))
        for i, (left, right) in enumerate(LANDMARKS, 1):
            filename = f"{i:02}.png"
            with Image.open(args.album / filename) as photo:
                if photo.size != (WIDTH, HEIGHT):
                    raise ValueError(f"{filename} must be {WIDTH}x{HEIGHT}, got {photo.size}")
                marked = annotation(photo, left, right)
            status = classify(left, right)
            if left is None or right is None:
                mid = ("", "", "")
            else:
                mid = ((left[0] + right[0]) / 2, (left[1] + right[1]) / 2, right[0] - left[0])
            writer.writerow((filename, *(left or ("", "")), *(right or ("", "")), *mid, status))
            col, row = (i - 1) % 3, (i - 1) // 3
            tx = column_gap + col * (tile_w + column_gap)
            ty = row_gap + row * (tile_h + label_h + row_gap)
            index.paste(marked.resize((tile_w, tile_h), Image.Resampling.LANCZOS), (tx, ty))
            labels.text((tx + 6, ty + tile_h + 3), f"{i:02}   {status}",
                        font=font, fill=STATUS_COLORS[status])
            if i == 8:
                marked.save(args.output / "reference_08.png")
    index.save(args.output / "overview.png")


if __name__ == "__main__":
    main()
