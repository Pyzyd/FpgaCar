"""Measure the K230 only, with all Ti60 signal wires disconnected."""

import os
import sys
import time

if "/sdcard/turn_verify" not in sys.path:
    sys.path.insert(0, "/sdcard/turn_verify")

from turn_gpio import TurnLink


def main():
    os.exitpoint(os.EXITPOINT_ENABLE)
    link = TurnLink()
    try:
        print("[LEVEL] K230 ONLY. Keep Ti60 signal leads disconnected.")
        for pin in link.data:
            pin.value(1)
        link.stb.value(1)
        print("[LEVEL] HIGH for 45 s: pin 1/2/8/10. Measure each relative to pin 4 GND.")
        for _ in range(450):
            os.exitpoint()
            time.sleep_ms(100)
    finally:
        link.close()
        print("[LEVEL] Outputs low; measurement complete.")


if __name__ == "__main__":
    main()
