"""Generate the README's resource and latency figures as SVG.

Render PNGs at 2x with:
    rsvg-convert -z 2 -b white resource.svg -o resource.png
    rsvg-convert -z 2 -b white latency.svg -o latency.png
"""

from math import log10
from pathlib import Path

INK = "#17202A"
MUTED = "#667085"
GRID = "#E2E6EA"
TRACK = "#E9EDF2"
AXIS = "#9AA3AD"
REFERENCE = "#A7B0BA"
ACCENT = "#2457A6"
FONT = "Arial, PingFang SC, Hiragino Sans GB, Microsoft YaHei, sans-serif"
OUT = Path(__file__).resolve().parent


def text(x, y, value, size=15, color=INK, anchor="start", weight=400):
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-family="{FONT}" '
        f'font-size="{size}" font-weight="{weight}" fill="{color}" '
        f'text-anchor="{anchor}">{value}</text>'
    )


def document(width, height, body):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" viewBox="0 0 {width} {height}">\n'
        f'<rect width="{width}" height="{height}" fill="#FFFFFF"/>\n'
        + "\n".join(body)
        + "\n</svg>\n"
    )


def resource():
    rows = [
        ("查找表  LUT", 45.74),
        ("触发器  FF", 26.14),
        ("逻辑块  CLB", 75.13),
        ("片上存储  M4K", 67.83),
        ("用户 I/O", 50.74),
    ]
    width, height = 1200, 330
    x0, x1, value_x = 240, 1000, 1028
    parts = [text(32, 36, "占器件总容量 / %", 14, MUTED)]
    parts += [
        text(x0, 66, "0", 13, MUTED, "middle"),
        text(x1, 66, "100", 13, MUTED, "middle"),
    ]
    for index, (label, value) in enumerate(rows):
        y = 94 + index * 44
        parts.append(text(206, y + 12, label, 16, INK, "end"))
        parts.append(
            f'<rect x="{x0}" y="{y}" width="{x1 - x0}" height="12" fill="{TRACK}"/>'
        )
        parts.append(
            f'<rect x="{x0}" y="{y}" width="{(x1 - x0) * value / 100:.2f}" '
            f'height="12" fill="{ACCENT}"/>'
        )
        parts.append(text(value_x, y + 12, f"{value:.2f}%", 16, INK, "start", 600))
    return document(width, height, parts)


def latency():
    points = [(1, 1.056), (17, 1.136), (18, 1.152), (511, 9.040), (1471, 24.400)]
    width, height = 1200, 430
    x0, x1, y0, y1 = 140, 1110, 60, 330
    ymax = 26.0
    log_max = log10(points[-1][0])

    def px(length):
        return x0 + log10(length) / log_max * (x1 - x0)

    def py(value):
        return y1 - value / ymax * (y1 - y0)

    parts = [text(32, 30, "端到端时延 / µs", 14, MUTED)]
    for tick in (0, 10, 20):
        y = py(tick)
        parts.append(
            f'<line x1="{x0}" y1="{y:.2f}" x2="{x1}" y2="{y:.2f}" '
            f'stroke="{GRID}" stroke-width="1"/>'
        )
        parts.append(text(112, y + 5, str(tick), 14, MUTED, "end"))
    parts.append(
        f'<line x1="{x0}" y1="{y1}" x2="{x1}" y2="{y1}" '
        f'stroke="{AXIS}" stroke-width="1"/>'
    )

    coordinates = " ".join(f"{px(n):.2f},{py(v):.2f}" for n, v in points)
    parts.append(
        f'<polyline points="{coordinates}" fill="none" stroke="{REFERENCE}" '
        'stroke-width="1.5" stroke-linejoin="round"/>'
    )
    for length, value in points:
        parts.append(
            f'<circle cx="{px(length):.2f}" cy="{py(value):.2f}" r="4.5" '
            f'fill="{ACCENT}"/>'
        )

    for length, _ in points:
        if length == 17:
            anchor, dx = "end", -9
        elif length == 18:
            anchor, dx = "start", 9
        elif length == 1471:
            anchor, dx = "end", 0
        else:
            anchor, dx = "middle", 0
        parts.append(text(px(length) + dx, 360, str(length), 14, INK, anchor))

    for length, anchor, dx in ((1, "start", 0), (511, "middle", 0), (1471, "end", 0)):
        value = dict(points)[length]
        parts.append(text(px(length) + dx, py(value) - 20, f"{value:.3f}", 15, ACCENT, anchor, 600))

    parts.append(text(x1, 408, "应用消息长度 / B（对数刻度）", 14, MUTED, "end"))
    return document(width, height, parts)


for name, figure in (("resource", resource), ("latency", latency)):
    path = OUT / f"{name}.svg"
    path.write_text(figure(), encoding="utf-8")
    print(path)
