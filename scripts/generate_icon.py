#!/usr/bin/env python3
"""Generate PodcastReady app icon as .icns file.

Creates a 1024x1024 icon with a dark background, purple circle,
and white camera shape, then converts to .icns via iconutil.
"""

import os
import subprocess
import sys
import tempfile
import math

from PIL import Image, ImageDraw

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
OUTPUT_ICNS = os.path.join(PROJECT_ROOT, "PodcastReady", "Resources", "AppIcon.icns")

# Colors
BG_COLOR = (11, 11, 26)        # #0b0b1a
CIRCLE_COLOR = (167, 139, 250)  # #a78bfa
WHITE = (255, 255, 255)


def draw_camera(draw: ImageDraw.Draw, cx: int, cy: int, size: int):
    """Draw a simple camera icon centered at (cx, cy)."""
    # Camera body - rounded rectangle
    body_w = int(size * 0.60)
    body_h = int(size * 0.42)
    body_left = cx - body_w // 2
    body_top = cy - body_h // 2 + int(size * 0.04)
    body_right = body_left + body_w
    body_bottom = body_top + body_h
    radius = int(size * 0.05)
    draw.rounded_rectangle(
        [body_left, body_top, body_right, body_bottom],
        radius=radius,
        fill=WHITE,
    )

    # Viewfinder hump (trapezoid on top of body)
    hump_w = int(size * 0.22)
    hump_h = int(size * 0.08)
    hump_top_w = int(size * 0.16)
    hump_cx = cx + int(size * 0.02)
    hump_bottom = body_top
    hump_top = hump_bottom - hump_h
    draw.polygon(
        [
            (hump_cx - hump_w // 2, hump_bottom),
            (hump_cx - hump_top_w // 2, hump_top),
            (hump_cx + hump_top_w // 2, hump_top),
            (hump_cx + hump_w // 2, hump_bottom),
        ],
        fill=WHITE,
    )

    # Lens circle (cut out from body)
    lens_r = int(size * 0.12)
    lens_cx = cx
    lens_cy = (body_top + body_bottom) // 2 + int(size * 0.01)
    draw.ellipse(
        [lens_cx - lens_r, lens_cy - lens_r, lens_cx + lens_r, lens_cy + lens_r],
        fill=CIRCLE_COLOR,
    )

    # Inner lens highlight
    inner_r = int(size * 0.07)
    draw.ellipse(
        [lens_cx - inner_r, lens_cy - inner_r, lens_cx + inner_r, lens_cy + inner_r],
        fill=BG_COLOR,
    )

    # Tiny lens reflection dot
    dot_r = int(size * 0.025)
    dot_cx = lens_cx - int(size * 0.02)
    dot_cy = lens_cy - int(size * 0.02)
    draw.ellipse(
        [dot_cx - dot_r, dot_cy - dot_r, dot_cx + dot_r, dot_cy + dot_r],
        fill=WHITE,
    )


def generate_icon(target_size: int = 1024) -> Image.Image:
    """Generate the icon at the given size."""
    img = Image.new("RGBA", (target_size, target_size), BG_COLOR + (255,))
    draw = ImageDraw.Draw(img)

    center = target_size // 2

    # Purple circle background
    circle_r = int(target_size * 0.38)
    draw.ellipse(
        [
            center - circle_r,
            center - circle_r,
            center + circle_r,
            center + circle_r,
        ],
        fill=CIRCLE_COLOR + (255,),
    )

    # Camera shape
    draw_camera(draw, center, center, target_size)

    return img


def create_iconset(base_img: Image.Image) -> str:
    """Create a .iconset directory with all required sizes. Returns path."""
    iconset_dir = tempfile.mkdtemp(suffix=".iconset")

    # Required sizes for macOS .iconset
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for size in sizes:
        resized = base_img.resize((size, size), Image.LANCZOS)
        # Standard resolution
        if size <= 512:
            resized.save(os.path.join(iconset_dir, f"icon_{size}x{size}.png"))
        # Retina (@2x) — the 2x version of half the size
        if size >= 32:
            half = size // 2
            resized.save(os.path.join(iconset_dir, f"icon_{half}x{half}@2x.png"))

    return iconset_dir


def main():
    print("Generating PodcastReady app icon...")

    # Generate base 1024x1024 icon
    base = generate_icon(1024)

    # Save 1024 PNG for reference
    os.makedirs(os.path.dirname(OUTPUT_ICNS), exist_ok=True)
    png_path = OUTPUT_ICNS.replace(".icns", ".png")
    base.save(png_path)
    print(f"  Saved PNG: {png_path}")

    # Create .iconset and convert to .icns
    iconset_dir = create_iconset(base)
    print(f"  Created iconset: {iconset_dir}")

    result = subprocess.run(
        ["iconutil", "-c", "icns", iconset_dir, "-o", OUTPUT_ICNS],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"  iconutil error: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    print(f"  Saved ICNS: {OUTPUT_ICNS}")

    # Cleanup
    import shutil
    shutil.rmtree(iconset_dir)

    print("Done.")


if __name__ == "__main__":
    main()
