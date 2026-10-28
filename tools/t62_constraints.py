"""T62 single-source constraint generation and exact physical allowlist.

The approved JSON contains the unchanged r5 A timing program and all 172 P0
assignments.  Optional region/Tile policies require a separately frozen version
with native placement evidence; no command is silently filtered from SDC.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / 'elinx/constraints_t62.json'
PRES = ('1.30', '1.40', '1.45', '1.50', '1.55', '1.60', '1.70')


def load_spec():
    spec = json.loads(SPEC.read_text(encoding='utf-8'))
    timing = spec['timing_sdc']
    if hashlib.sha256(timing.encode()).hexdigest().upper() != spec['timing_sha256']:
        raise ValueError('Approved timing program hash differs')
    if len(spec['pins']) != 172 or len({row['port'] for row in spec['pins']}) != 172:
        raise ValueError('Exactly 172 unique P0 ports are required')
    if len({row['pin'] for row in spec['pins']}) != 172:
        raise ValueError('P0 pin collision')
    return spec


def physical(spec, pres):
    if pres not in PRES:
        raise ValueError('Unapproved PRES value')
    lines = ['set_global_assignment -name PRES_FAC_MULT ' + pres]
    for row in spec['pins']:
        if not re.fullmatch(r'[A-Z]+[0-9]+', row['pin']):
            raise ValueError('Invalid approved pin')
        if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*(?:\[[0-9]+\])?', row['port']):
            raise ValueError('Invalid approved port')
        lines.append('set_location_assignment PIN_' + row['pin'] + ' -to {' + row['port'] + '}')
    # R/Tile are deliberately not admitted by the P0-only version.
    if spec.get('regions') or spec.get('tiles'):
        raise ValueError('R/Tile require a new native-validated policy version')
    return '\n'.join(lines) + '\n'


def render(pres='1.55'):
    spec = load_spec()
    timing = spec['timing_sdc']
    phys = physical(spec, pres)
    return dict(full=timing + phys, timing=timing, physical=phys)


def split(source):
    """Accept a complete generated file; reject every missing/extra statement."""
    if isinstance(source, bytes):
        source = source.decode('utf-8-sig')
    # Path.read_text normalizes CRLF. Whitespace within statements stays exact.
    source = source.replace('\r\n', '\n')
    for pres in PRES:
        expected = render(pres)
        if source == expected['full']:
            return dict(expected, pres=pres)
    raise ValueError('Constraint program differs from exact approved timing/PRES/P0 set')


def check_project_files(paths):
    """Both the full EDC and a generated GUI dual-file project have one source."""
    if len(paths) == 1:
        return split(paths[0].read_text(encoding='utf-8-sig'))
    if len(paths) == 2:
        edc = next((p for p in paths if p.suffix.lower() == '.edc'), None)
        sdc = next((p for p in paths if p.suffix.lower() == '.sdc'), None)
        if edc is not None and sdc is not None:
            return split(sdc.read_text(encoding='utf-8-sig') + edc.read_text(encoding='utf-8-sig'))
    raise ValueError('Expected one approved full EDC or approved physical EDC + pure SDC')


def generate(folder, pres='1.55'):
    data = render(pres)
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    for key, name in [('full', 'constraints.edc'), ('timing', 'timing_only.sdc'),
                      ('physical', 'physical_only.edc')]:
        (folder / name).write_text(data[key], encoding='utf-8', newline='\n')
    return data


def self_check():
    data = render()
    source = data['full']
    cases = {('approved_P' + pres): (render(pres)['full'], True) for pres in PRES}
    cases.update({
        'period_changed': (source.replace('-period 8.000', '-period 9.000'), False),
        'uncertainty_changed': (source.replace('-setup 0.30', '-setup 0.20'), False),
        'multicycle_changed': (source.replace('set_multicycle_path -setup 2', 'set_multicycle_path -setup 1', 1), False),
        'unknown_exception': (source + 'set_false_path -from [get_ports {reset}]\n', False),
        'missing_pin': (source.replace(physical(load_spec(), '1.55').splitlines()[1] + '\n', '', 1), False),
        'misspelled_port': (source.replace('-to {clk}', '-to {missing_clk}', 1), False),
        'unapproved_region': (source + 'create_pblock R -from X22_Y60 -to X41_Y75\n', False),
        'unapproved_tile': (source + 'set_location_assignment CLB_X25_Y62_N0 -to {stratix_clb2470}\n', False),
    })
    results = []
    for name, (program, expect) in cases.items():
        if not expect and program == source:
            raise ValueError('Unexercised mutation: ' + name)
        try:
            parsed = split(program)
            accepted = True
            detail = 'exact approved program; pure SDC contains no physical commands'
            if parsed['timing'] != data['timing']:
                raise ValueError('Timing changed')
        except ValueError as error:
            accepted = False
            detail = str(error)
        results.append(dict(case=name, accepted=accepted, expected=expect,
                            passed=accepted == expect, detail=detail))
    if not all(row['passed'] for row in results):
        raise ValueError(str(results))
    return dict(passed=True, tests=results, pins=172,
                region_tile_policy='not admitted before native proof and separate commit')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--generate', type=Path)
    parser.add_argument('--pres', choices=PRES, default='1.55')
    args = parser.parse_args()
    if args.generate:
        generate(args.generate, args.pres)
    print(json.dumps(self_check(), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
