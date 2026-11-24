#!/usr/bin/env python3
"""Generate Astro's desktop icons: project-drawn white line art.

The icons match the 34OS wallpapers (white line art on charcoal):
simple pictograms stroked in #ececec on a transparent background,
drawn at 192x192 so the WM's Imlib2 downscale to 48x48 stays
smooth. No icon theme is used; every motif is drawn here.

Motifs (same apps as the start menu):
    firefox.png   wireframe globe, 🌐 style (Firefox)
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
    # Wireframe globe in the style of the 🌐 emoji (user's pick):
    # outer circle, one meridian ellipse, a straight equator and
    # two parallels bowed away from the equator. Instantly reads
    # as "web browser" at 48px, no mascot required.
    d.ellipse([18, 18, 174, 174], outline=WHITE, width=W)
    # Meridian.
    d.ellipse([62, 18, 130, 174], outline=WHITE, width=W2)
    # Equator.
    d.line([18, 96, 174, 96], fill=WHITE, width=W2)
    # Parallels at dy = -34 / +34 (chord half-width 69, sag 14).
    d.arc([27, 48, 165, 76], start=180, end=360, fill=WHITE, width=W2)
    d.arc([27, 116, 165, 144], start=0, end=180, fill=WHITE, width=W2)
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
