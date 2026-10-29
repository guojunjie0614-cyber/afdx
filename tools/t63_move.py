"""T63 手工移动：在全锁定布局语句文件上把指定簇挪到空位，输出新的全锁定语句。

合法空位 = 任一已有布局中出现过的 CLB 坐标（--valid 下所有 .place 的并集），且在基础布局中未被占用。
--near 只列出某坐标附近的空位，不写文件。
"""
import argparse
import json
import re
from pathlib import Path

LINE = re.compile(r'set_location_assignment (CLB|M4K)_X(\d+)_Y(\d+)_N0 -to \{(\S+)\}')


def read_edc(path):
    pos = {}
    for line in Path(path).read_text(encoding='utf-8').splitlines():
        m = LINE.fullmatch(line.strip())
        if m:
            pos[m.group(4)] = (int(m.group(2)), int(m.group(3)))
    return pos


def valid_tiles(root):
    tiles = set()
    for place in Path(root).rglob('*.place'):
        for line in place.read_text(encoding='utf-8-sig').splitlines():
            f = line.split()
            if len(f) >= 4 and f[0].startswith('stratix_clb'):
                tiles.add((int(f[1]), int(f[2])))
    return tiles


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True, help='全锁定语句文件（如 out/t63/eco/m2.edc）')
    parser.add_argument('--valid', type=Path, default=Path('out/implementation'))
    parser.add_argument('--near', help='X,Y：列出附近空位')
    parser.add_argument('--move', nargs='*', default=[], help='stratix_clbN=X,Y')
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    pos = read_edc(args.base)
    used = {xy for c, xy in pos.items() if c.startswith('stratix_clb')}
    free = valid_tiles(args.valid) - used
    if args.near:
        x0, y0 = map(int, args.near.split(','))
        print(sorted(free, key=lambda t: abs(t[0] - x0) + abs(t[1] - y0))[:12])
        return
    moves = {}
    for item in args.move:
        cluster, xy = item.split('=')
        target = tuple(map(int, xy.split(',')))
        if cluster not in pos or not cluster.startswith('stratix_clb'):
            raise SystemExit('Unknown CLB cluster ' + cluster)
        if target not in free:
            raise SystemExit(f'{target} is not a free valid CLB tile')
        free.discard(target)
        free.add(pos[cluster])
        moves[cluster] = dict(before=pos[cluster], after=target)
        pos[cluster] = target
    lines = [f"set_location_assignment {'M4K' if c.startswith('stratix_mem') else 'CLB'}_X{x}_Y{y}_N0 -to {{{c}}}"
             for c, (x, y) in sorted(pos.items())]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text('\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
    stats = dict(base=str(args.base), locked=len(lines), moves=moves)
    args.out.with_suffix('.json').write_text(json.dumps(stats, indent=1) + '\n', encoding='utf-8')
    print(json.dumps(stats))


if __name__ == '__main__':
    main()
