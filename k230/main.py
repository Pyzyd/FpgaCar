"""K230 front camera: arrows, multi-target color tracking and SD field recorder.

Copy all sibling runtime .py files to /sdcard/car_vision/ first. Run this file
temporarily in CanMV IDE before installing the optional startup launcher.
"""
import sys
print("[CAR 1] Starting arrow/album script; name=", __name__)
if "/sdcard/car_vision" not in sys.path:
    sys.path.insert(0, "/sdcard/car_vision")
import os
import time
import gc
import image
try:
    from ulab import numpy as np
except ImportError:
    np = None
from media.sensor import Sensor, CAM_CHN_ID_0, CAM_CHN_ID_1
from media.display import Display
from media.media import MediaManager
from machine import FPIOA, Pin
import config as C


def ensure_capture_sizes(config):
    # Older deployed configs and an IDE session's cached module may lack v1.4
    # fields. Add only missing fields to the same object used by the detector.
    defaults = (("PREVIEW_WIDTH",640), ("PREVIEW_HEIGHT",360),
                ("PHOTO_WIDTH",1280), ("PHOTO_HEIGHT",720))
    missing = []
    for name, value in defaults:
        if not hasattr(config, name):
            setattr(config, name, value)
            missing.append(name)
    return missing


print("[CONFIG] Loaded from", getattr(C,"__file__","<cached/frozen module>"))
missing_sizes = ensure_capture_sizes(C)
if missing_sizes:
    print("[CONFIG] Old config: using capture-size defaults for", missing_sizes)
from detector import detect
from arrow_core import StableEvent
from album import Album
from color_detector import detect_colors, detect_multi_colors, DEFAULT_LAB
from multi_tracker import MultiTracker
from run_recorder import RunRecorder
print("[CAR 2] Modules loaded; display=", C.DISPLAY)
print("[RENDER] v1.6 multi-target gates + SD analysis recorder")
print("[LINK] v1.6.1 fixed DATA=42/43/34, STB=35; no ACK")

SCENES = ("normal", "far", "near", "tilted", "dim", "glare", "moving", "background")
LABEL_TEXT = ("未标注", "左箭头", "右箭头", "无目标", "红色", "绿色", "蓝色", "黄色")
SCENE_TEXT = ("普通", "远距", "近距", "斜视", "暗光", "反光", "运动", "背景")
DIRECTION_TEXT = {"left": "左转", "right": "右转", "unknown": "未确认"}
COLOR_TEXT = {"red":"红","green":"绿","blue":"蓝","yellow":"黄","unknown":"未确认"}
EVENT_CODES = {"left":1,"right":2,"red":3,"green":4,"blue":5,"yellow":6}
UI_ALPHA = 128                 # Half-transparent neutral black backgrounds.
PANEL_SHIFT_FAST = None
COPY_BYTES_FAST = None


class PreviewFPS:
    def __init__(self, now):
        self.reset(now)

    def reset(self, now):
        self.started, self.count, self.value = now, 0, None

    def tick(self, now):
        self.count += 1
        elapsed = time.ticks_diff(now, self.started)
        if elapsed >= 1000:
            self.value = self.count * 1000.0 / elapsed
            self.started, self.count = now, 0


class FrameProfiler:
    STAGES = ("capture", "detect", "photo", "compose", "ui", "show", "log", "gc")

    def __init__(self):
        self.reset()

    def reset(self):
        self.window = time.ticks_us()
        self.frames, self.total = 0, 0
        self.sums = dict((name,0) for name in self.STAGES)
        self.current={}

    def add(self, name, started):
        duration=time.ticks_diff(time.ticks_us(),started)
        self.sums[name] += duration
        self.current[name]=self.current.get(name,0)+duration

    def finish(self, started):
        now = time.ticks_us()
        self.total += time.ticks_diff(now,started)
        self.frames += 1
        if time.ticks_diff(now,self.window) >= 3000000:
            factor = 1.0/(1000*self.frames)
            other = max(0,self.total-sum(self.sums.values()))
            print("[PERF] ms/frame n=%d total=%.1f %s other=%.1f" %
                  (self.frames,self.total*factor,
                   " ".join("%s=%.1f" % (k,self.sums[k]*factor) for k in self.STAGES),
                   other*factor))
            report={'kind':'perf','ticks_ms':time.ticks_ms(),'frames':self.frames,
                    'total_ms':self.total*factor,'stage_ms':dict((k,v*factor) for k,v in self.sums.items()),
                    'other_ms':other*factor}
            self.reset()
            return report


def make_tracker():
    return MultiTracker(width=C.PREVIEW_WIDTH,
        arm=getattr(C,'TRACK_ARM_X',.72),commit=getattr(C,'TRACK_COMMIT_X',.88),
        confirm_ms=getattr(C,'TRACK_CONFIRM_MS',250),confirm_hits=getattr(C,'TRACK_CONFIRM_HITS',3),
        hold_ms=getattr(C,'TRACK_HOLD_MS',140),hold_hits=getattr(C,'TRACK_HOLD_HITS',2),
        lost_ms=getattr(C,'TRACK_LOST_MS',800),match_distance=getattr(C,'TRACK_MATCH_DISTANCE',70),
        min_travel=getattr(C,'TRACK_MIN_TRAVEL',55),jitter=getattr(C,'TRACK_JITTER',8),
        common_jump=getattr(C,'TRACK_COMMON_JUMP',22),shake_hold_ms=getattr(C,'TRACK_SHAKE_HOLD_MS',350),
        max_tracks=getattr(C,'TRACK_MAX_TARGETS',12))


def text(img, x, y, value, color=(255,255,255), size=20):
    img.draw_string_advanced(x, y, size, str(value), color=color)


def button_layout(browsing=False, burst=False):
    # Drawing and touch use exactly the same rectangles and action IDs.
    if browsing:
        return ((8,120,108,84,"上一张",4), (8,240,108,84,"下一张",5),
                (524,120,108,84,"返回",2), (524,360,108,84,"退出",7))
    return ((8,72,108,84,"拍照",0), (8,168,108,84,"停止" if burst else "连拍",1),
            (8,264,108,84,"相册",2), (8,360,108,84,"标签",3),
            (524,72,108,84,"场景",4), (524,168,108,84,"模式",6),
            (524,264,108,84,"清序",5),
            (524,360,108,84,"退出",7))


def touch_action(x, y, browsing=False, burst=False):
    for bx, by, bw, bh, name, action in button_layout(browsing, burst):
        if bx <= x < bx+bw and by <= y < by+bh:
            return action
    return None


def panel(view, x, y, w, h, color):
    # Neutral black at 50% opacity: integer divide by two, no per-channel tint.
    # Keep a same-appearance fallback for firmware builds lacking scalar shifts.
    global PANEL_SHIFT_FAST
    pixels = view.to_numpy_ref()
    region = pixels[y:y+h,x:x+w,:]
    if PANEL_SHIFT_FAST is not False:
        try:
            if np is None or not hasattr(np,"right_shift"):
                raise NotImplementedError("right_shift unavailable")
            blended = np.right_shift(region,1)
            PANEL_SHIFT_FAST = True
        except (TypeError, ValueError, NotImplementedError):
            PANEL_SHIFT_FAST = False
            print("[RENDER] Integer shift unavailable; half-opacity multiply fallback")
    if PANEL_SHIFT_FAST:
        pixels[y:y+h,x:x+w,:] = blended
    else:
        pixels[y:y+h,x:x+w,:] = region * 0.5


def rgb_bytes(img):
    pixels = img.to_numpy_ref()
    if pixels.shape != (img.height(),img.width(),3):
        raise RuntimeError("Expected contiguous RGB888 HWC image buffer")
    return memoryview(pixels.reshape((img.width()*img.height()*3,)))


def copy_rgb888(target, source, x, y):
    global COPY_BYTES_FAST
    if x < 0 or y < 0 or x+source.width()>target.width() or y+source.height()>target.height():
        raise ValueError("Preview copy outside screen")
    if COPY_BYTES_FAST is not False:
        try:
            src, dst = rgb_bytes(source), rgb_bytes(target)
            row_bytes, stride = source.width()*3, target.width()*3
            if x == 0 and source.width() == target.width():
                start = y*stride
                dst[start:start+row_bytes*source.height()] = src
            else:
                for row in range(source.height()):
                    start = (y+row)*stride+x*3
                    dst[start:start+row_bytes] = src[row*row_bytes:(row+1)*row_bytes]
            COPY_BYTES_FAST = True
            return
        except (TypeError, ValueError, NotImplementedError):
            COPY_BYTES_FAST = False
            print("[RENDER] Byte buffer unavailable; array copy fallback")
    target.to_numpy_ref()[y:y+source.height(),x:x+source.width(),:] = source.to_numpy_ref()


def fit_geometry(width, height):
    scale = min(C.WIDTH / width, C.HEIGHT / height)
    w, h = int(width * scale), int(height * scale)
    return scale, (C.WIDTH-w)//2, (C.HEIGHT-h)//2


def map_box(box, sx=1.0, sy=1.0, ox=0, oy=0):
    if box is None:
        return None
    x,y,w,h = box
    return (int(x*sx)+ox, int(y*sy)+oy, int(w*sx), int(h*sy))


def letterbox(frame):
    scale, x, y = fit_geometry(frame.width(), frame.height())
    fitted = frame.to_rgb888(x_scale=scale, y_scale=scale)
    canvas = image.Image(C.WIDTH, C.HEIGHT, image.RGB888)
    canvas.clear()
    copy_rgb888(canvas,fitted,x,y)
    return canvas, scale, x, y


def capture_photo(sensor, album, label, scene, stable, frame_number, mode="arrow", sequence=None):
    # Predict from a downscaled copy of THIS photo, rather than assigning a
    # previous preview frame's result to an asynchronously captured image.
    photo = sensor.snapshot(chn=CAM_CHN_ID_0)
    if (photo.width(), photo.height()) != (C.PHOTO_WIDTH, C.PHOTO_HEIGHT):
        raise RuntimeError("Photo channel must output 1280x720")
    captured_at = time.ticks_ms()
    sample = photo.to_rgb888(x_scale=C.PREVIEW_WIDTH/photo.width(),
                             y_scale=C.PREVIEW_HEIGHT/photo.height()).to_rgb565()
    if (sample.width(), sample.height()) != (C.PREVIEW_WIDTH, C.PREVIEW_HEIGHT):
        raise RuntimeError("Photo detection copy must be 640x360")
    prediction = detect_multi_colors(sample) if mode=="color" else detect(sample)
    photo_box = map_box(prediction["box"], photo.width()/sample.width(), photo.height()/sample.height())
    saved = album.save(photo, label, {"scene": scene, "ticks_ms": captured_at,
        "prediction": prediction, "prediction_size": [sample.width(), sample.height()],
        "photo_box": photo_box, "stable": stable, "stable_source": "preceding_preview",
        "preview_frame": frame_number, "mode":mode, "color_sequence":list(sequence or [])})
    return saved


def record_event(album, mode, label, result, sequence):
    import json
    record = {"ticks_ms":time.ticks_ms(),"mode":mode,"label":label,
              "gpio_code":EVENT_CODES[label],"result":result,"sequence":list(sequence)}
    with open(album.path+"/events.jsonl","a") as f:
        f.write(json.dumps(record)+"\n")


def draw_ui(ui, title, subtitle, browsing=False, burst=False, notice="", box=None, fps=None, roi=None, tracks=None, gates=None):
    if roi:
        ui.draw_rectangle(roi,color=(255,210,60),thickness=1)
    if box:
        ui.draw_rectangle(box, color=(80,255,150), thickness=2)
    if gates:
        for x in gates:
            ui.draw_line(int(x),60,int(x),419,color=(255,160,30),thickness=1)
    if tracks:
        for track in tracks:
            if not track['observed']:
                continue
            color=(120,180,255) if track['counted'] else (255,70,70) if track['blocked'] else (80,255,150)
            ui.draw_rectangle(map_box(track['box'],1,1,0,60),color=color,thickness=2)
            text(ui,int(track['box'][0]),max(60,int(track['box'][1])+40),
                 '%d %s'%(track['id'],COLOR_TEXT[track['color']]),color=color,size=16)
    panel(ui,124,4,392,56,(15,25,40))
    text(ui,136,7,title,size=28)
    if not browsing:
        text(ui,408,14,"-- FPS" if fps is None else "%.1f FPS" % fps,size=20)
    text(ui,136,37,subtitle,size=18)
    for x, y, w, h, name, action in button_layout(browsing, burst):
        panel(ui,x,y,w,h,(20,40,65))
        ui.draw_rectangle(x,y,w,h,color=(150,185,210),thickness=1)
        text(ui,x+(w-len(name)*28)//2,y+26,name,size=28)
    if notice:
        panel(ui,124,434,392,38,(15,25,40))
        text(ui,136,442,notice,size=22)


def show_preview(view, retained):
    # One format, one layer, one submission. Retain recent buffers across refresh.
    Display.show_image(view)
    retained.append(view)
    if len(retained) > 2:
        retained.pop(0)


def main():
    sensor = None
    display_ready = media_ready = False
    link = None
    recorder = None
    recorder_error = ''
    end_reason = 'stopped'
    try:
        os.exitpoint(os.EXITPOINT_ENABLE)
        print("[CAR 3] Opening album at", C.ALBUM_ROOT)
        album = Album(C.ALBUM_ROOT, C.MIN_FREE_BYTES)
        try:
            recorder=RunRecorder(album.path,C)
            recorder.write({'kind':'start','ticks_ms':time.ticks_ms()},True)
        except Exception as e:
            recorder_error=str(e)
            print('[RECORDER INIT FAILED]',e)
        with open(album.path + "/settings.json", "w") as f:
            import json
            json.dump({"version": "arrow-album-v1.6.1", "blue_lab": C.BLUE_LAB,
                       "white_min": C.WHITE_MIN, "white_spread": C.WHITE_SPREAD,
                       "min_iou": C.MIN_IOU, "min_margin": C.MIN_MARGIN,
                       "hmirror": C.HMIRROR, "vflip": C.VFLIP,
                       "preview_size": [C.PREVIEW_WIDTH,C.PREVIEW_HEIGHT],
                       "photo_size": [C.PHOTO_WIDTH,C.PHOTO_HEIGHT],
                       "display_size": [C.WIDTH,C.HEIGHT],
                       "color_roi":getattr(C,"COLOR_ROI",(.20,.25,.60,.65)),
                       "color_lab":getattr(C,"COLOR_LAB",DEFAULT_LAB)}, f)
        mux = FPIOA()
        print("[CAR 4] Initializing key, touch and camera")
        mux.set_function(61, FPIOA.GPIO61)
        key = Pin(61, Pin.IN, pull=Pin.PULL_UP)
        touch = None
        if C.DISPLAY == "LCD":
            try:
                from machine import TOUCH
                touch = TOUCH(0)
            except Exception as e:
                print("Touch unavailable; KEY: short photo, long change label", e)
        # Use the board firmware's default CSI, as verified by diagnose_preview.py.
        # Sensor(id=0) forces a physical CSI bus that may not be wired on Yahboom.
        sensor = Sensor()
        sensor.reset()
        sensor.set_framesize(width=C.PHOTO_WIDTH, height=C.PHOTO_HEIGHT, chn=CAM_CHN_ID_0)
        sensor.set_pixformat(Sensor.RGB565, chn=CAM_CHN_ID_0)
        sensor.set_framesize(width=C.PREVIEW_WIDTH, height=C.PREVIEW_HEIGHT, chn=CAM_CHN_ID_1)
        sensor.set_pixformat(Sensor.RGB565, chn=CAM_CHN_ID_1)
        sensor.set_hmirror(C.HMIRROR)
        sensor.set_vflip(C.VFLIP)
        if C.DISPLAY == "LCD":
            Display.init(Display.ST7701, width=C.WIDTH, height=C.HEIGHT, to_ide=C.TO_IDE, osd_num=1)
        else:
            Display.init(Display.VIRT, width=C.WIDTH, height=C.HEIGHT, to_ide=True, osd_num=1)
        display_ready = True
        MediaManager.init()
        media_ready = True
        sensor.run()
        print("[CAR 5] Camera/display running")
        try:
            from gpio_link import audit_pins
            pin_audit=audit_pins(mux)
            print('[PIN-AUDIT] Camera/display active:',pin_audit)
            if recorder:
                recorder.write({'kind':'pin_audit','pins':pin_audit,'ticks_ms':time.ticks_ms()},True)
        except Exception as e:
            print('[PIN-AUDIT] Query failed:',e)
        retained_views = []
        if C.GPIO_ENABLE:
            from gpio_link import GpioLink
            link = GpioLink()
        gate = StableEvent(C.CONFIRM_FRAMES, C.REARM_FRAMES)
        tracker = make_tracker()
        if recorder:
            recorder.write({'kind':'tracker_settings','parameters':dict((name,getattr(tracker,name)) for name in
                ('width','arm','commit','confirm_ms','confirm_hits','hold_ms','hold_hits','lost_ms',
                 'match_distance','min_travel','jitter','common_jump','shake_hold_ms','max_tracks'))},True)
        mode = getattr(C,"VISION_MODE","arrow")
        if mode not in ("arrow","color"):
            raise ValueError("VISION_MODE must be arrow or color")
        color_sequence = []
        label_index = scene_index = 0
        burst_left, burst_label, burst_scene = 0, "unknown", "normal"
        next_capture = time.ticks_ms()
        browsing, paths, photo_index = False, [], 0
        key_raw, key_state = 1, 1
        key_changed = key_down = time.ticks_ms()
        touch_down = False
        message, message_at = "预热中", time.ticks_ms()
        warmed_at = time.ticks_ms()
        frames = 0
        preview_fps = PreviewFPS(time.ticks_ms())
        profiler = FrameProfiler()
        last_log_us=last_gc_us=0
        while True:
            os.exitpoint()
            frame_started = time.ticks_us()
            profiler.current={}
            now = time.ticks_ms()
            action = None
            was_browsing = browsing
            # Debounced GPIO61 user key: short capture, long cycle label.
            raw = key.value()
            if raw != key_raw:
                key_raw, key_changed = raw, now
            if raw != key_state and time.ticks_diff(now, key_changed) >= 35:
                key_state = raw
                if raw == 0:
                    key_down = now
                else:
                    action = 3 if time.ticks_diff(now, key_down) >= 800 else 0
            if touch is not None:
                pts = touch.read(1)
                active = bool(pts) and pts[0].event != touch.EVENT_UP
                if active and not touch_down:
                    p = pts[0]
                    action = touch_action(p.x, p.y, browsing, burst_left > 0)
                touch_down = active
            snap = False
            if action == 0 and not browsing:
                snap = True
            elif action == 1 and not browsing:
                burst_left = 0 if burst_left else C.BURST_COUNT
                burst_label, burst_scene = C.LABELS[label_index], SCENES[scene_index]
                next_capture = now
            elif action == 2:
                burst_left = 0
                if not browsing:
                    paths = album.photos()
                    photo_index = max(0, len(paths)-1)
                    browsing = bool(paths)
                    if not paths:
                        message, message_at = "还没有照片", now
                else:
                    browsing = False
            elif action == 3 and not browsing:
                label_index = (label_index+1) % len(C.LABELS)
            elif action == 4:
                if browsing:
                    photo_index = max(0, photo_index-1)
                else:
                    scene_index = (scene_index+1) % len(SCENES)
            elif action == 5:
                if browsing:
                    photo_index = min(len(paths)-1, photo_index+1)
                else:
                    color_sequence = []
                    tracker.reset()
                    message, message_at = "顺序已清空", now
            elif action == 6:
                if browsing:
                    browsing = False
                else:
                    mode = "color" if mode=="arrow" else "arrow"
                    gate = StableEvent(C.CONFIRM_FRAMES,C.REARM_FRAMES)
                    tracker.pause()
                    message, message_at = ("颜色模式" if mode=="color" else "箭头模式"), now
                    print("[MODE]", mode)
                burst_left = 0
            elif action == 7:
                end_reason = 'exit_button'
                if recorder:
                    recorder.write({'kind':'control','action':7,'mode':mode,'browsing':browsing,
                        'ticks_ms':now,'sequence':list(color_sequence),'tracker_epoch':tracker.epoch},True)
                break
            if was_browsing and not browsing:
                preview_fps.reset(time.ticks_ms())
                profiler.reset()
                tracker.pause()
            if action is not None and recorder:
                recorder.write({'kind':'control','action':action,'mode':mode,'browsing':browsing,
                    'ticks_ms':now,'sequence':list(color_sequence),'tracker_epoch':tracker.epoch},True)
            if browsing:
                try:
                    photo_view = image.Image(paths[photo_index])
                    view, _, _, _ = letterbox(photo_view)
                    del photo_view
                    filename = paths[photo_index].split('/')[-1]
                    parts = filename.rsplit('.',1)[0].split('_',1)
                    photo_tag = LABEL_TEXT[C.LABELS.index(parts[1])] if len(parts)>1 and parts[1] in C.LABELS else "未标注"
                    draw_ui(view,"相册 %d / %d" % (photo_index+1,len(paths)),"标签："+photo_tag,browsing=True)
                    show_preview(view,retained_views)
                    del view
                except Exception as e:
                    browsing = False
                    message, message_at = "照片读取失败，见终端", now
                    print("ALBUM READ FAILED", e)
                if link:
                    link.poll()
                gc.collect()
                time.sleep_ms(30)
                continue
            stage_started = time.ticks_us()
            raw_img = sensor.snapshot(chn=CAM_CHN_ID_1)
            capture_ticks_ms=time.ticks_ms()
            profiler.add("capture",stage_started)
            if (raw_img.width(), raw_img.height()) != (C.PREVIEW_WIDTH,C.PREVIEW_HEIGHT):
                raise RuntimeError("Preview channel must output 640x360")
            if frames == 0:
                print("[CAR 6] First camera frame received")
            stage_started = time.ticks_us()
            result = detect_multi_colors(raw_img) if mode=="color" else detect(raw_img)
            warmed = time.ticks_diff(now, warmed_at) >= 2000
            tracking=None
            if mode=="color":
                tracking=tracker.update(result['candidates'] if warmed else [],now)
                events=tracking['events']
                color_sequence=list(tracker.sequence)
                observed=[t for t in tracking['tracks'] if t['observed'] and t['color']!='unknown']
                stable=observed[0]['color'] if len(observed)==1 else 'unknown'
            else:
                event = gate.update(result["label"],result["present"]) if warmed else None
                events=[{'label':event,'track':None}] if event else []
                stable = gate.stable
            profiler.add("detect",stage_started)
            for item in events:
                event=item['label']
                accepted=link.send(EVENT_CODES[event]) if link else None
                item['gpio_status']=('frame_sent_no_ack' if accepted else 'busy_or_fault') if link else 'disabled'
                print("[EVENT]",mode,event,"code=",EVENT_CODES[event],"sequence=",color_sequence)
                try:
                    record_event(album,mode,event,{'event':item,'detection':result},color_sequence)
                except Exception as e:
                    print("EVENT LOG FAILED",e)
                    message, message_at = "事件记录失败，见终端",now
                if link and not accepted:
                    message, message_at = "GPIO未发送，见终端", now
                    print("GPIO busy/fault: event not sent")
            if events and recorder:
                recorder.write({'kind':'count_events','frame':frames,'ticks_ms':now,
                    'events':events,'sequence':list(color_sequence)},True)
            if link:
                link.poll()
                if link.error:
                    message, message_at = "GPIO故障，见终端", now
                    print(link.error)
            timed = burst_left > 0 and time.ticks_diff(now, next_capture) >= 0
            manual_photo=None
            if (snap or timed) and warmed:
                stage_started = time.ticks_us()
                try:
                    label = burst_label if timed else C.LABELS[label_index]
                    scene = burst_scene if timed else SCENES[scene_index]
                    saved = capture_photo(sensor,album,label,scene,stable,frames,mode,color_sequence)
                    manual_photo={'saved':True,'file':'../'+saved.split('/')[-1]}
                    message, message_at = "已保存 第%d张" % album.count, now
                    print("SAVED 1280x720", saved)
                    if timed:
                        burst_left -= 1
                        next_capture = time.ticks_add(time.ticks_ms(), C.BURST_INTERVAL_MS)
                except Exception as e:
                    manual_photo={'saved':False,'error':str(e)}
                    burst_left = 0
                    message, message_at = "保存失败，见终端", now
                    print("SAVE FAILED", e)
                finally:
                    profiler.add("photo",stage_started)
            notice = message if time.ticks_diff(now,message_at)<2500 else ""
            if not warmed:
                notice = "预热中"
            elif burst_left:
                notice = "连拍 剩余%d张" % burst_left
            elif mode=="color" and not notice:
                notice = "顺序："+"-".join(COLOR_TEXT[c] for c in color_sequence) if color_sequence else "目标从左向右越线计数"
                if tracking['motion_hold']:
                    notice='画面晃动/关联歧义 暂缓计数'
                elif tracking['sequence_uncertain']:
                    notice='顺序待复核，轨迹已记录'
            if recorder_error or (recorder and recorder.error):
                notice='SD记录停止，见终端'
            title = ("颜色 跟踪%d块"%len(tracking['tracks'])) if mode=="color" else ("箭头："+DIRECTION_TEXT[stable])
            subtitle = "标签：%s  场景：%s" % (LABEL_TEXT[label_index],SCENE_TEXT[scene_index])
            stage_started = time.ticks_us()
            view, scale, offset_x, offset_y = letterbox(raw_img)
            profiler.add("compose",stage_started)
            if frames == 0:
                print("[RENDER] Center pixels raw/canvas:",
                      raw_img.get_pixel(C.PREVIEW_WIDTH//2,C.PREVIEW_HEIGHT//2),
                      view.get_pixel(C.WIDTH//2,C.HEIGHT//2))
            screen_box = map_box(result["box"],scale,scale,offset_x,offset_y)
            screen_roi = map_box(result.get("roi"),scale,scale,offset_x,offset_y)
            stage_started = time.ticks_us()
            draw_ui(view,title,subtitle,burst=burst_left>0,notice=notice,box=screen_box if mode!='color' else None,
                    fps=preview_fps.value,roi=screen_roi,
                    tracks=tracking['tracks'] if tracking else None,gates=tracking['gates'] if tracking else None)
            profiler.add("ui",stage_started)
            stage_started = time.ticks_us()
            show_preview(view,retained_views)
            profiler.add("show",stage_started)
            if frames == 0:
                print("[CAR 7] First preview submitted")
            stage_started=time.ticks_us()
            if recorder:
                important=bool(events) or bool(tracking and tracking['notes'])
                img_record=recorder.image(raw_img,frames,important)
                recorder.write({'kind':'frame','frame':frames,'ticks_ms':now,'capture_ticks_ms':capture_ticks_ms,'mode':mode,
                    'detection':result,'tracking':tracking,'events':events,'sequence':list(color_sequence),
                    'manual_label':C.LABELS[label_index],'scene':SCENES[scene_index],'manual_photo':manual_photo,
                    'fps':preview_fps.value,'stage_us_before_log':dict(profiler.current),
                    'previous_log_us':last_log_us,'previous_gc_us':last_gc_us,
                    'gpio':{'enabled':bool(link),'state':link.state if link else 'disabled',
                            'error':link.error if link else '',
                            'stb':link.stb.value() if link else None,
                            'sent_frames':link.sent_frames if link else 0},'image':img_record},bool(events))
            last_log_us=time.ticks_diff(time.ticks_us(),stage_started)
            profiler.add('log',stage_started)
            del raw_img, view
            frames += 1
            stage_started = time.ticks_us()
            gc.collect()
            last_gc_us=time.ticks_diff(time.ticks_us(),stage_started)
            profiler.add("gc",stage_started)
            preview_fps.tick(time.ticks_ms())
            performance=profiler.finish(frame_started)
            if performance and recorder:
                recorder.write(performance)
    except KeyboardInterrupt:
        end_reason = 'keyboard_interrupt'
        print("Stopped by user")
    except Exception as e:
        end_reason = 'error'
        sys.print_exception(e)
        if recorder:
            error_record={'kind':'error','ticks_ms':time.ticks_ms(),'error':repr(e)}
            try:
                import io
                trace=io.StringIO()
                sys.print_exception(e,trace)
                error_record['traceback']=trace.getvalue()
            except Exception:
                pass
            recorder.write(error_record,True)
        raise
    finally:
        if recorder:
            recorder.write({'kind':'end','ticks_ms':time.ticks_ms(),'reason':end_reason},True)
            recorder.close()
        if link:
            link.close()
        if sensor:
            sensor.stop()
        if display_ready:
            Display.deinit()
        if media_ready:
            MediaManager.deinit()


if __name__ == "__main__":
    main()
