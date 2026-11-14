"""Netlist-aware Min-Max Slack Cluster Placement Optimizer for EQ6HL130.

1. Parses loaded_cluster.xml + AFDX_EndSystem.vqm to extract:
   - Exact cell -> cluster ownership
   - Exact rigid vertical carry-chain macros (cout -> cin, (dx, dy) = (0, -1))
   - Complete cluster-level directed timing hypergraph (all non-clock/reset VQM nets)
   - Per-cluster combinational pass-through flag (whether any molecule has combout)
2. Parses expanded AFDX_EndSystem.tan.pb (10,000 near-critical setup paths)
   with exact hop sequences (dynamic CLB clusters + fixed M4K/IO coordinates).
3. Iteratively optimizes rigid CLB macro positions (over free valid CLB tiles
   plus safe swaps with non-critical single-tile CLBs) to maximize the minimum predicted
   slack across all 10,000 STA paths + all unseen VQM edges.
"""
import argparse
import collections
from pathlib import Path
import re
import sqlite3
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / 'tools') not in sys.path:
    sys.path.insert(0, str(ROOT / 'tools'))

from eco_place import normalize_cell
from eco_merge import read_owner
from eco_move import valid_tiles

GAIN_PS_PER_TILE = 55.0     # Conservative credit when shortening a path
PENALTY_PS_PER_TILE = 90.0  # Pessimistic penalty when lengthening a path
UNSEEN_BASE_SLACK_PS = 1890.0
TARGET_MARGIN_PS = 250.0


def parse_xy(loc):
    parts = str(loc).split(',')
    if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
        return int(parts[0]), int(parts[1])
    return None


def read_full_place(place_path):
    clb_mem_pos = {}
    io_pos = {}
    for line in Path(place_path).read_text(encoding='utf-8-sig').splitlines():
        if not line or line.startswith('#'):
            continue
        f = line.split()
        if f[0].startswith('stratix_'):
            clb_mem_pos[f[0]] = (int(f[1]), int(f[2]))
        elif len(f) >= 7 and f[3].startswith('stratix_pad'):
            io_pos[f[0]] = (int(f[4]), int(f[5]))
        elif len(f) >= 6 and f[2].startswith('stratix_pad'):
            io_pos[f[0]] = (int(f[3]), int(f[4]))
    return clb_mem_pos, io_pos


def load_xml_exact(xml_path):
    raw_owner = {}
    has_comb = collections.defaultdict(bool)
    cur = None
    with open(xml_path, encoding='utf-8') as f:
        for line in f:
            if '<CLUSTER ' in line:
                m = re.search(r'<CLUSTER name="([^"]+)"', line)
                if m:
                    cur = m.group(1)
            elif '<MOLECULE ' in line:
                m = re.search(r'<MOLECULE name="([^"]+)"', line)
                if m and cur:
                    raw_owner[m.group(1)] = cur
            elif 'name="output_mode"' in line and cur:
                if 'comb' in line:
                    has_comb[cur] = True
    return raw_owner, has_comb


def parse_vqm_graph(vqm_path, raw_owner, io_pos):
    t0 = time.monotonic()
    net_drivers = {}
    net_sinks = collections.defaultdict(list)
    cin_map = {}
    cout_map = {}

    port_re = re.compile(r'\.(\w+)\(([^)]+)\)')
    skip_nets = {'gnd', 'vcc', 'clk', 'reset', ''}
    skip_ports = {'clk', 'clk0', 'clk1', 'aclr', 'clr0', 'clr1', 'devclrn', 'devpor'}
    out_ports = {'combout', 'regout', 'portadataout', 'portbdataout', 'padio'}

    with open(vqm_path, encoding='utf-8', errors='replace') as f:
        cur_kind = None
        cur_cell = None
        cur_owner = None
        buf = []
        for line in f:
            s = line.lstrip()
            if cur_cell is None:
                if s.startswith(('stratix_lcell ', 'stratix_ram_block ', 'stratix_io ')):
                    parts = s.split(None, 2)
                    cur_kind = parts[0]
                    cur_cell = parts[1]
                    if cur_cell.endswith('('):
                        cur_cell = cur_cell[:-1].strip()
                    cur_owner = raw_owner.get(cur_cell)
                    buf = [s]
                    if ');' in s:
                        block = ' '.join(buf)
                        _process_block(
                            cur_kind, cur_cell, cur_owner, block, port_re,
                            skip_nets, skip_ports, out_ports, net_drivers, net_sinks,
                            cin_map, cout_map, io_pos
                        )
                        cur_cell = None
            else:
                buf.append(s)
                if ');' in s:
                    block = ' '.join(buf)
                    _process_block(
                        cur_kind, cur_cell, cur_owner, block, port_re,
                        skip_nets, skip_ports, out_ports, net_drivers, net_sinks,
                        cin_map, cout_map, io_pos
                    )
                    cur_cell = None

    carry_next = {}
    carry_prev = {}
    for net, src_cell in cout_map.items():
        dst_cell = cin_map.get(net)
        if dst_cell:
            c1 = raw_owner.get(src_cell)
            c2 = raw_owner.get(dst_cell)
            if c1 and c2 and c1 != c2:
                carry_next[c1] = c2
                carry_prev[c2] = c1

    out_edges = collections.defaultdict(set)
    in_edges = collections.defaultdict(set)
    for net, src in net_drivers.items():
        sinks = net_sinks.get(net)
        if not sinks or len(sinks) > 300:
            continue
        for dst in set(sinks):
            if dst != src:
                out_edges[src].add(dst)
                in_edges[dst].add(src)

    print(
        f'Parsed VQM in {time.monotonic()-t0:.2f}s: nets={len(net_drivers)}, '
        f'cluster_edges={sum(len(v) for v in out_edges.values())}, carry_links={len(carry_next)}'
    )
    return carry_next, carry_prev, out_edges, in_edges


def _process_block(
    kind, cell, owner, block, port_re, skip_nets, skip_ports, out_ports,
    net_drivers, net_sinks, cin_map, cout_map, io_pos
):
    if owner is None and kind == 'stratix_io':
        m_pad = re.search(r'\.padio\(([^)]+)\)', block)
        if m_pad:
            pname = m_pad.group(1).strip().lstrip('\\')
            if pname in io_pos:
                owner = f'IO:{pname}'
    if owner is None:
        return
    for p, expr in port_re.findall(block):
        if p in skip_ports:
            continue
        if p == 'cin':
            w = expr.strip()
            if w not in skip_nets:
                cin_map[w] = cell
            continue
        if p == 'cout':
            w = expr.strip()
            if w not in skip_nets:
                cout_map[w] = cell
            continue
        expr = expr.strip()
        if expr.startswith('{') and expr.endswith('}'):
            wires = [w.strip() for w in expr[1:-1].split(',')]
        else:
            wires = [expr]
        is_out = p in out_ports
        for w in wires:
            if not w or w in skip_nets or w == 'reset' or w == 'clk':
                continue
            if is_out:
                net_drivers[w] = owner
            else:
                net_sinks[w].append(owner)


def load_sta_paths(exp_db, norm_owner):
    con = sqlite3.connect(Path(exp_db).resolve().as_uri() + '?mode=ro', uri=True)
    raw_paths = {}
    for pid, x, y, slack, f, t in con.execute(
        'SELECT path_id, clock_scoped_path_reports_x, clock_scoped_path_reports_y, '
        'slack, from_cell_name, to_cell_name '
        'FROM elinx_intra_clock_longest_sync_path_report'
    ):
        raw_paths[(pid, x, y)] = (float(slack), f, t)

    nodes = collections.defaultdict(list)
    for pid, x, y, loc, res in con.execute(
        'SELECT path_id, clock_scoped_path_reports_x, clock_scoped_path_reports_y, '
        'location, resource FROM elinx_data_path_node_detail '
        'WHERE path_type=0 AND sync_type=0 ORDER BY path_node_detail_id'
    ):
        key = (pid, x, y)
        if key in raw_paths:
            nodes[key].append((loc, str(res)))
    con.close()

    paths = []
    cluster_to_paths = collections.defaultdict(list)
    for key, (slack0, _, end_cell) in raw_paths.items():
        rows = nodes[key]
        cut = next((i for i, r in enumerate(rows) if r[1] == end_cell), len(rows) - 1)
        rows = rows[: cut + 1]
        seq = []
        for loc, res in rows:
            xy = parse_xy(loc)
            if xy is None:
                continue
            c = norm_owner.get(normalize_cell(res))
            item = c if (c and c.startswith('stratix_clb')) else xy
            if not seq or seq[-1] != item:
                seq.append(item)
        if len(seq) < 2:
            continue
        idx = len(paths)
        paths.append([slack0, 0, seq])
        for item in set(seq):
            if isinstance(item, str):
                cluster_to_paths[item].append(idx)
    return paths, cluster_to_paths


def node_xy(node, pos):
    return pos[node] if isinstance(node, str) else node


def path_manhattan(seq, pos):
    total = 0
    prev = node_xy(seq[0], pos)
    for item in seq[1:]:
        cur = node_xy(item, pos)
        total += abs(cur[0] - prev[0]) + abs(cur[1] - prev[1])
        prev = cur
    return total


def pred_slack(slack0, base_len, new_len):
    delta = new_len - base_len
    if delta <= 0:
        return slack0 - GAIN_PS_PER_TILE * delta
    return slack0 - PENALTY_PS_PER_TILE * delta


def build_macros(pos, carry_next, carry_prev):
    macros = {}
    owner_macro = {}
    for c in sorted(pos):
        if not c.startswith('stratix_clb'):
            continue
        if c in carry_prev:
            continue
        chain = [c]
        cur = c
        while cur in carry_next:
            cur = carry_next[cur]
            chain.append(cur)
        mid = chain[0]
        macros[mid] = chain
        for idx, member in enumerate(chain):
            owner_macro[member] = (mid, idx)
    return macros, owner_macro


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True, help='Routed run folder with expanded/')
    parser.add_argument('--vqm', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--sweeps', type=int, default=6)
    args = parser.parse_args()

    run = args.run.resolve()
    imple = run / 'project/AFDX_EndSystem.runs/imple_1'
    exp_db = run / 'expanded/project/AFDX_EndSystem.runs/imple_1/AFDX_EndSystem.tan.pb'

    pos, io_pos = read_full_place(imple / 'AFDX_EndSystem.place')
    for pname, xy in io_pos.items():
        pos[f'IO:{pname}'] = xy
    base_pos = dict(pos)

    raw_owner, has_comb = load_xml_exact(imple / 'loaded_cluster.xml')
    norm_owner = read_owner(imple / 'loaded_cluster.xml')
    carry_next, carry_prev, out_edges, in_edges = parse_vqm_graph(args.vqm, raw_owner, io_pos)
    paths, cluster_to_paths = load_sta_paths(exp_db, norm_owner)

    for p in paths:
        p[1] = path_manhattan(p[2], base_pos)

    base_edge_dist = {}
    for u, vs in out_edges.items():
        if u not in base_pos:
            continue
        ux, uy = base_pos[u]
        for v in vs:
            if v in base_pos:
                vx, vy = base_pos[v]
                base_edge_dist[(u, v)] = abs(ux - vx) + abs(uy - vy)

    macros, owner_macro = build_macros(pos, carry_next, carry_prev)
    all_valid_clb = valid_tiles(ROOT / 'out')
    occupied = {xy: c for c, xy in pos.items() if c.startswith('stratix_clb')}
    free_tiles = set(all_valid_clb) - set(occupied.keys())

    def current_path_slack(p):
        return pred_slack(p[0], p[1], path_manhattan(p[2], pos))

    init_slacks = [current_path_slack(p) for p in paths]
    print(
        f'Initial: worst_slack={min(init_slacks):.1f}ps, '
        f'failing_paths={sum(s < 0 for s in init_slacks)}, '
        f'free_tiles={len(free_tiles)}, macros={len(macros)}'
    )

    def unseen_slack_for_cluster(c):
        cx, cy = pos[c]
        max_in_stretch = 0
        for u in in_edges.get(c, ()):
            if u in pos:
                d = abs(cx - pos[u][0]) + abs(cy - pos[u][1])
                s = d - base_edge_dist[(u, c)]
                if s > max_in_stretch:
                    max_in_stretch = s
        max_out_stretch = 0
        for v in out_edges.get(c, ()):
            if v in pos:
                d = abs(cx - pos[v][0]) + abs(cy - pos[v][1])
                s = d - base_edge_dist[(c, v)]
                if s > max_out_stretch:
                    max_out_stretch = s
        stretch = (max_in_stretch + max_out_stretch) if has_comb[c] else max(max_in_stretch, max_out_stretch)
        return UNSEEN_BASE_SLACK_PS - PENALTY_PS_PER_TILE * stretch

    def local_cost(pids, moved_clusters):
        worst = 1e9
        viol_sum = 0.0
        dist_sum = 0
        for pid in pids:
            p = paths[pid]
            nl = path_manhattan(p[2], pos)
            dist_sum += nl
            s = pred_slack(p[0], p[1], nl)
            if s < worst:
                worst = s
            if s < TARGET_MARGIN_PS:
                d = TARGET_MARGIN_PS - s
                viol_sum += d * d
        for c in moved_clusters:
            su = unseen_slack_for_cluster(c)
            if su < worst:
                worst = su
            if su < TARGET_MARGIN_PS + 100:
                d = (TARGET_MARGIN_PS + 100) - su
                viol_sum += d * d
            for nb in in_edges.get(c, set()) | out_edges.get(c, set()):
                if isinstance(nb, str) and nb.startswith('stratix_clb'):
                    snb = unseen_slack_for_cluster(nb)
                    if snb < worst:
                        worst = snb
                    if snb < TARGET_MARGIN_PS + 100:
                        d = (TARGET_MARGIN_PS + 100) - snb
                        viol_sum += d * d
                    dist_sum += abs(pos[c][0] - pos[nb][0]) + abs(pos[c][1] - pos[nb][1])
        return (-round(worst, 1), round(viol_sum, 1), dist_sum)

    total_moves = 0
    for sweep in range(1, args.sweeps + 1):
        macro_worst = {}
        for pid, p in enumerate(paths):
            s = current_path_slack(p)
            if s < TARGET_MARGIN_PS:
                for item in p[2]:
                    if isinstance(item, str) and item in owner_macro:
                        mid = owner_macro[item][0]
                        if mid not in macro_worst or s < macro_worst[mid]:
                            macro_worst[mid] = s
                        if sweep >= 2 and s < 150:
                            for nb in in_edges.get(item, set()) | out_edges.get(item, set()):
                                if isinstance(nb, str) and nb in owner_macro:
                                    nmid = owner_macro[nb][0]
                                    if nmid not in macro_worst or (s + 50) < macro_worst[nmid]:
                                        macro_worst[nmid] = s + 50
        order = [mid for mid, _ in sorted(macro_worst.items(), key=lambda kv: kv[1])]
        sweep_moves = 0

        for mid in order:
            chain = macros[mid]
            k = len(chain)
            pids = sorted({pid for c in chain for pid in cluster_to_paths.get(c, ())})
            orig_top = pos[chain[0]]
            base_score = local_cost(pids, chain)

            xs, ys = [orig_top[0]], [orig_top[1]]
            for pid in pids:
                p = paths[pid]
                seq = p[2]
                for i, item in enumerate(seq):
                    if item in chain:
                        if i > 0 and seq[i - 1] not in chain:
                            nx, ny = node_xy(seq[i - 1], pos)
                            xs.append(nx)
                            ys.append(ny + owner_macro[item][1])
                        if i + 1 < len(seq) and seq[i + 1] not in chain:
                            nx, ny = node_xy(seq[i + 1], pos)
                            xs.append(nx)
                            ys.append(ny + owner_macro[item][1])
            if not pids:
                for c in chain:
                    idx_c = owner_macro[c][1]
                    for nb in in_edges.get(c, set()) | out_edges.get(c, set()):
                        if nb in pos and nb not in chain:
                            nx, ny = pos[nb]
                            xs.append(nx)
                            ys.append(ny + idx_c)
            cx = int(sorted(xs)[len(xs) // 2])
            cy = int(sorted(ys)[len(ys) // 2])

            cand_tops = set()
            for tx, ty in free_tiles:
                if abs(tx - cx) + abs(ty - cy) <= 36 or (
                    min(cx, orig_top[0]) - 6 <= tx <= max(cx, orig_top[0]) + 6
                    and min(cy, orig_top[1]) - 6 <= ty <= max(cy, orig_top[1]) + 6
                ):
                    if all(((tx, ty - i) in free_tiles or (tx, ty - i) in [pos[m] for m in chain]) for i in range(k)):
                        cand_tops.add((tx, ty))

            best_score = base_score
            best_top = None
            best_swap_partner = None

            old_coords = [pos[m] for m in chain]
            for xy in old_coords:
                del occupied[xy]
                free_tiles.add(xy)

            for tx, ty in cand_tops:
                for i, m in enumerate(chain):
                    pos[m] = (tx, ty - i)
                sc = local_cost(pids, chain)
                if sc < best_score:
                    best_score = sc
                    best_top = (tx, ty)

            if k == 1:
                c0 = chain[0]
                for dx in range(-6, 7):
                    for dy in range(-6, 7):
                        if abs(dx) + abs(dy) > 7:
                            continue
                        t_xy = (cx + dx, cy + dy)
                        other = occupied.get(t_xy)
                        if not other:
                            continue
                        omid, _ = owner_macro[other]
                        if len(macros[omid]) != 1:
                            continue
                        near_free = None
                        best_nf_d = 99
                        for fx, fy in free_tiles:
                            if (fx, fy) == old_coords[0]:
                                continue
                            d = abs(fx - t_xy[0]) + abs(fy - t_xy[1])
                            if d < best_nf_d and d <= 4:
                                best_nf_d = d
                                near_free = (fx, fy)
                        if near_free is None:
                            continue
                        other_pids = cluster_to_paths.get(other, [])
                        joint_pids = sorted(set(pids) | set(other_pids))
                        pos[c0] = old_coords[0]
                        pos[other] = t_xy
                        joint_before = local_cost(joint_pids, [c0, other])
                        pos[other] = near_free
                        pos[c0] = t_xy
                        other_ok = True
                        if unseen_slack_for_cluster(other) < 500:
                            other_ok = False
                        if other_ok:
                            for opid in other_pids:
                                op = paths[opid]
                                if pred_slack(op[0], op[1], path_manhattan(op[2], pos)) < 400:
                                    other_ok = False
                                    break
                        if other_ok:
                            joint_after = local_cost(joint_pids, [c0, other])
                            sc = local_cost(pids, [c0])
                            if sc < best_score and joint_after < joint_before:
                                best_score = sc
                                best_top = t_xy
                                best_swap_partner = (other, t_xy, near_free)
                        pos[other] = t_xy

            if best_top is not None and best_top != orig_top:
                if best_swap_partner is not None:
                    other, o_old, o_new = best_swap_partner
                    del occupied[o_old]
                    free_tiles.remove(o_new)
                    pos[other] = o_new
                    occupied[o_new] = other
                    pos[chain[0]] = best_top
                    occupied[best_top] = chain[0]
                else:
                    for i, m in enumerate(chain):
                        xy = (best_top[0], best_top[1] - i)
                        free_tiles.remove(xy)
                        pos[m] = xy
                        occupied[xy] = m
                sweep_moves += 1
                total_moves += 1
            else:
                for m, xy in zip(chain, old_coords):
                    free_tiles.remove(xy)
                    pos[m] = xy
                    occupied[xy] = m

        cur_slacks = [current_path_slack(p) for p in paths]
        failing_eps = {
            paths[i][2][-1] for i, s in enumerate(cur_slacks) if s < 0
        }
        print(
            f'Sweep {sweep}: moves={sweep_moves}, worst_pred_slack={min(cur_slacks):.1f}ps, '
            f'pred_failing_paths={sum(s < 0 for s in cur_slacks)}, '
            f'pred_failing_endpoints={len(failing_eps)}'
        )
        if sweep_moves == 0:
            break

    clb_coords = [pos[c] for c in pos if c.startswith('stratix_clb')]
    assert len(clb_coords) == len(set(clb_coords)), 'Duplicate CLB coordinates!'
    assert set(clb_coords) <= all_valid_clb, 'Invalid CLB tile used!'
    for c1, c2 in carry_next.items():
        x1, y1 = pos[c1]
        x2, y2 = pos[c2]
        assert (x2 - x1, y2 - y1) == (0, -1), f'Broken carry chain {c1}->{c2}!'

    ranked = sorted(
        ((current_path_slack(p), p[0], p[1], path_manhattan(p[2], pos), p[2]) for p in paths),
        key=lambda x: x[0],
    )
    print('\nWORST 15 PREDICTED PATHS AFTER OPTIMIZATION:')
    for s_new, s_old, l_old, l_new, seq in ranked[:15]:
        print(f'  pred={s_new:6.1f}ps (was {s_old:6.1f}ps, len {l_old:3d}->{l_new:3d}) | {seq[0]} -> {seq[-1]}')

    lines = []
    for c in sorted(k for k in pos if k.startswith(('stratix_clb', 'stratix_mem'))):
        x, y = pos[c]
        kind = 'M4K' if c.startswith('stratix_mem') else 'CLB'
        lines.append(f'set_location_assignment {kind}_X{x}_Y{y}_N0 -to {{{c}}}')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
    moved_total = sum(
        pos[c] != base_pos[c] for c in pos if c.startswith('stratix_clb')
    )
    print(f'\nWrote {len(lines)} locks to {args.out} (moved {moved_total} CLB clusters total)')


if __name__ == '__main__':
    main()
