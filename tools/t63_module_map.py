"""T63 B 线：按模块统计簇在布局中的分布（只读）。

簇成员取自原生 udm_write_cluster 导出，位置取自同一检查点的 .place。
模块按分子名里的实体:实例层级归类，取前 depth 层实例名。
"""
import argparse
import collections
import json
import re
import statistics
from pathlib import Path

CLUSTER = re.compile(r'<CLUSTER name="([^"]+)" type="([^"]+)"')
MOLECULE = re.compile(r'<MOLECULE name="([^"]+)"')
LEVEL = re.compile(r'\\?([A-Za-z_][\w]*):([\w\[\]\.]+)')


def module_of(name, depth):
    parts = []
    for segment in name.lstrip('\\').split('|'):
        match = LEVEL.fullmatch(segment)
        if not match:
            break
        parts.append(match.group(2))
        if len(parts) == depth:
            break
    return '/'.join(parts) or '(top)'


def membership(xml, depth):
    clusters = {}
    current = None
    with open(xml, encoding='utf-8') as stream:
        for line in stream:
            match = CLUSTER.search(line)
            if match:
                current = clusters.setdefault(match.group(1), dict(type=match.group(2), modules=collections.Counter()))
                continue
            match = MOLECULE.search(line)
            if match and current is not None:
                current['modules'][module_of(match.group(1), depth)] += 1
    return clusters


def placement(path):
    places = {}
    for line in Path(path).read_text(encoding='utf-8-sig').splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[0].startswith('stratix_'):
            places[fields[0]] = (int(fields[1]), int(fields[2]))
    return places


def summarize(xml, place, depth):
    clusters = membership(xml, depth)
    places = placement(place)
    groups = collections.defaultdict(lambda: dict(clb=[], mem=[], mixed=0))
    for name, info in clusters.items():
        if name not in places or not info['modules']:
            continue
        module, count = info['modules'].most_common(1)[0]
        kind = 'mem' if 'mem' in name else 'clb'
        groups[module][kind].append(places[name])
        groups[module]['mixed'] += len(info['modules']) > 1
    rows = {}
    for module, data in groups.items():
        points = data['clb'] + data['mem']
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        rows[module] = dict(clb=len(data['clb']), mem=len(data['mem']), mixed_clusters=data['mixed'],
                            x=[min(xs), max(xs)], y=[min(ys), max(ys)],
                            median=[statistics.median(xs), statistics.median(ys)],
                            mem_columns=sorted({p[0] for p in data['mem']}))
    xs = [p[0] for p in places.values()]
    ys = [p[1] for p in places.values()]
    return dict(grid=dict(x=[min(xs), max(xs)], y=[min(ys), max(ys)]), depth=depth,
                modules=dict(sorted(rows.items(), key=lambda item: -(item[1]['clb'] + item[1]['mem']))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xml', type=Path, required=True)
    parser.add_argument('--place', type=Path, required=True)
    parser.add_argument('--depth', type=int, default=2)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    result = summarize(args.xml, args.place, args.depth)
    text = json.dumps(result, ensure_ascii=False, indent=1)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text + '\n', encoding='utf-8')
    for module, row in result['modules'].items():
        print(f"{module:40s} clb={row['clb']:5d} mem={row['mem']:4d} x={row['x']} y={row['y']} "
              f"med={row['median']} memcols={row['mem_columns']}")
    print('grid', result['grid'])


if __name__ == '__main__':
    main()
