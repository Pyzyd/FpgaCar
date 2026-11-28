"""Yahboom K230 first prototype. Tune with camera photos, not phone photos."""
WIDTH = 640
HEIGHT = 480
PREVIEW_WIDTH = 640
PREVIEW_HEIGHT = 360
PHOTO_WIDTH = 1280
PHOTO_HEIGHT = 720
DISPLAY = "LCD"                 # LCD or IDE (headless board)
TO_IDE = True
HMIRROR = False
VFLIP = False
ALBUM_ROOT = "/sdcard/car_photos"
LABELS = ("unknown", "left", "right", "negative", "red", "green", "blue", "yellow")
BURST_COUNT = 10
BURST_INTERVAL_MS = 1000
MIN_FREE_BYTES = 16 * 1024 * 1024
BLUE_LAB = (0, 70, -10, 90, -128, -12)
MIN_SIGN_SIZE = 48
MAX_CANDIDATES = 3
WHITE_MIN = 85
WHITE_SPREAD = 65
SAMPLE_SIZE = 40
TEMPLATE_SIZE = 24
MIN_IOU = 0.50
MIN_MARGIN = 0.12
CONFIRM_FRAMES = 4
REARM_FRAMES = 8
# Fixed wiring: docs/K230_GPIO_FIXED.md. Enable only after voltage/bench checks.
GPIO_ENABLE = False
DATA_PINS = (42, 43, 34)
STROBE_PIN = 35
GPIO_SYMBOL_MS = 1
GPIO_HEARTBEAT_MS = 500
# Bench color observation window, normalized x/y/w/h; tune for actual mounting.
VISION_MODE = "arrow"            # arrow / color; touchscreen can switch modes.
COLOR_ROI = (.20, .25, .60, .65)
COLOR_LAB = ((20,100,21,127,5,127), (15,95,-128,-16,-5,100),
             (5,80,-10,100,-128,-16), (35,100,-15,20,30,127))
COLOR_MIN_PIXELS = 500
COLOR_DOMINANCE = 1.6
COLOR_CONFIRM_MS = 250
COLOR_CLEAR_MS = 500
# Field-calibration starting values, all gates use original 640x360 coordinates.
TRACK_ROI = (.05,.10,.95,.85)
TRACK_ARM_X = .72
TRACK_COMMIT_X = .88
TRACK_CONFIRM_MS = 250
TRACK_CONFIRM_HITS = 3
TRACK_HOLD_MS = 140
TRACK_HOLD_HITS = 2
TRACK_LOST_MS = 800
TRACK_MATCH_DISTANCE = 70
TRACK_MIN_TRAVEL = 55
TRACK_JITTER = 8
TRACK_COMMON_JUMP = 22
TRACK_SHAKE_HOLD_MS = 350
TRACK_MAX_TARGETS = 12
# Competition calibration: edges use the full 640px capture coordinates.
FIELD_COLOR_ROI = (.05,.40,.95,.60)
# Red and yellow lose chroma when the camera views a screen or a shaded face.
# Keep the green and blue ranges and leave a gap between red and yellow on A.
FIELD_COLOR_LAB = ((16,100,16,127,-8,127), COLOR_LAB[1], COLOR_LAB[2],
                   (30,100,-16,14,20,127))
FIELD_ARM_EDGE = .94
FIELD_PASS_EDGE = .98
FIELD_MIN_TRAVEL = 40
FIELD_EDGE_HOLD_MS = 100
FIELD_STATUS_MS = 200           # Text status updates independently of detection boxes.
FIELD_RECORD_FULL = False       # True for diagnostics with per-frame JSON and periodic JPEGs.
LOG_MIN_FREE_BYTES = 32*1024*1024
LOG_MAX_BYTES = 128*1024*1024
LOG_IMAGE_INTERVAL_MS = 1000
LOG_EVENT_IMAGE_GAP_MS = 250
