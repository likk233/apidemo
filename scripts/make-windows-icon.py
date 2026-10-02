#!/usr/bin/env python3
"""Generate the code-drawn UsageBar gauge as a multi-resolution Windows icon."""
import math
import struct
from pathlib import Path


def pixel(x, y):
    if (abs(x - .5) > .40 and abs(y - .5) > .40 and
            math.hypot(abs(x - .5) - .40, abs(y - .5) - .40) > .085):
        return (0, 0, 0, 0)
    dx, dy = x - .5, y - .5
    radius = math.hypot(dx, dy)
    ring = abs(radius - .285) < .025
    # Needle, center dot, and the same gauge concept used by the macOS app.
    ax, ay, bx, by = .5, .54, .685, .34
    fraction = max(0, min(1, ((x-ax)*(bx-ax)+(y-ay)*(by-ay))/((bx-ax)**2+(by-ay)**2)))
    needle = math.hypot(x-ax-fraction*(bx-ax), y-ay-fraction*(by-ay)) < .022
    dot = math.hypot(x-.5, y-.54) < .041
    ticks = False
    for angle in (-150, -90, -30, 30, 90, 150):
        tx = .5 + .223 * math.cos(math.radians(angle))
        ty = .5 + .223 * math.sin(math.radians(angle))
        ticks |= math.hypot(x-tx, y-ty) < .018
    return (32, 174, 149, 255) if ring or needle or dot or ticks else (29, 42, 42, 255)


def image(size):
    rgba = []
    for row in range(size - 1, -1, -1):
        for col in range(size):
            colors = [pixel((col+(i+.5)/4)/size, (row+(j+.5)/4)/size) for i in range(4) for j in range(4)]
            r, g, b, a = (round(sum(c[k] for c in colors)/16) for k in range(4))
            rgba.append(bytes((b, g, r, a)))
    header = struct.pack('<IiiHHIIiiII', 40, size, size*2, 1, 32, 0, size*size*4, 0, 0, 0, 0)
    mask = bytes(((size+31)//32)*4*size)
    return header + b''.join(rgba) + mask


if __name__ == '__main__':
    root = Path(__file__).resolve().parent.parent
    sizes = (16, 32, 48, 64)
    images = [image(size) for size in sizes]
    offset = 6 + 16*len(sizes)
    directory = []
    for size, data in zip(sizes, images):
        directory.append(struct.pack('<BBBBHHII', size, size, 0, 0, 1, 32, len(data), offset))
        offset += len(data)
    (root/'Windows'/'UsageBar.ico').write_bytes(struct.pack('<HHH', 0, 1, len(sizes)) + b''.join(directory) + b''.join(images))
    print('Generated Windows/UsageBar.ico')
