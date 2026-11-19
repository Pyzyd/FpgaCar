"""Fixed 3-bit + STB sender for Ti60 src/k230_link.v; no ACK wire.

Each message sends (0,CAT,0,VAL,0) twice. Pulses are hardware-visible even
when the preview loop is slow: sending deliberately blocks for >=30ms.
"""
import time
from machine import FPIOA, Pin
import config as C

# Keep the existing application event codes; translate only on the wire.
EVENTS = {1:(2,1), 2:(2,2), 3:(1,1), 4:(1,3), 5:(1,4), 6:(1,2)}


def audit_pins(mux):
    """Read-only mux audit. It does not prove physical voltage or wiring."""
    rows=[]
    getter=getattr(mux,'get_pin_func',None)
    for n in (42,43,34,35):
        current=getter(n) if getter else None
        rows.append({'pin':n,'function':current,'gpio_function':getattr(FPIOA,'GPIO%d'%n),
                     'readable':bool(getter)})
    return rows


class GpioLink:
    def __init__(self):
        if tuple(C.DATA_PINS)!=(42,43,34) or C.STROBE_PIN!=35:
            raise ValueError('Fixed GPIO contract requires DATA=42/43/34, STB=35')
        self.step=getattr(C,'GPIO_SYMBOL_MS',1)
        self.heartbeat_ms=getattr(C,'GPIO_HEARTBEAT_MS',500)
        if self.step<1 or not 100<=self.heartbeat_ms<=1000:
            raise ValueError('Use >=1ms symbol stages and 100..1000ms heartbeat')
        self.mux=FPIOA()
        self.pin_audit=audit_pins(self.mux)
        print('[LINK] Pin mux before mapping:',self.pin_audit)
        if not all(row['readable'] for row in self.pin_audit):
            raise RuntimeError('Firmware cannot query pin mux; keep GPIO disabled')
        for row in self.pin_audit:
            if row['readable'] and row['function'] not in (None,row['gpio_function'],getattr(FPIOA,'RESV',None)):
                raise RuntimeError('GPIO%d is already assigned to function %s; refusing to steal it'%
                                   (row['pin'],row['function']))
        self.data=[]
        self.stb=None
        try:
            self.mux.set_function(C.STROBE_PIN,getattr(FPIOA,'GPIO%d'%C.STROBE_PIN))
            self.stb=Pin(C.STROBE_PIN,Pin.OUT,value=0)
            for n in C.DATA_PINS:
                self.mux.set_function(n,getattr(FPIOA,'GPIO%d'%n))
                self.data.append(Pin(n,Pin.OUT,value=0))
        except Exception:
            self.close()
            raise
        self.state,self.error='idle',''
        self.sent_frames=0
        self.last_sent=time.ticks_ms()

    def _symbol(self,value):
        for bit,pin in enumerate(self.data):
            pin.value((value>>bit)&1)
        time.sleep_ms(self.step)
        self.stb.value(1)
        time.sleep_ms(self.step)
        self.stb.value(0)
        time.sleep_ms(self.step)

    def _send(self,category,value):
        if self.state!='idle': return False
        self.state='sending'
        try:
            for _ in range(2):
                for symbol in (0,category,0,value,0): self._symbol(symbol)
            self.sent_frames+=1
            self.last_sent=time.ticks_ms()
            self.state='idle'
            return True              # Sent on pins; not a receiver acknowledgement.
        except Exception as e:
            self.error=str(e)
            self.state='fault'
            try: self.stb.value(0)
            except Exception: pass
            return False

    def send(self,code):
        if code not in EVENTS: raise ValueError('Unsupported application event code')
        return self._send(*EVENTS[code])

    def poll(self):
        if self.state=='idle' and time.ticks_diff(time.ticks_ms(),self.last_sent)>=self.heartbeat_ms:
            self._send(7,1)

    def close(self):
        pins=([self.stb] if self.stb is not None else [])+self.data
        for pin in pins:
            try: pin.value(0)
            except Exception: pass
        self.state='closed'
