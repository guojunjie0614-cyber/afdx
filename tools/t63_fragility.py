"""T63：多个布局下失败端点按结构归组，统计每组在几个布局里失败（只读）。

输入 t63 A 线导出的 wave*_endpoints.json；单元名去掉位号、复制序号和 ~I|ff 后缀后归组。
"""
import collections
import json
import re
import sys
from pathlib import Path


def stem(name):
    name = name.lstrip(chr(92))
    name = name[3:] if name.startswith('es|') else name
    name = re.sub(r'~I\|ff/[QD]$|~I\|.*$|/[A-Za-z]+$', '', name)
    name = re.sub(r'\[\d+\]', '[]', name)
    name = re.sub(r'~\d+', '', name)
    return name


def main():
    files = [Path(p) for p in sys.argv[1:-1]]
    out = Path(sys.argv[-1])
    groups = collections.defaultdict(lambda: dict(layouts=set(), worst=0, endpoints=set(), levels=[], net=[], logic=[]))
    layouts = []
    for path in files:
        for tag, row in json.loads(path.read_text(encoding='utf-8')).items():
            layouts.append(tag)
            for e in row['endpoints']:
                if e['slack'] >= 0:
                    continue
                g = groups[(stem(e['start']), stem(e['end']))]
                g['layouts'].add(tag)
                g['worst'] = min(g['worst'], e['slack'])
                g['endpoints'].add(e['end'])
                g['levels'].append(e['levels'])
                g['net'].append(e['net'])
                g['logic'].append(e['logic'])
    rows = []
    for (start, end), g in groups.items():
        rows.append(dict(start=start, end=end, layouts=len(g['layouts']), layout_tags=sorted(g['layouts']),
                         worst_ps=g['worst'], endpoints=len(g['endpoints']),
                         levels=max(x for x in g['levels'] if x is not None),
                         net_ps=max(x for x in g['net'] if x is not None),
                         logic_ps=max(x for x in g['logic'] if x is not None)))
    rows.sort(key=lambda r: (-r['layouts'], r['worst_ps']))
    out.write_text(json.dumps(dict(layouts=layouts, groups=rows), ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print(f'{len(layouts)} layouts, {len(rows)} failing start->end groups')
    for r in rows[:45]:
        print(f"{r['layouts']}/{len(layouts)} worst={r['worst_ps']:>6} eps={r['endpoints']:>3} lv={r['levels']} net={r['net_ps']} | {r['start'][:52]} -> {r['end'][:52]}")


if __name__ == '__main__':
    main()
