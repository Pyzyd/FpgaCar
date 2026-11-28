"""Run the field vision logic against saved JPEGs using approximate CanMV blobs."""

import argparse
from collections import Counter
from pathlib import Path
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

K230 = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(K230 / 'turn_verify'), str(K230)]
from field_vision import FieldVision
from replay_phone_photos import lab


class Blob:
    def __init__(self, box, area, code):
        self.box, self.area, self.channel = box, area, code

    def rect(self):
        return self.box

    def pixels(self):
        return self.area

    def code(self):
        return self.channel

    def x(self):
        return self.box[0]

    def y(self):
        return self.box[1]

    def w(self):
        return self.box[2]

    def h(self):
        return self.box[3]


class DesktopFrame:
    def __init__(self, path):
        with Image.open(path) as im:
            rgb = np.asarray(im.convert('RGB').resize((640, 360), Image.Resampling.LANCZOS))
        self.rgb = rgb & np.array([248, 252, 248], dtype=np.uint8)
        self.lab = lab(self.rgb)

    def width(self):
        return self.rgb.shape[1]

    def height(self):
        return self.rgb.shape[0]

    def get_pixel(self, x, y):
        return self.rgb[y, x].tolist()

    def find_blobs(self, thresholds, roi=(0, 0, 640, 360), pixels_threshold=0, area_threshold=0, **kwargs):
        dx, dy, width, height = roi
        values = self.lab[dy:dy+height, dx:dx+width]
        blobs = []
        for index, threshold in enumerate(thresholds):
            bounds = np.asarray(threshold).reshape(3, 2)
            mask = ((values >= bounds[:, 0]) & (values <= bounds[:, 1])).all(axis=-1)
            regions, _ = ndimage.label(mask)
            areas = np.bincount(regions.ravel())
            for label, window in enumerate(ndimage.find_objects(regions), 1):
                if window is None or areas[label] < pixels_threshold:
                    continue
                y, x = window
                w, h = x.stop-x.start, y.stop-y.start
                if w*h >= area_threshold:
                    blobs.append(Blob((x.start+dx, y.start+dy, w, h), int(areas[label]), 1 << index))
        return blobs


def timestamp(photo):
    return int(photo.stem.split('_')[-1].removesuffix('ms'))


def replay(folder, vision=None, offset_ms=0):
    if vision is None:
        vision = FieldVision()
    paths = sorted(folder.glob('*.jpg'))
    if not paths:
        return None
    seen = Counter()
    events = []
    for photo in paths:
        now = offset_ms + timestamp(photo)
        state = vision.update(DesktopFrame(photo), now)
        seen[state['turn']['label']] += 1
        if state['parking']['label'] == 'P':
            seen['P'] += 1
        events.extend((now, event['kind'], event['label']) for event in state['events'])
    print(folder.parent.name, folder.name, len(paths), dict(seen), events,
          'uncertain=', vision.tracker.sequence_uncertain, flush=True)
    return events


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dataset', type=Path)
    parser.add_argument('--check-nov19', action='store_true', help='assert expected events for the eight site runs')
    args = parser.parse_args()
    runs = sorted({p.parent for p in args.dataset.rglob('*.jpg')})
    results = {}
    for run in runs:
        events = replay(run)
        results[run.name] = [(kind, label) for _,kind,label in events]
    if not results:
        parser.error('No JPEG field captures found')
    if args.check_nov19:
        ordered_colors = [('color', c) for c in ('green','blue','red','yellow')]
        parking = [('parking','P')]
        expected = {'run_0008':[], 'run_0010':[], 'run_0011':parking,
                    'run_0012':[('turn','left')], 'run_0013':[('turn','right')],
                    'run_0014':[], 'run_0015':parking, 'run_0016':[('turn','left')]}
        if results != expected:
            raise SystemExit(f'Field replay differs: {results!r}')
        paths = {run.name: run for run in runs}
        for turn_run, color_run in (('run_0012','run_0010'), ('run_0013','run_0014')):
            vision = FieldVision()
            replay(paths[turn_run], vision)
            offset = max(timestamp(p) for p in paths[turn_run].glob('*.jpg')) + 1000
            events = replay(paths[color_run], vision, offset)
            if [(kind,label) for _,kind,label in events] != ordered_colors:
                raise SystemExit(f'Wrong color sequence after {turn_run}: {events!r}')
        print('PASS: color-only runs stay gated, both turn signs unlock four colors, and two P runs work before any turn')


if __name__ == '__main__':
    main()
