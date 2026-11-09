#!/usr/bin/env python3
"""Regenerates the asset catalog: app icon set, in-app logo and colours.

    python3 -m pip install Pillow
    python3 scripts/generate-app-icon.py

The mark is a jellyfish whose tentacles are equalizer bars: a dome over five
rounded bars of uneven length, in a coral-to-apricot gradient on near-black.
It deliberately avoids Jellyfin's purple/blue triangle and Plexamp's golden
mark.

App Store rules the output has to satisfy (checked at the end):
  * 1024x1024 px, square corners (iOS applies the mask itself)
  * the default and tinted icons are fully opaque RGB — an alpha channel in
    the marketing icon is rejected at upload (ITMS-90717)
  * sRGB, with the profile embedded so no tool has to guess
The iOS 18+ dark variant is the one exception: it must be transparent so the
system can put its own dark background behind the mark.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageCms, ImageDraw

SIZE = 1024
# Everything is drawn 4x and scaled down: Pillow's shape primitives are not
# anti-aliased, the Lanczos downsample is what makes the edges smooth.
SCALE = 4

REPO = Path(__file__).resolve().parent.parent
ASSETS = REPO / "ios" / "Jellyamp" / "Resources" / "Assets.xcassets"

# Brand colours (sRGB). ACCENT is also written to AccentColor.colorset.
CORAL = (255, 79, 123)
APRICOT = (255, 170, 108)
ACCENT = (255, 107, 129)
BACKGROUND_TOP = (27, 19, 36)
BACKGROUND_BOTTOM = (8, 8, 12)

# Geometry in 1024-space.
CENTER_X = 512
DOME_BASE_Y = 468
DOME_RADIUS = 272
DOME_CORNER_RADIUS = 34
BAR_WIDTH = 72
BAR_TOP_Y = 520
BAR_LENGTHS = (150, 262, 196, 300, 118)


def px(value: float) -> int:
    return round(value * SCALE)


def glyph_mask() -> Image.Image:
    """White-on-black mask of the mark at supersampled resolution."""
    mask = Image.new("L", (px(SIZE), px(SIZE)), 0)
    left = CENTER_X - DOME_RADIUS
    right = CENTER_X + DOME_RADIUS
    # Dome: the upper half of a circle. Intersecting it with a rounded
    # rectangle softens the two base corners so they match the bar caps.
    circle = Image.new("L", mask.size, 0)
    ImageDraw.Draw(circle).ellipse(
        [px(left), px(DOME_BASE_Y - DOME_RADIUS), px(right), px(DOME_BASE_Y + DOME_RADIUS)], fill=255
    )
    upper = Image.new("L", mask.size, 0)
    ImageDraw.Draw(upper).rounded_rectangle(
        [px(left), px(DOME_BASE_Y - 2 * DOME_RADIUS), px(right), px(DOME_BASE_Y)],
        radius=px(DOME_CORNER_RADIUS),
        fill=255,
    )
    mask = ImageChops.multiply(circle, upper)
    draw = ImageDraw.Draw(mask)

    # Tentacles / EQ bars, evenly spread across the dome's width.
    count = len(BAR_LENGTHS)
    gap = (2 * DOME_RADIUS - count * BAR_WIDTH) / (count - 1)
    for index, length in enumerate(BAR_LENGTHS):
        x0 = left + index * (BAR_WIDTH + gap)
        draw.rounded_rectangle(
            [px(x0), px(BAR_TOP_Y), px(x0 + BAR_WIDTH), px(BAR_TOP_Y + length)],
            radius=px(BAR_WIDTH / 2),
            fill=255,
        )
    return mask


def vertical_gradient(top: tuple[int, int, int], bottom: tuple[int, int, int], y0: int, y1: int) -> Image.Image:
    """Full-canvas RGB gradient running from `top` at y0 to `bottom` at y1."""
    ramp = Image.linear_gradient("L").resize((px(SIZE), px(y1 - y0)))
    column = Image.new("L", (px(SIZE), px(SIZE)), 0)
    column.paste(ramp, (0, px(y0)))
    column.paste(255, (0, px(y1), px(SIZE), px(SIZE)))
    return Image.composite(
        Image.new("RGB", column.size, bottom), Image.new("RGB", column.size, top), column
    )


def background() -> Image.Image:
    """Near-black canvas with a faint plum glow behind the dome."""
    base = vertical_gradient(BACKGROUND_TOP, BACKGROUND_BOTTOM, 0, SIZE)
    glow = Image.radial_gradient("L").resize((px(1400), px(1400)))
    glow_mask = Image.new("L", base.size, 255)
    glow_mask.paste(glow, (px(CENTER_X - 700), px(440 - 700)))
    # radial_gradient is black in the middle: invert so the centre is lit.
    glow_mask = ImageChops.invert(glow_mask).point(lambda value: value * 0.30)
    return Image.composite(Image.new("RGB", base.size, (92, 44, 96)), base, glow_mask)


def finish(image: Image.Image) -> Image.Image:
    return image.resize((SIZE, SIZE), Image.LANCZOS)


def glyph_extent() -> tuple[int, int]:
    top = DOME_BASE_Y - DOME_RADIUS
    bottom = BAR_TOP_Y + max(BAR_LENGTHS)
    return top, bottom


def render_default() -> Image.Image:
    top, bottom = glyph_extent()
    fill = vertical_gradient(APRICOT, CORAL, top, bottom)
    return finish(Image.composite(fill, background(), glyph_mask()))


def render_dark() -> Image.Image:
    """iOS 18+ dark appearance: the mark alone on a transparent canvas."""
    top, bottom = glyph_extent()
    fill = vertical_gradient(APRICOT, CORAL, top, bottom).convert("RGBA")
    fill.putalpha(glyph_mask())
    return finish(fill)


def render_tinted() -> Image.Image:
    """iOS 18+ tinted appearance: opaque grayscale; the system adds the tint."""
    top, bottom = glyph_extent()
    fill = vertical_gradient((255, 255, 255), (150, 150, 150), top, bottom)
    canvas = Image.new("RGB", fill.size, (0, 0, 0))
    return finish(Image.composite(fill, canvas, glyph_mask()))


def srgb_profile() -> bytes:
    return ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def color_component(value: int) -> str:
    return f"0x{value:02X}"


def colorset(rgb: tuple[int, int, int]) -> dict:
    red, green, blue = rgb
    return {
        "colors": [
            {
                "color": {
                    "color-space": "srgb",
                    "components": {
                        "alpha": "1.000",
                        "blue": color_component(blue),
                        "green": color_component(green),
                        "red": color_component(red),
                    },
                },
                "idiom": "universal",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }


def main() -> int:
    profile = srgb_profile()
    info = {"author": "xcode", "version": 1}

    ASSETS.mkdir(parents=True, exist_ok=True)
    write_json(ASSETS / "Contents.json", {"info": info})

    # --- App icon (single-size, Xcode 14+; appearances need Xcode 16+) ------
    appicon = ASSETS / "AppIcon.appiconset"
    appicon.mkdir(exist_ok=True)
    default = render_default()
    dark = render_dark()
    tinted = render_tinted()
    default.save(appicon / "AppIcon.png", icc_profile=profile, optimize=True)
    dark.save(appicon / "AppIcon-Dark.png", icc_profile=profile, optimize=True)
    tinted.save(appicon / "AppIcon-Tinted.png", icc_profile=profile, optimize=True)

    def icon_entry(filename: str, appearance: str | None = None) -> dict:
        entry: dict = {}
        if appearance:
            entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        entry.update({"filename": filename, "idiom": "universal", "platform": "ios", "size": "1024x1024"})
        return entry

    write_json(
        appicon / "Contents.json",
        {
            "images": [
                icon_entry("AppIcon.png"),
                icon_entry("AppIcon-Dark.png", "dark"),
                icon_entry("AppIcon-Tinted.png", "tinted"),
            ],
            "info": info,
        },
    )

    # --- In-app logo (About screen); the AppIcon set cannot be loaded by name
    logo = ASSETS / "AppLogo.imageset"
    logo.mkdir(exist_ok=True)
    logo_images = []
    for scale in (1, 2, 3):
        name = f"AppLogo@{scale}x.png"
        default.resize((120 * scale, 120 * scale), Image.LANCZOS).save(
            logo / name, icc_profile=profile, optimize=True
        )
        logo_images.append({"filename": name, "idiom": "universal", "scale": f"{scale}x"})
    write_json(logo / "Contents.json", {"images": logo_images, "info": info})

    # --- Colours ------------------------------------------------------------
    for name, rgb in (("AccentColor", ACCENT), ("LaunchBackground", BACKGROUND_BOTTOM)):
        directory = ASSETS / f"{name}.colorset"
        directory.mkdir(exist_ok=True)
        write_json(directory / "Contents.json", colorset(rgb))

    # --- Self-check against the App Store rules in the module docstring -----
    problems = []
    for filename, mode in (("AppIcon.png", "RGB"), ("AppIcon-Dark.png", "RGBA"), ("AppIcon-Tinted.png", "RGB")):
        with Image.open(appicon / filename) as written:
            if written.size != (SIZE, SIZE):
                problems.append(f"{filename}: size {written.size}")
            if written.mode != mode:
                problems.append(f"{filename}: mode {written.mode}, expected {mode}")
            if not written.info.get("icc_profile"):
                problems.append(f"{filename}: no embedded colour profile")
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if not problems:
        print(f"wrote {ASSETS.relative_to(REPO)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
