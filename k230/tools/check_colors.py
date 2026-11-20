"""Desktop color-event/selection checks; LAB thresholds still need real camera tests."""
import pathlib
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
from color_core import ColorEncounter, choose_color
from color_detector import detect_colors, detect_multi_colors, roi_rect


class Blob:
    def __init__(self,code=1,x=200,y=130,w=60,h=60,pixels=2500):
        self.values=(code,x,y,w,h,pixels)
    def code(self): return self.values[0]
    def x(self): return self.values[1]
    def y(self): return self.values[2]
    def w(self): return self.values[3]
    def h(self): return self.values[4]
    def pixels(self): return self.values[5]
    def rect(self): return self.values[1:5]


class Frame:
    def __init__(self,blobs): self.blobs=blobs
    def width(self): return 640
    def height(self): return 360
    def find_blobs(self,thresholds,**kwargs):
        self.thresholds,self.args=thresholds,kwargs
        return self.blobs


class Checks(unittest.TestCase):
    def test_field_recovers_a_faded_face_but_stops_at_gray(self):
        for code, rgb in ((1,(101,87,88)),(8,(120,109,96))):
            with self.subTest(code=code):
                img = Frame([Blob(code,x=492,y=171,w=74,h=106,pixels=5000)])
                img.get_pixel = lambda x,y: rgb if x<640 else (123,123,123)
                hit = detect_multi_colors(img,field=True)['candidates'][0]
                self.assertEqual(hit['core_box'],(492,171,74,106))
                self.assertEqual(hit['box'],(492,171,148,106))
                self.assertTrue(hit['clipped'])

                img.get_pixel = lambda x,y: rgb if x<595 or x>=608 else (123,123,123)
                hit = detect_multi_colors(img,field=True)['candidates'][0]
                self.assertLessEqual(abs(hit['box'][0]+hit['box'][2]-595),2)
                self.assertFalse(hit['clipped'])

    def test_multi_mode_preserves_candidates_and_clipped_tracks(self):
        result=detect_multi_colors(Frame([Blob(1),Blob(2,x=300)]))
        self.assertEqual(len(result['candidates']),2)
        self.assertEqual(result['label'],'unknown')
        clipped=detect_multi_colors(Frame([Blob(1,x=610,w=30)]))
        self.assertEqual(len(clipped['candidates']),1)
        self.assertTrue(clipped['candidates'][0]['clipped'])
        many=detect_multi_colors(Frame([Blob(1)]*30))
        self.assertEqual(len(many['candidates']),24)
        self.assertEqual(many['candidate_overflow'],6)

    def test_time_confirm_flicker_and_hold(self):
        g=ColorEncounter(250,500)
        self.assertIsNone(g.update('red',True,0))
        self.assertIsNone(g.update('yellow',True,200))
        self.assertIsNone(g.update('red',True,220))
        self.assertIsNone(g.update('red',True,469))
        self.assertEqual(g.update('red',True,470),'red')
        for t in (500,800,1000,2000):
            self.assertIsNone(g.update('red',True,t))

    def test_repeated_color_requires_clear_gap(self):
        g=ColorEncounter(250,500)
        g.update('red',True,0)
        self.assertEqual(g.update('red',True,250),'red')
        g.update('unknown',False,300)
        g.update('unknown',False,600)  # Too short: same encounter must remain locked.
        g.update('red',True,650)
        self.assertIsNone(g.update('red',True,950))
        g.update('unknown',False,1000)
        g.update('unknown',False,1500)
        g.update('red',True,1550)
        self.assertEqual(g.update('red',True,1800),'red')

    def test_ambiguity_does_not_rearm(self):
        g=ColorEncounter(250,500)
        g.update('blue',True,0)
        self.assertEqual(g.update('blue',True,250),'blue')
        for t in (300,900,1500): g.update('unknown',True,t)
        g.update('green',True,1600)
        self.assertIsNone(g.update('green',True,1900))
        g.reset()
        g.update('green',True,2000)
        self.assertEqual(g.update('green',True,2250),'green')

    def test_multi_color_selection(self):
        r={'label':'red','pixels':2000}
        g={'label':'green','pixels':1800}
        self.assertIsNone(choose_color([r,g]))
        self.assertEqual(choose_color([r,{'label':'green','pixels':600}]),r)
        self.assertEqual(choose_color([r,{'label':'red','pixels':1800}]),r)

    def test_album_pause_is_not_a_new_encounter(self):
        g=ColorEncounter(250,500)
        g.update('red',True,0)
        self.assertEqual(g.update('red',True,250),'red')
        g.pause()
        self.assertTrue(g.latched)
        self.assertIsNone(g.update('red',True,10000))
        self.assertIsNone(g.update('red',True,10250))

    def test_color_codes_and_observation_roi(self):
        for code,label in ((1,'red'),(2,'green'),(4,'blue'),(8,'yellow')):
            img=Frame([Blob(code)])
            with patch('color_detector.looks_like_arrow',return_value=False):
                result=detect_colors(img)
            self.assertEqual(result['label'],label)
            self.assertEqual(result['roi'],(128,90,384,234))
            self.assertFalse(img.args['merge'])
        for blob in (Blob(x=128),Blob(w=10),Blob(pixels=100),Blob(code=3)):
            result=detect_colors(Frame([blob]))
            self.assertEqual(result['label'],'unknown')
            self.assertFalse(result['present'])

    def test_sign_veto_and_competing_targets(self):
        with patch('color_detector.looks_like_arrow',return_value=True):
            result=detect_colors(Frame([Blob(4)]))
            self.assertEqual(result['label'],'unknown')
            self.assertFalse(result['present'])
        result=detect_colors(Frame([Blob(1),Blob(2,x=300)]))
        self.assertEqual(result['label'],'unknown')
        self.assertTrue(result['present'])  # Real ambiguous targets still hold latch.

    def test_clipped_background_cannot_hold_latch(self):
        gate=ColorEncounter(250,500)
        gate.update('red',True,0)
        self.assertEqual(gate.update('red',True,250),'red')
        background=detect_colors(Frame([Blob(x=128)]))
        gate.update(background['label'],background['present'],300)
        gate.update(background['label'],background['present'],800)
        gate.update('green',True,850)
        self.assertEqual(gate.update('green',True,1100),'green')


if __name__=='__main__':
    unittest.main(verbosity=2)
