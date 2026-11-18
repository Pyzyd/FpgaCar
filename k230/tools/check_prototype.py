"""Desktop checks. Optional --left/--right run supplied photos and perturbations.

These are development checks, NOT independent field accuracy measurements.
"""
import argparse
import ast
import json
import pathlib
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from arrow_core import classify, StableEvent, extract_mask
from arrow_templates import TEMPLATES
from album import Album


class Checks(unittest.TestCase):
    def test_letterbox_and_high_resolution_photo(self):
        import numpy as np
        # Load only pure/layout/capture functions without importing board APIs.
        tree = ast.parse(pathlib.Path(__file__).resolve().parents[1].joinpath('main.py').read_text(encoding='utf-8'))
        functions = [n for n in tree.body if isinstance(n, ast.FunctionDef)
                     and n.name in ('fit_geometry','map_box','rgb_bytes','copy_rgb888','letterbox','capture_photo')]
        class Frame:
            def __init__(self,w,h):
                self.w,self.h = w,h
                self.pixels = np.full((h,w,3),120,dtype=np.uint8)
            def width(self): return self.w
            def height(self): return self.h
            def to_rgb888(self,x_scale=1,y_scale=1):
                return Frame(int(self.w*x_scale),int(self.h*y_scale))
            def to_rgb565(self): return self
            def clear(self): self.pixels[:]=0
            def to_numpy_ref(self): return self.pixels
        c=types.SimpleNamespace(WIDTH=640,HEIGHT=480,PREVIEW_WIDTH=640,PREVIEW_HEIGHT=360,
                                PHOTO_WIDTH=1280,PHOTO_HEIGHT=720)
        ns={'COPY_BYTES_FAST':None,'C':c,'image':types.SimpleNamespace(RGB888=1,Image=lambda w,h,f:Frame(w,h)),
            'CAM_CHN_ID_0':0,'time':types.SimpleNamespace(ticks_ms=lambda:123),
            'detect':lambda im: {'label':'right','box':(100,50,80,90)}}
        exec(compile(ast.Module(body=functions,type_ignores=[]),'capture_helpers','exec'),ns)
        self.assertEqual(ns['fit_geometry'](640,360),(1.,0,60))
        self.assertEqual(ns['fit_geometry'](1280,720),(.5,0,60))
        self.assertEqual(ns['map_box']((100,50,80,90),1,1,0,60),(100,110,80,90))
        self.assertIsNone(ns['map_box'](None))
        canvas,_,_,_=ns['letterbox'](Frame(1280,720))
        self.assertTrue(np.all(canvas.pixels[:60]==0))
        self.assertTrue(np.all(canvas.pixels[60:420]==120))
        self.assertTrue(np.all(canvas.pixels[420:]==0))
        saved=[]
        album=types.SimpleNamespace(save=lambda photo,label,meta: saved.append((photo,label,meta)) or 'saved.jpg')
        channels=[]
        def snapshot(chn):
            channels.append(chn)
            return Frame(1280,720)
        sensor=types.SimpleNamespace(snapshot=snapshot)
        self.assertEqual(ns['capture_photo'](sensor,album,'right','far','right',7),'saved.jpg')
        self.assertEqual(channels,[0])
        self.assertEqual((saved[0][0].width(),saved[0][0].height()),(1280,720))
        self.assertEqual(saved[0][2]['prediction_size'],[640,360])
        self.assertEqual(saved[0][2]['photo_box'],(200,100,160,180))
        sensor.snapshot=lambda chn: Frame(640,360)
        with self.assertRaises(RuntimeError):
            ns['capture_photo'](sensor,album,'right','far','right',7)
        self.assertEqual(len(saved),1)  # Wrong size never silently saved as HD.

    def test_panel_pixel_blending(self):
        import numpy as np
        tree=ast.parse(pathlib.Path(__file__).resolve().parents[1].joinpath('main.py').read_text(encoding='utf-8'))
        node=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='panel')
        ns={'UI_ALPHA':128,'PANEL_SHIFT_FAST':None,'np':np}
        exec(compile(ast.Module(body=[node],type_ignores=[]),'panel','exec'),ns)
        pixels=np.full((480,640,3),240,dtype=np.uint8)
        view=types.SimpleNamespace(to_numpy_ref=lambda:pixels)
        ns['panel'](view,8,72,108,84,(20,40,65))
        expected=np.array([120,120,120],dtype=np.uint8)
        self.assertTrue(np.all(pixels[72:156,8:116]==expected))
        self.assertTrue(np.all(pixels[200,320]==240))
        # Both firmware paths must match, including odd values and saturation edges.
        for fast in (True,False):
            ns['PANEL_SHIFT_FAST']=fast
            pixels[72:156,8:116]=[1,127,255]
            ns['panel'](view,8,72,108,84,(20,40,65))
            self.assertTrue(np.all(pixels[72:156,8:116]==[0,63,127]))

    def test_rgb_byte_copy(self):
        import numpy as np
        tree=ast.parse(pathlib.Path(__file__).resolve().parents[1].joinpath('main.py').read_text(encoding='utf-8'))
        nodes=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in ('rgb_bytes','copy_rgb888')]
        ns={'COPY_BYTES_FAST':None}
        exec(compile(ast.Module(body=nodes,type_ignores=[]),'copy','exec'),ns)
        def frame(a):
            return types.SimpleNamespace(width=lambda:a.shape[1],height=lambda:a.shape[0],to_numpy_ref=lambda:a)
        dst=np.zeros((480,640,3),dtype=np.uint8)
        src=np.arange(360*640*3,dtype=np.uint8).reshape((360,640,3))
        ns['copy_rgb888'](frame(dst),frame(src),0,60)
        self.assertTrue(np.array_equal(dst[60:420],src))
        self.assertTrue(np.all(dst[:60]==0) and np.all(dst[420:]==0))
        small=src[:3,:5].copy()
        ns['copy_rgb888'](frame(dst),frame(small),13,17)
        self.assertTrue(np.array_equal(dst[17:20,13:18],small))
        ns['COPY_BYTES_FAST']=False
        dst[:]=0
        ns['copy_rgb888'](frame(dst),frame(src),0,60)
        self.assertTrue(np.array_equal(dst[60:420],src))
        with self.assertRaises(ValueError):
            ns['copy_rgb888'](frame(dst),frame(src),1,60)

    def test_negative_shapes(self):
        for mask in ([bytearray(24) for _ in range(24)],
                     [bytearray([1]*24) for _ in range(24)],
                     [bytearray(int((x-12)**2+(y-12)**2<80) for x in range(24)) for y in range(24)]):
            self.assertEqual(classify(mask, TEMPLATES)["label"], "unknown")

    def test_confirmation_and_rearm(self):
        g = StableEvent(3, 2)
        self.assertIsNone(g.update('left'))
        self.assertIsNone(g.update('right'))  # Flicker resets consecutive count.
        self.assertIsNone(g.update('right'))
        self.assertEqual(g.update('right'), 'right')
        self.assertIsNone(g.update('right'))  # Same encounter must not repeat.
        for _ in range(5):
            g.update('unknown', present=True)  # Blue sign still present, uncertain.
        for _ in range(3):
            self.assertIsNone(g.update('right'))
        g.update('unknown')
        g.update('unknown')
        g.update('right')
        g.update('right')
        self.assertEqual(g.update('right'), 'right')

    def test_album_sessions_and_metadata(self):
        class Frame:
            def save(self, path, quality):
                pathlib.Path(path).write_bytes(b'fixture')
            def width(self): return 640
            def height(self): return 480
        with tempfile.TemporaryDirectory() as root:
            # Windows Python has no statvfs; mock the board filesystem interface.
            with patch('album.os.statvfs', return_value=(4096,4096,99999,99999,99999), create=True):
                a, b = Album(root), Album(root)
                self.assertNotEqual(a.path, b.path)
                p = a.save(Frame(), 'left', {'prediction': {'label':'right'}, 'scene':'far'})
                self.assertEqual(b.photos(), [p])
                rec = json.loads(pathlib.Path(a.path, 'index.jsonl').read_text())
                self.assertEqual(rec['label'], 'left')  # Human truth not prediction.
                self.assertEqual(rec['prediction']['label'], 'right')
            with patch('album.os.statvfs', return_value=(4096,4096,0,0,0), create=True):
                with self.assertRaises(OSError):
                    a.save(Frame(), 'left', {})
                self.assertEqual(len(a.photos()), 1)


def photo_checks(left, right):
    from PIL import Image, ImageEnhance, ImageOps
    from build_templates import blue_box
    total = 0
    for label, path in (('left',left), ('right',right)):
        original = Image.open(path).convert('RGB')
        for scale in (1., .5, .25):
            for bright in (.65, 1., 1.25):
                for mirrored in (False, True):
                    img = original.resize((int(original.width*scale),int(original.height*scale)))
                    img = ImageEnhance.Brightness(img).enhance(bright)
                    if mirrored:
                        img = ImageOps.mirror(img)
                    expected = ('right' if label=='left' else 'left') if mirrored else label
                    mask, _ = extract_mask(lambda x,y: img.getpixel((x,y)), blue_box(img))
                    r = classify(mask, TEMPLATES)
                    if r['label'] != expected:
                        raise AssertionError((label, scale, bright, mirrored, r))
                    total += 1
    print('Reference-photo perturbations passed:', total,
          '(same source photos as templates; NOT field accuracy)')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--left')
    parser.add_argument('--right')
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Checks)
    if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
        sys.exit(1)
    if args.left and args.right:
        photo_checks(args.left, args.right)
