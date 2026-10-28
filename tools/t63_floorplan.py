"""T63 B 线：按现有布局生成模块级区域约束（add_insts_to_pblock）。

每个模块取其 CLB 簇坐标的 [p, 1-p] 分位矩形，四周外扩 margin，再检查矩形内的
CLB 位和 M4K 位容量；不足时沿四个方向轮流外扩，直到容量满足 目标数/利用率。
器件网格来自安装目录 core_arrangement.xml（EQ6HL130：164×100）。
"""
import argparse
import collections
import re
from pathlib import Path

ARRANGEMENT = Path(__file__).resolve().parents[3].parent / \
    'setup_pack/bin/shell/Infrastructure/psk_intern/eHiChip6/EQ6HL130/core_arrangement.xml'
INSTANCES = {
    'loader': r'\afdx_es:es|afdx_615a:loader',
    'rx_core': r'\afdx_es:es|afdx_rx_core:rx_core',
    'rtc': r'\afdx_es:es|afdx_rtc:rtc',
    'snmp': r'\afdx_es:es|afdx_snmp:snmp',
    'tx_core': r'\afdx_es:es|afdx_tx_core:tx_core',
    'cfg_regs': r'\afdx_es:es|afdx_cfg:cfg_regs',
    'application_tx': r'\afdx_app_tx:application_tx',
    'application_rx': r'\afdx_app_rx:application_rx',
}


def columns(kind_names):
    text = ARRANGEMENT.read_text(encoding='utf-8')
    result = set()
    for name, body in re.findall(r'<TILE name="([^"]+)"\s*>(.*?)</TILE>', text, re.S):
        if name not in kind_names:
            continue
        for spec in re.findall(r'loc_x="([^"]+)"', body):
            for part in spec.split(','):
                part = part.strip()
                if not part:
                    continue
                if ':' in part:
                    a, b = map(int, part.split(':'))
                    result.update(range(a, b + 1))
                else:
                    result.add(int(part))
    return result


CLB_COLUMNS = columns({'BLK', 'M4KLAB', 'DSPLAB'})
M4K_COLUMNS = columns({'M4K'})


def capacity(box):
    x0, y0, x1, y1 = box
    rows = y1 - y0 + 1
    clb = sum(1 for x in range(x0, x1 + 1) if x in CLB_COLUMNS) * rows
    mem = sum(1 for x in range(x0, x1 + 1) if x in M4K_COLUMNS) * rows
    return clb, mem


def module_points(xml, place, depth_names):
    pos = {}
    for line in Path(place).read_text(encoding='utf-8-sig').splitlines():
        f = line.split()
        if len(f) >= 4 and f[0].startswith('stratix_'):
            pos[f[0]] = (int(f[1]), int(f[2]))
    owner, current = {}, None
    with open(xml, encoding='utf-8') as stream:
        for line in stream:
            m = re.search(r'<CLUSTER name="([^"]+)"', line)
            if m:
                current = m.group(1)
                continue
            m = re.search(r'<MOLECULE name="([^"]+)"', line)
            if m and current and current not in owner:
                name = m.group(1).lstrip('\\')
                for key, instance in depth_names.items():
                    if name.startswith(instance.lstrip('\\') + '|'):
                        owner[current] = key
                        break
    points = collections.defaultdict(lambda: dict(clb=[], mem=[]))
    for cluster, key in owner.items():
        if cluster in pos:
            points[key]['mem' if 'mem' in cluster else 'clb'].append(pos[cluster])
    return points


def quantile(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, max(0, int(p * len(values))))]


def region(pts, p, margin, utilization):
    xs = [q[0] for q in pts['clb']]
    ys = [q[1] for q in pts['clb']]
    box = [max(1, quantile(xs, p) - margin), max(1, quantile(ys, p) - margin),
           min(164, quantile(xs, 1 - p) + margin), min(100, quantile(ys, 1 - p) + margin)]
    need_clb = len(pts['clb']) / utilization
    need_mem = len(pts['mem']) / utilization
    step = 0
    while True:
        clb, mem = capacity(box)
        if clb >= need_clb and mem >= need_mem:
            return box, clb, mem
        side = step % 4
        if side == 0 and box[2] < 164:
            box[2] += 1
        elif side == 1 and box[3] < 100:
            box[3] += 1
        elif side == 2 and box[0] > 1:
            box[0] -= 1
        elif side == 3 and box[1] > 1:
            box[1] -= 1
        step += 1
        if step > 2000:
            raise ValueError('Cannot satisfy capacity')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xml', type=Path, required=True)
    parser.add_argument('--place', type=Path, required=True)
    parser.add_argument('--modules', required=True, help='逗号分隔，取 INSTANCES 的键')
    parser.add_argument('--quantile', type=float, default=0.05)
    parser.add_argument('--margin', type=int, default=2)
    parser.add_argument('--utilization', type=float, default=0.8)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    wanted = {k: INSTANCES[k] for k in args.modules.split(',')}
    points = module_points(args.xml, args.place, INSTANCES)
    lines = ['# t63_floorplan quantile=%g margin=%d utilization=%g' % (args.quantile, args.margin, args.utilization)]
    for key, instance in wanted.items():
        box, clb, mem = region(points[key], args.quantile, args.margin, args.utilization)
        name = 'P_' + key
        lines.append(f'# {key}: clb {len(points[key]["clb"])}/{clb} mem {len(points[key]["mem"])}/{mem}')
        lines.append(f'create_pblock {name} -from X{box[0]}_Y{box[1]} -to X{box[2]}_Y{box[3]}')
        lines.append(f'add_insts_to_pblock {name} -to {{{instance}}}')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
