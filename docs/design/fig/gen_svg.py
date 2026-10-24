"""手绘 JSSC 风格 SVG：帧格式、状态机和环形缓冲指针。

用法: python3 -I gen_svg.py <输出目录>
状态与转移条件依据 rtl/afdx_tx_engine.v、afdx_mac_tx.v、afdx_mac_rx.v。
"""
import math
import os
import sys

FONT = 'Helvetica, Arial, sans-serif'
HEAD = '''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">
<style>
text {{ font-family: {font}; fill: #000; }}
.st {{ fill: #fff; stroke: #000; stroke-width: 1.4; }}
.st0 {{ fill: #e6e6e6; stroke: #000; stroke-width: 1.4; }}
.ed {{ fill: none; stroke: #000; stroke-width: 1.2; }}
.ed2 {{ fill: none; stroke: #000; stroke-width: 1.2; stroke-dasharray: 5 3; }}
.box {{ fill: #fff; stroke: #000; stroke-width: 1.2; }}
.gray {{ fill: #e0e0e0; stroke: #000; stroke-width: 1.2; }}
.hatch {{ fill: url(#hatch); stroke: #000; stroke-width: 1.2; stroke-dasharray: 4 2; }}
.thin {{ fill: none; stroke: #000; stroke-width: 0.8; }}
</style>
<defs>
<marker id="ar" markerUnits="userSpaceOnUse" markerWidth="10" markerHeight="7" refX="9.5" refY="3.5" orient="auto">
<polygon points="0 0, 10 3.5, 0 7" fill="#000"/></marker>
<pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
<rect width="6" height="6" fill="#fff"/><line x1="0" y1="0" x2="0" y2="6" stroke="#777" stroke-width="1.2"/></pattern>
</defs>
'''


# 印刷字号放大系数
FONT_SCALE = 1.2


def svg(w, h, body):
    return HEAD.format(w=w, h=h, font=FONT) + body + '</svg>\n'


def text(x, y, s, size=11, anchor='middle', weight='normal', style=''):
    s = s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    st = f' font-style="{style}"' if style else ''
    size = round(size * FONT_SCALE, 1)
    return f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" text-anchor="{anchor}" font-weight="{weight}"{st}>{s}</text>\n'


def state(x, y, name, r=40, sub=None, cls='st'):
    out = f'<circle cx="{x}" cy="{y}" r="{r}" class="{cls}"/>\n'
    if sub:
        out += text(x, y - 2, name, 12, weight='bold') + text(x, y + 13, sub, 9)
    else:
        out += text(x, y + 4, name, 12, weight='bold')
    return out


def edge_between(a, b, ra, rb, off=0.0, cls='ed', bend=0.0):
    """从圆 a 到圆 b 的箭头；off 为法向平移，bend 为弧线弯曲量。返回路径和中点、法向。"""
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    d = math.hypot(dx, dy)
    ux, uy = dx / d, dy / d
    nx, ny = -uy, ux
    if bend == 0:
        sx, sy = ax + ux * ra + nx * off, ay + uy * ra + ny * off
        ex, ey = bx - ux * rb + nx * off, by - uy * rb + ny * off
        path = f'<path d="M {sx:.1f} {sy:.1f} L {ex:.1f} {ey:.1f}" class="{cls}" marker-end="url(#ar)"/>\n'
        mx, my = (sx + ex) / 2, (sy + ey) / 2
    else:
        ang = 0.35 if bend > 0 else -0.35
        ca, sa = math.cos(ang), math.sin(ang)
        sux, suy = ux * ca - uy * sa, ux * sa + uy * ca
        eux, euy = -ux * ca - uy * sa, ux * sa * -1 + -uy * ca
        eux, euy = -(ux * ca + uy * sa), -(-ux * sa + uy * ca)
        sx, sy = ax + sux * ra, ay + suy * ra
        ex, ey = bx + eux * rb, by + euy * rb
        cx, cy = (ax + bx) / 2 + nx * bend, (ay + by) / 2 + ny * bend
        path = f'<path d="M {sx:.1f} {sy:.1f} Q {cx:.1f} {cy:.1f} {ex:.1f} {ey:.1f}" class="{cls}" marker-end="url(#ar)"/>\n'
        mx, my = 0.25 * sx + 0.5 * cx + 0.25 * ex, 0.25 * sy + 0.5 * cy + 0.25 * ey
    return path, (mx, my), (nx, ny)


def label_at(mid, normal, dist, lines, size=10, anchor='middle'):
    mx, my = mid
    nx, ny = normal
    x, y = mx + nx * dist, my + ny * dist
    out = ''
    y0 = y - (len(lines) - 1) * (size + 2) / 2 + size * 0.35
    for i, s in enumerate(lines):
        out += text(x, y0 + i * (size + 2), s, size, anchor=anchor)
    return out


def self_loop(x, y, r, side, cls='ed'):
    """在圆的一侧画自环。side: 'top' 或 'bottom'。返回路径和标签锚点。"""
    sgn = -1 if side == 'top' else 1
    a1, a2 = math.radians(60), math.radians(120)
    p1 = (x + r * math.cos(a1), y + sgn * r * math.sin(a1))
    p2 = (x + r * math.cos(a2), y + sgn * r * math.sin(a2))
    c1 = (x + r * 1.3, y + sgn * r * 2.3)
    c2 = (x - r * 1.3, y + sgn * r * 2.3)
    path = (f'<path d="M {p1[0]:.1f} {p1[1]:.1f} C {c1[0]:.1f} {c1[1]:.1f} {c2[0]:.1f} {c2[1]:.1f} '
            f'{p2[0]:.1f} {p2[1]:.1f}" class="{cls}" marker-end="url(#ar)"/>\n')
    return path, (x, y + sgn * r * 1.95)


def fig_tx_engine():
    R = 40
    init, idle = (90, 200), (320, 200)
    start, enq, grant = (600, 55), (660, 200), (600, 345)
    b = ''
    b += state(*init, 'INIT', R, 'clear tables', cls='st0')
    b += state(*idle, 'IDLE', 46, 'scan', cls='st')
    b += state(*start, 'START', R)
    b += state(*enq, 'ENQ', R)
    b += state(*grant, 'GRANT', R)
    p, m, n = edge_between(init, idle, R, 46)
    b += p + label_at(m, n, -12, ['init_flush'])
    def lines(x, y, ls, anchor):
        return ''.join(text(x, y + i * 14, t, 10, anchor=anchor) for i, t in enumerate(ls))
    for tgt in (start, enq, grant):
        b += edge_between(idle, tgt, 46, R, off=-7)[0]
        b += edge_between(tgt, idle, R, 46, off=-7)[0]
    # 标签用绝对坐标，避开成对的往返边
    b += lines(445, 108, ['(1) start ack'], 'end')
    b += lines(478, 150, ['next_time = t_start + BAG'], 'start')
    b += lines(490, 187, ['(2) enqueue req'], 'middle')
    b += lines(490, 225, ['accept / reject'], 'middle')
    b += lines(478, 256, ['fields to builder,', 'pend_vl = vl'], 'start')
    b += lines(468, 316, ['(3) candidate &', 'builder slot free'], 'end')
    p, a = self_loop(idle[0], idle[1], 46, 'bottom')
    b += p + text(250, a[1] + 34, 'no request: read one VL', 10) + text(250, a[1] + 47, 'every 2 cycles (pipelined)', 10)
    b += text(745, 405, 'Priority: (1) > (2) > (3)', 10, anchor='end', style='italic')
    return svg(760, 415, b)


def fig_mac_fsm():
    R = 38
    b = ''
    # (a) afdx_mac_tx
    gap, pre, dat, fcs, drn = (80, 150), (250, 150), (420, 150), (420, 330), (140, 330)
    b += state(*gap, 'GAP', R, 'idle / IFG', cls='st0')
    b += state(*pre, 'PRE', R, '55 x7, D5')
    b += state(*dat, 'DATA', R, '1 B / cycle')
    b += state(*fcs, 'FCS', R, '4 bytes')
    b += state(*drn, 'DRAIN', R, 'discard')
    p, m, n = edge_between(gap, pre, R, R)
    b += p + label_at(m, n, -22, ['gap_left = 0 &', 's_valid / tx_sof'])
    p, m, n = edge_between(pre, dat, R, R)
    b += p + label_at(m, n, -14, ['8th byte & s_valid'])
    p, m, n = edge_between(dat, fcs, R, R)
    b += p + label_at(m, n, -10, ['s_last sent', 'or underrun'], anchor='start')
    p, m, n = edge_between(pre, fcs, R, R, cls='ed2')
    b += p + label_at(m, n, 30, ['underrun'])
    p, m, n = edge_between(fcs, gap, R, R)
    b += p + label_at(m, n, -16, ['4th FCS byte / tx_eof'])
    p, m, n = edge_between(fcs, drn, R, R, cls='ed2')
    b += p + label_at(m, n, -14, ['after underrun'])
    p, m, n = edge_between(drn, gap, R, R, cls='ed2')
    b += p + label_at(m, n, -34, ['upstream', 's_last taken'])
    p, a = self_loop(dat[0], dat[1], R, 'top')
    b += p + text(a[0], a[1] - 24, 's_valid & !s_last', 10)
    b += text(250, 410, '(a) afdx_mac_tx', 12, weight='bold')
    # (b) afdx_mac_rx
    ox = 540
    idl, prr, frm, bad = (ox + 80, 150), (ox + 250, 150), (ox + 420, 150), (ox + 250, 330)
    b += state(*idl, 'IDLE', R, 'armed', cls='st0')
    b += state(*prr, 'PRE', R, 'wait D5')
    b += state(*frm, 'FRAME', R, 'CRC + length')
    b += state(*bad, 'BAD_PRE', R, 'f_err = 3')
    p, m, n = edge_between(idl, prr, R, R)
    b += p + label_at(m, n, -14, ['first byte 55'])
    p, m, n = edge_between(prr, frm, R, R)
    b += p + label_at(m, n, -14, ['D5'])
    p, m, n = edge_between(idl, frm, R, R, bend=-75)
    b += p + label_at(m, n, -12, ['first byte D5'])
    p, m, n = edge_between(idl, bad, R, R)
    b += p + text(ox + 112, 262, 'first byte', 10, anchor='end') + text(ox + 112, 275, 'not 55 / D5', 10, anchor='end')
    p2, m, n = edge_between(prr, bad, R, R)
    b += p2 + text(ox + 258, 245, 'not 55 / D5', 10, anchor='start')
    b += text(ox + 420, 300, 'Any state: rx_valid low', 10, style='italic')
    b += text(ox + 420, 314, '-> IDLE with f_end and', 10, style='italic')
    b += text(ox + 420, 328, 'f_err = ok / FCS / len / pre', 10, style='italic')
    b += text(ox + 250, 410, '(b) afdx_mac_rx', 12, weight='bold')
    return svg(1020, 425, b)


def fig_frame():
    b = ''
    fields = [
        ('Preamble', '7', 62, 'thin'), ('SFD', '1', 38, 'thin'),
        ('Dst MAC', '6', 92, 'box'), ('Src MAC', '6', 92, 'box'), ('Type', '2', 46, 'box'),
        ('IPv4 header', '20', 104, 'box'), ('UDP hdr', '8', 70, 'box'),
        ('Payload', 'n = 1..1471', 132, 'gray'), ('Pad', '17-n', 52, 'box'),
        ('SN', '1', 38, 'gray'), ('FCS', '4', 50, 'box'), ('IFG', '12', 46, 'thin'),
    ]
    x0, y0, h = 20, 70, 44
    x = x0
    pos = {}
    for name, nbytes, w, cls in fields:
        dash = ' stroke-dasharray="4 2"' if cls == 'thin' else ''
        klass = 'box' if cls == 'thin' else cls
        b += f'<rect x="{x}" y="{y0}" width="{w}" height="{h}" class="{klass}"{dash}/>\n'
        b += text(x + w / 2, y0 + 19, name, 11, weight='bold')
        b += text(x + w / 2, y0 + 34, nbytes, 10)
        pos[name] = (x, w)
        x += w
    xe = x
    # 上方括号：帧长和 CRC 范围
    def bracket_top(xa, xb, y, s):
        return (f'<path d="M {xa} {y + 8} L {xa} {y} L {xb} {y} L {xb} {y + 8}" class="thin"/>\n'
                + text((xa + xb) / 2, y - 5, s, 10))
    dx, _ = pos['Dst MAC']
    fx, fw = pos['FCS']
    sx, sw = pos['SN']
    b += bracket_top(dx, fx + fw, 40, 'Frame length incl. FCS: 47 + max(n, 17) = 64 ... 1518 bytes')
    b += bracket_top(dx, sx + sw, 58, '')
    b += text((dx + sx + sw) / 2 + 150, 54, 'CRC32 coverage', 9, style='italic')
    # 下方展开：MAC 地址
    def expand(name, parts, y):
        xa, wa = pos[name]
        out = f'<path d="M {xa} {y0 + h} L {xa - 30 if name == "Dst MAC" else xa} {y}" class="thin"/>\n'
        tot = sum(p[2] for p in parts)
        cx = 14 if name == 'Dst MAC' else 146
        out = (f'<path d="M {xa} {y0 + h} L {cx} {y}" class="thin"/>\n'
               f'<path d="M {xa + wa} {y0 + h} L {cx + tot} {y}" class="thin"/>\n')
        for t1, t2, w in parts:
            out += f'<rect x="{cx}" y="{y}" width="{w}" height="38" class="box"/>\n'
            out += text(cx + w / 2, y + 16, t1, 10, weight='bold') + text(cx + w / 2, y + 30, t2, 9)
            cx += w
        return out
    b += expand('Dst MAC', [('03 00 00 00', 'fixed', 74), ('VLID', '2 B', 50)], 150)
    b += expand('Src MAC', [('02 00 00', 'fixed', 58), ('User ID', '2 B', 52), ('IF', '20h A / 40h B', 74)], 150)
    ix, iw = pos['IPv4 header']
    ux, uw = pos['UDP hdr']
    b += text(ix + iw / 2, 135, 'total = n + 28', 9) + text(ix + iw / 2, 147, 'TTL 1, proto 17', 9)
    b += text(ux + uw / 2, 135, 'len = n + 8', 9) + text(ux + uw / 2, 147, 'checksum 0', 9)
    px, pw = pos['Payload']
    b += text(px + pw / 2, 135, 'application data', 9)
    sx, sw = pos['SN']
    b += text(sx + sw / 2 + 4, 135, '0, then 1..255', 9) + text(sx + sw / 2 + 4, 147, '(255 -> 1)', 9)
    return svg(xe + 20, 205, b)


def fig_ring():
    b = ''
    x0, y0, W, H = 40, 90, 760, 46
    segs = [
        (0.00, 0.14, 'box', 'free'),
        (0.14, 0.52, 'gray', 'committed, waiting for rx_deliver'),
        (0.52, 0.74, 'hatch', 'current frame (trial)'),
        (0.74, 1.00, 'box', 'free'),
    ]
    for a, c, cls, s in segs:
        xa, xc = x0 + a * W, x0 + c * W
        b += f'<rect x="{xa:.1f}" y="{y0}" width="{xc - xa:.1f}" height="{H}" class="{cls}"/>\n'
        b += text((xa + xc) / 2, y0 + H / 2 + 4, s, 10, weight='bold' if cls != 'box' else 'normal')
    def ptr(f, name, owner, up=True):
        x = x0 + f * W
        if up:
            return (f'<path d="M {x:.1f} {y0 - 34} L {x:.1f} {y0 - 2}" class="ed" marker-end="url(#ar)"/>\n'
                    + text(x, y0 - 52, name, 11, weight='bold') + text(x, y0 - 39, owner, 9))
        return (f'<path d="M {x:.1f} {y0 + H + 34} L {x:.1f} {y0 + H + 2}" class="ed" marker-end="url(#ar)"/>\n'
                + text(x, y0 + H + 48, name, 11, weight='bold') + text(x, y0 + H + 61, owner, 9))
    b += ptr(0.14, 'rd', 'rx_deliver')
    b += ptr(0.52, 'wr_commit', 'rx_parse')
    b += ptr(0.74, 'wr_trial', 'rx_parse')
    # 回绕
    b += (f'<path d="M {x0 + W + 4} {y0 + H / 2} L {x0 + W + 22} {y0 + H / 2} L {x0 + W + 22} {y0 + H + 80} '
          f'L {x0 - 22} {y0 + H + 80} L {x0 - 22} {y0 + H / 2} L {x0 - 4} {y0 + H / 2}" class="thin" marker-end="url(#ar)"/>\n')
    b += text(x0 + W / 2, y0 + H + 76, 'wrap: 2^RX_RING_AW = 4096 bytes per network, pointers carry one extra bit', 9, style='italic')
    xa = x0 + 0.52 * W
    xb = x0 + 0.74 * W
    b += text((xa + xb) / 2, y0 + H + 30, 'commit: wr_commit <= wr_trial', 10)
    b += text((xa + xb) / 2, y0 + H + 44, 'rollback: wr_trial <= wr_commit', 10)
    b += text(x0 + 0.33 * W, y0 + H + 30, 'free = 4096 - (wr_commit - rd)', 10)
    return svg(x0 + W + 50, y0 + H + 100, b)


if __name__ == '__main__':
    out = sys.argv[1]
    for name, fn in (('f06_frame', fig_frame), ('f08_txfsm', fig_tx_engine),
                     ('f10_macfsm', fig_mac_fsm), ('f12_ring', fig_ring)):
        with open(os.path.join(out, name + '.svg'), 'w', encoding='utf-8') as f:
            f.write(fn())
        print('wrote', name)
