#!/usr/bin/env python3
"""Generate Linxr launcher icons for all Android mipmap densities."""

import os
from PIL import Image, ImageDraw, ImageFilter

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES  = os.path.join(BASE, "android", "app", "src", "main", "res")

SIZES = {
    "mipmap-mdpi":    48,
    "mipmap-hdpi":    72,
    "mipmap-xhdpi":   96,
    "mipmap-xxhdpi":  144,
    "mipmap-xxxhdpi": 192,
}
STORE_SIZE = 512

BG    = (10, 14, 20, 255)   # near-black navy
TEAL  = (0, 210, 170, 255)  # mountain colour
GREEN = (0, 255, 130, 255)  # prompt / cursor colour


def rounded_rect_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=radius, fill=255
    )
    return mask


def draw_icon(size: int) -> Image.Image:
    SCALE = 4
    W = size * SCALE

    lw = max(4, W // 15)

    # ── background ─────────────────────────────────────────────────────────
    bg = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(bg).rounded_rectangle(
        [0, 0, W - 1, W - 1], radius=W // 8, fill=BG
    )

    # key coordinates
    mpx, mpy = W * 0.50, W * 0.16        # mountain peak
    mlx, mly = W * 0.12, W * 0.56        # mountain bottom-left
    mrx, mry = W * 0.88, W * 0.56        # mountain bottom-right
    mountain  = [(mlx, mly), (mpx, mpy), (mrx, mry)]

    # ">_" centred under the mountain
    cy        = W * 0.725                 # vertical centre of prompt row
    ch        = W * 0.105                 # chevron half-height
    chev_w    = W * 0.14                  # width of ">" (horizontal span)
    gap       = W * 0.05                  # gap between ">" and "_"
    under_w   = chev_w * 1.3             # underscore width
    total_w   = chev_w + gap + under_w   # total ">_" width
    x0        = (W - total_w) / 2        # left edge so group is centred
    cx1       = x0                        # chevron open end
    ctip      = x0 + chev_w              # chevron tip
    ux1       = ctip + gap               # underscore start
    ux2       = ux1 + under_w            # underscore end
    uy        = cy + ch * 0.7            # underscore near bottom of chevron

    # ── glow layer (blurred) ─────────────────────────────────────────────
    glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    gd   = ImageDraw.Draw(glow)
    glw  = lw * 4

    gd.line(mountain,                       fill=TEAL,  width=glw, joint="curve")
    gd.line([(cx1, cy-ch), (ctip, cy), (cx1, cy+ch)], fill=GREEN, width=glw, joint="curve")
    gd.line([(ux1, uy),   (ux2, uy)],                 fill=GREEN, width=glw)
    glow = glow.filter(ImageFilter.GaussianBlur(W // 11))

    # ── sharp strokes ───────────────────────────────────────────────────
    sharp = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sd    = ImageDraw.Draw(sharp)

    # mountain as single polyline so the peak joins cleanly
    sd.line(mountain, fill=TEAL, width=lw, joint="curve")
    # subtle inner fill for depth
    sd.polygon(
        [(mlx + lw, mly - lw // 2), (mpx, mpy + lw), (mrx - lw, mry - lw // 2)],
        fill=(0, 170, 130, 22)
    )

    # prompt ">_"
    sd.line([(cx1, cy-ch), (ctip, cy), (cx1, cy+ch)], fill=GREEN, width=lw, joint="curve")
    sd.line([(ux1, uy),    (ux2, uy)],                 fill=GREEN, width=lw)

    # ── composite ───────────────────────────────────────────────────────
    result = Image.alpha_composite(bg, glow)
    result = Image.alpha_composite(result, sharp)

    # ── downsample + round mask ─────────────────────────────────────────
    result = result.resize((size, size), Image.LANCZOS)
    mask   = rounded_rect_mask(size, size // 8)
    result.putalpha(mask)
    return result


def flatten(icon: Image.Image, bg_color=(10, 14, 20)) -> Image.Image:
    flat = Image.new("RGB", icon.size, bg_color)
    flat.paste(icon, mask=icon.split()[3])
    return flat


def circle_mask(size):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).ellipse([0, 0, size - 1, size - 1], fill=255)
    return m


def save_all():
    for density, px in SIZES.items():
        out = os.path.join(RES, density)
        os.makedirs(out, exist_ok=True)
        icon = draw_icon(px)
        flatten(icon).save(os.path.join(out, "ic_launcher.png"))
        round_icon = icon.copy()
        round_icon.putalpha(circle_mask(px))
        flat_r = Image.new("RGB", (px, px), (0, 0, 0))
        flat_r.paste(round_icon, mask=round_icon.split()[3])
        flat_r.save(os.path.join(out, "ic_launcher_round.png"))
        print(f"  {density}/{px}px")

    preview = os.path.join(BASE, "build")
    os.makedirs(preview, exist_ok=True)
    big = draw_icon(STORE_SIZE)
    flatten(big).save(os.path.join(preview, "linxr_icon_512.png"))
    print(f"  build/linxr_icon_512.png")


if __name__ == "__main__":
    print("Generating Linxr icons...")
    save_all()
    print("Done.")
