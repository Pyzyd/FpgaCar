"""Conservative multi-target tracking in original preview coordinates.

This is a bench prototype, not visual odometry. Common image jumps can suspend
counting but cannot distinguish all vehicle yaw from translation without a
motion reference. All uncertain cases are exposed for field calibration.
"""
from color_core import COLORS, elapsed


def center(box):
    return box[0]+box[2]/2, box[1]+box[3]/2


def median(values):
    values=sorted(values)
    return values[len(values)//2]


class MultiTracker:
    def __init__(self, width=640, arm=.72, commit=.88, confirm_ms=250,
                 confirm_hits=3, hold_ms=140, hold_hits=2, lost_ms=800,
                 match_distance=70, min_travel=55, jitter=8,
                 common_jump=22, shake_hold_ms=350, max_tracks=12, edge_pass=False):
        if not 0<arm<commit<1:
            raise ValueError('Tracker gates must satisfy 0 < arm < commit < 1')
        self.width=width
        self.arm,self.commit=width*arm,width*commit
        self.confirm_ms,self.confirm_hits=confirm_ms,confirm_hits
        self.hold_ms,self.hold_hits=hold_ms,hold_hits
        self.lost_ms,self.match_distance=lost_ms,match_distance
        self.min_travel,self.jitter=min_travel,jitter
        self.common_jump,self.shake_hold_ms=common_jump,shake_hold_ms
        self.max_tracks=max_tracks
        self.edge_pass=edge_pass
        self.next_id=1
        self.epoch=0
        self.clock=0
        self.last_raw=None
        self.sequence=[]
        self.reset()

    def reset(self, clear_sequence=True):
        self.tracks=[]
        self.epoch+=1
        self.hold_until=0
        self.notes=[]
        if clear_sequence:
            self.sequence=[]
            self.sequence_uncertain=False

    def pause(self):
        # No trajectory may bridge a browsing/mode pause and count unseen motion.
        self.reset(clear_sequence=False)

    def _clock(self, raw):
        if self.last_raw is not None:
            self.clock+=max(0,elapsed(raw,self.last_raw))
        self.last_raw=raw
        return self.clock

    def _vote(self,t,label):
        t['votes'].append(label)
        t['votes']=t['votes'][-12:]
        counts=dict((c,t['votes'].count(c)) for c in COLORS)
        winner=max(counts,key=counts.get)
        t['color']=winner if counts[winner]>=self.confirm_hits and counts[winner]/len(t['votes'])>=.7 else 'unknown'

    def _new(self,d,now):
        x,y=center(d['box'])
        t={'id':self.next_id,'box':list(d['box']),'x':x,'y':y,'vx':0.,'vy':0.,
           'seen':now,'born':now,'hits':1,'votes':[],'color':'unknown',
           'armed':False,'arm_x':None,'counted':False,'blocked':False,
           'cross_at':None,'beyond_hits':0,'state':'tentative','observed':True}
        self.next_id+=1
        self._vote(t,d['label'])
        self.tracks.append(t)
        self.notes.append({'kind':'new','track':t['id']})
        return t

    def _edge_step(self,t,d,old_box,dt,now,suspended,ready):
        """Latch at the right edge while the passing block is still identifiable."""
        x, _, w, _ = t['box']
        old_x, _, old_w, _ = old_box
        edge, old_edge = x+w, old_x+old_w
        confirmed=t['hits']>=self.confirm_hits and now-t['born']>=self.confirm_ms and t['color']!='unknown'
        if confirmed and not suspended and not d.get('clipped') and edge<=self.arm:
            if not t['armed']:
                t['armed'],t['arm_x']=True,edge
                self.notes.append({'kind':'armed','track':t['id']})
            t['arm_x']=min(t['arm_x'],edge)
        if not confirmed or not t['armed']:
            return
        if edge<self.commit-self.jitter or dt>400:
            t['cross_at'],t['beyond_hits']=None,0
        if suspended or dt>400:
            return
        if t['cross_at'] is None:
            advancing = (edge>old_edge+2 or x>old_x+2)
            core = d.get('core_box')
            if core and core[0]+core[2]<self.commit:
                # A weaker side face can reappear when exposure changes.
                # Require motion of the observed left edge for a recovered crossing.
                advancing = x>old_x+2
            at_edge = edge>=self.commit and edge-t['arm_x']>=self.min_travel
            if not (at_edge and advancing):
                return
            # Use the observed crossing time to preserve event order across tracks.
            t['cross_at']=now
            self.notes.append({'kind':'crossing','track':t['id']})
        if edge>=self.commit-self.jitter:
            t['beyond_hits']+=1
            if now-t['cross_at']>=self.hold_ms and t['beyond_hits']>=self.hold_hits:
                ready.append(t)

    def update(self,detections,raw_ms):
        now=self._clock(raw_ms)
        self.notes=[]
        alive=[]
        for t in self.tracks:
            ttl=max(self.lost_ms,2500) if t['counted'] else self.lost_ms
            if now-t['seen']>ttl:
                self.notes.append({'kind':'lost','track':t['id'],'counted':t['counted']})
                if t['armed'] and not t['counted']:
                    self.sequence_uncertain=True
            else:
                t['observed']=False
                alive.append(t)
        self.tracks=alive
        detections=[d for d in detections if d.get('label') in COLORS][:24]
        # Predict in pixel/ms; do not use color as a hard identity constraint.
        pairs=[]
        possible={}
        for ti,t in enumerate(self.tracks):
            dt=min(now-t['seen'],200)
            px,py=t['x']+t['vx']*dt,t['y']+t['vy']*dt
            for di,d in enumerate(detections):
                x,y=center(d['box'])
                distance=((x-px)**2+(y-py)**2)**.5
                ratio=(d['box'][2]*d['box'][3])/(t['box'][2]*t['box'][3])
                if distance<=self.match_distance and .35<=ratio<=2.85:
                    penalty=12 if t['color'] not in ('unknown',d['label']) else 0
                    score=distance+penalty
                    pairs.append((score,ti,di))
                    possible.setdefault(di,[]).append((score,ti))
        ambiguous=set()
        for di,choices in possible.items():
            choices.sort()
            if len(choices)>1 and choices[1][0]-choices[0][0]<10:
                ambiguous.add(di)
        if ambiguous:
            self.notes.append({'kind':'association_ambiguous','detections':sorted(ambiguous)})
        used_t,used_d=set(),set()
        motions=[]
        matched=[]
        for score,ti,di in sorted(pairs):
            if ti in used_t or di in used_d or di in ambiguous:
                continue
            used_t.add(ti); used_d.add(di)
            t,d=self.tracks[ti],detections[di]
            x,y=center(d['box'])
            dt=max(1,now-t['seen'])
            old_x,old_y=t['x'],t['y']
            old_box=t['box']
            if self.edge_pass and dt<=400:
                motions.append(((x-old_x)*100/dt,(y-old_y)*100/dt))
            elif not self.edge_pass and dt<=250:
                motions.append((x-old_x,y-old_y))
            t['vx']=.5*t['vx']+.5*(x-old_x)/dt
            t['vy']=.5*t['vy']+.5*(y-old_y)/dt
            t['box'],t['x'],t['y']=list(d['box']),x,y
            t['seen'],t['hits'],t['observed']=now,t['hits']+1,True
            if not d.get('clipped'):
                self._vote(t,d['label'])
            matched.append((t,d,old_x,old_box,dt))
        shake=False
        common=[0.,0.]
        if len(motions)>=2:
            common=[median([m[0] for m in motions]),median([m[1] for m in motions])]
            agreement=sum(1 for dx,dy in motions if abs(dx-common[0])<12 and abs(dy-common[1])<12)
            if agreement>=2 and max(abs(common[0]),abs(common[1]))>=self.common_jump:
                shake=True
                self.hold_until=now+self.shake_hold_ms
                self.notes.append({'kind':'common_jump','dx':common[0],'dy':common[1]})
        suspended=now<self.hold_until or bool(ambiguous)
        ready=[]
        for t,d,old_x,old_box,dt in matched:
            if t['counted'] or t['blocked']:
                continue
            if self.edge_pass:
                self._edge_step(t,d,old_box,dt,now,suspended,ready)
                continue
            confirmed=t['hits']>=self.confirm_hits and now-t['born']>=self.confirm_ms and t['color']!='unknown'
            if confirmed and not d.get('clipped') and t['x']<=self.arm:
                if not t['armed']:
                    t['armed'],t['arm_x']=True,t['x']
                    self.notes.append({'kind':'armed','track':t['id']})
                t['arm_x']=min(t['arm_x'],t['x'])
            if suspended:
                if old_x<self.commit<=t['x'] and t['armed']:
                    t['blocked']=True
                    self.sequence_uncertain=True
                    self.notes.append({'kind':'uncertain_crossing','track':t['id'],'reason':'camera_motion_or_association'})
                t['cross_at'],t['beyond_hits']=None,0
                continue
            if not confirmed or not t['armed']:
                continue
            if t['x']<self.commit-self.jitter:
                t['cross_at'],t['beyond_hits']=None,0
            if old_x<self.commit<=t['x'] and t['x']-t['arm_x']>=self.min_travel and dt<=250:
                t['cross_at']=now-dt+dt*(self.commit-old_x)/(t['x']-old_x)
                t['beyond_hits']=0
                self.notes.append({'kind':'crossing','track':t['id']})
            if t['cross_at'] is not None and t['x']>=self.commit-self.jitter:
                t['beyond_hits']+=1
                if now-t['cross_at']>=self.hold_ms and t['beyond_hits']>=self.hold_hits:
                    ready.append(t)
        # A pending, earlier crossing must resolve before a later one can emit.
        pending=sorted([t for t in self.tracks if t['cross_at'] is not None and not t['counted'] and not t['blocked']],key=lambda t:t['cross_at'])
        events=[]
        for i,t in enumerate(pending):
            if i+1<len(pending) and pending[i+1]['cross_at']-t['cross_at']<40:
                for item in (t,pending[i+1]): item['blocked']=True
                self.sequence_uncertain=True
                self.notes.append({'kind':'order_ambiguous','tracks':[t['id'],pending[i+1]['id']]})
                continue
            if t['blocked']:
                continue
            if t not in ready:
                break
            t['counted']=True
            included=len(self.sequence)<4
            if included:
                self.sequence.append(t['color'])
            events.append({'track':t['id'],'label':t['color'],'box':list(t['box']),
                           'cross_ms':t['cross_at'],'time_ms':now,'included':included,'epoch':self.epoch})
        for di,d in enumerate(detections):
            if di in used_d or di in ambiguous:
                continue
            # Don't spawn a duplicate near an unmatched/ambiguous existing track.
            x,y=center(d['box'])
            near=any(not t['observed'] and ((x-t['x'])**2+(y-t['y'])**2)**.5<self.match_distance for t in self.tracks)
            if not near and not d.get('clipped') and len(self.tracks)<self.max_tracks:
                self._new(d,now)
        for t in self.tracks:
            t['state']=('counted' if t['counted'] else 'uncertain' if t['blocked'] else
                        'missing' if not t['observed'] else 'crossing' if t['cross_at'] is not None else
                        'armed' if t['armed'] else 'confirmed' if t['color']!='unknown' else 'tentative')
        return {'events':events,'tracks':self.snapshot(),'notes':list(self.notes),
                'motion_hold':suspended,'common_motion':common,'time_ms':now,
                'sequence':list(self.sequence),'sequence_uncertain':self.sequence_uncertain,
                'gates':[self.arm,self.commit],'epoch':self.epoch}

    def snapshot(self):
        return [dict((key,t[key]) for key in ('id','box','x','y','vx','vy','hits','color','votes',
                    'state','armed','arm_x','counted','blocked','observed','cross_at','beyond_hits','born','seen')) for t in self.tracks]
