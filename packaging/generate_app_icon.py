#!/usr/bin/env python3
"""Draws Model Shelf's app icon into packaging/Resources/Assets.xcassets/AppIcon.appiconset.

Model "volumes" standing on a shelf next to an external drive. Drawn once at 4x of 1024 px and
scaled down, so edges are antialiased at every size. The PNGs are committed; build-app.sh compiles
them with `actool` into Assets.car + AppIcon.icns. Re-run this only to change the design:

    python3 packaging/generate_app_icon.py      (needs Pillow: pip3 install Pillow)
"""
import json
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    sys.exit("Pillow is required: pip3 install Pillow")

APPICONSET = Path(__file__).parent / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
S = 4                      # supersampling factor
N = 1024 * S               # master canvas


def px(v):
    return int(round(v * S))


def vertical_gradient(w, h, top, bottom):
    """RGBA gradient image from `top` to `bottom` colour."""
    mask = Image.linear_gradient("L").resize((w, h))
    a = Image.new("RGBA", (w, h), top)
    b = Image.new("RGBA", (w, h), bottom)
    return Image.composite(b, a, mask)


def rounded_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def render_master():
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # macOS icon grid: 824 pt body centred in 1024, corner radius ~185, soft drop shadow.
    body = (px(100), px(100), px(924), px(924))
    radius = px(185)
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (body[0], body[1] + px(12), body[2], body[3] + px(12)), radius=radius, fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(px(14))))

    bg = vertical_gradient(N, N, (32, 150, 140, 255), (34, 52, 120, 255))
    img.paste(bg, (0, 0), rounded_mask((N, N), body, radius))

    d = ImageDraw.Draw(img)

    # Soft highlight fading out from the top of the body.
    fade = Image.linear_gradient("L").rotate(180).resize((N, px(520)))     # 255 at top -> 0
    fade = fade.point(lambda v: v * 34 // 255)
    alpha = Image.new("L", (N, N), 0)
    alpha.paste(fade, (0, body[1]))
    alpha = Image.composite(alpha, Image.new("L", (N, N), 0), rounded_mask((N, N), body, radius))
    hl = Image.new("RGBA", (N, N), (255, 255, 255, 0))
    hl.putalpha(alpha)
    img.alpha_composite(hl)

    shelf_top = 700

    def block_shadow(x0, x1, top):
        sh = Image.new("RGBA", (N, N), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle((px(x0 + 6), px(top + 10), px(x1 + 6), px(shelf_top)),
                                             radius=px(22), fill=(10, 20, 50, 90))
        img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(px(8))))

    # Model volumes: (left, right, top, body colour, band colour)
    volumes = [
        (232, 352, 402, (248, 250, 252, 255), (32, 150, 140, 255)),
        (372, 492, 318, (255, 205, 112, 255), (176, 112, 20, 255)),
        (512, 632, 446, (160, 228, 205, 255), (20, 110, 96, 255)),
    ]
    for x0, x1, top, colour, band in volumes:
        block_shadow(x0, x1, top)
        d.rounded_rectangle((px(x0), px(top), px(x1), px(shelf_top)), radius=px(22), fill=colour)
        # Spine bands, like the layers of a model.
        for i, y in enumerate((top + 46, top + 78)):
            d.rounded_rectangle((px(x0 + 26), px(y), px(x1 - 26), px(y + 14)), radius=px(7), fill=band)
        # Base label block.
        d.rounded_rectangle((px(x0 + 26), px(shelf_top - 70), px(x1 - 26), px(shelf_top - 40)),
                            radius=px(10), fill=band)

    # External drive lying on the shelf.
    dx0, dx1, dtop = 652, 792, 598
    block_shadow(dx0, dx1, dtop)
    d.rounded_rectangle((px(dx0), px(dtop), px(dx1), px(shelf_top)), radius=px(26), fill=(226, 232, 242, 255))
    d.rounded_rectangle((px(dx0 + 18), px(dtop + 18), px(dx1 - 18), px(dtop + 34)), radius=px(8),
                        fill=(196, 204, 220, 255))
    d.ellipse((px(dx1 - 46), px(shelf_top - 44), px(dx1 - 26), px(shelf_top - 24)), fill=(64, 210, 120, 255))

    # The shelf.
    sh = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((px(196), px(shelf_top + 8), px(828), px(shelf_top + 58)),
                                         radius=px(14), fill=(5, 10, 40, 110))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(px(10))))
    d.rounded_rectangle((px(196), px(shelf_top), px(828), px(shelf_top + 44)), radius=px(14),
                        fill=(242, 228, 204, 255))
    d.rounded_rectangle((px(196), px(shelf_top + 30), px(828), px(shelf_top + 44)), radius=px(10),
                        fill=(214, 192, 158, 255))

    return img.resize((1024, 1024), Image.LANCZOS)


SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def main():
    APPICONSET.mkdir(parents=True, exist_ok=True)
    master = render_master()
    images = []
    for pt, scale in SIZES:
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        master.resize((pt * scale, pt * scale), Image.LANCZOS).save(APPICONSET / name)
        images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x", "filename": name})
    (APPICONSET / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2))
    (APPICONSET.parent / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))
    print(f"Wrote {len(SIZES)} icon images to {APPICONSET}")


if __name__ == "__main__":
    main()
