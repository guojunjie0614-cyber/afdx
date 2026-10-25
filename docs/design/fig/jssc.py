"""JSSC 风格插图的统一样式与绘图函数。

坐标单位即印刷 pt：全宽图画布宽 450 pt（版心约 453 pt），插入 LaTeX 时不缩放，
因此各图字号一致。主体 1.4 pt 黑色轮廓、1.6 pt 主数据路径，内部细线 0.9 pt。
字号：框标题 8 pt 粗体，副标题/信号/连线标签 7.3 pt，最小 6.7 pt。
"""
import os

FONT = 'Arial, Helvetica, sans-serif'
T1, T2 = 8.0, 7.3          # 标题、次级字号（pt）
LW = 1.4                   # 连线线宽
BW = 1.4                   # 框线宽
DW = 1.6                   # 主数据路径
PAD = 4.0                  # 文字到框边的最小留白

# 按功能着色，全文一套
PAL = {
    'tx':  ('#FCE7D5', '#000000'),   # 发送通路：填充、文字
    'rx':  ('#DDF1F4', '#000000'),   # 接收通路
    'svc': ('#ECE3F2', '#000000'),   # 服务
    'ram': ('#F5EBD3', '#000000'),   # 块 RAM 表
    'cfg': ('#E5EDF7', '#000000'),   # 配置与控制
    'ext': ('#FFFFFF', '#000000'),   # 片外对象（虚线框）
    'gray': ('#F1F1F1', '#000000'),  # 中性
    'white': ('#FFFFFF', '#000000'),
    'drop': ('#ECE3F2', '#000000'),  # 丢弃/异常
    'pass': ('#EAF2DF', '#000000'),  # 通过
    'txl': ('#FFF3E8', '#000000'),   # 发送通路浅色（状态机的操作态）
    'svcl': ('#F4F1F6', '#000000'),  # 服务浅色
}
LEGEND_NAMES = {
    'tx': 'TX path', 'rx': 'RX path', 'svc': 'Services', 'ram': 'Block RAM',
    'cfg': 'Config / control', 'ext': 'Off-chip',
}

# Helvetica 字宽（1/1000 em），用于估算文字宽度和检查溢出
_REG = dict(zip(' !"#$%&\'()*+,-./0123456789:;<=>?@', [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278] + [556] * 10 + [278, 278, 584, 584, 584, 556, 1015]))
_REG.update(dict(zip('ABCDEFGHIJKLMNOPQRSTUVWXYZ', [667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611])))
_REG.update(dict(zip('abcdefghijklmnopqrstuvwxyz', [556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500])))
_REG.update({'[': 278, '\\': 278, ']': 278, '^': 469, '_': 556, '`': 333, '{': 334, '|': 260, '}': 334, '~': 584, '×': 584, '·': 278, '→': 1000, '≤': 549, '−': 584, '′': 247, '∧': 604})
_BOLD = dict(_REG)
_BOLD.update(dict(zip('ABCDEFGHIJKLMNOPQRSTUVWXYZ', [722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611])))
_BOLD.update(dict(zip('abcdefghijklmnopqrstuvwxyz', [556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500])))
_BOLD.update({'_': 556, '(': 333, ')': 333, '/': 278, '-': 333, '.': 278, ',': 278, ' ': 278})


def tw(s, size=T2, bold=False):
    """估算文字宽度（pt）。"""
    t = _BOLD if bold else _REG
    return sum(t.get(c, 600) for c in s) * size / 1000


def esc(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


class Box:
    def __init__(self, x, y, w, h):
        self.x, self.y, self.w, self.h = x, y, w, h

    l = property(lambda s: s.x)
    r = property(lambda s: s.x + s.w)
    t = property(lambda s: s.y)
    b = property(lambda s: s.y + s.h)
    cx = property(lambda s: s.x + s.w / 2)
    cy = property(lambda s: s.y + s.h / 2)


class Fig:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.body = []
        self.warn = []
        self.boxes = []     # (Box, 名称)
        self.segs = []      # ((x0, y0), (x1, y1))
        self.tags = []      # (x0, y0, x1, y1, 文字)

    # ---------- 基本元素 ----------
    def text(self, x, y, s, size=T2, anchor='middle', bold=True, color='#000', italic=False):
        """y 为文字基线。"""
        w = ' font-weight="bold"' if bold else ''
        it = ' font-style="italic"' if italic else ''
        self.body.append(f'<text x="{x:.2f}" y="{y:.2f}" font-size="{size}" text-anchor="{anchor}" fill="{color}"{w}{it}>{esc(s)}</text>')

    def rect(self, x, y, w, h, fill='#fff', stroke='#000', sw=0.9, dash=None, rx=0):
        d = f' stroke-dasharray="{dash}"' if dash else ''
        self.body.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>')

    def lines(self, x, ytop, rows, anchor='middle', color='#000'):
        """rows: [(文字, 字号, 粗体)]，ytop 为第一行顶部。返回总高度。"""
        y = ytop
        for s, size, bold in rows:
            y += size * 0.78
            self.text(x, y, s, size, anchor, bold, color)
            y += size * 0.42
        return y - ytop

    # ---------- 组件 ----------
    def box(self, x, y, w, h, kind, title, *subs, align='middle', tsize=T1, ssize=T2, name=None, rx=0, pad=PAD):
        """填色功能框：title 粗体，subs 每项一行。"""
        fill, fg = PAL[kind]
        dash = '2.5 1.5' if kind == 'ext' else None
        self.rect(x, y, w, h, fill, '#000', BW, dash, rx=rx)
        rows = [(title, tsize, True)] + [(s, ssize, True) for s in subs]
        th = sum(sz * 1.2 for _, sz, _ in rows) - 0.42 * rows[-1][1] + 0.0
        for s, sz, bd in rows:
            if tw(s, sz, bd) > w - 2 * pad + 0.5:
                self.warn.append(f'overflow: "{s}" {tw(s, sz, bd):.1f} > {w - 2 * pad:.1f}')
        if th > h - 2:
            self.warn.append(f'too tall: "{title}" text {th:.1f} > box {h}')
        tx = {'middle': x + w / 2, 'start': x + PAD}[align]
        self.lines(tx, y + (h - th) / 2 + 0.3, rows, align, fg)
        self.boxes.append((Box(x, y, w, h), title))
        return Box(x, y, w, h)

    def mux(self, x, y, w, h, label='', name='mux'):
        """多路选择器：左宽右窄的梯形，登记为框以便检查。"""
        k = h * 0.18
        pts = f'{x:.2f},{y:.2f} {x + w:.2f},{y + k:.2f} {x + w:.2f},{y + h - k:.2f} {x:.2f},{y + h:.2f}'
        self.body.append(f'<polygon points="{pts}" fill="#EDEDED" stroke="#000" stroke-width="{BW}"/>')
        if label:
            self.text(x + w / 2, y + h / 2 + 2.4, label, T2 - 0.5, 'middle', True)
        self.boxes.append((Box(x, y, w, h), name))
        return Box(x, y, w, h)

    def stub(self, x, y, dir, text):
        """短箭头接浅灰胶囊，返回胶囊边界。"""
        w, h = tw(text, bold=True) + 8, 12
        dx, dy = {'r': (1, 0), 'l': (-1, 0), 'u': (0, -1), 'd': (0, 1)}[dir]
        ex, ey = x + 12 * dx, y + 12 * dy
        bx = ex if dx == 1 else ex - w if dx == -1 else ex - w / 2
        by = ey if dy == 1 else ey - h if dy == -1 else ey - h / 2
        self.arrow([(x, y), (ex, ey)])
        b = self.box(bx, by, w, h, 'gray', text, tsize=T2, rx=6, pad=3)
        return b

    def reg(self, x, y, h, label=None):
        """六点宽寄存器；底边三角表示时钟。"""
        b = Box(x, y, 6, h)
        self.rect(x, y, b.w, h, PAL['gray'][0], '#000', LW)
        self.arrow([(x + 1, b.b), (b.cx, b.b - 3), (b.r - 1, b.b)], head=None, check=False)
        self.boxes.append((b, label or 'reg'))
        if label:
            self.tag(b.cx, y - 3, label, size=6.5)
        return b

    def gate_and(self, x, y, h, inv_inputs=()):
        """二输入与门；inputs[0:2] / output 是外部连线锚点。"""
        w, radius = h * 0.8, 1.7
        b = Box(x, y, w, h)
        self.body.append(f'<path d="M {x} {y} H {x + w - h / 2} '
                         f'A {h / 2} {h / 2} 0 0 1 {x + w - h / 2} {y + h} '
                         f'H {x} Z" fill="{PAL["gray"][0]}" stroke="#000" stroke-width="{LW}"/>')
        b.inputs = [(x - 2 * radius if i in inv_inputs else x, y + h * t)
                    for i, t in enumerate((0.25, 0.75))]
        b.output = (b.r, b.cy)
        for i in inv_inputs:
            self.body.append(f'<circle cx="{x - radius}" cy="{b.inputs[i][1]}" r="{radius}" '
                             f'fill="{PAL["white"][0]}" stroke="#000" stroke-width="{LW}"/>')
        self.boxes.append((b, 'AND'))
        return b

    def cells(self, x, y, w, h, n, kind):
        """等宽 FIFO 单元条。"""
        b = Box(x, y, w, h)
        self.rect(x, y, w, h, PAL[kind][0], '#000', LW)
        for i in range(1, n):
            self.arrow([(x + i * w / n, y), (x + i * w / n, y + h)], head=None, check=False)
        self.boxes.append((b, 'FIFO'))
        return b

    def stage_line(self, x, y0, y1, label=None):
        """流水级边界；灰色虚线不作为数据连线检查。"""
        self.arrow([(x, y0), (x, y1)], dash=True, head=None, sw=LW, color='#777', check=False)
        if label:
            self.tag(x, y0 - 4, label, size=6.5, color='#444')
        return Box(x, y0, 0, y1 - y0)

    def outline(self, b, sw=1.6, rx=4):
        """在已有框上加粗边框。"""
        self.rect(b.x, b.y, b.w, b.h, 'none', '#000', sw, rx=rx)

    def group(self, x, y, w, h, kind, label, dash=None, label_color=None, stroke=None):
        """子系统分组框：黑色直角轮廓，左上角标签。"""
        col = stroke if stroke is not None else '#000'
        if label_color is None:
            label_color = '#000'
        self.rect(x, y, w, h, 'none', col, BW, dash)
        if label:
            self.text(x + 4, y + 8.6, label, T2, 'start', True, label_color)
        return Box(x, y, w, h)

    def tag(self, x, y, s, size=T2, anchor='middle', bg=False, bold=True, italic=False, color='#000'):
        """连线或注释标签。y 为基线。bg=True 时加白底压线。"""
        w0 = tw(s, size, bold)
        x0 = {'middle': x - w0 / 2, 'start': x, 'end': x - w0}[anchor]
        self.tags.append((x0, y - size * 0.72, x0 + w0, y + size * 0.05, s, bg))
        if bg:
            w = tw(s, size, bold) + 2
            x0 = {'middle': x - w / 2, 'start': x - 1, 'end': x - w + 1}[anchor]
            self.rect(x0, y - size * 0.8, w, size * 1.05, '#fff', 'none', 0)
        self.text(x, y, s, size, anchor, bold, color, italic)

    def arrow(self, pts, dash=False, head='end', sw=LW, color='#000', check=True):
        """正交折线。head: 'end' / 'start' / 'both' / None。"""
        d = ' '.join(('M' if i == 0 else 'L') + f' {x:.2f} {y:.2f}' for i, (x, y) in enumerate(pts))
        da = ' stroke-dasharray="3 2"' if dash else ''
        self.body.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{sw}"{da}/>')
        if check:
            self.segs += list(zip(pts[:-1], pts[1:]))
        if head in ('end', 'both'):
            self._head(pts[-2], pts[-1], color)
        if head in ('start', 'both'):
            self._head(pts[1], pts[0], color)

    def _head(self, p0, p1, color, L=5.5, W=2.5):
        (x0, y0), (x1, y1) = p0, p1
        dx, dy = x1 - x0, y1 - y0
        n = (dx * dx + dy * dy) ** 0.5
        ux, uy = dx / n, dy / n
        bx, by = x1 - ux * L, y1 - uy * L
        pts = f'{x1:.2f},{y1:.2f} {bx - uy * W:.2f},{by + ux * W:.2f} {bx + uy * W:.2f},{by - ux * W:.2f}'
        self.body.append(f'<polygon points="{pts}" fill="{color}"/>')

    def legend(self, x, y, kinds, gap=10):
        """顶部一行图例。y 为色块顶部。返回结束 x。"""
        for k in kinds:
            fill, _ = PAL[k]
            self.rect(x, y, 10, 6.5, fill, '#000', 0.5, '2 1' if k == 'ext' else None)
            name = LEGEND_NAMES[k]
            self.text(x + 13, y + 5.8, name, T2, 'start')
            x += 13 + tw(name) + gap
        return x

    # ---------- 检查 ----------
    @staticmethod
    def _inside(px, py, x0, y0, x1, y1, m):
        return x0 + m < px < x1 - m and y0 + m < py < y1 - m

    def _seg_in(self, seg, x0, y0, x1, y1, m):
        (ax, ay), (bx, by) = seg
        n = max(2, int(max(abs(bx - ax), abs(by - ay)) / 0.5))
        return any(self._inside(ax + (bx - ax) * i / n, ay + (by - ay) * i / n, x0, y0, x1, y1, m) for i in range(n + 1))

    def check(self):
        for seg in self.segs:
            for b, name in self.boxes:
                if self._seg_in(seg, b.l, b.t, b.r, b.b, 0.8):
                    self.warn.append(f'line {seg} crosses box "{name}"')
        for x0, y0, x1, y1, s, bg in self.tags:
            if x0 < -0.5 or x1 > self.w + 0.5 or y0 < -0.5 or y1 > self.h + 0.5:
                self.warn.append(f'label "{s}" outside canvas')
            for b, name in self.boxes:
                if x0 < b.r - 0.3 and x1 > b.l + 0.3 and y0 < b.b - 0.3 and y1 > b.t + 0.3:
                    self.warn.append(f'label "{s}" overlaps box "{name}"')
            if not bg:
                for seg in self.segs:
                    if self._seg_in(seg, x0 - 0.8, y0 - 0.8, x1 + 0.8, y1 + 0.8, 0):
                        self.warn.append(f'label "{s}" touches line {seg}')
        for i, (a, na) in enumerate(self.boxes):
            for b, nb in self.boxes[i + 1:]:
                if a.l < b.r - 0.3 and a.r > b.l + 0.3 and a.t < b.b - 0.3 and a.b > b.t + 0.3:
                    self.warn.append(f'box "{na}" overlaps box "{nb}"')
        for b, name in self.boxes:
            if b.l < -0.5 or b.r > self.w + 0.5 or b.t < -0.5 or b.b > self.h + 0.5:
                self.warn.append(f'box "{name}" outside canvas')

    # ---------- 输出 ----------
    def save(self, path):
        self.check()
        # Export the page rather than glyph/drawing bounds: preserve print scale
        # and leave room for strokes centered on the nominal canvas edge.
        margin = 1.5
        width, height = self.w + 2 * margin, self.h + 2 * margin
        head = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}pt" height="{height}pt" '
                f'viewBox="{-margin} {-margin} {width} {height}">\n<style>text {{ font-family: {FONT}; }}</style>\n')
        with open(path, 'w', encoding='utf-8') as f:
            f.write(head + '\n'.join(self.body) + '\n</svg>\n')
        name = os.path.basename(path)
        for w in self.warn:
            print(f'[WARN] {name}: {w}')
        print(f'wrote {name} ({self.w}x{self.h} pt)')
