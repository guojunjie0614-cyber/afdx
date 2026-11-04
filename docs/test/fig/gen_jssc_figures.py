"""测试报告平台图、判据图和性能图的 SVG 生成器。

平台图读取 src/t01_platform.svg；其余图在本模块生成。
"""

import os
import re
import sys

PAL = {
    'tx': '#D9813F',
    'rx': '#2F9688',
    'svc': '#6A5BA8',
    'ram': '#F2D488',
    'cfg': '#A9C6EA',
    'ext': '#FFFFFF',
    'gray': '#E6E6E6',
    'white': '#FFFFFF',
    'drop': '#F6D2B8',
    'pass': '#BFE3DC',
    'txl': '#F4CDAE',
    'border': '#000000',
    'grid': '#E5E7EB',
}

DEFS = """  <defs>
    <marker id="arr-blk" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
      <path d="M 1 1.5 L 7 4 L 1 6.5 z" fill="#000000"/>
    </marker>
    <marker id="arr-green" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
      <path d="M 1 1.5 L 7 4 L 1 6.5 z" fill="#2F9688"/>
    </marker>
    <marker id="arr-orange" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
      <path d="M 1 1.5 L 7 4 L 1 6.5 z" fill="#D9813F"/>
    </marker>
    <marker id="arr-gray" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="5" markerHeight="5" orient="auto-start-reverse">
      <path d="M 1 1.5 L 7 4 L 1 6.5 z" fill="#666666"/>
    </marker>
  </defs>
  <style>
    text {
      font-family: Arial, Helvetica, sans-serif;
      text-rendering: geometricPrecision;
    }
  </style>
  <rect width="100%" height="100%" fill="#ffffff"/>
"""

def _trim_top(svg, top, bottom=0):
    """Crop vertical viewport margins; retain the original drawing scale."""
    match = re.search(r'viewBox="0 0 ([0-9.]+) ([0-9.]+)"', svg)
    if match is None:
        raise ValueError('Expected an SVG canvas with origin 0, 0')
    width, height = match.groups()
    cropped_height = f'{float(height) - top - bottom:g}'
    svg = svg.replace(match.group(0), f'viewBox="0 {top} {width} {cropped_height}"', 1)
    svg = svg.replace(f'height="{height}"', f'height="{cropped_height}"', 1)
    # Percentage backgrounds would otherwise shrink before the viewport is cropped.
    return svg.replace('width="100%" height="100%"', f'width="{width}" height="{height}"', 1)


# ==============================================================================
# Fig 1: t01_platform (Scheme 1 Selected by User)
# ==============================================================================
def gen_t01_platform():
    src = os.path.join(os.path.dirname(__file__), 'src', 't01_platform.svg')
    with open(src, 'r', encoding='utf-8') as stream:
        return stream.read()


# ==============================================================================
# Fig 2: t02_criteria (Verification Closure & Multi-Gate Acceptance)
# ==============================================================================
def gen_t02_criteria():
    """Acceptance checks applied according to each test's configuration."""
    from html import escape

    w, h = 720, 376
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">', DEFS, "<style>text {font-family:'Arial Narrow',Arial,sans-serif;}</style>"]

    def box(x, y, width, height, fill):
        svg.append(f'<rect x="{x}" y="{y}" width="{width}" height="{height}" fill="{fill}" stroke="#000000" stroke-width="1.05"/>')

    def text(x, y, label, size=11, weight='normal', color='#000000'):
        svg.append(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="middle">{escape(label)}</text>')

    def arrow(path):
        svg.append(f'<path d="{path}" fill="none" stroke="#000000" stroke-width="1.1" marker-end="url(#arr-blk)"/>')

    stages = [
        (16, '#DCE8F4', '#B7CFE7', '#FFFFFF',
         'STAGE 1: TESTBENCH SELF-CHECK',
         'Runtime protocol and interface checks (all 67 RTL tests)',
         'Criterion: PASS result; errors = 0'),
        (140, '#F0F0F0', '#D7D7D7', '#FEF0C9',
         'STAGE 2: PYTHON REFERENCE CHECK',
         'Independent afdx_ref / fragment_ref / sys_ref checker',
         'Criterion: Checker passes; errors = 0'),
        (264, '#E3EDE4', '#C2D5C1', '#E0EDDF',
         'STAGE 3: RTL / NETLIST RECORD COMPARISON',
         '4 post-route VQM netlist categories (NET-01 to NET-04)',
         'Criterion: Same stimulus; byte-for-byte record match'),
    ]
    for y, body, header, criterion, title, scope, rule in stages:
        box(16, y, 452, 98 if y == 264 else 94, body)
        box(16, y, 452, 28, header)
        text(242, y + 20, title, 17, 'bold')
        text(242, y + 48, scope, 16)
        box(25, y + 58, 434, 27, criterion)
        text(242, y + 77, rule, 15.5)

    box(531, 135, 174, 80, '#B75854')
    text(618, 173, 'VERDICT: FAIL', 22, 'bold', '#FFFFFF')
    text(618, 194, 'Test failed', 16, color='#FFFFFF')
    box(531, 302, 174, 60, '#347F58')
    text(618, 330, 'VERDICT: PASS', 22, 'bold', '#FFFFFF')
    text(618, 350, 'Applicable checks passed', 14.5, color='#FFFFFF')

    arrow('M 242 110 L 242 140')
    text(266, 132, 'YES', 16, 'bold', '#347F58')
    arrow('M 242 234 L 242 264')
    text(284, 256, 'YES / N/A', 14.5, 'bold', '#347F58')

    arrow('M 468 63 L 618 63 L 618 135')
    text(500, 57, 'NO', 16, 'bold', '#965625')
    arrow('M 468 187 L 531 187')
    text(500, 181, 'NO', 16, 'bold', '#965625')
    arrow('M 468 281 L 618 281 L 618 215')
    text(500, 275, 'NO', 16, 'bold', '#965625')
    arrow('M 468 334 L 531 334')
    text(500, 328, 'YES / N/A', 14.5, 'bold', '#347F58')

    svg.append('</svg>')
    return '\n'.join(svg)


# ==============================================================================
# Fig 3: t20_thru (Throughput vs. Active VLs)
# ==============================================================================
def gen_t20_thru():
    """Per-direction payload throughput, with the 100 Mbps requirement."""
    w, h = 540, 310
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">', DEFS]
    x0, y0 = 70, 230
    gw, gh = 452, 206
    scale = gh / 1100.0

    for mbps in range(0, 1001, 200):
        y = y0 - mbps * scale
        if 0 < mbps < 1000:
            svg.append(f'<line x1="{x0}" y1="{y:.3f}" x2="{x0 + gw}" y2="{y:.3f}" stroke="#CCCCCC" stroke-width="0.7" stroke-dasharray="3 3"/>')
        svg.append(f'<line x1="{x0 - 5}" y1="{y:.3f}" x2="{x0}" y2="{y:.3f}" stroke="#000000" stroke-width="1"/>')
        svg.append(f'<text x="{x0 - 9}" y="{y + 3.3:.3f}" font-size="10" fill="#000000" text-anchor="end">{mbps}</text>')

    data = [
        (10, 117.680, 130, "10 VLs", "#34668B"),
        (63, 741.384, 244, "63 VLs (Full Spec)", "#2F9688"),
        (77, 906.136, 358, "77 VLs (Stress)", "#34668B"),
        (81, 953.208, 468, "81 VLs (Stress)", "#34668B"),
    ]
    bw = 56
    for vl, val, cx, lbl, fill in data:
        bh = val * scale
        by = y0 - bh
        svg.append(f'<rect x="{cx - bw / 2:.3f}" y="{by:.3f}" width="{bw}" height="{bh:.3f}" fill="{fill}" stroke="#000000" stroke-width="1"/>')
        svg.append(f'<text x="{cx}" y="{by - 6:.3f}" font-size="9.5" font-weight="bold" fill="#000000" text-anchor="middle">{val:.3f} Mbps</text>')
        svg.append(f'<line x1="{cx}" y1="{y0}" x2="{cx}" y2="{y0 + 5}" stroke="#000000" stroke-width="1"/>')
        svg.append(f'<text x="{cx}" y="{y0 + 18}" font-size="9.5" fill="#000000" text-anchor="middle">{lbl}</text>')

    # Draw the requirement across the bars, as in the supplied reference.
    y_spec = y0 - 100 * scale
    svg.append(f'<line x1="{x0}" y1="{y_spec:.3f}" x2="{x0 + gw}" y2="{y_spec:.3f}" stroke="#963C1E" stroke-width="1.1" stroke-dasharray="4 2"/>')
    svg.append(f'<text x="187" y="{y_spec - 4:.3f}" font-size="8.0" font-weight="bold" fill="#963C1E" text-anchor="middle">Spec: 100 Mbps</text>')
    svg.append(f'<rect x="{x0}" y="{y0 - gh}" width="{gw}" height="{gh}" fill="none" stroke="#000000" stroke-width="1.1"/>')
    svg.append(f'<text x="20" y="{y0 - gh / 2}" transform="rotate(-90 20 {y0 - gh / 2})" font-size="11" fill="#000000" text-anchor="middle">Throughput (Mbps)</text>')

    # Bottom annotation strip: Latency & Burst Summary
    svg.append(f'<rect x="{x0}" y="254" width="{gw}" height="46" fill="#F8F9FA" stroke="#D1D5DB" stroke-width="0.8"/>')
    svg.append(f'<text x="{x0 + 10}" y="268" font-size="8.2" font-weight="bold" fill="#1F2937">63-VL Full Spec: 741.384 Mbps/dir (1482.768 Mbps Bi-Dir, 77.5% Line) | P1 Lat: ≤80.336 µs | P2 Jitter: ≤3.360 µs</text>')
    svg.append(f'<text x="{x0 + 10}" y="281" font-size="7.9" fill="#4B5563">77/81-VL Stress Burst Drain (Top 2B-VLID / Core): 983.720 / 959.288 µs (77 VL) | 1032.936 / 1008.504 µs (81 VL)</text>')
    svg.append(f'<text x="{x0 + 10}" y="293" font-size="7.9" fill="#6B7280">63-VL Mixed (1472/3000/8192 B): 12,206 msgs, 0 drops | Multi-VL var_high: 904.752 Mbps (var_cycle jitter: 9.992 µs)</text>')
    svg.append('</svg>')
    return '\n'.join(svg)


# ==============================================================================
# Fig 4: t21_lat (End-to-End Latency vs. Payload Size)
# ==============================================================================
def gen_t21_lat():
    """End-to-end latency for the five measured message lengths and pipeline breakdown."""
    w, h = 540, 310
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">', DEFS]
    x0, y0 = 70, 218
    gw, gh = 452, 194
    scale = gh / 30.0

    for us in range(0, 31, 5):
        y = y0 - us * scale
        if 0 < us < 30:
            svg.append(f'<line x1="{x0}" y1="{y:.3f}" x2="{x0 + gw}" y2="{y:.3f}" stroke="#CCCCCC" stroke-width="0.7" stroke-dasharray="3 3"/>')
        svg.append(f'<line x1="{x0 - 5}" y1="{y:.3f}" x2="{x0}" y2="{y:.3f}" stroke="#000000" stroke-width="1"/>')
        svg.append(f'<text x="{x0 - 9}" y="{y + 3.3:.3f}" font-size="10" fill="#000000" text-anchor="end">{us}</text>')

    points = [(1, 1.056, 116), (17, 1.136, 196), (18, 1.152, 276),
              (511, 9.040, 356), (1471, 24.424, 446)]
    bw = 48
    for n, us, cx in points:
        bh = us * scale
        by = y0 - bh
        svg.append(f'<rect x="{cx - bw / 2:.3f}" y="{by:.3f}" width="{bw}" height="{bh:.3f}" fill="#34668B" stroke="#000000" stroke-width="1"/>')
        lbl_us = f"{us:.3f} µs" if n != 1471 else f"{us:.3f} µs (max 24.432)"
        svg.append(f'<text x="{cx}" y="{by - 6:.3f}" font-size="9.5" font-weight="bold" fill="#000000" text-anchor="middle">{lbl_us}</text>')
        svg.append(f'<line x1="{cx}" y1="{y0}" x2="{cx}" y2="{y0 + 5}" stroke="#000000" stroke-width="1"/>')
        svg.append(f'<text x="{cx}" y="{y0 + 18}" font-size="10" fill="#000000" text-anchor="middle">{n} B</text>')

    svg.append(f'<rect x="{x0}" y="{y0 - gh}" width="{gw}" height="{gh}" fill="none" stroke="#000000" stroke-width="1.1"/>')
    svg.append(f'<text x="20" y="{y0 - gh / 2}" transform="rotate(-90 20 {y0 - gh / 2})" font-size="11" fill="#000000" text-anchor="middle">Latency (µs)</text>')

    # Pipeline breakdown box below the plot
    svg.append(f'<rect x="{x0}" y="244" width="{gw}" height="56" fill="#F8F9FA" stroke="#D1D5DB" stroke-width="0.8"/>')
    svg.append(f'<text x="{x0 + 10}" y="258" font-size="8.5" font-weight="bold" fill="#1F2937">1471 B Core Single-Frame Latency Pipeline (afdx_es R97, 125 MHz, Link=0 ns):</text>')
    svg.append(f'<text x="{x0 + 10}" y="271" font-size="8.0" fill="#374151">TX Pipeline: 32 cyc (0.256 µs) [SFD: 39 cyc / 0.312 µs]  |  GMII Wire: 1525 cyc (12.200 µs)</text>')
    svg.append(f'<text x="{x0 + 10}" y="283" font-size="8.0" fill="#374151">RX Core: 26 cyc (0.208 µs)  |  Deliver (app): 1470 cyc (11.760 µs)  |  Total: 3053 cyc = 24.424 µs (Max: 3054 cyc = 24.432 µs)</text>')
    svg.append(f'<text x="{x0 + 10}" y="295" font-size="8.0" font-weight="bold" fill="#059669">Same-VL R97 Jitter: 0.008 µs (1 cyc AGE sweep interleaving)  |  TX Interval Jitter: 0.000 µs</text>')
    svg.append('</svg>')
    return '\n'.join(svg)


# ==============================================================================
# Fig 5: t15_w_615a (ARINC 615A TFTP Data & Ack Protocol Sequence)
# ==============================================================================
def gen_t15_w_615a():
    w, h = 660, 240
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">', DEFS]

    svg.append(f'  <rect x="12" y="12" width="{w - 24}" height="{h - 24}" fill="none" stroke="#000000" stroke-width="1.0" stroke-dasharray="5 3"/>')
    svg.append(f'  <text x="24" y="27" font-size="9.5" font-weight="bold" fill="#000000" letter-spacing="0.5px">ARINC 615A / TFTP DATA BLOCK &amp; DUAL-NETWORK REDUNDANT ACK PROTOCOL TIMING</text>')

    rows = [
        ("clk (125 MHz)", 52, "#000000"),
        ("rx_valid (GMII)", 82, "#2F9688"),
        ("rx_data [7:0]", 116, "#2F9688"),
        ("tx_valid_a / b", 154, "#D9813F"),
        ("txd_a / txd_b [7:0]", 188, "#D9813F"),
    ]

    for label, y, col in rows:
        svg.append(f'  <text x="118" y="{y}" font-size="8.5" font-weight="bold" fill="{col}" text-anchor="end">{label}</text>')

    x_start = 126
    x_end = 636
    cyc_w = 14

    # 时钟信号
    clk_d = []
    for i in range(36):
        cx = x_start + i * cyc_w
        if i == 0:
            clk_d.append(f"M {cx} 54 L {cx + cyc_w/2} 54 L {cx + cyc_w/2} 44 L {cx + cyc_w} 44")
        else:
            clk_d.append(f"L {cx} 54 L {cx + cyc_w/2} 54 L {cx + cyc_w/2} 44 L {cx + cyc_w} 44")
    svg.append(f'  <path d="{" ".join(clk_d)}" fill="none" stroke="#555555" stroke-width="0.8"/>')

    # rx_valid
    x_r1_s, x_r1_e = x_start + 2 * cyc_w, x_start + 12 * cyc_w
    x_r2_s, x_r2_e = x_start + 20 * cyc_w, x_start + 28 * cyc_w

    svg.append(f'''  <!-- rx_valid -->
  <path d="M {x_start} 86 L {x_r1_s} 86 L {x_r1_s} 74 L {x_r1_e} 74 L {x_r1_e} 86 L {x_r2_s} 86 L {x_r2_s} 74 L {x_r2_e} 74 L {x_r2_e} 86 L {x_end} 86" fill="none" stroke="#2F9688" stroke-width="1.2"/>''')

    # 总线底线 (表示空闲与连续总线)
    svg.append(f'''  <!-- rx_data idle lines -->
  <line x1="{x_start}" y1="114" x2="{x_r1_s}" y2="114" stroke="#999999" stroke-width="0.8"/>
  <line x1="{x_r1_e}" y1="114" x2="{x_r2_s}" y2="114" stroke="#999999" stroke-width="0.8"/>
  <line x1="{x_r2_e}" y1="114" x2="{x_end}" y2="114" stroke="#999999" stroke-width="0.8"/>''')

    def bus_box(x, y, bw, bh, fill, label, sub=""):
        res = [f'<polygon points="{x},{y+bh/2} {x+4},{y} {x+bw-4},{y} {x+bw},{y+bh/2} {x+bw-4},{y+bh} {x+4},{y+bh}" fill="{fill}" stroke="#000000" stroke-width="1.0"/>']
        if sub:
            res.append(f'<text x="{x + bw/2}" y="{y + bh/2 - 1}" font-size="8.0" font-weight="bold" fill="#FFFFFF" text-anchor="middle">{label}</text>')
            res.append(f'<text x="{x + bw/2}" y="{y + bh/2 + 8}" font-size="7.0" fill="#FFFFFF" text-anchor="middle">{sub}</text>')
        else:
            res.append(f'<text x="{x + bw/2}" y="{y + bh/2 + 3}" font-size="8.0" font-weight="bold" fill="#000000" text-anchor="middle">{label}</text>')
        return "\n  ".join(res)

    # DATA n 前导 + 块
    svg.append(f'  {bus_box(x_r1_s, 104, 24, 20, "#FFFFFF", "55", "")}')
    svg.append(f'  {bus_box(x_r1_s + 24, 104, (x_r1_e - x_r1_s - 24), 20, "#2F9688", "DATA n", "512 Bytes")}')

    # DATA n+1 前导 + 末块
    svg.append(f'  {bus_box(x_r2_s, 104, 24, 20, "#FFFFFF", "55", "")}')
    svg.append(f'  {bus_box(x_r2_s + 24, 104, (x_r2_e - x_r2_s - 24), 20, "#2F9688", "DATA n+1", "&lt; 512 B (Final)")}')

    # tx_valid_a/b
    x_t1_s, x_t1_e = x_r1_e + 2 * cyc_w, x_r1_e + 7 * cyc_w
    x_t2_s, x_t2_e = x_r2_e + 2 * cyc_w, x_r2_e + 7 * cyc_w

    svg.append(f'''  <!-- tx_valid_a/b -->
  <path d="M {x_start} 158 L {x_t1_s} 158 L {x_t1_s} 146 L {x_t1_e} 146 L {x_t1_e} 158 L {x_t2_s} 158 L {x_t2_s} 146 L {x_t2_e} 146 L {x_t2_e} 158 L {x_end} 158" fill="none" stroke="#D9813F" stroke-width="1.2"/>''')

    # tx_data idle lines
    svg.append(f'''  <!-- tx_data idle lines -->
  <line x1="{x_start}" y1="186" x2="{x_t1_s}" y2="186" stroke="#999999" stroke-width="0.8"/>
  <line x1="{x_t1_e}" y1="186" x2="{x_t2_s}" y2="186" stroke="#999999" stroke-width="0.8"/>
  <line x1="{x_t2_e}" y1="186" x2="{x_end}" y2="186" stroke="#999999" stroke-width="0.8"/>''')

    # tx_data 总线 (暖橙色 #D9813F 填充)
    svg.append(f'  {bus_box(x_t1_s, 176, 20, 20, "#FFFFFF", "55", "")}')
    svg.append(f'  {bus_box(x_t1_s + 20, 176, (x_t1_e - x_t1_s - 20), 20, "#D9813F", "ACK n", "Block n")}')

    svg.append(f'  {bus_box(x_t2_s, 176, 20, 20, "#FFFFFF", "55", "")}')
    svg.append(f'  {bus_box(x_t2_s + 20, 176, (x_t2_e - x_t2_s - 20), 20, "#D9813F", "ACK n+1", "Final ACK")}')

    # 测量指示箭头与注解
    svg.append(f'''  <!-- Dimension Labels -->
  <line x1="{x_r1_s}" y1="98" x2="{x_r1_e}" y2="98" stroke="#000000" stroke-width="0.8"/>
  <rect x="{(x_r1_s + x_r1_e)/2 - 50}" y="92" width="100" height="11" fill="#FFFFFF" stroke="none"/>
  <text x="{(x_r1_s + x_r1_e)/2}" y="100" font-size="7.5" font-weight="bold" fill="#000000" text-anchor="middle">512-Byte Full Block</text>

  <line x1="{x_r2_s}" y1="98" x2="{x_r2_e}" y2="98" stroke="#000000" stroke-width="0.8"/>
  <rect x="{(x_r2_s + x_r2_e)/2 - 65}" y="92" width="130" height="11" fill="#FFFFFF" stroke="none"/>
  <text x="{(x_r2_s + x_r2_e)/2}" y="100" font-size="7.5" font-weight="bold" fill="#000000" text-anchor="middle">Last Block (&lt; 512 B) Ends Transfer</text>

  <!-- Dual Network Redundant Sync -->
  <line x1="{x_t1_s}" y1="214" x2="{x_t1_e}" y2="214" stroke="#D9813F" stroke-width="1.0"/>
  <text x="{(x_t1_s + x_t1_e)/2}" y="224" font-size="7.5" font-weight="bold" fill="#D9813F" text-anchor="middle">Net A &amp; B Co-Clock Ack</text>''')

    svg.append('</svg>')
    return '\n'.join(svg)


# ==============================================================================
# Fig 6: t16_w_rtc (SNTP Clock Sync Timestamp Verification)
# ==============================================================================
def gen_t16_w_rtc():
    w, h = 660, 240
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">', DEFS]

    svg.append(f'  <rect x="12" y="12" width="{w - 24}" height="{h - 24}" fill="none" stroke="#000000" stroke-width="1.0" stroke-dasharray="5 3"/>')
    svg.append(f'  <text x="24" y="27" font-size="9.5" font-weight="bold" fill="#000000" letter-spacing="0.5px">SNTP TIME SYNCHRONIZATION REQUEST/RESPONSE TIMESTAMP LOOP INTEGRITY</text>')

    rows = [
        ("clk (125 MHz)", 52, "#000000"),
        ("tx_valid_a / b", 82, "#D9813F"),
        ("txd_a / txd_b [7:0]", 116, "#D9813F"),
        ("rx_valid (GMII)", 154, "#2F9688"),
        ("rx_data [7:0]", 188, "#2F9688"),
    ]

    for label, y, col in rows:
        svg.append(f'  <text x="118" y="{y}" font-size="8.5" font-weight="bold" fill="{col}" text-anchor="end">{label}</text>')

    x_start = 126
    x_end = 636
    cyc_w = 14

    # 时钟
    clk_d = []
    for i in range(36):
        cx = x_start + i * cyc_w
        if i == 0:
            clk_d.append(f"M {cx} 54 L {cx + cyc_w/2} 54 L {cx + cyc_w/2} 44 L {cx + cyc_w} 44")
        else:
            clk_d.append(f"L {cx} 54 L {cx + cyc_w/2} 54 L {cx + cyc_w/2} 44 L {cx + cyc_w} 44")
    svg.append(f'  <path d="{" ".join(clk_d)}" fill="none" stroke="#555555" stroke-width="0.8"/>')

    def bus_box(x, y, bw, bh, fill, label, sub=""):
        res = [f'<polygon points="{x},{y+bh/2} {x+4},{y} {x+bw-4},{y} {x+bw},{y+bh/2} {x+bw-4},{y+bh} {x+4},{y+bh}" fill="{fill}" stroke="#000000" stroke-width="1.0"/>']
        if sub:
            res.append(f'<text x="{x + bw/2}" y="{y + bh/2 - 1}" font-size="8.0" font-weight="bold" fill="#FFFFFF" text-anchor="middle">{label}</text>')
            res.append(f'<text x="{x + bw/2}" y="{y + bh/2 + 8}" font-size="7.0" fill="#FFFFFF" text-anchor="middle">{sub}</text>')
        else:
            res.append(f'<text x="{x + bw/2}" y="{y + bh/2 + 3}" font-size="8.0" font-weight="bold" fill="#000000" text-anchor="middle">{label}</text>')
        return "\n  ".join(res)

    # tx_valid: 发送 SNTP Request (cyc 2..12)
    x_t_s, x_t_e = x_start + 2 * cyc_w, x_start + 12 * cyc_w
    svg.append(f'''  <!-- tx_valid -->
  <path d="M {x_start} 86 L {x_t_s} 86 L {x_t_s} 74 L {x_t_e} 74 L {x_t_e} 86 L {x_end} 86" fill="none" stroke="#D9813F" stroke-width="1.2"/>''')

    # tx_data idle lines
    svg.append(f'''  <!-- tx_data idle lines -->
  <line x1="{x_start}" y1="114" x2="{x_t_s}" y2="114" stroke="#999999" stroke-width="0.8"/>
  <line x1="{x_t_e}" y1="114" x2="{x_end}" y2="114" stroke="#999999" stroke-width="0.8"/>''')

    svg.append(f'  {bus_box(x_t_s, 104, 24, 20, "#FFFFFF", "55", "")}')
    svg.append(f'  {bus_box(x_t_s + 24, 104, (x_t_e - x_t_s - 24), 20, "#D9813F", "SNTP Request", "Transmit = T1")}')

    # rx_valid: 主端回复 SNTP Response (cyc 20..32)
    x_r_s, x_r_e = x_start + 20 * cyc_w, x_start + 32 * cyc_w
    svg.append(f'''  <!-- rx_valid -->
  <path d="M {x_start} 158 L {x_r_s} 158 L {x_r_s} 146 L {x_r_e} 146 L {x_r_e} 158 L {x_end} 158" fill="none" stroke="#2F9688" stroke-width="1.2"/>''')

    # rx_data idle lines
    svg.append(f'''  <!-- rx_data idle lines -->
  <line x1="{x_start}" y1="186" x2="{x_r_s}" y2="186" stroke="#999999" stroke-width="0.8"/>
  <line x1="{x_r_e}" y1="186" x2="{x_end}" y2="186" stroke="#999999" stroke-width="0.8"/>''')

    svg.append(f'  {bus_box(x_r_s, 176, 24, 20, "#FFFFFF", "55", "")}')
    svg.append(f'  {bus_box(x_r_s + 24, 176, (x_r_e - x_r_s - 24), 20, "#2F9688", "SNTP Response", "Originate = T1 | T2, T3")}')

    # 时间戳比对闭环连线 (T1 Loop Match)
    svg.append(f'''  <!-- Timestamp Verification Bridge -->
  <path d="M {(x_t_s + x_t_e)/2} 124 L {(x_t_s + x_t_e)/2} 140 L {(x_r_s + x_r_e)/2} 140 L {(x_r_s + x_r_e)/2} 176" fill="none" stroke="#000000" stroke-width="1.2" stroke-dasharray="3 2" marker-end="url(#arr-blk)"/>
  <rect x="{(x_t_s + x_r_e)/2 - 110}" y="134" width="220" height="13" fill="#FFFFFF" stroke="#000000" stroke-width="0.8"/>
  <text x="{(x_t_s + x_r_e)/2}" y="143" font-size="8.0" font-weight="bold" fill="#000000" text-anchor="middle">Verification: Originate Timestamp in Response == T1</text>''')

    svg.append('</svg>')
    return '\n'.join(svg)


GENERATORS = {
    't01_platform': gen_t01_platform,
    't02_criteria': gen_t02_criteria,
    't20_thru': gen_t20_thru,
    't21_lat': gen_t21_lat,
    't15_w_615a': gen_t15_w_615a,
    't16_w_rtc': gen_t16_w_rtc,
}

if __name__ == '__main__':
    base_dir = os.path.dirname(os.path.abspath(__file__))
    v2_dir = os.path.join(base_dir, 'v2')
    pdf_dir = os.path.join(base_dir, 'pdf')
    os.makedirs(v2_dir, exist_ok=True)
    os.makedirs(pdf_dir, exist_ok=True)

    for name, gen in GENERATORS.items():
        svg_content = gen()
        svg_path = os.path.join(v2_dir, f'{name}.svg')
        with open(svg_path, 'w', encoding='utf-8') as f:
            f.write(svg_content)
        print(f'Generated SVG: {svg_path}')
