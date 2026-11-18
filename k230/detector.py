import config as C
from arrow_core import extract_mask, classify
from arrow_templates import TEMPLATES


def detect(img):
    blobs = img.find_blobs([C.BLUE_LAB], pixels_threshold=250, area_threshold=500, merge=True)
    candidates = [b for b in blobs if b.w() >= C.MIN_SIGN_SIZE and b.h() >= C.MIN_SIGN_SIZE
                  and .65 <= b.w()/b.h() <= 1.5
                  and b.x() > 1 and b.y() > 1
                  and b.x()+b.w() < img.width()-1 and b.y()+b.h() < img.height()-1]
    candidates.sort(key=lambda b: b.w()*b.h(), reverse=True)
    results = []
    for b in candidates[:C.MAX_CANDIDATES]:
        box = b.rect()
        mask, count = extract_mask(img.get_pixel, box, C.SAMPLE_SIZE, C.WHITE_MIN, C.WHITE_SPREAD)
        result = classify(mask, TEMPLATES, C.MIN_IOU, C.MIN_MARGIN)
        # Reject tiny reflections and implausibly filled inner regions.
        if not .025 <= count/(C.SAMPLE_SIZE**2) <= .40:
            result["label"] = "unknown"
        result["box"] = box
        results.append(result)
    valid = [r for r in results if r["label"] != "unknown"]
    # Two different signs in view are ambiguous; let the car get closer.
    if len(set(r["label"] for r in valid)) > 1:
        return {"label": "unknown", "score": 0., "margin": 0., "box": None, "present": True}
    best = max(valid or results, key=lambda r: r["score"]) if results else {
        "label": "unknown", "score": 0., "margin": 0., "box": None}
    best["present"] = bool(candidates)
    return best
