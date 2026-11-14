"""布局合并：以基础布局为底，保留 ECO 布局中修好原失败端点的簇移动，撤回造成新失败的移动。

保留集 K：基础布局中失败、ECO 中已转正的端点，其 ECO 最差路径上被移动过的簇。
撤回集 R：ECO 中余量低于 margin、基础布局中不低于 margin 的端点，其 ECO 最差路径上被移动过的簇（减去 K）。
其余移动按 --default 处理（keep 保留 ECO 位置 / revert 回基础位置）。输出全部簇的锁定语句。
"""
import argparse
import json
import sqlite3
from pathlib import Path

from eco_place import normalize_cell, normalize_molecule


def read_owner(xml):
    import re
    owner, current = {}, None
    with open(xml, encoding='utf-8') as stream:
        for line in stream:
            m = re.search(r'<CLUSTER name="([^"]+)"', line)
            if m:
                current = m.group(1)
                continue
            m = re.search(r'<MOLECULE name="([^"]+)"', line)
            if m and current:
                owner[normalize_molecule(m.group(1))] = current
    return owner


def read_place(path):
    pos = {}
    for line in Path(path).read_text(encoding='utf-8-sig').splitlines():
        f = line.split()
        if len(f) >= 4 and f[0].startswith('stratix_'):
            pos[f[0]] = (int(f[1]), int(f[2]))
    return pos


def endpoint_paths(db, owner):
    """每个端点的最差余量和最差路径经过的簇。"""
    con = sqlite3.connect(Path(db).resolve().as_uri() + '?mode=ro', uri=True)
    worst = {}
    for pid, x, to, slack in con.execute('SELECT path_id, clock_scoped_path_reports_x, to_cell_name, slack '
                                         'FROM elinx_intra_clock_longest_sync_path_report'):
        if to not in worst or slack < worst[to][0]:
            worst[to] = (slack, pid, x)
    # 只关心余量 < 2 ns 的端点；节点明细整表读一次，避免逐端点全表扫描。
    wanted = {(pid, x): to for to, (slack, pid, x) in worst.items() if slack < 2000}
    cells = {}
    for pid, x, resource in con.execute('SELECT path_id, clock_scoped_path_reports_x, resource '
                                        'FROM elinx_data_path_node_detail'):
        to = wanted.get((pid, x))
        if to is not None:
            cluster = owner.get(normalize_cell(str(resource)))
            if cluster:
                cells.setdefault(to, set()).add(cluster)
    return {to: (slack, cells.get(to, set())) for to, (slack, pid, x) in worst.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xml', type=Path, required=True)
    parser.add_argument('--base-place', type=Path, required=True)
    parser.add_argument('--base-timing', type=Path, required=True)
    parser.add_argument('--eco-place', type=Path, required=True)
    parser.add_argument('--eco-timing', type=Path, required=True)
    parser.add_argument('--margin', type=int, default=30)
    parser.add_argument('--default', choices=['keep', 'revert'], default='keep')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    owner = read_owner(args.xml)
    base, eco = read_place(args.base_place), read_place(args.eco_place)
    moved = {c for c in eco if eco[c] != base.get(c)}
    bt, et = endpoint_paths(args.base_timing, owner), endpoint_paths(args.eco_timing, owner)
    keep, revert, fixed, regressed = set(), set(), [], []
    for to, (slack, clusters) in et.items():
        before = bt.get(to, (10 ** 6, set()))[0]
        if before < 0 <= slack:
            fixed.append(to)
            keep |= clusters & moved
        elif slack < args.margin <= before:
            regressed.append(to)
            revert |= clusters & moved
    revert -= keep
    # 从合法的 ECO 布局出发，逐个撤回到基础坐标；目标位被占则暂缓，直到不再有变化。
    final = dict(eco)
    owner_of = {tile: cluster for cluster, tile in final.items()}
    pending = sorted(revert if args.default == 'keep' else (moved - keep))
    changed = True
    while changed:
        changed = False
        for cluster in list(pending):
            target = base[cluster]
            if target not in owner_of:
                del owner_of[final[cluster]]
                final[cluster] = target
                owner_of[target] = cluster
                pending.remove(cluster)
                changed = True
    collisions = pending
    lines = [f"set_location_assignment {'M4K' if c.startswith('stratix_mem') else 'CLB'}_X{x}_Y{y}_N0 -to {{{c}}}"
             for c, (x, y) in sorted(final.items())]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
    stats = dict(moved=len(moved), kept=len(keep), revert_targets=len(revert), not_revertible=len(collisions),
                 other_moves=args.default, fixed_endpoints=len(fixed), regressed_endpoints=len(regressed),
                 collisions=collisions, locked=len(lines),
                 final_moved=sum(final[c] != base[c] for c in final))
    args.out.with_suffix('.json').write_text(json.dumps(stats, indent=1) + '\n', encoding='utf-8')
    print(json.dumps(stats))


if __name__ == '__main__':
    main()
