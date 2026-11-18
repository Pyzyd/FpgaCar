"""Bounded SD flight recorder. Data errors are visible; never delete old runs."""
import os
import sys
import time
import json
from album import mkdir


class RunRecorder:
    def __init__(self,session,config):
        self.path=session+'/analysis'
        mkdir(self.path)
        mkdir(self.path+'/images')
        self.minimum=getattr(config,'LOG_MIN_FREE_BYTES',32*1024*1024)
        self.budget=getattr(config,'LOG_MAX_BYTES',128*1024*1024)
        self.image_interval=getattr(config,'LOG_IMAGE_INTERVAL_MS',1000)
        self.image_gap=getattr(config,'LOG_EVENT_IMAGE_GAP_MS',250)
        self.buffer=[]
        self.bytes=0
        self.error=''
        self.last_flush=self.last_sync=time.ticks_ms()
        self.last_image=None
        self.part=1
        self.part_bytes=0
        self.handle=None
        self._space()
        settings={}
        for name in dir(config):
            if name.isupper():
                value=getattr(config,name)
                if isinstance(value,(str,int,float,bool,tuple,list)) or value is None:
                    settings[name]=value
        manifest=json.dumps({'schema':1,'software':'FpgaCar-K230-v1.6.1',
                'firmware':sys.version,'board':list(os.uname()),'config':settings,
                'coordinates':'detections/tracks: 640x360; screen y offset +60',
                'images':'raw 640x360 periodic/key frames; NOT complete video',
                'durability':'buffer <= 500ms normally; sync <=2s; critical events sync immediately'})
        self._space(len(manifest.encode('utf-8')))
        with open(self.path+'/manifest.json','w') as f:
            f.write(manifest)
        self.bytes+=len(manifest.encode('utf-8'))
        self._open()
        # Save exact deployed sources for reproducing this run's analysis.
        mkdir(self.path+'/source')
        for name in ('main.py','config.py','detector.py','arrow_core.py','arrow_templates.py',
                     'color_core.py','color_detector.py','multi_tracker.py','run_recorder.py','gpio_link.py','album.py'):
            try:
                with open('/sdcard/car_vision/'+name,'r') as src:
                    data=src.read()
                size=len(data.encode('utf-8'))
                self._space(size)
                with open(self.path+'/source/'+name,'w') as dst:
                    dst.write(data)
                self.bytes+=size
            except OSError:
                self.write({'kind':'source_unavailable','file':name})

    def _open(self):
        self.handle=open(self.path+'/frames_%04d.jsonl'%self.part,'a')

    def _space(self,extra=0):
        stat=os.statvfs(self.path)
        if stat[0]*stat[4]<self.minimum or self.bytes+extra>self.budget:
            raise OSError('SD recorder full/low space; old data preserved')

    def _fail(self,e):
        self.error=str(e)
        print('[RECORDER STOPPED]',self.error)
        self.buffer=[]
        if self.handle:
            # Best effort final reason, even when the normal budget is exhausted.
            # A full/unmounted card can still prevent this small emergency record.
            try:
                final=json.dumps({'kind':'error','component':'recorder',
                    'ticks_ms':time.ticks_ms(),'error':self.error[:256]})+'\n'
                self.handle.write(final)
                self.handle.flush()
                if hasattr(os,'sync'): os.sync()
            except Exception:
                pass
            try: self.handle.close()
            except Exception: pass
            self.handle=None

    def write(self,record,critical=False):
        if self.error:
            return False
        try:
            # Serialize now: tracker dictionaries will change on subsequent frames.
            line=json.dumps(record)+'\n'
            self.buffer.append(line)
            now=time.ticks_ms()
            if critical or len(self.buffer)>=8 or time.ticks_diff(now,self.last_flush)>=500:
                self.flush(critical)
            return not bool(self.error)
        except Exception as e:
            self._fail(e)
            return False

    def flush(self,sync=False):
        if self.error or not self.handle:
            return
        try:
            data=''.join(self.buffer)
            self._space(len(data))
            if data:
                # UTF-8 may use more bytes than characters; use actual byte count.
                size=len(data.encode('utf-8'))
                self._space(size)
                self.handle.write(data)
                self.handle.flush()
                self.bytes+=size
                self.part_bytes+=size
                self.buffer=[]
            now=time.ticks_ms()
            self.last_flush=now
            if sync or time.ticks_diff(now,self.last_sync)>=2000:
                if hasattr(os,'sync'): os.sync()
                self.last_sync=now
            if self.part_bytes>=4*1024*1024:
                self.handle.close()
                self.part+=1
                self.part_bytes=0
                self._open()
        except Exception as e:
            self._fail(e)

    def image(self,img,frame_id,important=False):
        if self.error:
            return {'saved':False,'reason':'recorder_stopped'}
        now=time.ticks_ms()
        gap=self.image_gap if important else self.image_interval
        if self.last_image is not None and time.ticks_diff(now,self.last_image)<gap:
            return {'saved':False,'reason':'rate_limited'}
        name='images/frame_%08d.jpg'%frame_id
        try:
            self._space(1024*1024)  # Reserve headroom before encoding.
            img.save(self.path+'/'+name,quality=85)
            size=os.stat(self.path+'/'+name)[6]
            self.bytes+=size
            self.last_image=now
            return {'saved':True,'file':name,'bytes':size,'ticks_ms':now,
                    'width':img.width(),'height':img.height()}
        except Exception as e:
            self._fail(e)
            return {'saved':False,'reason':'save_failed','error':str(e)}

    def close(self):
        self.flush(True)
        if self.handle:
            self.handle.close()
            self.handle=None
