"""Yahboom K230 standalone field photo sampler."""

import gc
import os
import sys
import time

VERSION = "v1.5"
PHOTO_SIZE = (1280, 720)
SCREEN_SIZE = (640, 480)
PREVIEW_SIZE = (640, 360)
PANEL_Y = PREVIEW_SIZE[1]
PANEL_HEIGHT = SCREEN_SIZE[1] - PANEL_Y
JPEG_QUALITY = 90
INTERVAL_MS = 250
MIN_GAP_MS = 175  # After a stall, do not take two almost simultaneous photos.
SNAPSHOT_TIMEOUT_MS = 120
DURATIONS = (5000, 15000, 30000)
DATA_MOUNT = "/data"
PHOTO_ROOT = DATA_MOUNT + "/field_photos"
MIN_FREE = 512 * 1024 * 1024
WARMUP_MS = 2000

BG = (14, 28, 42)
WHITE = (250, 251, 255)
MUTED = (180, 210, 230)
BLUE = (27, 86, 134)
SELECTED = (17, 118, 97)
LIVE_ACTIONS = ((10, 48, 200, 70, "5 秒", 5000),
                (220, 48, 200, 70, "15 秒", 15000),
                (430, 48, 200, 70, "30 秒", 30000))


def ascii_digits(value):
    return bool(value) and all("0" <= c <= "9" for c in value)


def run_number(name):
    number = name[4:]
    if name[:4].lower() == "run_" and 4 <= len(number) <= 9 and ascii_digits(number):
        return int(number)
    return 0


def new_run():
    # Require the large partition. A missing /data must not redirect to /sdcard.
    stat = os.statvfs(DATA_MOUNT)
    free = (stat[1] or stat[0]) * stat[4]
    if free < MIN_FREE:
        raise OSError("/data free space below 512 MiB")
    try:
        os.mkdir(PHOTO_ROOT)
    except OSError as exc:
        if exc.args[0] != 17:  # EEXIST on CanMV and Windows Python
            raise
    number = max([0] + [run_number(name) for name in os.listdir(PHOTO_ROOT)]) + 1
    path = PHOTO_ROOT + "/run_%04d" % number
    os.mkdir(path)
    return path


def stage_photo(frame, path):
    temporary = path[:-4] + ".part.jpg"
    try:
        frame.save(temporary, quality=JPEG_QUALITY)
    except Exception:
        try:
            os.remove(temporary)
        except OSError:
            pass
        raise
    return temporary


def publish_photos(pending):
    # Do FAT directory lookups and renames after the timed capture loop.
    failed = 0
    for temporary, path in pending:
        try:
            if os.stat(temporary)[6] <= 0:
                raise OSError("JPEG is empty")
            os.rename(temporary, path)
        except OSError as exc:
            failed += 1
            print("[FIELD] Could not finalize", temporary, exc)
    if hasattr(os, "sync"):
        os.sync()
    return failed


def capture_run(path, duration, snapshot, progress=None, finalizing=None):
    """Take at most one current frame per slot; never backfill missed slots."""
    pending = []
    next_slot, previous_ms, max_gap, worst_capture, worst_save = 0, -MIN_GAP_MS, 0, 0, 0
    capture_sum, save_sum, last_draw, draw_budget = 0, 0, 0, 45
    camera_errors = consecutive_errors = 0
    target = duration // INTERVAL_MS
    gc.collect()  # Reclaim idle/UI objects before the timer starts.
    started = time.ticks_ms()
    try:
        while True:
            os.exitpoint()
            elapsed = time.ticks_diff(time.ticks_ms(), started)
            if elapsed >= duration:
                break
            due = max(next_slot * INTERVAL_MS, previous_ms + MIN_GAP_MS)
            remaining = min(due, duration) - elapsed
            if remaining > 0:
                if progress and pending and elapsed - last_draw >= 1000 and remaining >= draw_budget:
                    last_draw = elapsed
                    progress(len(pending), target, elapsed)
                    draw_budget = max(draw_budget, time.ticks_diff(time.ticks_ms(), started) - elapsed + 15)
                else:
                    time.sleep_ms(remaining)
                continue

            # Slot is based on when the snapshot starts. A frame that completes
            # just across a boundary must not also consume the next slot.
            slot = elapsed // INTERVAL_MS
            next_slot = slot + 1
            try:
                frame = snapshot()
            except RuntimeError as exc:
                camera_errors += 1
                consecutive_errors += 1
                if consecutive_errors >= 3:
                    raise
                continue
            consecutive_errors = 0
            captured_ms = time.ticks_diff(time.ticks_ms(), started)
            actual_width, actual_height = frame.width(), frame.height()
            if (actual_width, actual_height) != PHOTO_SIZE:
                raise RuntimeError("camera returned %dx%d, expected %dx%d" %
                                   (actual_width, actual_height, PHOTO_SIZE[0], PHOTO_SIZE[1]))
            # Use the actual capture time; this is when snapshot returns, not ISP time.
            if captured_ms >= duration:
                del frame
                break
            filename = "%s/%04d_%05dms.jpg" % (path, slot + 1, captured_ms)
            save_started = time.ticks_ms()
            pending.append((stage_photo(frame, filename), filename))
            del frame

            capture_ms = captured_ms - elapsed
            save_ms = time.ticks_diff(time.ticks_ms(), save_started)
            capture_sum += capture_ms
            save_sum += save_ms
            worst_capture = max(worst_capture, capture_ms)
            worst_save = max(worst_save, save_ms)
            if previous_ms >= 0:
                max_gap = max(max_gap, captured_ms - previous_ms)
            previous_ms = captured_ms
    finally:
        try:
            if finalizing and pending:
                finalizing(len(pending), target)
        finally:
            failed = publish_photos(pending)
    divisor = max(1, len(pending))
    return (len(pending) - failed, target, max_gap, capture_sum / divisor,
            save_sum / divisor, worst_capture, worst_save, camera_errors, failed)


def label_at(screen, x, y, size, value, color=WHITE):
    screen.draw_string_advanced(x, y, size, value, color=color)


def button(screen, x, y, w, h, label, color=BLUE, size=24, inset=14):
    screen.draw_rectangle(x, y, w, h, color=color, fill=True)
    label_at(screen, x + inset, y + (h - size) // 2, size, label)


def action_at(areas, x, y):
    for bx, by, w, h, action in areas:
        if bx <= x < bx + w and by <= y < by + h:
            return action
    return None


def draw_panel(screen, display, title, detail, ready, duration):
    # This opaque panel occupies only the bottom of the LCD, beyond VIDEO1.
    screen.draw_rectangle(0, 0, SCREEN_SIZE[0], PANEL_HEIGHT, color=BG, fill=True)
    label_at(screen, 14, 0, 24, title)
    label_at(screen, 14, 25, 20, detail, MUTED)
    if ready:
        label_at(screen, 390, 10, 24, "按板载用户键开拍", MUTED)
        for x, y, w, h, label, action in LIVE_ACTIONS:
            color = SELECTED if action == duration else BLUE
            button(screen, x, y, w, h, label, color, 36, 58 if action == DURATIONS[0] else 48)
    display.show_image(screen, y=PANEL_Y, layer=display.LAYER_OSD0)


LIVE_HITS = tuple((x, y + PANEL_Y, w, h, action) for x, y, w, h, _, action in LIVE_ACTIONS)


def main():
    import image
    from machine import FPIOA, Pin
    from media.sensor import Sensor, CAM_CHN_ID_0, CAM_CHN_ID_1
    from media.display import Display
    from media.media import MediaManager

    sensor = None
    display_ready = media_ready = False
    panels = []
    next_panel = 0
    duration = DURATIONS[0]
    live_title, live_detail = "现场采样  720p", "每 0.25 秒一张"
    try:
        os.exitpoint(os.EXITPOINT_ENABLE)
        mux = FPIOA()
        mux.set_function(61, FPIOA.GPIO61)
        key = Pin(61, Pin.IN, pull=Pin.PULL_UP)
        try:
            from machine import TOUCH
            touch = TOUCH(0)
        except Exception as exc:
            print("[FIELD] Touch unavailable; use the onboard user key:", exc)
            touch = None

        sensor = Sensor()  # Use vendor default CSI rather than forcing id=0.
        sensor.reset()
        width, height = PHOTO_SIZE
        sensor.set_framesize(width=width, height=height, chn=CAM_CHN_ID_0)
        sensor.set_pixformat(Sensor.RGB565, chn=CAM_CHN_ID_0)
        sensor.set_framesize(width=PREVIEW_SIZE[0], height=PREVIEW_SIZE[1], chn=CAM_CHN_ID_1)
        sensor.set_pixformat(Sensor.YUV420SP, chn=CAM_CHN_ID_1)
        sensor.set_hmirror(False)
        sensor.set_vflip(False)
        preview = sensor.bind_info(x=0, y=0, chn=CAM_CHN_ID_1)
        Display.bind_layer(**preview, layer=Display.LAYER_VIDEO1)
        Display.init(Display.ST7701, width=SCREEN_SIZE[0], height=SCREEN_SIZE[1], to_ide=False, osd_num=1)
        display_ready = True
        MediaManager.init()
        media_ready = True
        sensor.run()
        for _ in range(3):
            panels.append(image.Image(SCREEN_SIZE[0], PANEL_HEIGHT, image.RGB888))

        def status(title, detail, ready=False):
            nonlocal next_panel
            draw_panel(panels[next_panel], Display, title, detail, ready, duration)
            next_panel = (next_panel + 1) % len(panels)

        status("现场采样", "摄像头预热中")
        warm_at = time.ticks_ms()
        while time.ticks_diff(time.ticks_ms(), warm_at) < WARMUP_MS:
            os.exitpoint()
            time.sleep_ms(20)

        def snapshot():
            return sensor.snapshot(chn=CAM_CHN_ID_0, timeout=SNAPSHOT_TIMEOUT_MS)

        def progress(count, target, elapsed):
            status("已拍 %d/%d 张    %.1f 张/秒" % (count, target, count * 1000 / elapsed),
                   "已用 %.1f 秒，请勿断电" % (elapsed / 1000))

        def finalizing(count, target):
            status("正在整理 %d/%d 张" % (count, target), "请勿断电")

        status(live_title, live_detail, True)
        print("[FIELD]", VERSION, "Ready", PHOTO_SIZE, "quality", JPEG_QUALITY, "path", PHOTO_ROOT)
        raw_key = stable_key = key.value()
        changed = time.ticks_ms()
        touch_down = False
        while True:
            os.exitpoint()
            now = time.ticks_ms()
            trigger = False
            raw = key.value()
            if raw != raw_key:
                changed, raw_key = now, raw
            if raw != stable_key and time.ticks_diff(now, changed) >= 35:
                stable_key = raw
                trigger = raw == 0
            if touch is not None:
                pts = touch.read(1)
                active = bool(pts) and pts[0].event != touch.EVENT_UP
                if active and not touch_down:
                    p = pts[0]
                    selected = action_at(LIVE_HITS, p.x, p.y)
                    if selected in DURATIONS and selected != duration:
                        duration = selected
                        if not trigger:
                            status(live_title, live_detail, True)
                touch_down = active
            if trigger:
                try:
                    request = duration
                    path = new_run()
                    status("已拍 0/%d 张" % (request // INTERVAL_MS), "正在拍摄，请勿断电")
                    stats = capture_run(path, request, snapshot, progress, finalizing)
                    count, target, max_gap, cap_avg, save_avg, cap_max, save_max, cam_errors, file_errors = stats
                    print("[FIELD] %s: %d/%d, capture avg/max=%.1f/%dms, JPEG+write avg/max=%.1f/%dms, max gap=%dms, camera errors=%d, file errors=%d" %
                          (path, count, target, cap_avg, cap_max, save_avg, save_max, max_gap, cam_errors, file_errors))
                    title = "完成" if count == target else "漏拍"
                    live_title = "%s  %d/%d 张" % (title, count, target)
                    live_detail = "%.1f 张/秒   最长 %d ms" % (count * 1000 / request, max_gap)
                    status(live_title, live_detail, True)
                except Exception as exc:
                    print("[FIELD] Capture error:", exc)
                    sys.print_exception(exc)
                    live_title, live_detail = "连拍中断", "已拍照片保留，请看串口"
                    status(live_title, live_detail, True)
                raw_key = stable_key = key.value()
                changed = time.ticks_ms()
            time.sleep_ms(20)
    except KeyboardInterrupt:
        print("[FIELD] Stopped")
    finally:
        if sensor is not None:
            sensor.stop()
        if display_ready:
            Display.deinit()
        if media_ready:
            MediaManager.deinit()


if __name__ == "__main__":
    main()
