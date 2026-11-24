#!/usr/bin/env python3
"""Generate Astro's desktop icons: project-drawn white line art.

The icons match the 34OS wallpapers (white line art on charcoal):
simple pictograms stroked in #ececec on a transparent background,
drawn at 192x192 so the WM's Imlib2 downscale to 48x48 stays
smooth. No icon theme is used; every motif is drawn here.

Motifs (same apps as the start menu):
    firefox.png   circle + flame          (Firefox)
    files.png     folder                  (書庫 / PCManFM)
    terminal.png  screen with ">_"        (ターミナル / sakura)
    writer.png    document with lines     (タイプライター / AbiWord)
    calc.png      body, display, key grid (電卓 / galculator)

Output: ./icons/<name>.png next to this script.
Usage:  python3 make-icons.py
"""

import math
import os

from PIL import Image, ImageDraw

SIZE = 192
WHITE = (236, 236, 236, 255)   # #ececec, the WM's text colour
W = 9                          # main stroke width at 192px
W2 = 7                         # secondary stroke width

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons")


def canvas():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def save(img, name):
    path = os.path.join(OUT, name)
    img.save(path)
    print("wrote", path)


def firefox():
    img, d = canvas()
    # Globe: outer circle.
    d.ellipse([18, 18, 174, 174], outline=WHITE, width=W)
    # Flame: a teardrop outline rising from the bottom of the
    # circle, drawn as a closed polyline through parametric points
    # (right side bulges out, left side curls in, tip at the top).
    pts = []
    for i in range(41):
        t = i / 40.0                    # 0 at the tip, 1 back at tip
        ang = math.pi * t               # half-turn for the body
        # teardrop: width grows then shrinks, centre drifts down
        r = 34 * math.sin(ang) ** 0.8
        y = 52 + 96 * t
        x = 96 + r
        pts.append((x, y))
    for i in range(40, -1, -1):
        t = i / 40.0
        ang = math.pi * t
        r = 34 * math.sin(ang) ** 0.8
        y = 52 + 96 * t
        x = 96 - r * 0.82 - 6 * math.sin(ang * 2)
        pts.append((x, y))
    d.line(pts, fill=WHITE, width=W2, joint="curve")
    # Inner flame tongue.
    pts = []
    for i in range(31):
        t = i / 30.0
        ang = math.pi * t
        r = 15 * math.sin(ang) ** 0.9
        pts.append((96 + r, 96 + 52 * t))
    for i in range(30, -1, -1):
        t = i / 30.0
        ang = math.pi * t
        r = 15 * math.sin(ang) ** 0.9
        pts.append((96 - r, 96 + 52 * t))
    d.line(pts, fill=WHITE, width=W2, joint="curve")
    return img


def files():
    img, d = canvas()
    # Folder: back outline with a tab, front mouth line.
    d.line([(28, 148), (28, 54), (80, 54), (95, 72), (164, 72),
            (164, 148), (28, 148)],
           fill=WHITE, width=W, joint="curve")
    d.line([(28, 88), (164, 88)], fill=WHITE, width=W2)
    return img


def terminal():
    img, d = canvas()
    d.rectangle([28, 40, 164, 152], outline=WHITE, width=W)
    d.line([(28, 66), (164, 66)], fill=WHITE, width=W2)
    # ">_"
    d.line([(54, 86), (79, 105), (54, 124)], fill=WHITE, width=W,
           joint="curve")
    d.line([(93, 124), (126, 124)], fill=WHITE, width=W)
    return img


def writer():
    img, d = canvas()
    # Document with a folded top-right corner.
    d.line([(56, 24), (116, 24), (140, 48), (140, 168), (56, 168),
            (56, 24)], fill=WHITE, width=W, joint="curve")
    d.line([(116, 24), (116, 48), (140, 48)], fill=WHITE, width=W2,
           joint="curve")
    # Text lines.
    for y, x1 in ((84, 124), (108, 124), (132, 102)):
        d.line([(72, y), (x1, y)], fill=WHITE, width=W2)
    return img


def calc():
    img, d = canvas()
    d.rectangle([50, 24, 142, 168], outline=WHITE, width=W)
    d.rectangle([66, 40, 126, 66], outline=WHITE, width=W2)
    # 3x3 key grid.
    for y in (86, 109, 132):
        for x in (66, 89, 112):
            d.rectangle([x, y, x + 14, y + 14], outline=WHITE, width=5)
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    save(firefox(), "firefox.png")
    save(files(), "files.png")
    save(terminal(), "terminal.png")
    save(writer(), "writer.png")
    save(calc(), "calc.png")


if __name__ == "__main__":
    main()
