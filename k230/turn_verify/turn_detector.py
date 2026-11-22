"""Turn sign candidate selection, shared between the K230 and desktop replay."""

from turn_shape import extract_mask, classify
from turn_templates import TEMPLATES

BLUE_LAB = (0, 70, -20, 100, -128, -16)
PREVIEW_SIZE = (640, 360)
CANDIDATE_MIN = 20
CONFIRM_MIN = 36  # Short side in pixels after scaling to 640x360.
MAX_CANDIDATES = 4
MIN_IOU = .60
MIN_MARGIN = .15
LABELS = ("left", "right")


def empty(reason="search", present=False):
    return {"label": "unknown", "score": 0., "margin": 0., "box": None,
            "reason": reason, "present": present}


def select(width, height, get_pixel, blobs):
    """blobs is a sequence of (x, y, w, h, blue_pixels)."""
    candidates = []
    cut_off = False
    for x, y, w, h, pixels in blobs:
        if min(w, h) < CANDIDATE_MIN or not .60 <= w / h <= 1.60:
            continue
        if not .26 <= pixels / (w * h) <= .86:
            continue
        if x < 2 or y < 2 or x + w > width - 2 or y + h > height - 2:
            cut_off = True
            continue
        candidates.append((x, y, w, h))
    candidates.sort(key=lambda b: b[2] * b[3], reverse=True)
    valid = []
    best = None
    plausible = False
    for box in candidates[:MAX_CANDIDATES]:
        mask, area = extract_mask(get_pixel, box, sample=40, white_min=80, spread=68)
        if not 40 <= area <= 545:
            if best is None:
                best = empty("shape")
                best["box"] = box
            continue
        r = classify(mask, TEMPLATES, min_iou=MIN_IOU, min_margin=MIN_MARGIN)
        r["box"] = box
        r["reason"] = "candidate"
        if r["label"] in LABELS:
            plausible = True
            if min(box[2], box[3]) < CONFIRM_MIN:
                r["label"], r["reason"] = "unknown", "far"
            else:
                valid.append(r)
        else:
            r["reason"] = "shape"
            plausible = plausible or r["score"] >= .50
        if best is None or r["score"] > best["score"]:
            best = r

    if valid:
        if any(r["label"] != valid[0]["label"] for r in valid[1:]):
            return empty("ambiguous", True)
        best = max(valid, key=lambda r: r["score"])
    if best is None:
        return empty("partial" if cut_off else "search")
    best["present"] = plausible
    return best


def blue_regions(frame):
    blobs = frame.find_blobs([BLUE_LAB], x_stride=2, y_stride=2,
                             pixels_threshold=110, area_threshold=300, merge=False)
    return [(b.x(), b.y(), b.w(), b.h(), b.pixels()) for b in blobs]


def detect(frame):
    return select(frame.width(), frame.height(), frame.get_pixel, blue_regions(frame))
