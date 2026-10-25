#!/usr/bin/env python3
"""Produces the card image and the post text for a single TestFlight build.

    usage: xpost.py BUILD NOTES_FILE --icon ICON_PNG [--out DIR] [--version X.Y] [--theme light|dark]

The notes file holds the What to Test text. A line that is not a bullet is a group heading, and the
bullets under it (each starting with a dot) belong to that heading. The recognised headings are
"Changed in this build", "Fixed in this build" and, optionally, "Coming next". The result is a 4:5 portrait card
(a PNG plus a JPEG meant for posting) and two post texts printed to the terminal, one short enough
for 280 characters and one longer list. Pillow and numpy are required. The icon is a large render
of Shared/AppIcon.icon.
"""
import argparse
import os
import re
import sys
from dataclasses import dataclass

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SITE = os.environ.get("NOLLIE_SITE", "")
GROUPS_USED = ("Fixed in this build", "Changed in this build", "Coming next")
BULLET = "•"


@dataclass(frozen=True)
class Theme:
    base: tuple
    glow_a: tuple
    glow_b: tuple
    headline: tuple
    body: tuple
    muted: tuple
    accent: tuple
    shadow_alpha: int


THEMES = {
    "dark": Theme((9, 10, 16), (20, 60, 120), (50, 22, 90), (245, 245, 250), (228, 229, 238),
                  (150, 152, 168), (120, 160, 255), 160),
    "light": Theme((246, 247, 251), (200, 222, 255), (232, 214, 250), (18, 20, 30), (40, 42, 56),
                   (112, 116, 134), (31, 110, 210), 48),
}

FONT_CHOICES = [
    ("/System/Library/Fonts/SFCompact.ttf", 0),
    ("/System/Library/Fonts/HelveticaNeue.ttc", None),
    ("/System/Library/Fonts/Supplemental/Arial.ttf", 0),
]


def load_font(size, bold=False):
    for path, index in FONT_CHOICES:
        try:
            face = ImageFont.truetype(path, size, index=(1 if bold else 0) if index is None else index)
        except OSError:
            continue
        if path.endswith("SFCompact.ttf"):
            try:
                face.set_variation_by_name("Bold" if bold else "Regular")
            except Exception:
                pass
        return face
    return ImageFont.load_default()


def read_groups(text):
    """{heading: [bullet text, ...]}. Blank lines are ignored; bullets before any heading are dropped."""
    groups, heading = {}, None
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith(BULLET):
            if heading is not None:
                groups[heading].append(line.lstrip(BULLET + " ").strip())
        else:
            heading = line
            groups.setdefault(heading, [])
    return {name: items for name, items in groups.items() if items}


def trim(bullet, limit=120):
    """Cuts a bullet down to its first clause so it fits on a card or in a post."""
    clause = re.split(r"(?<=[a-z0-9)]):\s|;\s", bullet, maxsplit=1)[0]
    # Drop a trailing aside such as ", for anyone who..." once the point has been made.
    aside = re.match(r"(.{40,}?),\s(?:for|so|which|instead)\b.*", clause)
    if aside:
        clause = aside.group(1)
    clause = re.sub(r"\s*\([^)]*\)", "", clause).rstrip(".")
    if len(clause) <= limit:
        return clause
    return clause[:limit - 1].rsplit(" ", 1)[0] + "…"


def wrap_lines(draw, text, face, max_width):
    lines, current = [], ""
    for word in text.split():
        trial = f"{current} {word}".strip()
        if draw.textlength(trial, font=face) <= max_width:
            current = trial
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def backdrop(width, height, theme, seed=7):
    """Paints two soft colour glows over the base colour. The maths runs in floating point with
    dithering, as a blurred 8-bit gradient would show visible bands on a phone; a touch of
    triangular noise masks the steps."""
    ys, xs = np.mgrid[0:height, 0:width].astype(np.float32)
    canvas = np.broadcast_to(np.array(theme.base, np.float32), (height, width, 3)).copy()
    for (cx, cy, radius), colour in (((0.10, 0.08, 0.62), theme.glow_a), ((0.95, 0.95, 0.70), theme.glow_b)):
        distance = ((xs / width - cx) ** 2 + ((ys / height - cy) * height / width) ** 2) / radius ** 2
        weight = np.exp(-distance * 1.8)[:, :, None]
        canvas = canvas * (1 - weight) + np.array(colour, np.float32) * weight
    noise = np.random.default_rng(seed)
    canvas += (noise.uniform(-0.5, 0.5, canvas.shape) + noise.uniform(-0.5, 0.5, canvas.shape)).astype(np.float32)
    return Image.fromarray(np.clip(canvas + 0.5, 0, 255).astype(np.uint8), "RGB")


def soften_icon(icon, size):
    """The icon render has glass gradients that step by several levels. Blurring the colour a
    little at full size and then shrinking spreads and averages the steps away."""
    red, green, blue, alpha = icon.split()
    colour = Image.merge("RGB", (red, green, blue)).filter(ImageFilter.GaussianBlur(3.5))
    return Image.merge("RGBA", (*colour.split(), alpha)).resize((size, size), Image.LANCZOS)


def paste_icon(card, icon_path, scale, theme):
    side = int(330 * scale)
    x0 = (card.width - side) // 2
    y0 = int(96 * scale)
    tile = soften_icon(Image.open(icon_path).convert("RGBA"), side)
    # A wide faint shadow: a tight dark one made the dither look like texture.
    pad = int(90 * scale)
    sink = int(22 * scale)
    haze = Image.new("RGBA", (side + 2 * pad,) * 2, (0, 0, 0, 0))
    box = (pad, pad + sink, pad + side, pad + side + sink)
    ImageDraw.Draw(haze).rounded_rectangle(box, radius=int(side * 0.22), fill=(20, 30, 70, theme.shadow_alpha))
    haze = haze.filter(ImageFilter.GaussianBlur(36 * scale))
    card.paste(haze, (x0 - pad, y0 - pad), haze)
    card.paste(tile, (x0, y0), tile)


class CardPen:
    """Draws onto a card in design units (a 1200 by 1500 layout) and applies the scale itself."""

    def __init__(self, card, scale):
        self.card = card
        self.scale = scale
        self.pen = ImageDraw.Draw(card)

    def font(self, size, bold=False):
        return load_font(int(size * self.scale), bold)

    def width_of(self, text, font):
        return self.pen.textlength(text, font=font)

    def centred(self, text, font, y, colour):
        x = (self.card.width - self.width_of(text, font)) / 2
        self.pen.text((x, y * self.scale), text, font=font, fill=colour)

    def text(self, x, y, text, font, colour):
        self.pen.text((x * self.scale, y * self.scale), text, font=font, fill=colour)

    def dot(self, x, y, colour):
        k = self.scale
        self.pen.ellipse((x * k, y * k, (x + 11) * k, (y + 11) * k), fill=colour)

    def wrapped(self, text, font, limit):
        return wrap_lines(self.pen, text, font, limit * self.scale)


# Spacing for the bullet list: roomy by default, tighter when there are many bullets.
ROOMY = {"heading": 28, "bullet": 34, "line": 46, "gap": 10, "group": 30, "title": 50}
TIGHT = {"heading": 26, "bullet": 30, "line": 40, "gap": 6, "group": 22, "title": 44}
LIST_LEFT, LIST_TOP, LIST_WIDTH = 110, 700, 940
GROUP_CUTOFF, BULLET_CUTOFF = 1300, 1370


def draw_list(art, groups, theme):
    count = sum(len(items) for items in groups.values())
    sizes = TIGHT if count >= 8 else ROOMY
    heading_font = art.font(sizes["heading"], True)
    bullet_font = art.font(sizes["bullet"])
    y = LIST_TOP
    for title, items in groups.items():
        if y > GROUP_CUTOFF:
            continue
        art.text(LIST_LEFT, y, title.upper(), heading_font, theme.accent)
        y += sizes["title"]
        for item in items:
            rows = art.wrapped(trim(item), bullet_font, LIST_WIDTH)
            if y + sizes["line"] * len(rows) > BULLET_CUTOFF:
                break
            art.dot(LIST_LEFT + 4, y + 14, theme.accent)
            for row in rows:
                art.text(LIST_LEFT + 38, y, row, bullet_font, theme.body)
                y += sizes["line"]
            y += sizes["gap"]
        y += sizes["group"]


def save_card(card, png_path):
    # The post goes out as JPEG regardless, and the dithering inflates the PNG to several megabytes.
    card.save(png_path, optimize=True)
    stem = os.path.splitext(png_path)[0]
    card.save(stem + ".jpg", quality=95, subsampling=0, optimize=True)


def render_card(build, version, groups, icon_path, out_path, theme_name="light", scale=1.5):
    """Draws the 1200x1500 layout (multiplied by `scale`), a ratio that X displays without cropping."""
    theme = THEMES[theme_name]
    card = backdrop(int(1200 * scale), int(1500 * scale), theme)
    if icon_path and os.path.exists(icon_path):
        paste_icon(card, icon_path, scale, theme)
    art = CardPen(card, scale)
    lines = (("Nollie", 64, True, 458, theme.headline),
             (f"TestFlight build {build}", 38, False, 540, theme.accent),
             (f"Public beta {version}", 28, False, 592, theme.muted))
    for words, size, bold, top, colour in lines:
        art.centred(words, art.font(size, bold), top, colour)
    draw_list(art, groups, theme)
    art.centred(SITE, art.font(34, True), 1408, theme.accent)
    save_card(card, out_path)


def short_post(build, groups):
    fixed, changed = ([trim(b, 95) for b in groups.get(name, [])]
                      for name in ("Fixed in this build", "Changed in this build"))

    def compose():
        sentences = [f"Nollie beta {build} is now on TestFlight."]
        for label, items, most in (("Fixed: ", fixed, 3), ("New: ", changed, 2)):
            if items:
                sentences.append(label + "; ".join(items[:most]) + ".")
        return " ".join(sentences + [SITE])

    text = compose()
    while len(text) > 280 and (fixed or changed):
        # Give up fixes first (down to one), then changes, then the last fix.
        (fixed if len(fixed) > 1 or not changed else changed).pop()
        text = compose()
    return text


def long_post(build, groups):
    lines = [f"{BULLET} {trim(b, 90)}" for items in groups.values() for b in items[:5]]
    return f"Nollie beta build {build} is on TestFlight.\n\n" + "\n".join(lines) + f"\n\n{SITE}"


def main():
    parser = argparse.ArgumentParser(description="Card and post text for a TestFlight build.")
    parser.add_argument("build")
    parser.add_argument("notes")
    parser.add_argument("--icon", required=True, help="a current render of Shared/AppIcon.icon")
    parser.add_argument("--out", default=".")
    parser.add_argument("--version", default="1.1")
    parser.add_argument("--theme", choices=tuple(THEMES), default="light")
    args = parser.parse_args()

    with open(args.notes) as handle:
        found = read_groups(handle.read())
    groups = {name: found[name] for name in GROUPS_USED if name in found}
    if not groups:
        sys.exit("found no bullets under 'Fixed in this build' or 'Changed in this build'")

    os.makedirs(args.out, exist_ok=True)
    picture = os.path.join(args.out, f"nollie-build-{args.build}.png")
    render_card(args.build, args.version, groups, args.icon, picture, args.theme)

    brief, longer = short_post(args.build, groups), long_post(args.build, groups)
    print(picture, "(+ .jpg for posting)")
    print(f"\n--- short ({len(brief)} chars) ---\n{brief}\n\n--- long ---\n{longer}")


if __name__ == "__main__":
    main()
