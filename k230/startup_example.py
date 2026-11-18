# Optional /sdcard/main.py launcher. Back up the existing main.py first.
import sys
sys.path.insert(0, "/sdcard/car_vision")
# Avoid importing 'main': the startup file may itself occupy that module name.
exec(open("/sdcard/car_vision/main.py").read(), {"__name__": "__main__"})
