"""Launch the turn verifier with the fixed Ti60 GPIO link enabled."""

import sys

if "/sdcard/turn_verify" not in sys.path:
    sys.path.insert(0, "/sdcard/turn_verify")

from field_turn import main
from turn_gpio import TurnLink

if __name__ == "__main__":
    main(TurnLink)
