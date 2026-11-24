from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] * (1 - t) + b[i] * t) for i in range(3))


def ramp(t: float, stops: tuple[tuple[int, int, int], ...]) -> tuple[int, int, int]:
    t = max(0.0, min(1.0, t))
    p = t * (len(stops) - 1)
    i = int(p)
    j = min(len(stops) - 1, i + 1)
    return mix(stops[i], stops[j], p - i)


def make_icon(size: int = 512) -> Image.Image:
    scale = 2
    n = size * scale
    image = Image.new("RGBA", (n, n), (4, 8, 24, 255))
    pixels = image.load()

    # Midnight blue base gradient.
    for y in range(n):
        col = mix((3, 10, 30), (13, 10, 43), y / (n - 1))
        for x in range(n):
            pixels[x, y] = (*col, 255)

    # Soft cyan/violet glow behind the audio mark.
    glow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((58*scale, 62*scale, 454*scale, 458*scale), fill=(10, 98, 235, 76))
    gd.ellipse((135*scale, 160*scale, 395*scale, 420*scale), fill=(82, 36, 228, 62))
    image = Image.alpha_composite(image, glow.filter(ImageFilter.GaussianBlur(50*scale)))
    d = ImageDraw.Draw(image)

    # Glass-like orbital ring.
    d.ellipse((45*scale, 45*scale, 467*scale, 467*scale), outline=(24, 67, 145, 210), width=3*scale)
    d.arc((45*scale, 45*scale, 467*scale, 467*scale), 192, 350, fill=(0, 210, 255, 220), width=4*scale)
    d.arc((45*scale, 45*scale, 467*scale, 467*scale), 8, 166, fill=(180, 55, 255, 225), width=4*scale)

    # Recessed equalizer bars in the background.
    xs = [76, 108, 140, 172, 204, 308, 340, 372, 404, 436]
    heights = [54, 83, 116, 152, 108, 108, 152, 116, 83, 54]
    for x, height in zip(xs, heights):
        color = ramp((x - 76) / (436 - 76), ((0, 208, 255), (28, 112, 255), (171, 51, 255)))
        box = ((x-7)*scale, (315-height)*scale, (x+7)*scale, 315*scale)
        d.rounded_rectangle(box, radius=7*scale, fill=(*color, 205))
        d.line(((x-3)*scale, (315-height+7)*scale, (x-3)*scale, 308*scale),
               fill=(228, 251, 255, 105), width=2*scale)

    # A sculpted audio ribbon with a dark extrusion, metallic face and specular edges.
    points = []
    for x in range(32, 481, 2):
        u = (x - 32) / 448
        y = 282 + 82*math.sin(u*math.pi*2.15 - 0.5) + 11*math.sin(u*math.pi*4.3)
        points.append((x*scale, int(y)*scale))

    def offset(dy: int):
        return [(x, y + dy*scale) for x, y in points]

    d.line(offset(17), fill=(0, 1, 14, 235), width=90*scale, joint="curve")
    d.line(offset(8), fill=(1, 14, 54, 255), width=82*scale, joint="curve")
    for i in range(len(points)-1):
        t = i / (len(points)-2)
        color = ramp(t, ((0, 143, 236), (0, 208, 255), (18, 97, 238),
                         (119, 45, 239), (206, 50, 255)))
        d.line((points[i], points[i+1]), fill=(*color, 255), width=70*scale)

    # Bevel-like lighter face and chrome highlight.
    d.line(offset(-7), fill=(46, 132, 245, 255), width=48*scale, joint="curve")
    for i in range(len(points)-1):
        t = i / (len(points)-2)
        color = ramp(t, ((52, 225, 255), (200, 248, 255), (51, 170, 255), (230, 186, 255)))
        p1 = (points[i][0], points[i][1] - 14*scale)
        p2 = (points[i+1][0], points[i+1][1] - 14*scale)
        d.line((p1, p2), fill=(*color, 255), width=13*scale)
    d.line(offset(-22), fill=(244, 255, 255, 240), width=4*scale, joint="curve")
    d.line(offset(24), fill=(12, 20, 92, 220), width=7*scale, joint="curve")

    # Bright glass highlights at the two wave ends.
    for cx, cy, color in ((37, points[2][1]//scale, (0, 220, 255)),
                          (475, points[-3][1]//scale, (194, 67, 255))):
        d.ellipse(((cx-11)*scale, (cy-11)*scale, (cx+11)*scale, (cy+11)*scale),
                  fill=(*color, 255))
        d.ellipse(((cx-4)*scale, (cy-4)*scale, (cx+4)*scale, (cy+4)*scale),
                  fill=(245, 255, 255, 255))

    floor = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(floor).ellipse((70*scale, 405*scale, 450*scale, 492*scale),
                                  fill=(0, 133, 255, 65))
    image = Image.alpha_composite(image, floor.filter(ImageFilter.GaussianBlur(28*scale)))
    return image.resize((size, size), Image.Resampling.LANCZOS)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate Aura Voice Studio's 3D-style Windows icon.")
    parser.add_argument("--output-dir", default=".")
    args = parser.parse_args()
    output = Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)

    icon = make_icon(512)
    icon.save(output / "aura_voice_icon.png", format="PNG", optimize=True)
    icon.save(output / "app_icon.ico", format="ICO",
              sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)])


if __name__ == "__main__":
    main()
