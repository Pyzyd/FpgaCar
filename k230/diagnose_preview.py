"""Run this file alone in CanMV IDE; no SD files changed, no GPIO outputs."""
import os
import sys
import time
import image

print("[DIAG 1] Script started; name=", __name__)
print("Firmware:", sys.version)
from media.sensor import Sensor, CAM_CHN_ID_1
from media.display import Display
from media.media import MediaManager

sensor = None
display_ready = media_ready = False
stage = "imports"
try:
    os.exitpoint(os.EXITPOINT_ENABLE)
    stage = "camera reset"
    print("[DIAG 2] Camera reset")
    sensor = Sensor()
    sensor.reset()
    sensor.set_framesize(width=640, height=480, chn=CAM_CHN_ID_1)
    sensor.set_pixformat(Sensor.RGB565, chn=CAM_CHN_ID_1)
    stage = "LCD init"
    print("[DIAG 3] LCD ST7701 640x480")
    Display.init(Display.ST7701, width=640, height=480, to_ide=True)
    display_ready = True
    stage = "media init"
    MediaManager.init()
    media_ready = True
    stage = "LCD test card"
    card = image.Image(640, 480, image.ARGB8888)
    card.draw_rectangle(0,0,640,480,color=(20,70,140),fill=True)
    card.draw_string_advanced(30,180,32,"K230 LCD TEST",color=(255,255,255))
    Display.show_image(card)
    print("[DIAG 4] Blue LCD test card submitted; camera starts in 2s")
    time.sleep_ms(2000)
    del card
    stage = "camera run"
    sensor.run()
    frames = 0
    last_report = time.ticks_ms()
    while True:
        os.exitpoint()
        stage = "snapshot"
        frame = sensor.snapshot(chn=CAM_CHN_ID_1)
        stage = "display raw RGB565"
        Display.show_image(frame)
        frames += 1
        now = time.ticks_ms()
        if time.ticks_diff(now, last_report) >= 1000:
            print("[DIAG 5] Camera preview alive; frames=", frames)
            last_report = now
except KeyboardInterrupt:
    print("Diagnostic stopped")
except Exception as e:
    print("[DIAG FAILED] stage:", stage)
    sys.print_exception(e)
finally:
    if sensor:
        try:
            sensor.stop()
        except Exception as e:
            print("Cleanup sensor:", e)
    if display_ready:
        Display.deinit()
    if media_ready:
        MediaManager.deinit()
