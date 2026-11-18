"""K230 turn-only validation: live screen and serial direction events."""

import gc
import os
import sys
import time

APP_DIR = "/sdcard/turn_verify"
if APP_DIR not in sys.path:
    sys.path.insert(0, APP_DIR)

from turn_detector import PREVIEW_SIZE, detect, empty
from turn_shape import StableEvent

SCREEN = (640, 480)
PANEL_Y = PREVIEW_SIZE[1]
PANEL_HEIGHT = SCREEN[1] - PANEL_Y
ANALYSIS_PERIOD_MS = 100
PANEL_PERIOD_MS = 300
HOLD_MS = 1500
VERSION = "turn-v1"

NAMES = {"left": "左转", "right": "右转", "unknown": "未识别"}
NOTES = {"search": "寻找蓝底白箭头", "shape": "蓝色目标，箭头形状不符",
         "partial": "候选目标贴边，等完整入镜", "far": "箭头较小，请靠近",
         "ambiguous": "同框左右冲突，暂不确认", "candidate": "同方向连续 3 次后确认",
         "camera": "取帧超时"}


def draw_panel(img, display, result, direction, event_count, fps, hits, link=None, link_failed=False):
    img.draw_rectangle(0, 0, SCREEN[0], PANEL_HEIGHT, color=(13, 26, 41), fill=True)
    tone = (127, 237, 170) if direction != "unknown" else (247, 250, 255)
    img.draw_string_advanced(14, 6, 40, NAMES[direction], color=tone)
    link_text = "识别 %.1f FPS   确认 %d 次" % (fps, event_count)
    if link_failed or (link is not None and link.error is not None):
        link_text = "GPIO 未发送，请看串口"
    elif link is not None:
        link_text = "确认 %d   已发 %d   %.1f FPS" % (event_count, link.sent_turns, fps)
    img.draw_string_advanced(262, 13, 23, link_text, color=(204, 226, 244))
    message = NOTES[result["reason"]]
    if result["label"] != "unknown":
        message = "候选 %s  %d/3" % (NAMES[result["label"]], min(3, hits))
    img.draw_string_advanced(16, 54, 24, message, color=(247, 250, 255))
    box = result["box"]
    if box is not None:
        line = "目标 %dx%d px   匹配 %.2f   左右差 %.2f" % (box[2], box[3], result["score"], result["margin"])
        img.draw_string_advanced(16, 88, 21, line, color=(175, 205, 226))
    display.show_image(img, y=PANEL_Y, layer=display.LAYER_OSD0)


def main(link_factory=None):
    import image
    from media.sensor import Sensor, CAM_CHN_ID_0, CAM_CHN_ID_1
    from media.display import Display
    from media.media import MediaManager

    display_ready = media_ready = sensor_running = False
    link, link_failed = None, False
    try:
        os.exitpoint(os.EXITPOINT_ENABLE)
        sensor = Sensor()
        sensor.reset()
        width, height = PREVIEW_SIZE
        sensor.set_framesize(width=width, height=height, chn=CAM_CHN_ID_0)
        sensor.set_pixformat(Sensor.RGB565, chn=CAM_CHN_ID_0)
        sensor.set_framesize(width=width, height=height, chn=CAM_CHN_ID_1)
        sensor.set_pixformat(Sensor.YUV420SP, chn=CAM_CHN_ID_1)
        sensor.set_hmirror(False)
        sensor.set_vflip(False)
        preview = sensor.bind_info(x=0, y=0, chn=CAM_CHN_ID_1)
        Display.bind_layer(**preview, layer=Display.LAYER_VIDEO1)
        Display.init(Display.ST7701, width=SCREEN[0], height=SCREEN[1], to_ide=False, osd_num=1)
        display_ready = True
        MediaManager.init()
        media_ready = True
        sensor.run()
        sensor_running = True
        if link_factory is not None:
            try:
                link = link_factory()
            except Exception as exc:
                link_failed = True
                print("[LINK] GPIO disabled:", exc)
        panels = [image.Image(SCREEN[0], PANEL_HEIGHT, image.RGB888) for _ in range(3)]
        panel_index = 0
        gate = StableEvent(confirm=3, rearm=6)
        shown = "unknown"
        count = 0
        fps = 0.
        fps_count = 0
        now = time.ticks_ms()
        last_seen = fps_since = last_draw = now
        draw_panel(panels[0], Display, empty(), shown, count, fps, 0, link, link_failed)
        panel_index = 1
        print("[TURN]", VERSION, "left/right validation", PREVIEW_SIZE, "GPIO", link is not None)
        if link is not None:
            link.poll()
        while True:
            os.exitpoint()
            started = time.ticks_ms()
            try:
                frame = sensor.snapshot(chn=CAM_CHN_ID_0, timeout=120)
            except RuntimeError:
                result = empty("camera")
            else:
                result = detect(frame)
                del frame
                fps_count += 1

            now = time.ticks_ms()
            event = gate.update(result["label"], result["present"])
            if event:
                shown = event
                last_seen = now
            elif shown != "unknown" and gate.stable == shown:
                last_seen = now
            elif time.ticks_diff(now, last_seen) >= HOLD_MS:
                shown = "unknown"
            if event:
                count += 1
                tx = "local"
                if link is not None:
                    tx = "sent_no_ack" if link.send_turn(event) else "send_failed"
                elif link_failed:
                    tx = "disabled"
                print("[TURN] #%d %s score=%.2f margin=%.2f box=%s %s" %
                      (count, event, result["score"], result["margin"], result["box"], tx))
            if link is not None:
                link.poll()
            fps_elapsed = time.ticks_diff(now, fps_since)
            if fps_elapsed >= 1000:
                fps = fps_count * 1000 / fps_elapsed
                fps_since, fps_count = now, 0
                gc.collect()
            if event or time.ticks_diff(now, last_draw) >= PANEL_PERIOD_MS:
                draw_panel(panels[panel_index], Display, result, shown, count, fps, gate.count, link, link_failed)
                panel_index = (panel_index + 1) % len(panels)
                last_draw = now
            delay = ANALYSIS_PERIOD_MS - time.ticks_diff(time.ticks_ms(), started)
            if delay > 0:
                time.sleep_ms(delay)
    except KeyboardInterrupt:
        print("[TURN] Stopped")
    finally:
        if link is not None:
            link.close()
        if sensor_running:
            sensor.stop()
        if display_ready:
            Display.deinit()
        if media_ready:
            MediaManager.deinit()


if __name__ == "__main__":
    main()
