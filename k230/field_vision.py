"""K230 field vision: traffic arrows, color blocks and the parking sign."""

import config as C
from color_core import elapsed
from color_detector import detect_multi_colors
from multi_tracker import MultiTracker
from parking_detector import select as select_parking
from turn_detector import blue_regions, select as select_turn
from turn_shape import StableEvent


VERSION = 'FpgaCar-field-integration-v12'
PARK_RETRY_MS = 400
EVENT_CODES = {'left':1, 'right':2, 'red':3, 'green':4, 'blue':5, 'yellow':6, 'P':7}
LABELS = {'left':'左转', 'right':'右转', 'red':'红', 'green':'绿', 'blue':'蓝', 'yellow':'黄'}
BOX_COLORS = {'red':(255,76,76), 'yellow':(255,217,60),
              'green':(60,235,126), 'blue':(74,169,255), 'P':(90,230,255)}
PANEL_BG = (13,26,41)
TAG_WIDTH, TAG_HEIGHT = 28, 24
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

        # The confirmed turn stays latched for this run until the user restarts recognition.
        colors = tracking = None
        if self.last_turn is not None:
            sign_box = turn['box'] if turn['present'] else None
            colors = detect_multi_colors(img, field=True, sign_box=sign_box, parking_box=parking['box'])
            tracking = self.tracker.update(colors['candidates'], now)
            for passage in tracking['events']:
                if passage['included']:
                    events.append({'kind':'color','label':passage['label'],'track':passage['track']})
        return {'turn':turn, 'last_turn':self.last_turn, 'parking':parking, 'colors':colors,
                'tracking':tracking, 'sequence':tracking['sequence'] if tracking else [], 'events':events}


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


def draw_labeled_box(panel, box, tag, color, width):
    x,y,w,h = box
    panel.draw_rectangle(x,y,w,h,color=color,thickness=3)
    panel.draw_image(tag,min(x,width-TAG_WIDTH),max(0,y-TAG_HEIGHT))


def publish_event(link, event, send_gpio):
    if link is None:
        event['gpio'] = 'fault' if send_gpio else 'preview_only'
        return
    try:
        event['gpio'] = 'sent_no_ack' if link.send(EVENT_CODES[event['label']]) else 'fault'
        if event['gpio'] == 'fault':
            event['gpio_error'] = link.error
    except Exception as exc:
        # 旧版 gpio_link 不接受 P 的事件码。保留取景，并在事件日志里报出具体原因。
        event['gpio'] = 'fault'
        event['gpio_error'] = str(exc)


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
        Display.init(Display.ST7701,width=C.WIDTH,height=C.HEIGHT,to_ide=False,osd_num=2)
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
        # Keep the moving boxes on the preview and the text on the lower strip.
        status_height = C.HEIGHT-height
        box_panels = [image.Image(width,height,image.ARGB8888) for _ in range(3)]
        status_panels = [image.Image(C.WIDTH,status_height,image.ARGB8888) for _ in range(3)]
        tags = {}
        for label,color in BOX_COLORS.items():
            tag = image.Image(TAG_WIDTH,TAG_HEIGHT,image.ARGB8888)
            tag.draw_rectangle(0,0,TAG_WIDTH,TAG_HEIGHT,color=PANEL_BG,fill=True)
            tag.draw_string_advanced(3,1,20,LABELS.get(label,label),color=color)
            tags[label] = tag
        last_boxes = None
        box_index = status_index = frame_id = rate_count = box_updates = 0
        fps = 0.
        warmed_at = rate_at = last_status = time.ticks_ms()
        reset_at, redraw = None, True
        gpio_send_failed = False
        parking_sent, parking_sent_at = False, 0
        perf = [0, 0, 0, 0, 0]

        def poll_restart(now):
            nonlocal reset_at, redraw, gpio_send_failed, parking_sent
            if restart_key is None or not restart_key.update(key.value(), now):
                return
            vision.reset()
            gpio_send_failed = False
            parking_sent = False
            reset_at, redraw = now, True
            print('[FIELD] recognition restarted')
            if recorder:
                recorder.write({'kind':'recognition_reset','ticks_ms':now,'frame':frame_id}, True)

        print('[FIELD]', VERSION, 'GPIO:', bool(link), 'SD:', recorder.path if recorder else 'off',
              'Record:', 'full' if C.FIELD_RECORD_FULL else 'events')
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
            detected_at = time.ticks_ms()
            if result is not None:
                for event in events:
                    publish_event(link,event,send_gpio)
                    if link and event['gpio'] == 'fault':
                        gpio_send_failed = True
                    if event['kind'] == 'parking':
                        parking_sent = event['gpio'] == 'sent_no_ack'
                        parking_sent_at = now
                    print('[FIELD EVENT]',event)
                # P 的 GPIO 链路没有回执。牌仍稳定可见时补发，不重复记录识别事件。
                if parking_sent and vision.parking_gate.stable == 'P' and time.ticks_diff(now,parking_sent_at) >= PARK_RETRY_MS:
                    retry = {'kind':'parking_retry','label':'P'}
                    publish_event(link,retry,send_gpio)
                    parking_sent = retry['gpio'] == 'sent_no_ack'
                    parking_sent_at = now
                    if not parking_sent:
                        gpio_send_failed = True
                    print('[P RETRY]',retry)
            if link:
                link.poll()
            sent_at = time.ticks_ms()
            if recorder and result is not None and (events or C.FIELD_RECORD_FULL):
                record = {'kind':'frame','ticks_ms':now,'frame':frame_id,'mode':'field',
                          'sequence':result['sequence'],'events':events}
                if C.FIELD_RECORD_FULL:
                    record['detection'] = {'turn':result['turn'],'parking':result['parking'],
                                           'colors':result['colors']}
                    record['tracking'] = result['tracking']
                    record['image'] = recorder.image(frame,frame_id,bool(events))
                recorder.write(record,bool(events))
            del frame
            recorded_at = time.ticks_ms()
            candidates = result['colors']['candidates'] if result and result['colors'] else ()
            parking_box = result['parking']['box'] if result else None
            boxes = tuple((item['label'],tuple(item['box'])) for item in candidates)
            if parking_box:
                boxes += (('P',tuple(parking_box)),)
            if boxes != last_boxes:
                panel = box_panels[box_index]
                panel.clear()
                for label,box in boxes:
                    draw_labeled_box(panel,box,tags[label],BOX_COLORS[label],width)
                Display.show_image(panel,layer=Display.LAYER_OSD0)
                box_index = (box_index+1)%len(box_panels)
                last_boxes = boxes
                box_updates += 1
            if redraw or events or time.ticks_diff(recorded_at,last_status)>=C.FIELD_STATUS_MS:
                panel = status_panels[status_index]
                panel.draw_rectangle(0,0,C.WIDTH,status_height,color=PANEL_BG,fill=True)
                status_x = C.WIDTH // 2 + 8
                arrow = LABELS.get(vision.last_turn,'--')
                sequence = ''.join(LABELS[c] for c in vision.tracker.sequence) or '--'
                tx = 'GPIO已启用' if link and not link.error else 'GPIO未输出'
                panel.draw_string_advanced(status_x,8,24,'转向 '+arrow+'  色序 '+sequence,color=(241,246,251))
                status = '预热中' if result is None else '顺序待复核' if vision.tracker.sequence_uncertain else tx
                if recorder and recorder.error:
                    status = 'SD记录停止'
                if gpio_send_failed:
                    status = 'GPIO发送失败'
                if reset_at is not None:
                    if time.ticks_diff(now,reset_at)<1000:
                        status = '识别已重开'
                    else:
                        reset_at = None
                visible = ('等待转向牌' if vision.last_turn is None else
                           ''.join(LABELS[item['label']] for item in candidates[:4]) or '--')
                panel.draw_string_advanced(status_x,48,22,'色块 '+visible,color=(241,246,251))
                if vision.parking_seen:
                    parking_text = 'P 已发送' if parking_sent else 'P 已识别'
                    panel.draw_string_advanced(C.WIDTH-124,48,24,parking_text,color=BOX_COLORS['P'])
                panel.draw_string_advanced(status_x,83,22,'%s  %.1f FPS' % (status,fps),color=(180,217,242))
                Display.show_image(panel,y=height,layer=Display.LAYER_OSD1)
                status_index = (status_index+1)%len(status_panels)
                last_status, redraw = time.ticks_ms(), False
            finished_at = time.ticks_ms()
            if result is not None:
                rate_count += 1
                perf[0] += time.ticks_diff(now,started)
                perf[1] += time.ticks_diff(detected_at,now)
                perf[2] += time.ticks_diff(sent_at,detected_at)
                perf[3] += time.ticks_diff(recorded_at,sent_at)
                perf[4] += time.ticks_diff(finished_at,recorded_at)
                period = time.ticks_diff(finished_at,rate_at)
                if period >= 2000:
                    fps = rate_count*1000/period
                    averages = tuple(ms/rate_count for ms in perf)
                    print('[FIELD PERF] %.1f FPS box_updates/s=%.1f ms/frame capture=%.1f vision=%.1f gpio=%.1f sd=%.1f osd=%.1f' %
                          ((fps,box_updates*1000/period) + averages))
                    rate_count,box_updates,rate_at = 0,0,finished_at
                    perf = [0, 0, 0, 0, 0]
                    gc.collect()
            else:
                rate_at = finished_at
                box_updates = 0
            frame_id += 1
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
