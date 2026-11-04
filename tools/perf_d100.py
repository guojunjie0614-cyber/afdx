"""Reconstruct the 77-VL, 100-clock GMII experiment in an isolated directory.

prepare only generates inputs and verifies the existing fullperf executable's
source identity. run consumes one simulator slot; check never launches HDL.
This is a current reconstruction, not evidence that a historical run was repeated.
"""
import argparse
import collections
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
TEST = 'tb_sys_perf_d100'
STAGE = 'gbe77_d100'
VLS, SIZE, ROUNDS, BAG, DELAY = 77, 1471, 23, 125000, 100
COUNT = VLS * ROUNDS
DEFAULT_SOURCE = ROOT / 'out/open_verilator/20261103_164842_323414/tb_sys_perf'
CHANNELS = tuple(f'es{es}_{kind}' for es in (1, 2)
                 for kind in ('tx', 'rx', 'gmii_tx', 'gmii_rx'))
ANALYSIS = ('sys_cases', 'afdx_ref', 'tx_ref', 'rx_ref', 'rx_checks',
            'sys_ref', 'sys_checks', 'gmii_ref', 'sys_run_checks',
            'verification_profile', 'perf_d100')


def save(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_identity(source):
    """Use Verilator's actual S dependencies, not unrelated tb/lib modules."""
    source = source.resolve()
    build = json.loads((source / 'build.json').read_text(encoding='utf-8'))
    if build['top'] != 'tb_sys_perf' or build['parameters']:
        raise ValueError('Expected the default-parameter tb_sys_perf executable')
    batch = source.parent
    manifest = (source / 'obj/Vsim__verFiles.dat').read_text(encoding='utf-8')
    dependencies = []
    for line in manifest.splitlines():
        match = re.match(r'^S\s+.*"([^"]+)"$', line)
        if not match:
            continue
        compiled = Path(match[1])
        try:
            relative = compiled.relative_to(batch / 'sources')
        except ValueError:
            continue  # Verilator's own executable is also an S entry.
        if relative.suffix not in ('.v', '.vh') or relative.parts[0] not in ('rtl', 'tb'):
            raise ValueError('Unexpected compiled source: ' + str(relative))
        original = batch / 'originals' / relative
        current = ROOT / relative
        if original.read_bytes() != current.read_bytes():
            raise ValueError('Executable source identity mismatch: ' + str(relative))
        dependencies.append(dict(path=relative.as_posix(), bytes=current.stat().st_size,
                                 sha256=digest(current)))
    paths = {d['path'] for d in dependencies}
    required = {'tb/tb_sys_perf.v', 'tb/lib/sys_suite.v', 'tb/lib/sys_endpoint.v',
                'tb/lib/top_stream_endpoint.v', 'tb/lib/link_model.v',
                'tb/lib/gmii_monitor.v', 'tb/lib/line_monitor.v'}
    rtl = {p.relative_to(ROOT).as_posix() for p in (ROOT / 'rtl').glob('*.v')}
    if not required <= paths or paths & rtl != rtl:
        raise ValueError('Incomplete RTL/testbench dependency identity evidence')
    executable = source / 'simulation.exe'
    return dict(source=str(source), build_top=build['top'], parameters=[],
                executable=str(executable), executable_sha256=digest(executable),
                dependencies=sorted(dependencies, key=lambda d: d['path']),
                dependency_manifest_sha256=digest(source / 'obj/Vsim__verFiles.dat'))


def make_case():
    from sys_cases import Cases
    case = Cases(1)
    case.stage(STAGE)
    case.user()
    case.emit(f'W {BAG}')
    for link in range(4):
        case.emit(f'L {link} {DELAY}')
    for es in (1, 2):
        for vl in range(VLS):
            case.config(es, vl, maximum=SIZE, bag=BAG)
    offsets = [case.blob(b''.join(case.data(SIZE) for _ in range(COUNT))) for es in (1, 2)]
    for link in range(4):
        case.frames[link] += COUNT
    case.emit(f'F 2 {ROUNDS} {BAG} {VLS} {offsets[0]} {offsets[1]}')
    case.emit('D')
    case.counts()
    return case, offsets


def prepare(source, folder):
    identity = source_identity(source)
    folder.mkdir(parents=True, exist_ok=False)
    case, offsets = make_case()
    case.save(folder / 'vectors')
    for channel in CHANNELS:
        (folder / channel).mkdir()
    for row in identity['dependencies']:
        relative = Path(row['path'])
        target = folder / 'originals' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, target)
    sources = [ROOT / 'tools' / (name + '.py') for name in ANALYSIS]
    sources.append(ROOT / 'sim/r97_measure.tcl')
    analysis = []
    for path in sources:
        relative = path.relative_to(ROOT)
        target = folder / 'analysis_sources' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        analysis.append(dict(path=relative.as_posix(), sha256=digest(path)))
    inputs = {p.name: digest(p) for p in (folder / 'vectors').iterdir()}
    info = dict(test=TEST, stage=STAGE, status='prepared_not_simulated',
                experiment='current reconstruction of the 100-clock condition',
                historical_reproduction_claim=False, created=datetime.now().astimezone().isoformat(),
                verification_profile='fragmentation1030', binary_identity=identity,
                analysis_sources=analysis, input_sha256=inputs, offsets=offsets,
                matrix=dict(vls=VLS, payload_bytes=SIZE, rounds=ROUNDS, directions=2,
                            networks='AB', bag_cycles=BAG, link_delay_cycles=DELAY,
                            warmup_rounds=2, measured_cycles=21*BAG, measured_ms=21),
                notes=['Build top remains tb_sys_perf; independent checker name is tb_sys_perf_d100.',
                       'No perf_ref.measure/measure_r97 delay assumptions are used.',
                       'run requires one available HDL execution slot.'])
    save(folder / 'd100_manifest.json', info)
    return info


def verify_prepared(folder):
    info = json.loads((folder / 'd100_manifest.json').read_text(encoding='utf-8'))
    if info['test'] != TEST or info['stage'] != STAGE:
        raise ValueError('Not a prepared 100-clock experiment')
    identity = source_identity(Path(info['binary_identity']['source']))
    if identity != info['binary_identity']:
        raise ValueError('Executable/dependency evidence changed since prepare')
    for row in identity['dependencies']:
        if (folder / 'originals' / row['path']).read_bytes() != (ROOT / row['path']).read_bytes():
            raise ValueError('Prepared original source changed: ' + row['path'])
    for row in info['analysis_sources']:
        if digest(ROOT / row['path']) != row['sha256'] or digest(folder / 'analysis_sources' / row['path']) != row['sha256']:
            raise ValueError('Analysis source changed: ' + row['path'])
    for name, value in info['input_sha256'].items():
        if digest(folder / 'vectors' / name) != value:
            raise ValueError('Prepared input changed: ' + name)
    return info


def read_rows(path):
    return [line.split() for line in path.read_text(encoding='ascii').splitlines() if line.strip()]


def interval_stats(samples):
    """Signed interval-minus-BAG, retaining its worst actual frame witness."""
    if not samples:
        return dict(samples=0, min_cycles=None, max_cycles=None, max_abs_cycles=None)
    worst = max(samples, key=lambda x: abs(x['deviation_cycles']))
    values = [r['deviation_cycles'] for r in samples]
    return dict(samples=len(values), min_cycles=min(values), max_cycles=max(values),
                max_abs_cycles=max(map(abs, values)), worst=worst)


def public_checks(folder):
    """All warmup/window/drain messages, independently bound to generated input."""
    case, offsets = make_case()
    failures = []
    checks = errors = 0

    def expect(ok, label):
        nonlocal checks, errors
        checks += 1
        if not ok:
            errors += 1
            if len(failures) < 100:
                failures.append(label)
        return bool(ok)

    commands = (folder / 'vectors/sys_commands.txt').read_text(encoding='ascii')
    expect(commands == '\n'.join(case.commands) + '\n', 'exact independent 77-VL/23-round/AB/1471/F command matrix')
    payload = bytes(int(x, 16) for x in (folder / 'vectors/sys_payload.hex').read_text(encoding='ascii').split())
    expect(payload == bytes(case.payload), 'generated input payload unchanged')
    expect(int((folder / 'vectors/sys_payload.count').read_text()) == len(payload), 'input payload count')
    system = read_rows(folder / 'sys_events.txt')
    marks = [r for r in system if r[0] == 'P']
    expect(len(marks) == 1 and marks[0][2] == STAGE, 'single reconstructed stage, no historical-stage substitution')
    # sys_suite records its four power-on link defaults before the P stage.
    # The experiment programs all links after entering this stage; their
    # actual captured frame delays are also checked independently below.
    stage_cycle = int(marks[0][1]) if len(marks) == 1 else 0
    delays = [tuple(map(int, r[2:])) for r in system if r[0] == 'L' and int(r[1]) >= stage_cycle]
    expect(sorted(delays) == [(i, DELAY) for i in range(4)], 'all four stage link delays exactly 100')
    windows = {r[2]: int(r[1]) for r in system if r[0] == 'F' and r[2] in ('begin', 'end')}
    expect(len([r for r in system if r[0] == 'F']) == 2 and set(windows) == {'begin', 'end'}, 'exactly two full measurement-window edges')
    if set(windows) != {'begin', 'end'}:
        raise ValueError('Missing F window edges')
    begin, end = windows['begin'], windows['end']
    duration = end - begin
    expect(duration == 21*BAG and duration >= 2625000, 'full 21ms window, no shortened measurement')
    expect(not any(r[0] in ('A', 'R', 'J', 'E') for r in system), 'no faults, replay, injections or adapter errors')
    directions = {}
    for es in (1, 2):
        dest = 3 - es
        txrows = read_rows(folder / f'es{es}_tx/events.txt')
        rxrows = read_rows(folder / f'es{dest}_rx/events.txt')
        messages = [r for r in txrows if r[0] == 'M']
        inputs = [r for r in txrows if r[0] == 'A']
        delivered = [r for r in rxrows if r[0] == 'D']
        expect(len(messages) == len(inputs) == len(delivered) == COUNT, f'ES{es} all 23x77 inputs and deliveries present exactly once')
        offers = [r for r in system if r[0] == 'O' and int(r[2]) == es]
        expect(len(offers) == COUNT, f'ES{es} all planned release records')
        if not offers:
            raise ValueError('No planned release records')
        base = int(offers[0][5])
        expect(begin == base + 2*BAG and end == base + ROUNDS*BAG, f'ES{es} exactly 2 BAG warmup and 21 BAG measurement')
        for index, r in enumerate(offers):
            roundno, vl = divmod(index, VLS)
            target = base + roundno*BAG + vl*BAG//VLS
            expect(list(map(int, r[1:])) == [target, es, vl, SIZE, target], f'ES{es} planned matrix slot {index}')
        source_messages = {}
        firsts = collections.defaultdict(list)
        inject = 0
        for index, (m, a) in enumerate(zip(messages, inputs)):
            roundno, vl = divmod(index, VLS)
            off = offsets[es-1] + index*SIZE
            body = payload[off:off+SIZE]
            vlid = (100 if es == 1 else 2000) + vl
            expect(len(m) >= 12 and len(a) == 8, f'ES{es} public application timestamps available {index}')
            if len(m) < 12 or len(a) != 8:
                continue
            first, last = int(a[5]), int(a[1])
            expect((int(m[2]), int(m[3]), bytes.fromhex(m[7])) == (vl, SIZE, body), f'ES{es} exact source input/order {index}')
            expect((int(a[2], 16), int(a[3]), bytes.fromhex(a[4])) == (vlid, SIZE, body), f'ES{es} public VLID and payload {index}')
            expect((int(m[8]), int(m[10]), int(m[9]), int(m[11])) == (first, last, int(a[7]), int(a[6])), f'ES{es} core/public first/end/stalls binding {index}')
            expect(last-first+1 == SIZE+2+int(a[6]) and first <= last, f'ES{es} actual public input duration {index}')
            source_messages[vl, roundno] = dict(first=first, last=last, payload=body, index=index)
            firsts[vl].append((index, first))
            inject += max(0, min(last+1, end)-max(first+2, begin)) - (int(a[6]) if begin <= first and last < end else 0)
        accepted = collections.Counter()
        latencies = collections.defaultdict(list)
        received = 0
        for r in delivered:
            vl = int(r[3]); roundno = accepted[vl]; accepted[vl] += 1
            m = source_messages.get((vl, roundno))
            if not expect(m is not None and len(r) >= 10, f'ES{es} delivery belongs to one actual public input'):
                continue
            expect(int(r[6]) == SIZE and bytes.fromhex(r[7]) == m['payload'], f'ES{es} exact complete delivered payload {m["index"]}')
            first, last = int(r[8]), int(r[9])
            expect(last-first+1 == SIZE+2, f'ES{es} whole public VLID+payload delivery duration {m["index"]}')
            latency = last-m['first']
            expect(0 < latency <= 250000, f'ES{es} all-message public first-valid to public last-byte <=2ms {m["index"]}')
            latencies[vl, SIZE].append((m['index'], latency))
            received += max(0, min(last+1, end)-max(first+2, begin))
        expect(accepted == collections.Counter({v: ROUNDS for v in range(VLS)}), f'ES{es} every VL delivered all 23 rounds')
        group_ranges = [dict(vl=v, length=n, min_cycles=min(x[1] for x in samples),
                             max_cycles=max(x[1] for x in samples),
                             jitter_cycles=max(x[1] for x in samples)-min(x[1] for x in samples))
                        for (v, n), samples in latencies.items()]
        expect(len(group_ranges) == VLS and all(r['jitter_cycles'] <= 6250 for r in group_ranges), f'ES{es} same-VL same-length all-message jitter <=50us')
        tx_events = collections.Counter(r[2] for r in txrows if r[0] == 'E')
        rx_events = collections.Counter(r[2] for r in rxrows if r[0] == 'E')
        expect(tx_events == collections.Counter(accept=COUNT, tx_a=COUNT, tx_b=COUNT), f'ES{es} zero TX reject/error, every AB frame completed')
        expect(rx_events == collections.Counter(a_good=COUNT, b_good=COUNT, deliver=COUNT, rm_drop=COUNT), f'ES{es} zero RX loss/duplicate/overflow/error, normal redundancy ledger')
        intervals = []
        for vl, seq in firsts.items():
            for (i, a), (j, b) in zip(seq, seq[1:]):
                intervals.append(dict(vl=vl, previous=i, current=j, interval_cycles=b-a, deviation_cycles=b-a-BAG))
        wire = {}
        wire_intervals = {}
        for net in ('A', 'B'):
            tx = read_rows(folder / f'es{es}_gmii_tx/dump_{net.lower()}.txt')
            rx = read_rows(folder / f'es{dest}_gmii_rx/dump_{net.lower()}.txt')
            expect(len(tx) == len(rx) == COUNT, f'ES{es}/{net} complete GMII matrix')
            counts = collections.Counter()
            previous = {}
            deviations = []
            observed_delays = []
            for index, (t, r) in enumerate(zip(tx, rx)):
                tw, rw = bytes.fromhex(t[3]), bytes.fromhex(r[3])
                delta = int(r[1])-int(t[1]); observed_delays.append(delta)
                expect(t[0] == r[0] == net and int(t[2]) == len(tw) and int(r[2]) == len(rw), f'ES{es}/{net} GMII length/format {index}')
                expect(delta == DELAY and tw == rw, f'ES{es}/{net} actual exact 100-clock GMII delay and bytes {index}')
                vl = int.from_bytes(tw[12:14], 'big')-(100 if es == 1 else 2000)
                roundno = counts[vl]; counts[vl] += 1
                m = source_messages.get((vl, roundno))
                expect(m is not None and tw[50:50+SIZE] == m['payload'], f'ES{es}/{net} wire input binding {index}')
                start = int(t[1])
                if vl in previous:
                    pi, ps = previous[vl]
                    deviations.append(dict(vl=vl, previous=pi, current=index, interval_cycles=start-ps, deviation_cycles=start-ps-BAG))
                    expect(start-ps >= BAG, f'ES{es}/{net} actual same-VL BAG respected {index}')
                previous[vl] = (index, start)
            expect(counts == collections.Counter({v: ROUNDS for v in range(VLS)}), f'ES{es}/{net} every VL has 23 complete physical frames')
            wire[net] = dict(frames=len(tx), delay_min=min(observed_delays, default=None), delay_max=max(observed_delays, default=None))
            wire_intervals[net] = interval_stats(deviations)
        inject_mbps = inject*1000/duration if duration > 0 else 0
        delivered_mbps = received*1000/duration if duration > 0 else 0
        expect(inject_mbps >= 900 and delivered_mbps >= 900, f'ES{es} actual window injection and delivery >=900Mbps')
        all_latencies = [value for samples in latencies.values() for _, value in samples]
        directions[f'es{es}_to_es{dest}'] = dict(messages=len(messages), delivered=len(delivered),
            window_cycles=duration, inject_payload_bytes=inject, inject_mbps=inject_mbps,
            delivered_payload_bytes=received, delivered_mbps=delivered_mbps,
            all_message_latency_samples=len(all_latencies),
            all_message_latency_max_cycles=max(all_latencies, default=None),
            all_message_latency_max_us=max(all_latencies, default=0)*0.008,
            all_message_jitter_max_cycles=max((r['jitter_cycles'] for r in group_ranges), default=None),
            all_message_jitter_groups=group_ranges, public_input_interval_deviation=interval_stats(intervals),
            gmii_interval_deviation=wire_intervals, gmii=wire)
    return dict(checks=checks, errors=errors, failures=failures, window=[begin, end], directions=directions)


def tcl_measure(folder):
    import tkinter
    interp = tkinter.Tcl()
    interp.call('source', str(ROOT / 'sim/r97_measure.tcl'))
    measured = interp.call('r97::measure', str(folder), (STAGE,))
    values = {}
    for key in interp.splitlist(interp.call('dict', 'keys', measured)):
        value = str(interp.call('dict', 'get', measured, key))
        try:
            values[str(key)] = int(value)
        except ValueError:
            try:
                values[str(key)] = float(value)
            except ValueError:
                values[str(key)] = value
    return values


def check(folder):
    info = verify_prepared(folder)
    os.environ['AFDX_VERIFICATION_PROFILE'] = 'fragmentation1030'
    import sys_run_checks
    with (folder / 'check.log').open('w', encoding='utf-8') as stream:
        from contextlib import redirect_stdout
        with redirect_stdout(stream):
            independent = sys_run_checks.run(TEST, folder)
    public = public_checks(folder)
    measured = tcl_measure(folder)
    failures = []
    for direction, own in public['directions'].items():
        prefix = f'{STAGE}/{direction}/accepted/all'
        if measured[prefix+'/inject/window_cycles'] != 21*BAG:
            failures.append(direction+' Tcl full 21ms window')
        if measured[prefix+'/inject/mbps'] < 900:
            failures.append(direction+' Tcl injection >=900Mbps')
        rate = measured[prefix+'/throughput/payload_bytes']*1000/measured[prefix+'/throughput/window_cycles']
        if rate < 900:
            failures.append(direction+' Tcl delivery >=900Mbps')
        if abs(measured[prefix+'/inject/mbps']-own['inject_mbps']) > 1e-8 or abs(rate-own['delivered_mbps']) > 1e-8:
            failures.append(direction+' independent Python/Tcl public-byte window agreement')
        for key in ('offered/messages', 'delivered/messages', 'redundancy/rejections'):
            if measured[prefix+'/'+key] != COUNT:
                failures.append(direction+' Tcl '+key)
        for key in ('dropped', 'duplicate', 'overflow', 'errors'):
            if measured[prefix+'/integrity/'+key] != 0:
                failures.append(direction+' Tcl integrity '+key)
        for net in ('A', 'B'):
            key = f'{STAGE}/{direction}/{net}/all/L_gmii'
            if measured[key+'/min'] != DELAY or measured[key+'/max'] != DELAY or measured[key+'/samples'] != 21*VLS:
                failures.append(direction+'/'+net+' Tcl actual GMII delay and full window coverage')
        if measured[prefix+'/L_entry_last/max'] > 250000 or measured[prefix+'/jitter_r119/jitter'] > 6250:
            failures.append(direction+' Tcl public-last latency/jitter requirement')
    identity_after = verify_prepared(folder)
    assert identity_after == info
    result = dict(test=TEST, stage=STAGE, experiment=info['experiment'],
                  capture_provenance=info.get('capture_provenance', {'kind': 'HDL execution in this directory'}),
                  historical_reproduction_claim=False, verification_profile='fragmentation1030',
                  passed=independent['errors'] == public['errors'] == len(failures) == 0,
                  errors=independent['errors']+public['errors']+len(failures),
                  independent=independent, strict_public=public, tcl_failures=failures,
                  tcl_fields=len(measured), tcl_metrics=measured)
    save(folder / 'd100_summary.json', result)
    info['status'] = 'checked_pass' if result['passed'] else 'checked_fail'
    save(folder / 'd100_manifest.json', info)
    return result


def run(folder, timeout):
    info = verify_prepared(folder)
    if (folder / 'simulation.log').exists() or (folder / 'sys_events.txt').exists():
        raise ValueError('This isolated directory already contains simulation evidence; prepare a new one')
    info['status'] = 'simulation_started'
    save(folder / 'd100_manifest.json', info)
    from process_guard import run as guarded_run
    with (folder / 'simulation.log').open('w', encoding='utf-8') as stream:
        process = guarded_run([info['binary_identity']['executable']], cwd=folder,
                              stdout=stream, stderr=-2, timeout=timeout,
                              metrics=folder / 'simulation.resources.json')
    text = (folder / 'simulation.log').read_text(encoding='utf-8', errors='replace')
    results = re.findall(r'\[RESULT\]\s+(\w+)\s+(PASS|FAIL)\s+checks=(\d+)\s+errors=(\d+)', text)
    if process.returncode or not results or results[-1][0] != 'tb_sys_perf' or any(r[1] != 'PASS' or int(r[3]) for r in results) or '[FAIL]' in text or 'RAMCOLL' in text:
        raise RuntimeError('HDL run failed; see simulation.log')
    info['status'] = 'simulation_pass_pending_checks'
    save(folder / 'd100_manifest.json', info)
    return check(folder)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    prep = commands.add_parser('prepare', help='generate vectors and check binary identity; no HDL execution')
    prep.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    prep.add_argument('--out', type=Path)
    for name in ('run', 'check'):
        sub = commands.add_parser(name)
        sub.add_argument('folder', type=Path)
        if name == 'run':
            sub.add_argument('--timeout', type=int, default=1800)
    args = parser.parse_args()
    folder = (args.out or ROOT/'out/perf_d100'/datetime.now().strftime('%Y%m%d_%H%M%S_%f')).resolve() if args.action == 'prepare' else args.folder.resolve()
    try:
        if args.action == 'prepare':
            info = prepare(args.source, folder)
            print(json.dumps(dict(folder=str(folder), status=info['status'],
                                  source_dependencies=len(info['binary_identity']['dependencies']),
                                  matrix=info['matrix']), indent=2))
            return 0
        result = run(folder, args.timeout) if args.action == 'run' else check(folder)
        compact = {direction: {key: values[key] for key in (
            'messages', 'delivered', 'window_cycles', 'inject_mbps', 'delivered_mbps',
            'all_message_latency_max_us', 'all_message_jitter_max_cycles',
            'public_input_interval_deviation', 'gmii_interval_deviation')}
            for direction, values in result['strict_public']['directions'].items()}
        print(json.dumps(dict(folder=str(folder), passed=result['passed'], errors=result['errors'],
                              directions=compact), indent=2))
        return int(not result['passed'])
    except Exception as exc:
        if folder.is_dir():
            save(folder / 'd100_failure.json', dict(action=args.action, error=str(exc)))
        raise


if __name__ == '__main__':
    raise SystemExit(main())
