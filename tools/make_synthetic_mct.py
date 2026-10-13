#!/usr/bin/env python3
"""Create a synthetic 8x8 raw-RGBA MCT fixture; contains no game assets."""
import struct
import sys

def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "synthetic.mct"
    w = h = 8
    header = bytearray(42)
    header[0:4] = b"MCT_"
    struct.pack_into("<H", header, 8, 1)
    struct.pack_into("<H", header, 30, 0)
    struct.pack_into("<H", header, 32, 0)
    struct.pack_into("<H", header, 34, w)
    struct.pack_into("<H", header, 36, h)
    struct.pack_into("<H", header, 38, 0)
    struct.pack_into("<H", header, 40, 2)
    pixels = bytearray()
    for y in range(h):
        for x in range(w):
            if ((x // 2) + (y // 2)) % 2:
                pixels += bytes((25, 75, 120, 255))
            else:
                pixels += bytes((220, 75, 25, 255))
    body = bytes(header) + bytes(pixels)
    struct.pack_into("<I", body := bytearray(body), 10, len(body) - 10)
    with open(out_path, "wb") as f:
        f.write(body)
    print(f"Generated synthetic MCT: {out_path} ({len(body)} bytes, {w}x{h}, format=2)")

if __name__ == "__main__":
    main()
