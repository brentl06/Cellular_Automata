#!/usr/bin/env python3
"""
Render CA generations into animated GIFs.

Accepts either source:
  * ca_frames.txt from tb_ca_gif_dump.v  (has a "W H" header and
    "# RULE <bits>" block markers -> one GIF per rule)
  * a raw PuTTY session log captured from the FPGA over UART
    (no header, possibly with junk lines -> one GIF)

Every frame is data the hardware or the RTL simulation produced. This
script only colors cells in; it computes no cellular automaton of its own.

    pip install pillow
    python3 make_gif.py                      # ca_frames.txt
    python3 make_gif.py putty.log            # raw UART capture
    python3 make_gif.py putty.log 40 30      # raw, explicit grid size
"""

import sys
from PIL import Image

CELL_PX  = 12              # rendered pixels per CA cell
GAP_PX   = 1               # grid gap, cosmetic
FG       = (235, 235, 240) # live cell
BG       = (18, 18, 22)    # dead cell / background
FRAME_MS = 120             # playback speed

DEFAULT_W, DEFAULT_H = 40, 30

# {survive[8:0], birth[8:0]} as written by the RTL -> (name, notation)
RULE_NAMES = {
    "000001100000001000": ("life",      "B3/S23"),
    "000001100001001000": ("highlife",  "B36/S23"),
    "000111110000001000": ("maze",      "B3/S12345"),
    "111110000000001000": ("coral",     "B3/S45678"),
    "000000000000000100": ("seeds",     "B2/S"),
    "000000010000000010": ("gnarl",     "B1/S1"),
}


def parse(path, width, height):
    """Return (width, height, [(label, [generation_strings]), ...])."""
    with open(path, "r", errors="replace") as fh:
        lines = fh.read().splitlines()

    # Simulation dumps start with "W H". A raw UART log doesn't.
    first = lines[0].split() if lines else []
    if len(first) == 2 and all(tok.isdigit() for tok in first):
        width, height = int(first[0]), int(first[1])
        lines = lines[1:]
        structured = True
    else:
        structured = False

    expected = width * height
    blocks, label, frames = [], "hw", []

    for line in lines:
        line = line.strip()
        if not line:
            continue
        if line.startswith("# RULE"):
            if frames:
                blocks.append((label, frames))
            bits = line.split()[-1]
            label, frames = RULE_NAMES.get(bits, (f"rule_{bits}", "?"))[0], []
            continue
        # Keep only well-formed grids. A raw capture legitimately contains
        # a truncated first line (we joined the stream mid-frame) and can
        # contain junk if the baud was briefly wrong -- drop those rather
        # than rendering a corrupt frame.
        if len(line) == expected and not (set(line) - {"0", "1"}):
            frames.append(line)

    if frames:
        blocks.append((label, frames))

    if not structured and blocks:
        print(f"raw capture: kept {len(blocks[0][1])} well-formed generations")

    return width, height, blocks


def render(width, height, bits):
    img = Image.new("RGB", (width * CELL_PX, height * CELL_PX), BG)
    px = img.load()
    span = CELL_PX - GAP_PX
    for idx, ch in enumerate(bits):
        if ch == "1":
            x0, y0 = (idx % width) * CELL_PX, (idx // width) * CELL_PX
            for dy in range(span):
                for dx in range(span):
                    px[x0 + dx, y0 + dy] = FG
    return img


def main(src="ca_frames.txt", width=DEFAULT_W, height=DEFAULT_H):
    width, height = int(width), int(height)
    width, height, blocks = parse(src, width, height)

    if not blocks:
        sys.exit(f"{src}: no usable generations found. For a raw capture, "
                 f"check the grid size -- expected {width*height} chars per line.")

    for label, gens in blocks:
        frames = [render(width, height, row) for row in gens]
        dst = f"ca_{label}.gif"
        frames[0].save(dst, save_all=True, append_images=frames[1:],
                       duration=FRAME_MS, loop=0, optimize=True)
        live = sum(r.count("1") for r in gens) / len(gens)
        print(f"{dst:24s} {len(frames):4d} generations, "
              f"{live:6.1f} live cells/gen average")


if __name__ == "__main__":
    main(*sys.argv[1:])
