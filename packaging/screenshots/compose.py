#!/usr/bin/env python3
"""Puts window captures on a background, for capture.sh.

    compose.py OUT [--size 1440x900] [--plain] LAYER...

Each LAYER is `file.png@x,y`: a window captured without its shadow (`screencapture -o -l`), and
where its top-left corner was on screen, in points. The first layer is the main window; the others
(sheets, the open panel) keep their position relative to it. Every layer gets a soft shadow.

--size  fixed canvas (App Store screenshots: 1440x900, 1280x800, 2560x1600 or 2880x1800); the
        windows are centred and scaled down if they don't fit. Without it the canvas fits the windows.
--plain light grey background instead of the brand gradient (App Review attachments).
The result has no alpha channel, which App Store Connect requires.
"""
import argparse
import sys

try:
    from PIL import Image, ImageFilter
except ImportError:
    sys.exit("Pillow is required: pip3 install Pillow")


def gradient(w, h):
    top, bottom = (196, 232, 226), (186, 196, 236)
    mask = Image.linear_gradient("L").resize((w, h))
    return Image.composite(Image.new("RGB", (w, h), bottom), Image.new("RGB", (w, h), top), mask)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("layers", nargs="+")
    p.add_argument("--size")
    p.add_argument("--plain", action="store_true")
    a = p.parse_args()

    layers = []
    for spec in a.layers:
        path, pos = spec.rsplit("@", 1)
        x, y = (int(v) for v in pos.split(","))
        layers.append((Image.open(path).convert("RGBA"), x, y))

    # Pixels per point, from the main window (2 on a Retina display).
    main_img, mx, my = layers[0]
    scale = 1
    # Union of all windows, in pixels relative to the main window.
    boxes = [((x - mx) * scale, (y - my) * scale, (x - mx) * scale + im.width, (y - my) * scale + im.height)
             for im, x, y in layers]
    x0, y0 = min(b[0] for b in boxes), min(b[1] for b in boxes)
    x1, y1 = max(b[2] for b in boxes), max(b[3] for b in boxes)
    pad = 80
    group = Image.new("RGBA", (x1 - x0 + 2 * pad, y1 - y0 + 2 * pad), (0, 0, 0, 0))
    for (im, _, _), (bx, by, _, _) in zip(layers, boxes):
        ox, oy = bx - x0 + pad, by - y0 + pad
        shadow = Image.new("RGBA", group.size, (0, 0, 0, 0))
        alpha = Image.new("L", group.size, 0)
        alpha.paste(im.getchannel("A").point(lambda v: v * 70 // 255), (ox, oy + 14))
        shadow.putalpha(alpha.filter(ImageFilter.GaussianBlur(22)))
        group.alpha_composite(shadow)
        group.alpha_composite(im, (ox, oy))

    if a.size:
        w, h = (int(v) for v in a.size.lower().split("x"))
    else:
        w, h = group.size
    canvas = Image.new("RGB", (w, h), (236, 236, 239)) if a.plain else gradient(w, h)
    # Fit the windows (not their shadow padding) inside the canvas with a margin.
    inner_w, inner_h = group.width - 2 * pad, group.height - 2 * pad
    fit = min(1.0, (w - 80) / inner_w, (h - 60) / inner_h) if a.size else 1.0
    if fit < 1.0:
        group = group.resize((round(group.width * fit), round(group.height * fit)), Image.LANCZOS)
    canvas.paste(group, ((w - group.width) // 2, (h - group.height) // 2), group)
    canvas.save(a.out)
    print(f"{a.out} ({w}x{h})")


if __name__ == "__main__":
    main()
