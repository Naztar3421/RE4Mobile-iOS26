#!/usr/bin/env python3
"""Generate tiny synthetic MCT fixtures for formats 2, 6, 7 and format-6 LZW.

All bytes are synthetic; no original game assets are embedded.
Usage: make_synthetic_mct.py output.mct --format 6 --compression 1
Also writes output.mct.expected.rgba for byte-for-byte validation.
"""
import argparse
import struct
from pathlib import Path

WIDTH = HEIGHT = 8

def pack_lsb_codes(codes):
    bits = []
    for code, width in codes:
        bits.extend((code >> bit) & 1 for bit in range(width))
    packed = bytearray((len(bits) + 7) // 8)
    for i, bit in enumerate(bits):
        packed[i // 8] |= bit << (i % 8)
    return bytes(packed)

def encode_lzw(data, minimum_code_size=8):
    """Small GIF-style LZW encoder; our repetitive fixture stays within 9-bit codes."""
    clear = 1 << minimum_code_size
    end = clear + 1
    next_code = end + 1
    code_width = minimum_code_size + 1
    dictionary = {bytes([i]): i for i in range(clear)}
    codes = [(clear, code_width)]
    current = bytes([data[0]])
    for value in data[1:]:
        trial = current + bytes([value])
        if trial in dictionary:
            current = trial
            continue
        codes.append((dictionary[current], code_width))
        if next_code < 4096:
            dictionary[trial] = next_code
            next_code += 1
            if next_code == (1 << code_width) and code_width < 12:
                code_width += 1
        current = bytes([value])
    codes.append((dictionary[current], code_width))
    codes.append((end, code_width))
    if any(width > 9 for _, width in codes):
        raise ValueError("Synthetic fixture no longer fits the intended 9-bit LZW path")
    return pack_lsb_codes(codes)

def make_palette_rgb():
    palette = bytearray(256 * 3)
    palette[0:3] = bytes((220, 75, 25))
    palette[3:6] = bytes((25, 75, 120))
    return bytes(palette)

def make_palette_rgba():
    palette = bytearray(256 * 4)
    # Index 0 is explicitly transparent; index 1 is an opaque contrasting color.
    palette[0:4] = bytes((0, 0, 0, 0))
    palette[4:8] = bytes((220, 75, 25, 255))
    palette[8:12] = bytes((25, 75, 120, 128))
    return bytes(palette)

def make_indices():
    return bytes(((x // 2) + (y // 2)) % 2 for y in range(HEIGHT) for x in range(WIDTH))

def expected_from_palette(palette, index_data, channels):
    out = bytearray()
    for index in index_data:
        start = index * channels
        sample = palette[start:start + channels]
        if channels == 3:
            out.extend(sample)
            out.append(255)
        else:
            out.extend(sample)
    return bytes(out)

def make_rgba_direct():
    out = bytearray()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            if ((x // 2) + (y // 2)) % 2:
                out.extend((25, 75, 120, 255))
            else:
                out.extend((220, 75, 25, 128 if (x + y) % 3 == 0 else 255))
    return bytes(out)

def build_header(pixel_format, compression, payload):
    header = bytearray(42)
    header[0:4] = b"MCT_"
    struct.pack_into("<H", header, 8, 1)
    struct.pack_into("<I", header, 10, 42 + len(payload) - 10)
    struct.pack_into("<H", header, 30, 768 if compression == 1 else 0)
    struct.pack_into("<H", header, 32, 2 if compression == 1 else 0)
    struct.pack_into("<H", header, 34, WIDTH)
    struct.pack_into("<H", header, 36, HEIGHT)
    struct.pack_into("<H", header, 38, compression)
    struct.pack_into("<H", header, 40, pixel_format)
    return bytes(header)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    parser.add_argument("--format", type=int, choices=(2, 6, 7), default=2)
    parser.add_argument("--compression", type=int, choices=(0, 1), default=0)
    args = parser.parse_args()
    if args.compression == 1 and args.format != 6:
        parser.error("Only format 6 compression=1 is valid for this synthetic MCT fixture")

    indices = make_indices()
    if args.format == 2:
        if args.compression != 0:
            parser.error("Format 2 fixture must be uncompressed")
        payload = make_rgba_direct()
        expected_rgba = payload
    elif args.format == 6 and args.compression == 0:
        palette = make_palette_rgb()
        payload = palette + indices
        expected_rgba = expected_from_palette(palette, indices, 3)
    elif args.format == 7:
        palette = make_palette_rgba()
        payload = palette + indices
        expected_rgba = expected_from_palette(palette, indices, 4)
    else:
        palette = make_palette_rgb()
        decompressed = palette + indices
        compressed = encode_lzw(decompressed)
        blocks = bytearray([8])
        for offset in range(0, len(compressed), 255):
            block = compressed[offset:offset + 255]
            blocks.append(len(block))
            blocks.extend(block)
        blocks.append(0)
        payload = bytes(blocks)
        expected_rgba = expected_from_palette(palette, indices, 3)

    result = build_header(args.format, args.compression, payload) + payload
    output = Path(args.output)
    output.write_bytes(result)
    output.with_suffix(output.suffix + ".expected.rgba").write_bytes(expected_rgba)
    print(f"Generated synthetic MCT: {output.name} ({len(result)} bytes, {WIDTH}x{HEIGHT}, format={args.format}, compression={args.compression})")

if __name__ == "__main__":
    main()
