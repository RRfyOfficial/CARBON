#!/usr/bin/env python3
"""CARBON's dot-matrix "C" icon: the companion's tray glyph, on near-black, as the app icon.

    python assets/brand/make_dot_icon.py

Writes (standard library only, so it runs anywhere):
  assets/brand/carbon-dot-icon-1024.png                      the source image
  ios/Carbon/Assets.xcassets/AppIcon.appiconset/AppIcon.png  iPhone app icon (1024 px, RGB, no alpha)
  windows/src/Carbon.Companion/Assets/carbon.ico             companion exe / Start menu (16-256 px)

The same 5 x 7 "C" the tray icon draws (TrayIcon.cs). Tactura colours: dots #F4F4F1 on #0A0A0B.
Small sizes fill more of the square so the dots stay readable.
"""

import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GLYPH = [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."]
DOT = (0xF4, 0xF4, 0xF1)
BACKGROUND = (0x0A, 0x0A, 0x0B)


def render(size: int, letter_height: float, dot_ratio: float = 0.8) -> list[bytearray]:
    """RGB rows. letter_height is the glyph's height as a fraction of the square."""
    pitch = size * letter_height / len(GLYPH)
    radius = pitch * dot_ratio / 2
    left = (size - pitch * len(GLYPH[0])) / 2
    top = (size - pitch * len(GLYPH)) / 2
    rows = [bytearray(bytes(BACKGROUND) * size) for _ in range(size)]
    for r, line in enumerate(GLYPH):
        for c, mark in enumerate(line):
            if mark != "#":
                continue
            cx, cy = left + (c + 0.5) * pitch, top + (r + 0.5) * pitch
            for y in range(max(0, int(cy - radius - 1)), min(size, int(cy + radius + 2))):
                for x in range(max(0, int(cx - radius - 1)), min(size, int(cx + radius + 2))):
                    # Anti-aliased edge: coverage from the pixel centre's distance to the dot's edge.
                    distance = ((x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2) ** 0.5
                    coverage = min(1.0, max(0.0, radius - distance + 0.5))
                    if coverage:
                        i = x * 3
                        for k in range(3):
                            rows[y][i + k] = round(BACKGROUND[k] + (DOT[k] - BACKGROUND[k]) * coverage)
    return rows


def png(rows: list[bytearray], alpha: bool) -> bytes:
    width, height = len(rows[0]) // 3, len(rows)
    raw = bytearray()
    for row in rows:
        raw.append(0)
        if alpha:
            for x in range(width):
                raw += row[x * 3:x * 3 + 3] + b"\xff"
        else:
            raw += row

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 6 if alpha else 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")


def ico(images: list[tuple[int, bytes]]) -> bytes:
    """An .ico whose entries are PNGs (Windows Vista and later)."""
    out = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    blobs = b""
    for size, data in images:
        dim = 0 if size == 256 else size  # 0 means 256 in an icon directory
        out += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset + len(blobs))
        blobs += data
    return out + blobs


def main() -> None:
    big = render(1024, letter_height=0.56)
    (ROOT / "assets/brand/carbon-dot-icon-1024.png").write_bytes(png(big, alpha=False))
    (ROOT / "ios/Carbon/Assets.xcassets/AppIcon.appiconset/AppIcon.png").write_bytes(png(big, alpha=False))
    # The letter grows as the icon shrinks: tray-like proportions at 16-32 px, roomier at 256.
    sizes = {16: 0.94, 32: 0.88, 48: 0.8, 64: 0.74, 256: 0.62}
    entries = [(size, png(render(size, letter_height=height), alpha=True)) for size, height in sizes.items()]
    (ROOT / "windows/src/Carbon.Companion/Assets/carbon.ico").write_bytes(ico(entries))
    print("wrote the 1024 px source, the iPhone AppIcon.png and the companion carbon.ico")


if __name__ == "__main__":
    main()
