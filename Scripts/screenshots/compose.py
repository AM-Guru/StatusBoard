#!/usr/bin/env python3
"""Compose App Store screenshots from raw simulator captures.

Each output is drawn at exactly the pixel size App Store Connect wants, in
the layout the Slaptop store screenshots use: a coloured gradient field, a
small product eyebrow, one big headline, a subhead, a paragraph of body copy,
a couple of how-to lines, and the app itself inside a device bezel.

    compose.py <raw-dir> <out-dir> [--only <platform>] [--shot <id>]

Drawing is done with Pillow rather than a browser on purpose: headless Chrome
on this machine either took 90 seconds a frame or hung outright, and there is
nothing here that needs a layout engine.
"""

from __future__ import annotations

import html
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))

# App Store Connect canvas sizes.
SIZES = {
    "iphone": (1320, 2868),    # 6.9" — iPhone 17 Pro Max
    "ipad": (2064, 2752),      # 13" — iPad Pro
    "mac": (2880, 1800),
    "appletv": (3840, 2160),
    "watch": (416, 496),       # Apple Watch Series 10/11, 46mm
}

# Gradient fields, chosen per shot so a set reads as a family without any two
# frames looking the same. (from, to, glow)
FIELDS = [
    ((10, 28, 51), (7, 20, 38), (29, 78, 122)),     # deep navy
    ((26, 15, 46), (13, 8, 32), (91, 58, 134)),     # indigo
    ((6, 33, 38), (3, 22, 26), (18, 98, 107)),      # teal
    ((42, 15, 28), (24, 8, 19), (138, 51, 88)),     # wine
    ((13, 26, 18), (6, 16, 10), (31, 107, 69)),     # forest
    ((36, 20, 5), (21, 11, 3), (138, 90, 30)),      # amber
]

ACCENT = (99, 179, 245)

FONT_FILE = "/System/Library/Fonts/HelveticaNeue.ttc"
FACE = {"regular": 0, "bold": 1, "ultralight": 5, "light": 7, "medium": 10}

# Bezel geometry as fractions of the frame's own width, so a bezel looks the
# same whether it is drawn 400px wide or 2000px wide.
BEZELS = {
    #            pad     outer_r  inner_r
    "iphone":  (0.0117, 0.0660, 0.0544),
    "ipad":    (0.0087, 0.0261, 0.0186),
    "appletv": (0.0052, 0.0115, 0.0073),
    "watch":   (0.0270, 0.2400, 0.2000),
    "mac":     (0.0,    0.0111, 0.0111),
}
BEZEL_STOPS = [(0.00, (92, 98, 107)), (0.35, (32, 36, 42)),
               (0.65, (20, 23, 27)), (1.00, (74, 80, 89))]


def font(size: int, weight: str = "regular") -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_FILE, max(1, int(size)), index=FACE[weight])


# --------------------------------------------------------------------------
# backgrounds
# --------------------------------------------------------------------------

def gradient_field(size, c1, c2, glow, angle_deg=148.0):
    """Linear gradient plus a soft corner glow.

    Both are computed small and scaled up — a gradient has no detail to lose,
    and a 3840x2160 per-pixel loop in Python does not finish in a useful time.
    """
    w, h = size
    n = 96
    yy, xx = np.mgrid[0:n, 0:n] / (n - 1.0)

    theta = math.radians(angle_deg)
    t = xx * math.cos(theta) + yy * math.sin(theta)
    t = (t - t.min()) / (t.max() - t.min())

    base = np.zeros((n, n, 3))
    for i in range(3):
        base[..., i] = c1[i] + (c2[i] - c1[i]) * t

    # Corner glow, falling off to nothing well before the far edge.
    gx, gy = 0.88, 0.12
    aspect = w / float(h)
    d = np.sqrt(((xx - gx) * aspect) ** 2 + (yy - gy) ** 2) / (1.20 * aspect)
    fall = np.clip(1.0 - d / 0.58, 0.0, 1.0) ** 2

    for i in range(3):
        base[..., i] = base[..., i] + (glow[i] - base[..., i]) * fall

    small = Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB")
    return small.resize((w, h), Image.BICUBIC)


def bezel_fill(size, radius):
    """The brushed-metal band that reads as a device edge."""
    w, h = size
    n = 128
    yy, xx = np.mgrid[0:n, 0:n] / (n - 1.0)
    theta = math.radians(160.0)
    t = xx * math.cos(theta) + yy * math.sin(theta)
    t = (t - t.min()) / (t.max() - t.min())

    out = np.zeros((n, n, 3))
    stops = BEZEL_STOPS
    for i in range(len(stops) - 1):
        p0, c0 = stops[i]
        p1, c1 = stops[i + 1]
        m = (t >= p0) & (t <= p1)
        local = (t - p0) / max(1e-6, p1 - p0)
        for k in range(3):
            out[..., k][m] = (c0[k] + (c1[k] - c0[k]) * local)[m]

    img = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGB").resize((w, h), Image.BICUBIC)
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=255)
    img.putalpha(mask)
    return img


def rounded(img: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1],
                                           radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def drop_shadow(canvas, box, radius, blur, opacity=0.55, offset=(0, 0)):
    x, y, w, h = box
    pad = blur * 3
    layer = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(
        [pad, pad, pad + w, pad + h], radius=radius,
        fill=(0, 0, 0, int(255 * opacity)))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(layer, (x - pad + offset[0], y - pad + offset[1]))


# --------------------------------------------------------------------------
# device frame
# --------------------------------------------------------------------------

def framed(shot_platform: str, screenshot: Image.Image, width: int) -> Image.Image:
    """Wrap a raw capture in its device bezel, scaled to `width`."""
    pad_f, outer_f, inner_f = BEZELS[shot_platform]
    pad = int(round(width * pad_f))
    inner_w = width - pad * 2
    inner_h = int(round(screenshot.height * inner_w / screenshot.width))
    shot = screenshot.convert("RGB").resize((inner_w, inner_h), Image.LANCZOS)

    total_h = inner_h + pad * 2
    outer_r = int(round(width * outer_f))
    inner_r = int(round(width * inner_f))

    out = Image.new("RGBA", (width, total_h), (0, 0, 0, 0))
    if pad > 0:
        out.alpha_composite(bezel_fill((width, total_h), outer_r), (0, 0))
    else:
        out.alpha_composite(Image.new("RGBA", (width, total_h), (0, 0, 0, 0)))
    out.alpha_composite(rounded(shot, inner_r), (pad, pad))

    # A hairline of light along the top edge sells the glass.
    edge = Image.new("RGBA", (width, total_h), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle([0, 0, width - 1, total_h - 1],
                                           radius=outer_r, outline=(255, 255, 255, 22),
                                           width=max(1, width // 900))
    out.alpha_composite(edge)
    return out


# --------------------------------------------------------------------------
# text
# --------------------------------------------------------------------------

def measure(draw, text, fnt):
    return draw.textbbox((0, 0), text, font=fnt)[2]


def wrap(draw, text, fnt, max_w):
    if not text:
        return []
    lines, cur = [], ""
    for word in text.split():
        trial = (cur + " " + word).strip()
        if measure(draw, trial, fnt) <= max_w or not cur:
            cur = trial
        else:
            lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    return lines


def tracked(draw, xy, text, fnt, fill, tracking):
    """Draw with letter-spacing — PIL has no tracking of its own."""
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=fnt, fill=fill)
        x += measure(draw, ch, fnt) + tracking
    return x


def blend(color, alpha):
    return tuple(list(color) + [int(255 * alpha)])


def arrow(draw, x, y, size, color):
    """A how-to bullet, drawn rather than typed.

    Helvetica Neue has no U+2192, and asking for one gets a tofu box in the
    middle of the screenshot. Three lines are cheaper than a second font.
    """
    cy = y + size * 0.60
    x2 = x + size * 0.78
    thick = max(1, int(size * 0.075))
    draw.line([(x, cy), (x2, cy)], fill=color, width=thick)
    head = size * 0.26
    draw.line([(x2 - head, cy - head), (x2, cy)], fill=color, width=thick)
    draw.line([(x2 - head, cy + head), (x2, cy)], fill=color, width=thick)


# --------------------------------------------------------------------------
# layouts
# --------------------------------------------------------------------------

def draw_copy(draw, shot, x, y, col_w, scale, portrait, prose_w=None):
    """Eyebrow, headline, subhead, body, how-to. Returns the y it ended at."""
    white = (255, 255, 255)
    prose_w = prose_w or col_w

    eb_size = int(scale * (0.026 if portrait else 0.0125))
    h1_size = int(scale * (0.086 if portrait else 0.052))
    sub_size = int(scale * (0.040 if portrait else 0.0195))
    body_size = int(scale * (0.029 if portrait else 0.0145))
    how_size = int(scale * (0.028 if portrait else 0.0135))

    f_eb = font(eb_size, "medium")
    # Headlines are hand-wrapped in the manifest, so a line that is too long
    # for the column can only be fixed by setting it smaller — otherwise it
    # runs out from under the text column and across the device.
    f_h1 = font(h1_size, "regular")
    while h1_size > 12 and max(measure(draw, l, f_h1) for l in shot["headline"]) > col_w:
        h1_size = int(h1_size * 0.96)
        f_h1 = font(h1_size, "regular")
    f_sub = font(sub_size, "regular")
    f_body = font(body_size, "regular")
    f_how = font(how_size, "regular")

    tracked(draw, (x, y), shot["eyebrow"], f_eb, ACCENT, eb_size * 0.12)
    y += int(eb_size * (2.4 if portrait else 4.6))

    for line in shot["headline"]:
        draw.text((x, y), line, font=f_h1, fill=white)
        y += int(h1_size * 1.03)
    y += int(h1_size * (0.34 if portrait else 0.42))

    for line in wrap(draw, shot["sub"], f_sub, prose_w):
        draw.text((x, y), line, font=f_sub, fill=blend(white, 0.96))
        y += int(sub_size * 1.28)
    y += int(sub_size * 0.55)

    for line in wrap(draw, shot.get("body", ""), f_body, prose_w):
        draw.text((x, y), line, font=f_body, fill=blend(white, 0.62))
        y += int(body_size * 1.45)

    steps = shot.get("howto") or []
    if steps:
        y += int(body_size * 0.9)
        indent = int(how_size * 1.65)
        for step in steps:
            arrow(draw, x, y, how_size, blend(ACCENT, 0.9))
            lines = wrap(draw, step, f_how, prose_w - indent)
            for i, line in enumerate(lines):
                draw.text((x + indent, y + i * int(how_size * 1.5)), line,
                          font=f_how, fill=blend(white, 0.72))
            y += int(how_size * 1.5) * (len(lines) - 1) + int(how_size * 1.85)
    return y


def compose_landscape(shot, size, field, screenshot):
    w, h = size
    canvas = gradient_field(size, *field).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    pad = int(w * 0.055)
    frame_w = int(w * 0.47)
    gutter = int(w * 0.035)
    # Whatever is left after the device and the margins is the text column, so
    # a long headline can never be laid over the screenshot.
    col_w = w - pad * 2 - frame_w - gutter
    # Headlines are pre-wrapped and want the full column; running body copy to
    # the same measure gives a 90-character line, so it gets a narrower one.
    draw_copy(draw, shot, pad, int(h * 0.13), col_w, w, portrait=False,
              prose_w=int(col_w * 0.90))

    dev = framed(shot["platform"], screenshot, frame_w)
    fx = w - pad - dev.width
    fy = int((h - dev.height) / 2)
    drop_shadow(canvas, (fx, fy, dev.width, dev.height),
                int(frame_w * BEZELS[shot["platform"]][1]),
                blur=int(w * 0.016), opacity=0.55, offset=(0, int(h * 0.02)))
    canvas.alpha_composite(dev, (fx, fy))
    return canvas.convert("RGB")


def compose_portrait(shot, size, field, screenshot):
    w, h = size
    canvas = gradient_field(size, *field).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    pad = int(w * 0.075)
    col_w = w - pad * 2
    end_y = draw_copy(draw, shot, pad, int(h * 0.035), col_w, w, portrait=True)

    frame_w = int(w * 0.82)
    dev = framed(shot["platform"], screenshot, frame_w)
    fx = int((w - dev.width) / 2)
    fy = int(end_y + h * 0.028)
    drop_shadow(canvas, (fx, fy, dev.width, dev.height),
                int(frame_w * BEZELS[shot["platform"]][1]),
                blur=int(w * 0.030), opacity=0.55, offset=(0, int(h * 0.008)))
    canvas.alpha_composite(dev, (fx, fy))
    return canvas.convert("RGB")


def compose_watch(shot, size, field, screenshot):
    w, h = size
    canvas = gradient_field(size, *field).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    x, y = 16, 14
    f_eb = font(9, "medium")
    f_h1 = font(26, "regular")
    f_sub = font(12, "regular")

    tracked(draw, (x, y), shot["eyebrow"], f_eb, ACCENT, 1.0)
    y += 20
    for line in shot["headline"]:
        draw.text((x, y), line, font=f_h1, fill=(255, 255, 255))
        y += 27
    y += 4
    for line in wrap(draw, shot["sub"], f_sub, w - x * 2):
        draw.text((x, y), line, font=f_sub, fill=blend((255, 255, 255), 0.72))
        y += 15

    frame_w = int(w * 0.70)
    dev = framed("watch", screenshot, frame_w)
    fx = int((w - dev.width) / 2)
    fy = y + 12
    drop_shadow(canvas, (fx, fy, dev.width, dev.height),
                int(frame_w * BEZELS["watch"][1]), blur=10, opacity=0.6)
    canvas.alpha_composite(dev, (fx, fy))
    return canvas.convert("RGB")


# --------------------------------------------------------------------------

def main():
    args = sys.argv[1:]
    only = shot_filter = None
    if "--only" in args:
        i = args.index("--only"); only = args[i + 1]; args = args[:i] + args[i + 2:]
    if "--shot" in args:
        i = args.index("--shot"); shot_filter = args[i + 1]; args = args[:i] + args[i + 2:]
    if len(args) < 2:
        print(__doc__)
        return 2
    raw_dir, out_dir = args[0], args[1]

    with open(os.path.join(HERE, "shots.json")) as fh:
        shots = json.load(fh)

    # The copy is written with HTML entities so it stays readable in the
    # manifest; PIL wants the real characters.
    def unescape(value):
        if isinstance(value, str):
            return html.unescape(value)
        if isinstance(value, list):
            return [unescape(v) for v in value]
        if isinstance(value, dict):
            return {k: unescape(v) for k, v in value.items()}
        return value

    shots = [unescape(s) for s in shots]

    made, skipped = 0, []
    for shot in shots:
        if only and shot["platform"] != only:
            continue
        if shot_filter and shot["id"] != shot_filter:
            continue
        src = os.path.join(raw_dir, shot["source"])
        if not os.path.exists(src):
            skipped.append(f"{shot['platform']}/{shot['id']} (no {shot['source']})")
            continue

        size = SIZES[shot["platform"]]
        field = FIELDS[shot.get("field", made) % len(FIELDS)]
        screenshot = Image.open(src)

        if shot["platform"] == "watch":
            img = compose_watch(shot, size, field, screenshot)
        elif size[0] > size[1]:
            img = compose_landscape(shot, size, field, screenshot)
        else:
            img = compose_portrait(shot, size, field, screenshot)

        target = os.path.join(out_dir, shot["platform"])
        os.makedirs(target, exist_ok=True)
        out_png = os.path.join(target, shot["id"] + ".png")
        img.save(out_png)
        print(f"composed {shot['platform']}/{shot['id']}.png  {img.width}x{img.height}")
        made += 1

    if skipped:
        print("\nskipped (raw capture not made yet):", file=sys.stderr)
        for s in skipped:
            print("  " + s, file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
