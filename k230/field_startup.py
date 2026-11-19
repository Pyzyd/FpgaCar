"""K230 SD-card launcher. Install as /sdcard/main.py for field integration."""
import sys

sys.path.insert(0, '/sdcard/car_vision')
sys.path.insert(0, '/sdcard/car_vision/turn_verify')
from field_vision import main

if __name__ == '__main__':
    main(send_gpio=True)
