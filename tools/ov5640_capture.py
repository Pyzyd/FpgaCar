"""Request a fresh OV5640 snapshot over the Ti60 CH340N port and save a PNG."""

import argparse
from datetime import datetime
from pathlib import Path
import struct
import time
import zlib


MAGIC = b"OVS1"
FRAME_SIZE = (320, 240)
BAUD = 115_200


def read_exact(port, length, deadline):
    data = bytearray()
    while len(data) < length:
        if time.monotonic() >= deadline:
            raise TimeoutError(f"expected {length} bytes, received {len(data)}")
        data.extend(port.read(min(length - len(data), 4096)))
    return data


def read_snapshot(port, timeout=20):
    deadline = time.monotonic() + timeout
    window = bytearray()
    while window != MAGIC:
        window.extend(read_exact(port, 1, deadline))
        del window[:-len(MAGIC)]

    width, height = struct.unpack("<HH", read_exact(port, 4, deadline))
    if (width, height) != FRAME_SIZE:
        raise ValueError(f"unexpected frame size {width}x{height}")
    pixels = read_exact(port, width * height, deadline)
    (expected_crc,) = struct.unpack("<I", read_exact(port, 4, deadline))
    if zlib.crc32(pixels) != expected_crc:
        raise ValueError("photo CRC32 did not match")
    return width, height, pixels


def png_chunk(kind, data):
    contents = kind + data
    return struct.pack(">I", len(data)) + contents + struct.pack(">I", zlib.crc32(contents))


def save_png(path, width, height, pixels):
    rows = b"".join(b"\x00" + pixels[i:i + width] for i in range(0, len(pixels), width))
    # Eight-bit grayscale and no filtering per row preserve the captured samples.
    header = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
           + png_chunk(b"IDAT", zlib.compress(rows)) + png_chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as output:
        output.write(png)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", help="Ti60 CH340N serial port, for example COM12")
    parser.add_argument("output", nargs="?", type=Path, help="optional output PNG path")
    args = parser.parse_args()
    path = args.output
    if path is None:
        filename = datetime.now().strftime("ov5640_%Y%m%d_%H%M%S_%f.png")
        path = Path(__file__).resolve().parents[1] / "data" / "ov5640_capture" / filename
    if path.suffix.lower() != ".png" or path.exists():
        parser.error("output must be an unused .png path")

    try:
        import serial
    except ImportError:
        parser.exit(1, "Install pyserial first: python -m pip install pyserial\n")

    try:
        with serial.Serial(args.port, BAUD, timeout=.25, write_timeout=2) as port:
            port.reset_input_buffer()
            port.write(b"S")
            print(f"Requested a photo on {args.port}. Waiting for a complete frame...", flush=True)
            width, height, pixels = read_snapshot(port)
        save_png(path, width, height, pixels)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"Capture failed: {exc}\n")
    print(f"Saved {width}x{height} grayscale PNG: {path.resolve()}")


if __name__ == "__main__":
    main()
