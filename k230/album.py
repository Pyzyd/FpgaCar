"""Append-only session album. Raw JPEGs never contain preview annotations."""
import os
import json


def mkdir(path):
    try:
        os.mkdir(path)
    except OSError:
        # Ignore existing directory only, not full card / permission failures.
        if not (os.stat(path)[0] & 0x4000):
            raise


class Album:
    def __init__(self, root, min_free=16*1024*1024):
        mkdir(root)
        self.root, self.min_free = root, min_free
        n = 1
        while True:
            self.path = root + "/session_%04d" % n
            try:
                os.stat(self.path)
            except OSError:
                os.mkdir(self.path)
                break
            n += 1
        self.count = 0

    def save(self, img, label, metadata):
        stat = os.statvfs(self.root)
        if stat[0] * stat[4] < self.min_free:
            raise OSError("SD space low; capture stopped")
        self.count += 1
        name = "%05d_%s.jpg" % (self.count, label)
        path = self.path + "/" + name
        try:
            img.save(path, quality=95)
        except Exception:
            # A failed save must never appear as a completed album entry.
            try:
                os.remove(path)
            except OSError:
                pass
            raise
        record = dict(metadata)
        record.update({"file": name, "label": label, "width": img.width(), "height": img.height()})
        with open(self.path + "/index.jsonl", "a") as f:
            f.write(json.dumps(record) + "\n")
        if hasattr(os, "sync"):
            os.sync()
        return path

    def photos(self):
        # All sessions, including previous boots; no delete control on the board.
        paths = []
        for session in sorted(os.listdir(self.root)):
            if session.startswith("session_"):
                folder = self.root + "/" + session
                for name in sorted(os.listdir(folder)):
                    if name.endswith(".jpg"):
                        paths.append(folder + "/" + name)
        return paths
