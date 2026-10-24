"""把 archify 生成的 HTML 里的主 SVG 转成 JSSC 风格的黑白矢量图。

用法: python3 -I jssc_svg.py <in.html> <out.svg>
去掉背景网格、图标和交互属性，折线改成直角，颜色统一为黑白灰，字体为 Helvetica。
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

SVG_NS = 'http://www.w3.org/2000/svg'
ET.register_namespace('', SVG_NS)

STYLE = """
rect[class^="c-"], path[class^="c-"] { fill: none; stroke: #000; stroke-width: 1; }
text { font-family: Helvetica, Arial, sans-serif; fill: #000; }
.t-dim { fill: #000; font-weight: 600; }
.c-lane { fill: #f4f4f4; stroke: #000; stroke-width: 0.8; }
.c-lane-exception { fill: #fff; stroke: #000; stroke-width: 0.8; stroke-dasharray: 6 3; }
.t-muted { fill: #333; }
.c-mask { fill: #fff !important; stroke: none !important; }
.c-backend, .c-frontend, .c-cloud, .c-security { fill: #fff; stroke: #000; stroke-width: 1.3; }
.c-database, .c-messagebus { fill: #e6e6e6; stroke: #000; stroke-width: 1.3; }
.c-external { fill: #fff; stroke: #000; stroke-width: 1.3; stroke-dasharray: 5 3; }
.c-region { fill: none; stroke: #000; stroke-width: 1; stroke-dasharray: 8 4; }
.c-sgroup, .c-security-group { fill: none; stroke: #555; stroke-width: 1; stroke-dasharray: 3 3; }
.a-default, .a-security { fill: none; stroke: #000; stroke-width: 1.2; }
.a-emphasis { fill: none; stroke: #000; stroke-width: 2.2; }
.a-dashed { fill: none; stroke: #000; stroke-width: 1.2; stroke-dasharray: 5 3; }
.m-default, .m-emphasis, .m-security, .m-dashed { fill: #000; stroke: none; }
"""


def local(tag):
    return tag.split('}')[-1]


def main(src, dst):
    html = open(src, encoding='utf-8').read()
    start = html.index('<svg viewBox')
    svg = html[start:html.index('</svg>', start) + 6]
    svg = svg.replace('<svg ', f'<svg xmlns="{SVG_NS}" ', 1)
    root = ET.fromstring(svg)

    def walk(parent):
        for child in list(parent):
            tag = local(child.tag)
            cls = child.get('class', '')
            drop = (
                tag in ('title', 'desc', 'pattern')
                or 'semantic-sigil' in cls
                or child.get('fill', '').startswith('url(#grid')
                or 'c-grid' in cls
            )
            if drop:
                parent.remove(child)
                continue
            # 直角折线：用 composition 点列代替带圆角的路径
            pts = child.get('data-composition-points')
            if tag == 'path' and pts and cls.startswith('a-'):
                xy = [p.split(',') for p in pts.split(';')]
                child.set('d', 'M ' + ' L '.join(f'{x} {y}' for x, y in xy))
                child.attrib.pop('stroke-width', None)
            if tag == 'rect' and child.get('rx'):
                child.set('rx', '0' if 'c-region' not in cls else '0')
            if tag in ('rect', 'path') and re.match(r'c-(backend|frontend|cloud|security|database|messagebus|external)', cls):
                child.attrib.pop('stroke-width', None)
            if tag == 'marker':
                child.set('markerUnits', 'userSpaceOnUse')
            for k in list(child.attrib):
                if k.startswith(('data-', 'aria-')) or k in ('tabindex', 'role', 'id') and tag == 'g':
                    child.attrib.pop(k)
            walk(child)

    walk(root)
    # 放大字号：排版宽度约 15.8 cm，宽画布按比例放大，保证印刷字号不低于约 5 pt
    w = float(root.get('viewBox').split()[2])
    k = 1.6 if w >= 1000 else (1.35 if w >= 850 else 1.25)
    k = float(os.environ.get('JSSC_K', k))
    for el in root.iter():
        tag = local(el.tag)
        fs = el.get('font-size')
        if tag == 'text' and fs:
            el.set('font-size', f'{float(fs) * k:.1f}')
        # 只放大连线标签的底衬（高度 < 30），节点底衬保持原尺寸
        if tag == 'rect' and 'c-mask' in el.get('class', '') and float(el.get('height', 99)) < 30:
            x, y = float(el.get('x', 0)), float(el.get('y', 0))
            rw, rh = float(el.get('width', 0)), float(el.get('height', 0))
            el.set('x', f'{x - rw * (k - 1) / 2:.1f}')
            el.set('y', f'{y - rh * (k - 1) / 2:.1f}')
            el.set('width', f'{rw * k:.1f}')
            el.set('height', f'{rh * k:.1f}')
    for k in list(root.attrib):
        if k.startswith(('data-', 'aria-')) or k in ('role', 'lang'):
            root.attrib.pop(k)
    vb = root.get('viewBox').split()
    root.set('width', vb[2])
    root.set('height', vb[3])
    style = ET.Element(f'{{{SVG_NS}}}style')
    style.text = STYLE
    root.insert(0, style)
    ET.ElementTree(root).write(dst, encoding='utf-8', xml_declaration=True)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
