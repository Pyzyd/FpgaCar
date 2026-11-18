import contextlib
import io
import json
import pathlib
import tempfile
import unittest
from analyze_run import analyze


class Checks(unittest.TestCase):
    def test_critical_events_deduplicated_and_partial_tail_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp)/'analysis'
            root.mkdir()
            event={'track':1,'label':'red','included':True}
            rows=[{'kind':'count_events','frame':2,'ticks_ms':500,'events':[event]},
                  {'kind':'frame','frame':2,'ticks_ms':500,'events':[event],
                   'image':{'saved':True,'file':'images/frame_00000002.jpg'},
                   'tracking':{'time_ms':500,'epoch':1,'sequence_uncertain':True,
                    'tracks':[{'id':1,'color':'red','state':'counted','box':[540,100,40,40],
                               'vx':.1,'observed':True,'counted':True,'blocked':False}],
                    'notes':[{'kind':'common_jump','dx':30,'dy':0}]}}]
            data=''.join(json.dumps(r)+'\n' for r in rows).encode('utf-8')
            (root/'frames_0001.jsonl').write_bytes(data+b'{"kind":"partial"\n'+b'\xff\n')
            with contextlib.redirect_stdout(io.StringIO()): report=analyze(tmp)
            self.assertEqual(len(report['count_events']),1)
            self.assertEqual(report['frame_records'],1)
            self.assertEqual(report['saved_images'],1)
            self.assertEqual(len(report['invalid_lines']),2)
            self.assertFalse(report['end_record_seen'])
            self.assertTrue(report['sequence_uncertain_seen'])
            self.assertTrue((root/'report/tracks.csv').exists())


if __name__=='__main__': unittest.main(verbosity=2)
