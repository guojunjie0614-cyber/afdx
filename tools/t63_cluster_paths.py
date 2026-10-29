"""T63 手工移动前的簇路径分析：列出经过指定簇的最差路径及各段连线延迟和位置。

用法：--run <imple_1 目录> --timing <full_timing.tan.pb> --cluster stratix_clbN [...] [--per 6] [--below 3000]
"""
import argparse
import sqlite3
from pathlib import Path

from t63_merge import read_owner, read_place
from t63_eco import normalize_cell


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--timing', type=Path, required=True)
    parser.add_argument('--cluster', nargs='+', required=True)
    parser.add_argument('--per', type=int, default=6)
    parser.add_argument('--below', type=int, default=3000)
    args = parser.parse_args()
    owner = read_owner(args.run / 'loaded_cluster.xml')
    pos = read_place(args.run / 'AFDX_EndSystem.place')
    wanted = set(args.cluster)
    con = sqlite3.connect(args.timing.resolve().as_uri() + '?mode=ro', uri=True)
    paths = {(pid, x): (slack, f, t) for pid, x, slack, f, t in con.execute(
        'SELECT path_id, clock_scoped_path_reports_x, slack, from_cell_name, to_cell_name '
        'FROM elinx_intra_clock_longest_sync_path_report WHERE slack < ?', (args.below,))}
    nodes = {}
    for pid, x, kind, incr, loc, res in con.execute(
            'SELECT path_id, clock_scoped_path_reports_x, delay_type, incr_delay, location, resource '
            'FROM elinx_data_path_node_detail ORDER BY path_node_detail_id'):
        if (pid, x) in paths:
            nodes.setdefault((pid, x), []).append((kind, incr, loc, res))
    hits = {c: [] for c in wanted}
    for key, rows in nodes.items():
        # 路径明细末尾附带一段无关的 RAM 写入路径；只取到端点为止。
        end = paths[key][2]
        cut = next((i for i, r in enumerate(rows) if str(r[3]) == end), len(rows) - 1)
        rows = rows[:cut + 1]
        through = {owner.get(normalize_cell(str(r[3]))) for r in rows} & wanted
        for c in through:
            hits[c].append((paths[key][0], key, rows))
    for c in args.cluster:
        print(c, pos.get(c), 'paths', len(hits[c]))
        seen = set()
        for slack, key, rows in sorted(hits[c], key=lambda h: h[0]):
            sig = (paths[key][1], paths[key][2])
            if sig in seen:
                continue
            seen.add(sig)
            hops = ' '.join(f"{r[2].rsplit(',', 1)[0]}{'*' if owner.get(normalize_cell(str(r[3]))) == c else ''}"
                            f"+{r[1] / 1000:.2f}" for r in rows if r[0] == 1)
            print(f'  {slack:7.0f} {paths[key][1][-34:]} -> {paths[key][2][-34:]}')
            print('          ', hops)
            if len(seen) >= args.per:
                break


if __name__ == '__main__':
    main()
