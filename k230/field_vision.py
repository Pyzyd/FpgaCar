"""K230 field vision: traffic arrows, color blocks and the parking sign."""

import config as C
from color_core import COLORS, elapsed
from color_detector import detect_multi_colors
from multi_tracker import MultiTracker
from parking_detector import select as select_parking
from turn_detector import blue_regions, select as select_turn
from turn_shape import StableEvent


VERSION = 'FpgaCar-field-integration-v1'
EVENT_CODES = {'left':1, 'right':2, 'red':3, 'green':4, 'blue':5, 'yellow':6, 'P':7}
LABELS = {'left':'左转', 'right':'右转', 'red':'红', 'green':'绿', 'blue':'蓝', 'yellow':'黄'}
BOX_COLORS = {'red':(255,76,76), 'yellow':(255,217,60),
              'green':(60,235,126), 'blue':(74,169,255)}
SOURCES = ('field_vision.py','config.py','color_detector.py','color_core.py','arrow_core.py',
           'arrow_templates.py','multi_tracker.py','gpio_link.py','album.py','run_recorder.py',
           'parking_detector.py',
           'turn_verify/turn_detector.py','turn_verify/turn_shape.py','turn_verify/turn_templates.py')


class RestartKey:
    def __init__(self, initial, now):
        self.raw = self.stable = initial
        self.changed = now

    def update(self, value, now):
        if value != self.raw:
            self.raw, self.changed = value, now
        if value != self.stable and elapsed(now, self.changed) >= 35:
            self.stable = value
            return value == 0
        return False


class FieldVision:
    def __init__(self):
        self.turn_gate = StableEvent(confirm=3, rearm=6)
        self.parking_gate = StableEvent(confirm=3, rearm=6, labels=('P',))
        self.tracker = MultiTracker(width=C.PREVIEW_WIDTH, arm=C.FIELD_ARM_EDGE,
                                    commit=C.FIELD_PASS_EDGE, min_travel=C.FIELD_MIN_TRAVEL,
                                    hold_ms=C.FIELD_EDGE_HOLD_MS, edge_pass=True)
        self.last_turn = None
        self.parking_seen = False

    def reset(self):
        self.turn_gate.reset()
        self.parking_gate.reset()
        self.tracker.reset()
        self.last_turn = None
        self.parking_seen = False

    def update(self, img, now):
        regions = blue_regions(img)
        width, height = img.width(), img.height()
        turn = select_turn(width, height, img.get_pixel, regions)
        parking = select_parking(width, height, img.get_pixel, regions)
        direction = self.turn_gate.update(turn['label'], turn['present'])
        events = []
        if direction:
            self.last_turn = direction
            events.append({'kind':'turn','label':direction})
        if self.parking_gate.update(parking['label'], parking['present']):
            self.parking_seen = True
            events.append({'kind':'parking','label':'P'})

        sign_box = turn['box'] if turn['present'] else None
        colors = detect_multi_colors(img, field=True, sign_box=sign_box, parking_box=parking['box'])
        tracking = self.tracker.update(colors['candidates'], now)
        for passage in tracking['events']:
            if passage['included']:
                events.append({'kind':'color','label':passage['label'],'track':passage['track']})
        return {'turn':turn, 'last_turn':self.last_turn, 'parking':parking, 'colors':colors,
                'tracking':tracking, 'sequence':tracking['sequence'], 'events':events}


def open_recorder():
    from album import Album
    from run_recorder import RunRecorder

    for root in ('/data/field_vision_runs', '/sdcard/field_vision_runs'):
        try:
            session = Album(root, C.LOG_MIN_FREE_BYTES).path
            return RunRecorder(session, C, source_files=SOURCES, software=VERSION, screen_offset=0)
        except OSError as exc:
            print('[SD]', root, exc)
    return None


def draw_labeled_box(panel, box, text, color, width):
    x,y,w,h = box
    panel.draw_rectangle(x,y,w,h,color=color,thickness=3)
    tx,ty = min(x,width-28),max(0,y-24)
    panel.draw_rectangle(tx,ty,28,24,color=(13,26,41),fill=True)
    panel.draw_string_advanced(tx+3,ty+1,20,text,color=color)


def main(send_gpio=False):
    import gc
    import image
    import os
    import time
    from machine import FPIOA, Pin
    from media.sensor import Sensor, CAM_CHN_ID_0, CAM_CHN_ID_1
    from media.display import Display
    from media.media import MediaManager

    sensor = None
    display_ready = media_ready = sensor_running = False
    link = recorder = None
    os.exitpoint(os.EXITPOINT_ENABLE)
    try:
        sensor = Sensor()
        sensor.reset()
        width,height = C.PREVIEW_WIDTH,C.PREVIEW_HEIGHT
        sensor.set_framesize(width=width,height=height,chn=CAM_CHN_ID_0)
        sensor.set_pixformat(Sensor.RGB565,chn=CAM_CHN_ID_0)
        sensor.set_framesize(width=width,height=height,chn=CAM_CHN_ID_1)
        sensor.set_pixformat(Sensor.YUV420SP,chn=CAM_CHN_ID_1)
        sensor.set_hmirror(C.HMIRROR)
        sensor.set_vflip(C.VFLIP)
        Display.bind_layer(**sensor.bind_info(x=0,y=0,chn=CAM_CHN_ID_1),layer=Display.LAYER_VIDEO1)
        Display.init(Display.ST7701,width=C.WIDTH,height=C.HEIGHT,to_ide=False,osd_num=1)
        display_ready = True
        MediaManager.init()
        media_ready = True
        sensor.run()
        sensor_running = True
        if send_gpio:
            try:
                from gpio_link import GpioLink
                link = GpioLink()
            except Exception as exc:
                print('[GPIO] disabled:',exc)
        recorder = open_recorder()
        vision = FieldVision()
        key = None
        try:
            mux = FPIOA()
            mux.set_function(61, FPIOA.GPIO61)
            key = Pin(61, Pin.IN, pull=Pin.PULL_UP)
        except Exception as exc:
            print('[FIELD] Restart key unavailable:', exc)
        restart_key = RestartKey(key.value(), time.ticks_ms()) if key is not None else None
        panels = [image.Image(C.WIDTH,C.HEIGHT,image.ARGB8888) for _ in range(3)]
        index = frame_id = rate_count = 0
        fps = 0.
        warmed_at = rate_at = last_draw = time.ticks_ms()
        reset_at, redraw, boxes_visible = None, False, False

        def poll_restart(now):
            nonlocal reset_at, redraw
            if restart_key is None or not restart_key.update(key.value(), now):
                return
            vision.reset()
            reset_at, redraw = now, True
            print('[FIELD] recognition restarted')
            if recorder:
                recorder.write({'kind':'recognition_reset','ticks_ms':now,'frame':frame_id}, True)

        print('[FIELD]', VERSION, 'GPIO:', bool(link), 'SD:', recorder.path if recorder else 'off')
        while True:
            os.exitpoint()
            started = time.ticks_ms()
            poll_restart(started)
            try:
                frame = sensor.snapshot(chn=CAM_CHN_ID_0,timeout=120)
            except RuntimeError:
                if link:
                    link.poll()
                time.sleep_ms(10)
                continue
            now = time.ticks_ms()
            poll_restart(now)
            result = None
            events = []
            if time.ticks_diff(now,warmed_at)>=1500:
                result = vision.update(frame,now)
                events = result['events']
                for event in events:
                    ok = link.send(EVENT_CODES[event['label']]) if link else False
                    event['gpio'] = 'sent_no_ack' if ok else 'fault' if send_gpio else 'preview_only'
                    print('[FIELD EVENT]',event)
                if recorder:
                    saved = recorder.image(frame,frame_id,bool(events))
                    recorder.write({'kind':'frame','ticks_ms':now,'frame':frame_id,'mode':'field',
                                    'detection':{'turn':result['turn'],'parking':result['parking'],
                                                 'colors':result['colors']},
                                    'tracking':result['tracking'],'sequence':result['sequence'],
                                    'events':events,'image':saved},bool(events))
            if link:
                link.poll()
            del frame
            rate_count += 1
            elapsed = time.ticks_diff(now,rate_at)
            if elapsed>=1000:
                fps = rate_count*1000/elapsed
                rate_count,rate_at = 0,now
                gc.collect()
            candidates = result['colors']['candidates'] if result else ()
            parking_box = result['parking']['box'] if result else None
            if frame_id==0 or redraw or events or candidates or parking_box or boxes_visible or time.ticks_diff(now,last_draw)>=300:
                panel = panels[index]
                panel.clear()
                for item in candidates:
                    label = item['label']
                    draw_labeled_box(panel,item['box'],LABELS[label],BOX_COLORS[label],width)
                if parking_box:
                    draw_labeled_box(panel,parking_box,'P',(90,230,255),width)
                panel.draw_rectangle(0,height,C.WIDTH,C.HEIGHT-height,color=(13,26,41),fill=True)
                arrow = LABELS.get(vision.last_turn,'--')
                sequence = '  '.join(LABELS[c] for c in vision.tracker.sequence) or '--'
                tx = 'GPIO已启用' if link and not link.error else 'GPIO未输出'
                panel.draw_string_advanced(12,height+8,30,'转向 '+arrow+'    色序 '+sequence,color=(241,246,251))
                status = '预热中' if result is None else '顺序待复核' if vision.tracker.sequence_uncertain else tx
                if recorder and recorder.error:
                    status = 'SD记录停止'
                if reset_at is not None:
                    if time.ticks_diff(now,reset_at)<1000:
                        status = '识别已重开'
                    else:
                        reset_at = None
                labels = {item['label'] for item in candidates}
                visible = '  '.join(LABELS[c] for c in COLORS if c in labels) or '--'
                parking_status = '    停车牌 P 已确认' if vision.parking_seen else ''
                panel.draw_string_advanced(12,height+48,22,'当前色块 '+visible+parking_status,color=(241,246,251))
                panel.draw_string_advanced(12,height+83,22,'%s    %.1f FPS' % (status,fps),color=(180,217,242))
                Display.show_image(panel,layer=Display.LAYER_OSD0)
                index = (index+1)%len(panels)
                last_draw, redraw, boxes_visible = now, False, bool(candidates or parking_box)
            frame_id += 1
            while True:
                now = time.ticks_ms()
                delay = C.FIELD_PERIOD_MS-time.ticks_diff(now,started)
                if delay <= 0:
                    break
                time.sleep_ms(min(10, delay))
                poll_restart(time.ticks_ms())
    except KeyboardInterrupt:
        print('[FIELD] stopped')
    finally:
        if link:
            link.close()
        if recorder:
            recorder.write({'kind':'end','ticks_ms':time.ticks_ms()},True)
            recorder.close()
        if sensor_running:
            sensor.stop()
        if display_ready:
            Display.deinit()
        if media_ready:
            MediaManager.deinit()


if __name__ == '__main__':
    main()
