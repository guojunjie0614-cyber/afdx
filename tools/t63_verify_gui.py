"""只读比对用户提供的 eLinx 运行产物与 T63-F1 官方 CLI 终验基线。"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def vqm_signature(path):
    """只忽略导出日期和独立 wire 声明的排列，保留其余网表逐行内容。"""
    wires, body = [], []
    for line in Path(path).read_text(encoding='utf-8-sig').splitlines():
        if re.fullmatch(r'\s*//\s*DATE\s+.*', line):
            continue
        if re.match(r'^\s*wire\s+', line):
            if not line.rstrip().endswith(';'):
                raise ValueError('VQM contains a multiline wire declaration; structural comparison needs review')
            wires.append(line)
        else:
            body.append(line)
    text = '\n'.join(body) + '\n---WIRE DECLARATIONS---\n' + '\n'.join(sorted(wires)) + '\n'
    return dict(sha256=hashlib.sha256(text.encode('utf-8')).hexdigest().upper(),
                wire_declarations=len(wires), nonwire_lines=len(body))


def read_place(path):
    clusters, pins = {}, {}
    for line in Path(path).read_text(encoding='utf-8-sig').splitlines():
        fields = line.split()
        if not fields or fields[0].startswith('#'):
            continue
        if len(fields) >= 7 and fields[1] in ('input', 'output', 'inout'):
            if fields[0] in pins:
                raise ValueError('Duplicate placed port: ' + fields[0])
            pins[fields[0]] = dict(pin=fields[2], xyz=list(map(int, fields[4:7])))
        elif len(fields) >= 4:
            if fields[0] in clusters:
                raise ValueError('Duplicate placed cluster: ' + fields[0])
            clusters[fields[0]] = list(map(int, fields[1:4]))
        else:
            raise ValueError('Unrecognized placement row: ' + line)
    return clusters, pins


def literal_path(value, origin):
    value = value.strip()
    if value[:1] in ('"', '{'):
        closing = '"' if value[0] == '"' else '}'
        if not value.endswith(closing):
            raise ValueError('Nonliteral PSF path: ' + value)
        value = value[1:-1]
    if '$' in value or ';' in value or '\n' in value:
        raise ValueError('PSF variable or script substitution requires manual review: ' + value)
    value = re.sub(r'\\([\[\]"$])', r'\1', value).replace('\\', '/')
    path = Path(value)
    return path if path.is_absolute() else (origin / path).resolve()


def check_psf(path, timing, physical, full):
    reads, sources, targets = [], [], []
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        match = re.fullmatch(r'\s*(source|read_sdc)\s+(.+?)\s*', line)
        if match:
            linked = literal_path(match[2], path.parent)
            text = linked.read_text(encoding='utf-8-sig')
            (sources if match[1] == 'source' else reads).append((linked, text))
        match = re.fullmatch(r'\s*set_global_assignment\s+-name\s+TARGET_CONSTRAINT_FILE\s+(.+?)\s*', line)
        if match:
            targets.append(literal_path(match[1], path.parent))
    accepted = len(reads) == 1 and reads[0][1] == timing and len(sources) == 1 and sources[0][1] in (physical, full)
    accepted = accepted and len(targets) == 1 and targets[0] == sources[0][0]
    return dict(passed=accepted, file=str(path), sha256=digest(path),
                source=[str(x[0]) for x in sources], read_sdc=[str(x[0]) for x in reads],
                target=[str(x) for x in targets],
                meaning='One approved physical/full EDC via Tcl; pure timing SDC only via read_sdc')


def compare(baseline_path, runs_dir, extra_logs=()):
    baseline = json.loads(baseline_path.read_text(encoding='utf-8-sig'))
    expected = baseline['acceptance']
    checks, detail = {}, {}
    spec = json.loads((ROOT / 'elinx/constraints_t62.json').read_text(encoding='utf-8-sig'))
    timing = (ROOT / 'elinx/timing_only.sdc').read_text(encoding='utf-8-sig')
    physical = (ROOT / 'elinx/physical_only.edc').read_text(encoding='utf-8-sig')
    full = (ROOT / 'elinx/constraints.edc').read_text(encoding='utf-8-sig')
    checks['frozen_sources'] = all((ROOT / name).is_file() and digest(ROOT / name) == sha for name, sha in baseline['source_hashes'].items())
    checks['frozen_constraints'] = all((ROOT / name).is_file() and digest(ROOT / name) == sha for name, sha in baseline['constraint_hashes'].items())
    checks['constraint_split'] = timing + physical == full and timing == spec['timing_sdc']
    checks['pres'] = re.findall(r'^set_global_assignment -name PRES_FAC_MULT (\S+)$', physical, re.M) == [expected['pres']]
    checks['uncertainty'] = re.findall(r'^set_clock_uncertainty -setup (\S+) \[get_clocks \{clk\}\]$', timing, re.M) == ['0.30']
    document = ET.parse(ROOT / 'elinx/AFDX_EndSystem.epr').getroot()
    files = document.findall("./FileSets/FileSet[@Name='constrs_1']/File")
    target = document.find("./FileSets/FileSet[@Name='constrs_1']/Config/Option[@Name='TargetConstrsFile']")
    checks['project_pair'] = [x.attrib['Path'] for x in files] == ['/physical_only.edc', '/timing_only.sdc'] and target is not None and target.attrib.get('Val') == '/physical_only.edc'
    synth, route = runs_dir / 'synth_1', runs_dir / 'imple_1'
    name = 'AFDX_EndSystem'
    required = [synth / (name + '.vqm'), route / (name + '.place'), route / (name + '.tan.pb'),
                synth / (name + '.run.psf'), route / (name + '.run.psf'), synth / (name + '_utilization_synth.rpt'),
                route / (name + '_utilization_placed.rpt')]
    missing = [str(p) for p in required if not p.is_file() or p.stat().st_size == 0]
    checks['required_artifacts'] = not missing
    if missing:
        return dict(passed=False, checks=checks, missing=missing)
    cutoff = datetime.fromisoformat(baseline['verification_started']).timestamp()
    checks['fresh_artifacts'] = all(p.stat().st_mtime >= cutoff for p in required)
    detail['psf'] = [check_psf(p, timing, physical, full) for p in required[3:5]]
    checks['psf_read_chain'] = all(x['passed'] for x in detail['psf'])
    detail['vqm_signature'] = vqm_signature(required[0])
    checks['mapped_circuit'] = detail['vqm_signature'] == baseline['vqm_signature']
    clusters, pins = read_place(required[1])
    pin_errors = [r['port'] for r in spec['pins'] if pins.get(r['port']) != dict(pin=r['pin'], xyz=r['xyz'])]
    tile_errors = [r['cluster'] for r in spec['tiles'] if clusters.get(r['cluster']) != [r['x'], r['y'], 0]]
    checks['pins'] = len(pins) == expected['pins'] and not pin_errors
    checks['tiles'] = len(clusters) == expected['tiles'] and not tile_errors
    detail['physical'] = dict(pins=len(pins), tiles=len(clusters), pin_mismatches=pin_errors, tile_mismatches=tile_errors,
                              place_sha256=digest(required[1]), expected_place_sha256=expected['place_sha256'])
    checks['place_sha256'] = digest(required[1]) == expected['place_sha256']
    with sqlite3.connect(required[2].resolve().as_uri() + '?mode=ro', uri=True) as db:
        db.execute('PRAGMA query_only=ON')
        db.row_factory = sqlite3.Row
        clocks = [dict(r) for r in db.execute('SELECT * FROM elinx_intra_clock_summary')]
    detail['clocks'] = clocks
    wanted = dict(name='clk', period=8000, setup_worst_slack=expected['setup_ps'], hold_worst_slack=expected['hold_ps'],
                  setup_fail_ends=0, hold_fail_ends=0, setup_total_ends=expected['endpoints'], hold_total_ends=expected['endpoints'])
    checks['raw_timing'] = len(clocks) == 1 and all(clocks[0].get(k) == v for k, v in wanted.items())
    resource_rows = []
    for path in required[5:7]:
        text = path.read_text(encoding='utf-8-sig', errors='replace')
        values = {key: int(re.search(r'Total ' + label + r'\s*:\s*(\d+)', text)[1])
                  for key, label in [('lut', 'LUTs'), ('ff', 'FFs'), ('clb', 'CLBs'), ('memory', 'Memorys'), ('pins', 'Pins'), ('dsp', 'DSPs'), ('pll', 'PLLs')]}
        resource_rows.append(dict(file=str(path), values=values, successful='Successful' in text))
    detail['resources'] = resource_rows
    checks['resources'] = all(x['values'] == baseline['resources'] and x['successful'] for x in resource_rows)
    logs = sorted({*synth.glob('*.edi'), *route.glob('*.edi'), *synth.glob('*.log'), *route.glob('*.log'), *map(Path, extra_logs)})
    log_text = '\n'.join(p.read_text(encoding='utf-8-sig', errors='replace') for p in logs)
    errors = re.findall(r'(?im)^.*(?:\[(?:ERROR|CRIT)\]|\*\* (?:Error|Fatal)|^Error\s*\([0-9]+\)|invalid[- ]command|We don.t support the command|Found [1-9][0-9]* error\(s\) total).*$' , log_text)
    detail['logs'] = dict(files=[str(p) for p in logs], errors=errors,
                         clock_uncertainty_trace=bool(re.search(r'Argument uncertainty\s*=\s*0\.30\b', log_text)),
                         multicycle_trace=bool(re.search(r'Command:\s*set_multicycle_path', log_text)),
                         pres_trace=bool(re.search(r'PRES_FAC_MULT\s*[= ]\s*1\.30?\b', log_text)))
    checks['native_logs'] = len(logs) >= 2 and not errors
    return dict(passed=all(checks.values()), checks=checks, detail=detail,
                baseline=str(baseline_path), baseline_sha256=digest(baseline_path),
                verification_commit=baseline['verification_commit'], runs_dir=str(runs_dir),
                provenance='Comparison of supplied run artifacts; this tool does not launch or observe a GUI',
                checked=datetime.now().astimezone().isoformat())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, default=ROOT / 'docs/evidence/t63_f1_final.json')
    parser.add_argument('--runs-dir', type=Path, default=ROOT / 'elinx/AFDX_EndSystem.runs')
    parser.add_argument('--console-log', type=Path, action='append', default=[])
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = args.output or ROOT / 'out/t63/gui_compare' / (datetime.now().strftime('%Y%m%d_%H%M%S_%f') + '.json')
    try:
        result = compare(args.baseline.resolve(), args.runs_dir.resolve(), args.console_log)
    except Exception as error:
        result = dict(passed=False, error=str(error))
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('x', encoding='utf-8') as stream:
        stream.write(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    for name, value in result.get('checks', {}).items():
        print(('PASS ' if value else 'FAIL ') + name)
    print('T63 F1 ARTIFACT COMPARISON ' + ('PASS' if result['passed'] else 'FAIL'))
    print(output)
    if result.get('error'):
        print(result['error'])
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
