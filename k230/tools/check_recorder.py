"""Recorder durability/limits checks on a temporary filesystem."""
import contextlib
import json
import pathlib
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
from run_recorder import RunRecorder


class Checks(unittest.TestCase):
    def setUp(self):
        self.clock=0
        self.free=100000
        self.context=contextlib.ExitStack()
        self.context.enter_context(patch('run_recorder.time.ticks_ms',lambda:self.clock,create=True))
        self.context.enter_context(patch('run_recorder.time.ticks_diff',lambda a,b:a-b,create=True))
        self.context.enter_context(patch('run_recorder.os.uname',lambda:('test','test','test','test','test'),create=True))
        self.context.enter_context(patch('run_recorder.os.statvfs',lambda p:(4096,4096,self.free,self.free,self.free),create=True))
        self.context.enter_context(patch('run_recorder.os.sync',lambda:None,create=True))
        self.tmp=self.context.enter_context(tempfile.TemporaryDirectory())
        self.cfg=types.SimpleNamespace(LOG_MAX_BYTES=10*1024*1024,LOG_MIN_FREE_BYTES=4096,
            LOG_IMAGE_INTERVAL_MS=1000,LOG_EVENT_IMAGE_GAP_MS=250)

    def tearDown(self): self.context.close()

    def test_records_frozen_at_write_and_flushed(self):
        rec=RunRecorder(self.tmp,self.cfg)
        payload={'kind':'frame','tracks':[{'x':10}]}
        rec.write(payload)
        payload['tracks'][0]['x']=999
        rec.write({'kind':'end'},True)
        rec.close()
        rows=[]
        for f in pathlib.Path(rec.path).glob('frames_*.jsonl'):
            rows.extend(json.loads(line) for line in f.read_text().splitlines())
        self.assertEqual(next(r for r in rows if r['kind']=='frame')['tracks'][0]['x'],10)
        self.assertEqual(rows[-1]['kind'],'end')
        self.assertTrue(pathlib.Path(rec.path,'manifest.json').exists())

    def test_image_rate_limit_and_dimensions(self):
        class Frame:
            def save(self,path,quality): pathlib.Path(path).write_bytes(b'JPEG placeholder')
            def width(self): return 640
            def height(self): return 360
        rec=RunRecorder(self.tmp,self.cfg)
        first=rec.image(Frame(),0)
        self.assertTrue(first['saved'])
        self.assertEqual((first['width'],first['height']),(640,360))
        self.clock=100
        self.assertEqual(rec.image(Frame(),1,True)['reason'],'rate_limited')
        self.clock=300
        self.assertTrue(rec.image(Frame(),2,True)['saved'])
        self.clock=500
        self.assertFalse(rec.image(Frame(),3)['saved'])
        rec.close()

    def test_low_space_stops_recording_without_removing_data(self):
        rec=RunRecorder(self.tmp,self.cfg)
        rec.write({'kind':'start'},True)
        before=list(pathlib.Path(rec.path).rglob('*'))
        self.free=0
        self.assertFalse(rec.write({'kind':'frame'},True))
        self.assertTrue(rec.error)
        self.assertTrue(all(p.exists() for p in before))
        self.assertFalse(rec.write({'kind':'later'}))
        rec.close()
        rows=[json.loads(line) for file in pathlib.Path(rec.path).glob('frames_*.jsonl')
              for line in file.read_text().splitlines()]
        self.assertEqual(rows[-1]['component'],'recorder')
        self.assertIn('low space',rows[-1]['error'])

    def test_budget_limit_is_reported(self):
        rec=RunRecorder(self.tmp,self.cfg)
        rec.flush(True)
        rec.budget=rec.bytes+10
        self.assertFalse(rec.write({'kind':'frame','payload':'x'*100},True))
        self.assertTrue(rec.error)
        rec.close()


if __name__=='__main__': unittest.main(verbosity=2)
