"""Read the frozen Ti60 avoidance trace over CH340 and save it as CSV."""

import argparse
import binascii
import csv
from datetime import datetime
from pathlib import Path
import struct
import time

import serial
from serial.tools.list_ports import comports


MAGIC = b"\xa5AVD1\x5a"
ROW = struct.Struct("<HiiHHHBBBB")
MAX_ROWS = 1024
FIELDS = ("ms", "enc_l", "enc_r", "duty_l", "duty_r", "dist_cm", "track_raw",
          "phase", "state", "motor_on", "running", "line_on", "lost", "wide",
          "fault", "obstacle", "owns", "fault_phase", "fault_reason")
REASONS = {
    1: "backward encoder movement",
    2: "left wheel stalled",
    3: "right wheel stalled",
    4: "entry alignment",
    5: "no fresh range sample",
    6: "invalid line during approach",
    7: "range outside the start window",
    8: "phase timeout",
    9: "side pass did not establish clearance",
    10: "center line not reacquired",
}


def read_exact(port, size, until):
    data = bytearray()
    while len(data) < size and time.monotonic() < until:
        data.extend(port.read(size - len(data)))
    if len(data) != size:
        raise TimeoutError("incomplete trace response")
    return bytes(data)


def read_trace(port):
    port.reset_input_buffer()
    port.write(b"G")
    until = time.monotonic() + 8
    tail = bytearray()
    while tail != MAGIC:
        tail.extend(read_exact(port, 1, until))
        if len(tail) > len(MAGIC):
            del tail[0]
    header = read_exact(port, 3, until)
    count, frozen = struct.unpack("<HB", header)
    if count > MAX_ROWS or frozen not in (0, 1) or (not frozen and count != 0):
        raise ValueError("invalid trace header")
    payload = read_exact(port, count * ROW.size, until)
    crc, = struct.unpack("<H", read_exact(port, 2, until))
    if binascii.crc_hqx(header + payload, 0xFFFF) != crc:
        raise ValueError("trace CRC mismatch")
    return bool(frozen), payload


def decode(rows):
    elapsed = 0
    previous = None
    for stamp, left, right, dl, dr, distance, raw, status, flags, fault in ROW.iter_unpack(rows):
        if previous is not None:
            elapsed += (stamp - previous) & 0xFFFF
        previous = stamp
        yield (elapsed, left, right, dl, dr, "" if distance == 0xFFFF else distance,
               f"{raw:08b}", status >> 4, status & 7,
               *((flags >> bit) & 1 for bit in range(7, -1, -1)), fault >> 4, fault & 15)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", help="CH340 port, detected automatically when unique")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--clear", action="store_true", help="discard the saved trace while stopped")
    args = parser.parse_args()
    if args.port is None:
        devices = [p.device for p in comports() if (p.vid, p.pid) == (0x1A86, 0x7523)]
        if len(devices) != 1:
            parser.error("connect a single CH340 or specify --port")
        args.port = devices[0]

    try:
        with serial.Serial(baudrate=115200, timeout=.15, write_timeout=2) as port:
            port.dtr = False
            port.rts = False
            port.port = args.port
            port.open()
            if args.clear:
                port.write(b"C!")
                port.flush()
                time.sleep(.02)
            frozen, payload = read_trace(port)
    except (OSError, TimeoutError, ValueError) as exc:
        parser.exit(1, f"{exc}\n")

    if not frozen:
        print("No frozen trace. It may be empty or still recording.")
        return
    if args.clear:
        parser.exit(1, "Trace is still frozen. Stop the car before clearing.\n")
    rows = list(decode(payload))
    if not rows:
        parser.exit(1, "Trace is frozen but contains no records.\n")
    output = args.output or Path("data/avoid_trace") / datetime.now().strftime("%Y%m%d-%H%M%S.csv")
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x", encoding="utf-8", newline="") as stream:
        csv_writer = csv.writer(stream)
        csv_writer.writerow(FIELDS)
        csv_writer.writerows(rows)
    print(f"CRC OK: {len(rows)} records, {rows[-1][0]} ms, {output.resolve()}")
    old_phase = None
    for row in rows:
        phase = row[7]
        if phase != old_phase:
            print(f"{row[0]:5d} ms B={phase:X} M={row[8]} D={row[5]} "
                  f"L={row[1]} R={row[2]} PWM={row[3]}/{row[4]}")
            old_phase = phase
    last = rows[-1]
    if last[-1]:
        print(f"Stopped in B={last[-2]:X}: {REASONS.get(last[-1], last[-1])}")


if __name__ == "__main__":
    main()
