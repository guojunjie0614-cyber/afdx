"""Generate the README resource and latency figures as SVG.

Render PNGs at 2x with:
    rsvg-convert -z 2 -b white resource.svg -o resource.png
    rsvg-convert -z 2 -b white latency.svg -o latency.png
"""

from html import escape
from pathlib import Path

INK = "#17202A"
SLATE = "#334155"
MUTED = "#64748B"
OUTER_BORDER = "#E2E8F0"
GRID = "#E2E6EA"
TRACK = "#EEF2F6"
AXIS = "#94A3B8"
ACCENT = "#1D4ED8"
ACCENT_SOFT = "#EFF6FF"
ACCENT_BORDER = "#93C5FD"
FONT = "PingFang SC, Hiragino Sans GB, Microsoft YaHei, Arial, sans-serif"
MONO = "Menlo, Consolas, Monaco, monospace"
OUT = Path(__file__).resolve().parent


def text(x, y, value, size=14, color=INK, anchor="start", weight=400, mono=False):
    family = MONO if mono else FONT
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-family="{family}" '
        f'font-size="{size}" font-weight="{weight}" fill="{color}" '
        f'text-anchor="{anchor}">{escape(str(value))}</text>'
    )


def box(x, y, w, h, fill="#FFFFFF", stroke=ACCENT_BORDER, sw=1.5, rx=8):
    return (
        f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
        f'rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>'
    )


def document(width, height, body):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" viewBox="0 0 {width} {height}">\n'
        f'<rect width="{width}" height="{height}" fill="#FFFFFF"/>\n'
        f'<rect x="0.75" y="0.75" width="{width-1.5}" height="{height-1.5}" '
        f'rx="8" fill="none" stroke="{OUTER_BORDER}" stroke-width="1.5"/>\n'
        + "\n".join(body)
        + "\n</svg>\n"
    )


def resource():
    rows = [
        ("查找表  LUT", 62274, 136160, 45.74),
        ("触发器  FF", 35597, 136160, 26.14),
        ("逻辑块  CLB", 10230, 13616, 75.13),
        ("片上存储  M4K", 814, 1200, 67.83),
        ("用户引脚  I/O", 172, 339, 50.74),
    ]
    width, height = 1200, 346
    x0, x1, value_x = 228, 880, 904
    parts = [
        text(32, 38, "EQ6HL130-CSG484_H 布线后资源占用", 17, INK, "start", 700),
        text(1168, 38, "专用 DSP：0 / 48 (0.00%) · PLL：0 / 8 (0.00%)", 13, MUTED, "end", 500),
        f'<line x1="32" y1="54" x2="1168" y2="54" stroke="{OUTER_BORDER}" stroke-width="1"/>',
        text(x0, 80, "0%", 12.5, MUTED, "middle"),
        text((x0 + x1) / 2, 80, "50%", 12.5, MUTED, "middle"),
        text(x1, 80, "100%", 12.5, MUTED, "middle"),
        f'<line x1="{(x0+x1)/2}" y1="88" x2="{(x0+x1)/2}" y2="316" stroke="{GRID}" stroke-dasharray="4 4" stroke-width="1"/>',
    ]
    for index, (label, used, total, pct) in enumerate(rows):
        y = 104 + index * 44
        parts.append(text(204, y + 13, label, 15, INK, "end", 500))
        parts.append(f'<rect x="{x0}" y="{y}" width="{x1 - x0}" height="14" rx="3" fill="{TRACK}"/>')
        bar_color = ACCENT if pct < 70 else "#1E40AF"
        parts.append(
            f'<rect x="{x0}" y="{y}" width="{(x1 - x0) * pct / 100:.2f}" '
            f'height="14" rx="3" fill="{bar_color}"/>'
        )
        parts.append(
            text(value_x, y + 13, f"{used:,} / {total:,}  ({pct:.2f}%)", 14.5, INK, "start", 600, True)
        )
    return document(width, height, parts)


def latency():
    points = [
        ("1 B", 1.576),
        ("17 B", 1.968),
        ("18 B", 2.000),
        ("511 B", 17.776),
        ("1471 B", 48.592),
    ]
    width, height = 1200, 440
    x0, x1, y0, y1 = 110, 1140, 88, 344
    ymax = 55.0
    xs = [215, 410, 605, 800, 995]
    bar_w = 68

    def py(value):
        return y1 - value / ymax * (y1 - y0)

    parts = [
        text(32, 38, "端到端传输时延（125 MHz 轻载单帧）", 17, INK, "start", 700),
        text(1168, 38, "分片版 tb_sys_perf 轻载工况（11-03）；63 VL 满载见 5.2 节", 13, MUTED, "end", 500),
        f'<line x1="32" y1="54" x2="1168" y2="54" stroke="{OUTER_BORDER}" stroke-width="1"/>',
        text(32, 84, "时延 / µs", 13, MUTED),
    ]

    for tick in (0, 10, 20, 30, 40, 50):
        y = py(tick)
        parts.append(
            f'<line x1="{x0}" y1="{y:.2f}" x2="{x1}" y2="{y:.2f}" '
            f'stroke="{GRID if tick > 0 else AXIS}" stroke-width="1"/>'
        )
        parts.append(text(x0 - 14, y + 5, str(tick), 13, MUTED, "end"))

    for x, (label, value) in zip(xs, points):
        top = py(value)
        h = max(4.0, y1 - top)
        parts.append(
            f'<rect x="{x - bar_w/2:.1f}" y="{top:.2f}" width="{bar_w}" '
            f'height="{h:.2f}" rx="4" fill="{ACCENT}"/>'
        )
        parts.append(text(x, top - 12, f"{value:.3f} µs", 14.5, INK, "middle", 700))
        parts.append(text(x, y1 + 26, label, 14.5, INK, "middle", 600))

    parts.append(text(x1, y1 + 58, "应用消息载荷长度（每种 8 样本，取正反方向与两种链路延迟中的最大值）", 13, MUTED, "end"))
    return document(width, height, parts)


for name, figure in (("resource", resource), ("latency", latency)):
    path = OUT / f"{name}.svg"
    path.write_text(figure(), encoding="utf-8")
    print(path)
