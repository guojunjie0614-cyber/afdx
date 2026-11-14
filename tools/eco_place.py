"""增量布局：网表不变，锁定旧布局，只放开临界路径上的簇交给布局器重放。

从旧布局的完整时序库取余量低于阈值的路径，收集路径上每个单元（起点、组合、终点），
按分子名对应到簇；这些 CLB 簇不锁，其余全部簇（含 M4K）锁在旧坐标。
时序库单元名形如 \\es|rx_core|engine|x~I|ff/Q，分子名形如
\\afdx_es:es|afdx_rx_core:rx_core|afdx_rx_engine:engine|x~I；比较前去掉实体名和引脚后缀。
"""
import argparse
import collections
import json
import re
import sqlite3
from pathlib import Path


def normalize_molecule(name):
    return '|'.join(part.split(':', 1)[1] if ':' in part else part
                    for part in name.lstrip('\\').split('|'))


def normalize_cell(resource):
    name = resource.lstrip('\\')
    name = re.sub(r'\|ff/\w+$', '', name)
    name = re.sub(r'\|port_\w+$', '', name)
    name = re.sub(r'/\w+(\[\d+\])?$', '', name)
    return name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xml', type=Path, required=True)
    parser.add_argument('--place', type=Path, required=True)
    parser.add_argument('--timing', type=Path, required=True, help='完整时序库 full_timing.tan.pb')
    parser.add_argument('--threshold', type=int, required=True, help='放开余量低于该值(ps)的路径上的簇')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    owner = {}
    current = None
    with open(args.xml, encoding='utf-8') as stream:
        for line in stream:
            m = re.search(r'<CLUSTER name="([^"]+)"', line)
            if m:
                current = m.group(1)
                continue
            m = re.search(r'<MOLECULE name="([^"]+)"', line)
            if m and current:
                owner[normalize_molecule(m.group(1))] = current
    pos = {}
    for line in args.place.read_text(encoding='utf-8-sig').splitlines():
        f = line.split()
        if len(f) >= 4 and f[0].startswith('stratix_'):
            pos[f[0]] = (int(f[1]), int(f[2]))
    con = sqlite3.connect(args.timing.resolve().as_uri() + '?mode=ro', uri=True)
    con.row_factory = sqlite3.Row
    paths = con.execute('SELECT path_id, clock_scoped_path_reports_x AS x, slack, to_cell_name '
                        'FROM elinx_intra_clock_longest_sync_path_report WHERE slack < ?',
                        (args.threshold,)).fetchall()
    free, unmatched, endpoints = set(), collections.Counter(), set()
    for row in paths:
        endpoints.add(row['to_cell_name'])
        for node in con.execute('SELECT resource FROM elinx_data_path_node_detail '
                                'WHERE path_id=? AND clock_scoped_path_reports_x=?', (row['path_id'], row['x'])):
            cell = normalize_cell(str(node['resource']))
            cluster = owner.get(cell)
            if cluster is None:
                unmatched[cell] += 1
            elif cluster.startswith('stratix_clb'):
                free.add(cluster)
    lines = []
    for cluster, (x, y) in sorted(pos.items()):
        if cluster in free:
            continue
        kind = 'M4K' if cluster.startswith('stratix_mem') else 'CLB'
        lines.append(f'set_location_assignment {kind}_X{x}_Y{y}_N0 -to {{{cluster}}}')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
    stats = dict(threshold_ps=args.threshold, paths=len(paths), endpoints=len(endpoints),
                 released_clusters=len(free), locked=len(lines),
                 unmatched_cells=len(unmatched), unmatched_examples=list(unmatched)[:8],
                 released=sorted(free))
    args.out.with_suffix('.json').write_text(json.dumps(stats, indent=1) + '\n', encoding='utf-8')
    print(json.dumps({k: v for k, v in stats.items() if k != 'released'}))


if __name__ == '__main__':
    main()
