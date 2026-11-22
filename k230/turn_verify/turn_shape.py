"""Pure Python arrow geometry and temporal filter; also runs on desktop Python."""


def normalize(mask, size=24):
    points = [(x, y) for y, row in enumerate(mask) for x, v in enumerate(row) if v]
    if not points:
        return None
    x0 = min(p[0] for p in points)
    x1 = max(p[0] for p in points)
    y0 = min(p[1] for p in points)
    y1 = max(p[1] for p in points)
    return [bytearray(mask[min(y1, y0 + int((y + .5) * (y1-y0+1)/size))]
                      [min(x1, x0 + int((x + .5) * (x1-x0+1)/size))]
                      for x in range(size)) for y in range(size)]


def largest_component(mask):
    h, w = len(mask), len(mask[0])
    seen = set()
    best = []
    for y in range(h):
        for x in range(w):
            if not mask[y][x] or (x, y) in seen:
                continue
            seen.add((x, y))
            todo, component = [(x, y)], []
            while todo:
                px, py = todo.pop()
                component.append((px, py))
                for nx, ny in ((px-1, py), (px+1, py), (px, py-1), (px, py+1)):
                    if 0 <= nx < w and 0 <= ny < h and mask[ny][nx] and (nx, ny) not in seen:
                        seen.add((nx, ny))
                        todo.append((nx, ny))
            if len(component) > len(best):
                best = component
    result = [bytearray(w) for _ in range(h)]
    for x, y in best:
        result[y][x] = 1
    return result, len(best)


def extract_mask(get_pixel, box, sample=40, white_min=85, spread=65):
    """Sample inner ellipse to suppress the white circular border."""
    bx, by, bw, bh = box
    mask = [bytearray(sample) for _ in range(sample)]
    for y in range(sample):
        for x in range(sample):
            u, v = (x+.5)/sample, (y+.5)/sample
            if (2*u-1)**2 + (2*v-1)**2 > .78**2:
                continue
            rgb = get_pixel(bx + min(bw-1, int(u*bw)), by + min(bh-1, int(v*bh)))
            if rgb is not None and min(rgb) >= white_min and max(rgb)-min(rgb) <= spread:
                mask[y][x] = 1
    return largest_component(mask)


def iou(a, b):
    inter = union = 0
    for ar, br in zip(a, b):
        for av, bv in zip(ar, br):
            inter += bool(av and bv)
            union += bool(av or bv)
    return inter / union if union else 0.0


def classify(mask, templates, min_iou=.50, min_margin=.12):
    norm = normalize(mask)
    if norm is None:
        return {"label": "unknown", "score": 0.0, "margin": 0.0}
    scores = {}
    for label in ("left", "right"):
        scores[label] = max(iou(norm, t) for t in templates[label])
    label = max(scores, key=scores.get)
    score = scores[label]
    margin = abs(scores["left"] - scores["right"])
    return {"label": label if score >= min_iou and margin >= min_margin else "unknown",
            "score": score, "margin": margin}


class StableEvent:
    """One event per encounter. Only an absence interval rearms the event."""
    def __init__(self, confirm=4, rearm=8, labels=("left", "right")):
        self.confirm, self.rearm = confirm, rearm
        self.labels = labels
        self.reset()

    def reset(self):
        self.candidate, self.count, self.absent = "unknown", 0, 0
        self.latched = False
        self.stable = "unknown"

    def update(self, label, present=False):
        if label not in self.labels:
            self.count, self.candidate, self.stable = 0, "unknown", "unknown"
            self.absent = 0 if present else self.absent + 1
            if self.absent >= self.rearm:
                self.latched = False
            return None
        self.absent = 0
        self.count = self.count + 1 if label == self.candidate else 1
        self.candidate = label
        self.stable = label if self.count >= self.confirm else "unknown"
        if self.count >= self.confirm and not self.latched:
            self.latched = True
            return label
        return None
