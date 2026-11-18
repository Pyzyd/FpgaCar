"""Desktop replay of the detector with a LAB/blob approximation (Pillow + NumPy)."""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

from turn_detector import BLUE_LAB, PREVIEW_SIZE, select


def lab(rgb):
    v = rgb.astype(float) / 255
    v = np.where(v > .04045, ((v + .055) / 1.055) ** 2.4, v / 12.92)
    xyz = v @ np.array([[.4124564, .2126729, .0193339], [.3575761, .7151522, .1191920],
                        [.1804375, .0721750, .9503041]])
    xyz /= np.array([.95047, 1., 1.08883])
    f = np.where(xyz > .008856, xyz ** (1 / 3), 7.787 * xyz + 16 / 116)
    return np.stack((116 * f[:, :, 1] - 16, 500 * (f[:, :, 0] - f[:, :, 1]),
                     200 * (f[:, :, 1] - f[:, :, 2])), axis=-1)


def components(mask):
    h, w = mask.shape
    seen = np.zeros_like(mask)
    for y, x in zip(*np.where(mask)):
        if seen[y, x]:
            continue
        x, y = int(x), int(y)
        todo = [(x, y)]
        seen[y, x] = True
        x0 = x1 = x
        y0 = y1 = y
        n = 0
        while todo:
            xx, yy = todo.pop()
            n += 1
            x0, x1 = min(x0, xx), max(x1, xx)
            y0, y1 = min(y0, yy), max(y1, yy)
            for u, v in ((xx+1, yy), (xx-1, yy), (xx, yy+1), (xx, yy-1)):
                if 0 <= u < w and 0 <= v < h and mask[v, u] and not seen[v, u]:
                    seen[v, u] = True
                    todo.append((u, v))
        bw, bh = x1-x0+1, y1-y0+1
        if n >= 110 and bw * bh >= 300:
            yield x0, y0, bw, bh, n


def replay(img):
    rgb = np.asarray(img) & np.array([248, 252, 248], np.uint8)
    channels = lab(rgb)
    mask = np.ones(rgb.shape[:2], dtype=bool)
    for ch in range(3):
        mask &= (channels[:, :, ch] >= BLUE_LAB[ch * 2]) & (channels[:, :, ch] <= BLUE_LAB[ch * 2 + 1])
    h, w = mask.shape
    return select(w, h, lambda x, y: rgb[y, x].tolist(), components(mask))


def fit(path, pad=False):
    src = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    scale = Image.Resampling.LANCZOS
    if pad:
        return ImageOps.pad(src, PREVIEW_SIZE, method=scale, color=(112, 112, 112))
    return ImageOps.fit(src, PREVIEW_SIZE, method=scale)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site", type=Path)
    parser.add_argument("--left", type=Path, help="optional earlier unmirrored left reference")
    parser.add_argument("--bench", type=Path, help="optional archived K230 car_photos directory")
    args = parser.parse_args()
    expected_right = {"IMG_9690", "IMG_9698"}
    results = {}
    frames = {}
    for path in sorted(args.site.iterdir()):
        if path.suffix.lower() not in (".jpg", ".jpeg", ".png"):
            continue
        img = fit(path)
        result = replay(img)
        frames[path.stem] = img
        results[path.stem] = result
        print(path.name, result)
    assert expected_right.union({"IMG_9705"}).issubset(results)
    assert len(results) == 17, len(results)
    assert {name for name, result in results.items() if result["label"] == "right"} == expected_right
    assert not any(result["label"] == "left" for result in results.values())
    assert results["IMG_9705"]["reason"] == "far", results["IMG_9705"]
    for name in sorted(expected_right):
        result = replay(ImageOps.mirror(frames[name]))
        assert result["label"] == "left", (name, result)
    if args.left:
        result = replay(fit(args.left, pad=True))
        assert result["label"] == "left", result
    print("PASS: 17 site frames, 2 mirrored controls, far sign held back, left reference checked:", bool(args.left))
    if args.bench:
        expected = {("session_0017", "00003"): "left", ("session_0017", "00004"): "left",
                    ("session_0017", "00005"): "right"}
        found = {}
        files = sorted(args.bench.glob("*/*.jpg"))
        assert len(files) == 17, len(files)
        for path in files:
            result = replay(fit(path))
            if result["label"] != "unknown":
                found[(path.parent.name, path.name[:5])] = result["label"]
        assert found == expected, found
        print("PASS: archived K230 bench photos, 3 signs on a monitor and 14 other scenes")


if __name__ == "__main__":
    main()
