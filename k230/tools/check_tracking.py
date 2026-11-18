"""Trajectory tests: no camera or moving car required."""
import pathlib
import sys
import unittest
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
from multi_tracker import MultiTracker


def detection(x,color='red',y=150,clipped=False):
    return {'box':(x-20,y-20,40,40),'label':color,'pixels':1400,'clipped':clipped}


class Checks(unittest.TestCase):
    def tracker(self,**kwargs):
        return MultiTracker(confirm_ms=200,hold_ms=120,**kwargs)

    def test_forward_cross_once_and_back_swing(self):
        tracker=self.tracker()
        events=[]
        positions=[350,360,370,400,430,460,490,520,550,570,580,590,580,570,550,570,590]
        for i,x in enumerate(positions):
            events+=tracker.update([detection(x)],i*100)['events']
        self.assertEqual(len(events),1)
        self.assertEqual(events[0]['label'],'red')

    def test_same_color_two_objects(self):
        tracker=self.tracker()
        events=[]
        for i in range(40):
            xs=[350+15*i,200+15*i]
            ds=[detection(x) for x in xs if x<645]
            events+=tracker.update(ds,i*100)['events']
        self.assertEqual([e['label'] for e in events],['red','red'])
        self.assertNotEqual(events[0]['track'],events[1]['track'])

    def test_right_edge_appearance_and_wrong_direction(self):
        tracker=self.tracker()
        events=[]
        for i,x in enumerate([580,590,600,610,600,580,550,520,490,460,430]):
            events+=tracker.update([detection(x)],i*100)['events']
        self.assertEqual(events,[])

    def test_small_stationary_jitter(self):
        tracker=self.tracker()
        events=[]
        for i in range(50):
            events+=tracker.update([detection(555+(-1)**i*10)],i*80)['events']
        self.assertEqual(events,[])

    def test_common_jump_cross_is_uncertain(self):
        tracker=self.tracker()
        events=[]; notes=[]
        positions=[400,410,420,440,460,480,500,520,540,575,580,580,580,580,580]
        for i,x in enumerate(positions):
            result=tracker.update([detection(x),detection(x-140,'green')],i*100)
            events+=result['events']; notes+=result['notes']
        self.assertEqual(events,[])
        self.assertTrue(any(n['kind']=='uncertain_crossing' for n in notes))

    def test_short_occlusion_preserves_id(self):
        tracker=self.tracker()
        ids=[]; events=[]
        for i,x in enumerate([350,360,370,400,430,None,470,500,530,560,580,590,600]):
            result=tracker.update([] if x is None else [detection(x)],i*100)
            ids += [t['id'] for t in result['tracks'] if t['observed']]
            events+=result['events']
        self.assertEqual(len(set(ids)),1)
        self.assertEqual(len(events),1)

    def test_simultaneous_cross_order_not_guessed(self):
        tracker=self.tracker()
        events=[]; notes=[]
        for i,x in enumerate(range(350,611,20)):
            result=tracker.update([detection(x,'red',100),detection(x,'green',240)],i*100)
            events+=result['events']; notes+=result['notes']
        self.assertEqual(events,[])
        self.assertTrue(any(n['kind']=='order_ambiguous' for n in notes))

    def test_clipped_color_does_not_overwrite_vote(self):
        tracker=self.tracker()
        events=[]
        for i,x in enumerate([350,360,370,400,430,460,490,520,550,570,580,590]):
            d=detection(x,'blue' if x>=550 else 'red',clipped=x>=550)
            events+=tracker.update([d],i*100)['events']
        self.assertEqual([e['label'] for e in events],['red'])

    def test_pause_cannot_bridge_unseen_crossing(self):
        tracker=self.tracker()
        for i,x in enumerate([350,360,370]): tracker.update([detection(x)],i*100)
        old_id=tracker.next_id
        tracker.pause()
        events=[]
        for i,x in enumerate([580,590,600,610]):
            events+=tracker.update([detection(x)],(i+3)*100)['events']
        self.assertEqual(events,[])
        self.assertGreater(tracker.next_id,old_id)


if __name__=='__main__': unittest.main(verbosity=2)
