"""K230 -> Ti60 fixed DATA[2:0]+STB sender. No receiver acknowledgement."""

import time
from machine import FPIOA, Pin

DATA_PINS = (42, 43, 34)
STROBE_PIN = 35
HEARTBEAT_MS = 500
SYMBOL_MS = 1
DIRECTION = {"left": 1, "right": 2}


class TurnLink:
    def __init__(self):
        mux = FPIOA()
        getter = getattr(mux, "get_pin_func", None)
        if getter is None:
            raise RuntimeError("cannot check the four K230 pin functions")
        pins = DATA_PINS + (STROBE_PIN,)
        gpio_functions = [getattr(FPIOA, "GPIO%d" % pin) for pin in pins]
        observed = [getter(pin) for pin in pins]
        print("[LINK] Pin functions (42,43,34,35):", observed)
        free = getattr(FPIOA, "RESV", None)
        for pin, active, gpio in zip(pins, observed, gpio_functions):
            if active not in (None, free, gpio):
                raise RuntimeError("GPIO%d is mapped to %s; GPIO output aborted" % (pin, active))

        self.stb = None
        self.data = []
        self.error = None
        self.last_sent = None
        self.sent_turns = 0
        self.sent_heartbeats = 0
        try:
            # Define STB low before changing the three data lines.
            mux.set_function(STROBE_PIN, gpio_functions[3])
            self.stb = Pin(STROBE_PIN, Pin.OUT, value=0)
            for i, pin in enumerate(DATA_PINS):
                mux.set_function(pin, gpio_functions[i])
                self.data.append(Pin(pin, Pin.OUT, value=0))
        except Exception:
            self.close()
            raise

    def _symbol(self, value):
        for bit, pin in enumerate(self.data):
            pin.value((value >> bit) & 1)
        time.sleep_ms(SYMBOL_MS)
        self.stb.value(1)
        time.sleep_ms(SYMBOL_MS)
        self.stb.value(0)
        time.sleep_ms(SYMBOL_MS)

    def _send(self, category, value):
        if self.error is not None:
            return False
        try:
            for _ in range(2):
                for symbol in (0, category, 0, value, 0):
                    self._symbol(symbol)
            self.last_sent = time.ticks_ms()
            return True
        except Exception as exc:
            self.error = str(exc)
            print("[LINK] GPIO write failed:", exc)
            self.close()
            return False

    def send_turn(self, label):
        sent = self._send(2, DIRECTION[label])
        if sent:
            self.sent_turns += 1
        return sent

    def poll(self):
        if self.last_sent is None or time.ticks_diff(time.ticks_ms(), self.last_sent) >= HEARTBEAT_MS:
            if self._send(7, 1):
                self.sent_heartbeats += 1

    def close(self):
        pins = ([self.stb] if self.stb is not None else []) + self.data
        for pin in pins:
            try:
                pin.value(0)
            except Exception:
                pass
