"""One color event per encounter; no global color deduplication."""
import time

COLORS = ("red", "green", "blue", "yellow")


def elapsed(now, started):
    return time.ticks_diff(now,started) if hasattr(time,"ticks_diff") else now-started


class ColorEncounter:
    def __init__(self, confirm_ms=250, clear_ms=500):
        self.confirm_ms, self.clear_ms = confirm_ms, clear_ms
        self.reset()

    def reset(self):
        self.candidate, self.stable = "unknown", "unknown"
        self.started = self.absent_since = None
        self.latched = False

    def pause(self):
        # Browsing photos is not evidence that the physical target has left.
        self.candidate, self.stable = "unknown", "unknown"
        self.started = self.absent_since = None

    def update(self, label, present, now):
        if label not in COLORS:
            self.candidate, self.stable, self.started = "unknown", "unknown", None
            if present:
                self.absent_since = None  # Ambiguous object still in observation area.
            elif self.absent_since is None:
                self.absent_since = now
            elif elapsed(now,self.absent_since) >= self.clear_ms:
                self.latched = False
            return None
        self.absent_since = None
        if label != self.candidate:
            self.candidate, self.started, self.stable = label, now, "unknown"
        if elapsed(now,self.started) < self.confirm_ms:
            return None
        self.stable = label
        if not self.latched:
            self.latched = True
            return label
        return None


def choose_color(candidates, dominance=1.6):
    """Reject different colors of comparable size; don't invent a spatial order."""
    ranked = sorted(candidates,key=lambda c:c["pixels"],reverse=True)
    if not ranked:
        return None
    first = ranked[0]
    for other in ranked[1:]:
        if other["label"] != first["label"] and first["pixels"] < other["pixels"]*dominance:
            return None
    return first
