"""Representative FAQ C157-2 multi-VL fragmentation on native RTL and official VQM.

One AFDX_top uses its public A/B pins in loopback. This is functional GLS,
without SDF or a claim of bidirectional/full-load gate-level performance.
"""
import argparse
from collections import defaultdict
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import eda
from adapt_gui_vqm import adapt
from fragment_integration import config, pattern, records, write_bytes
import fragment_integration
import fragment_ref
from gui_netlist import adapt_simulation_source, MODELS

BUILD = ROOT / 'out/build1030/AFDX_top_1030/20261103_103410_728861'
NETLIST = BUILD / 'project/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm'
MODEL_DIR = Path('C:/Program Files (x86)/eHiWay/eLinx3.0/Simulation/elinx_lib')
CAPTURES = ('tx_a.txt', 'tx_b.txt', 'rx.txt', 'tx_messages.txt', 'events.txt')
TOOLS = ('faq_gls.py', 'fragment_integration.py', 'fragment_ref.py', 'gui_netlist.py',
         'adapt_gui_vqm.py', 'modelsim_compat.py', 'eda.py')


def source_paths():
    return [*sorted((ROOT / 'rtl').glob('*.v')), ROOT / 'tb/tb_faq_gls.v',
            *(ROOT / 'tools' / name for name in TOOLS),
            ROOT / 'hardware_spec.yaml', ROOT / 'hardware_contract.yaml']


def prepare(folder):
    folder.mkdir(parents=True, exist_ok=False)
    v = folder / 'vectors'
    v.mkdir()
    config(v / 'config.txt', [(0x100, 1000, 1471, 1000, 2000),
                              (0x101, 1000, 1471, 1000, 2000)])
    lengths = (1472, 64, 17)
    ids = (0x100, 0x101, 0x101)
    dues = (0, 2000, 5000)
    data = bytearray()
    schedule = []
    for tag, (n, vl, due) in enumerate(zip(lengths, ids, dues), 1):
        schedule.append((due, vl, n, len(data)))
        data.extend(pattern(tag, n))
    write_bytes(v / 'payload.hex', data)
    (v / 'schedule.txt').write_text('3 1553 3\n' + ''.join('%d %d %d %d\n' % row for row in schedule), encoding='ascii')
    (v / 'injection.txt').write_text('0 0\n', encoding='ascii')
    paths = source_paths() + [NETLIST, BUILD / 'summary.json', *(MODEL_DIR / n for n in MODELS)]
    eda.save(folder / 'manifest.json', dict(
        name='FAQ-GLS', status='prepared', top='tb_faq_gls', ce_div=2,
        scope='one full AFDX_top, public dual-network loopback, two active VLs, three application messages',
        fragmented_payload=1472, short_payloads=[64, 17], bag_cycles=125000,
        gate_instances=1, sdf=False, netlist=str(NETLIST), model_dir=str(MODEL_DIR),
        inputs={str(p): eda.sha(p) for p in paths},
        vectors={p.name: eda.sha(p) for p in sorted(v.iterdir())}))
    print('FAQ GLS PREPARED ' + str(folder), flush=True)
    return folder


def verify_prepared(folder):
    manifest = json.loads((folder / 'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('top') != 'tb_faq_gls' or manifest.get('ce_div') != 2:
        raise RuntimeError('Unexpected prepared top/configuration')
    for path, expected in manifest['inputs'].items():
        if not Path(path).is_file() or eda.sha(Path(path)) != expected:
            raise RuntimeError('Prepared input changed: ' + path)
    actual_vectors = {p.name: eda.sha(p) for p in sorted((folder / 'vectors').iterdir()) if p.is_file()}
    if actual_vectors != manifest['vectors']:
        raise RuntimeError('Prepared vectors changed')
    build = json.loads((BUILD / 'summary.json').read_text(encoding='utf-8'))
    if not build.get('synthesis_completed') or build.get('top') != 'AFDX_top' or build.get('ce_div') != 2:
        raise RuntimeError('Official VQM synthesis identity/configuration missing')
    snapshot = Path(build['source_snapshot']) / 'rtl'
    canonical = {p.name: eda.sha(p) for p in sorted((ROOT / 'rtl').glob('*.v'))}
    synthesized = {p.name: eda.sha(p) for p in sorted(snapshot.glob('*.v'))}
    if canonical != synthesized or len(canonical) != 34:
        raise RuntimeError('Current RTL is not the official VQM source set')
    if Path(build['netlist']).resolve() != NETLIST.resolve():
        raise RuntimeError('Wrong official VQM path')
    return manifest


def check_capture(folder):
    """Independent plan -> complete application and per-network frame checks."""
    fragment_integration.check(folder, app=True)
    # The generic checker's historical R139 label is not a FAQ interpretation.
    # The result below explicitly records raw completion; no BAG is subtracted.
    frames = {net: [(int(r[0]), bytes.fromhex(r[1]), fragment_ref.decode(bytes.fromhex(r[1])))
                    for r in records(folder / ('tx_' + net + '.txt'))] for net in ('a', 'b')}
    per_vl = defaultdict(list)
    for t, wire, f in frames['a']:
        per_vl[f['vlid']].append((t, f))
        idx = f['vlid'] - 0x100
        if idx not in (0, 1) or (f['src'], f['dst']) != (0x0a000101 + idx, 0xe0e00000 | f['vlid']):
            raise RuntimeError('Configured VL/source/destination fields differ')
        if f['offset'] == 0:
            if f['data'][:4] != bytes.fromhex('03e807d0'):
                raise RuntimeError('UDP source/destination port mismatch')
    if set(per_vl) != {0x100, 0x101} or any(len(per_vl[v]) != 2 for v in per_vl):
        raise RuntimeError('Expected two physical frames per participating VL')
    a_long = per_vl[0x100]
    a_short = per_vl[0x101]
    if [(f['offset'], f['mf']) for _, f in a_long] != [(0, True), (1472, False)]:
        raise RuntimeError('1472-byte message did not produce two expected fragments')
    if not a_long[0][0] < a_short[0][0] < a_long[1][0]:
        raise RuntimeError('Other VL did not progress during unfinished fragmented datagram')
    if len(frames['a']) != 4 or len(frames['b']) != 4:
        raise RuntimeError('Missing or additional A/B frames')
    for (_, wa, _), (_, wb, _) in zip(frames['a'], frames['b']):
        ba, bb = wa[8:], wb[8:]
        if ba[11] != 0x20 or bb[11] != 0x40 or ba[:11] + ba[12:-4] != bb[:11] + bb[12:-4]:
            raise RuntimeError('A/B copies differ outside network selector and FCS')
    tx = [tuple(map(int, r)) for r in records(folder / 'tx_messages.txt') if r[0] != 'E']
    rx = list(records(folder / 'rx.txt'))
    if len(tx) != 3 or len(rx) != 3:
        raise RuntimeError('Exactly three public input/output messages required')
    latency = []
    starts = defaultdict(list)
    for first, last, vl, n in tx:
        starts[vl].append((first, n))
    for first, last, vl_hex, raw in rx:
        vl = int(vl_hex, 16)
        begin, n = starts[vl].pop(0)
        latency.append(dict(vl=vl, payload_bytes=n, first_valid_cycle=begin,
                            public_last_cycle=int(last), raw_completion_us=(int(last)-begin)*0.008))
    events = list(records(folder / 'events.txt'))
    final = [r for r in events if r[0] == 'FINAL']
    if final != [['FINAL', '3', '0', '0']]:
        raise RuntimeError('Final complete-delivery/error evidence missing')
    rm = sum(int(r[5], 16) for r in events if r[0] != 'FINAL')
    if rm != 4:
        raise RuntimeError('Exactly one RM duplicate rejection per physical frame required')
    result = dict(passed=True, messages=3, active_vls=2, frames_per_network=4,
                  redundancy_rejections=rm, raw_latencies=latency,
                  progress_while_fragment_open=True,
                  fragmented_latency_rule='C156-1: 既然已经分片，不再受单帧限制。 Raw completion retained; no new numeric limit inferred.',
                  checks='input-derived exact payload/order/quantity; FCS/IP/UDP; ID/MF/offset/SN; per-fragment BAG; A/B bytes; short raw <=2ms')
    eda.save(folder / 'check_summary.json', result)
    return result


def diagnostics(log):
    return {kind: len(re.findall(r'\*\* ' + kind + r'(?: \([^\n]*?\))?:', log))
            for kind in ('Error', 'Fatal', 'Warning')}


def run_case(prepared, mode, deadline):
    manifest = verify_prepared(prepared)
    flow = eda.Flow('faq_gls', mode, deadline)
    copied = []
    adaptations = []
    flow.result.update(mode=mode, prepared=str(prepared), ce_div=2,
                       scope=manifest['scope'] + '; functional GLS, no SDF',
                       inputs=manifest['inputs'], passed=False)
    def copy(source, relative):
        destination = flow.folder / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        expected = eda.sha(source)
        if eda.sha(destination) != expected:
            raise RuntimeError('Snapshot copy mismatch: ' + str(source))
        copied.append(dict(source=str(source), snapshot=relative, sha256=expected))
        return relative
    def hdl(source):
        rel = source.relative_to(ROOT).as_posix()
        original = copy(source, 'original_sources/' + rel)
        text, changed = adapt_simulation_source(rel, (flow.folder / original).read_bytes().decode('utf-8-sig'))
        compiled = 'compile_sources/' + rel
        path = flow.folder / compiled
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode('utf-8'))
        adaptations.extend(changed)
        return compiled
    try:
        for source in source_paths():
            if source.suffix not in ('.v', '.vh'):
                copy(source, 'original_sources/' + source.relative_to(ROOT).as_posix())
        shutil.copytree(prepared / 'vectors', flow.folder / 'vectors')
        if mode == 'rtl':
            sources = [hdl(p) for p in sorted((ROOT / 'rtl').glob('*.v'))]
        else:
            copy(NETLIST, 'original.vqm')
            flow.result['adaptation'] = adapt(flow.folder / 'original.vqm', flow.folder / 'simulation.vqm')
            sources = [copy(MODEL_DIR / name, name) for name in MODELS] + ['simulation.vqm']
        sources.append(hdl(ROOT / 'tb/tb_faq_gls.v'))
        eda.save(flow.folder / 'input_manifest.json', copied)
        eda.save(flow.folder / 'modelsim_adaptations.json', adaptations)
        (flow.folder / 'run.do').write_text('onerror {quit -code 1}\nonbreak {quit -code 1}\nrun -all\nquit -code 0\n', encoding='ascii')
        ms = eda.modelsim_dir()
        flow.job('library', [ms / 'vlib.exe', 'work'], 60)
        log = flow.job('compile', [ms / 'vlog.exe', '-vlog01compat', '+define+AFDX_CE_DIV=2', *sources], 900)
        flow.result['compile_diagnostics'] = diagnostics(log)
        if any(flow.result['compile_diagnostics'].values()) or not re.search(r'Errors: 0, Warnings: 0', log):
            raise RuntimeError('Nonzero or missing compile diagnostics summary')
        print('FAQ GLS START mode=' + mode + ' output=' + str(flow.folder), flush=True)
        log = flow.job('simulation', [ms / 'vsim.exe', '-batch', '-t', '1ps', 'work.tb_faq_gls',
                                    '-wlf', 'simulation.wlf', '-do', 'do run.do'],
                       5400 if mode == 'rtl' else 8 * 3600)
        flow.result['simulation_diagnostics'] = diagnostics(log)
        rows = re.findall(r'\[RESULT\] tb_faq_gls (PASS|FAIL) checks=(\d+) errors=(\d+) deliveries=(\d+) frames_a=(\d+) frames_b=(\d+) duplicates=(\d+)', log)
        flow.result['results'] = rows
        if (len(rows) != 1 or rows[0][0] != 'PASS' or int(rows[0][1]) < 1000 or
                rows[0][2:] != ('0', '3', '4', '4', '4') or
                any(flow.result['simulation_diagnostics'].values()) or 'RAMCOLL' in log):
            raise RuntimeError('Missing complete diagnostic-free HDL PASS/X/liveness evidence')
        flow.result['independent_check'] = check_capture(flow.folder)
        verify_prepared(prepared)
        flow.result.update(passed=True, capture_sha256={n: eda.sha(flow.folder / n) for n in CAPTURES})
        print('FAQ GLS PASS mode=' + mode + ' output=' + str(flow.folder), flush=True)
        return flow.folder
    except Exception as error:
        flow.result.update(passed=False, error=str(error))
        for stage in ('compile', 'simulation'):
            path = flow.folder / (stage + '.log')
            if path.exists():
                flow.result[stage + '_diagnostics'] = diagnostics(path.read_text(encoding='utf-8-sig', errors='replace'))
        raise
    finally:
        eda.save(flow.folder / 'input_manifest.json', copied)
        eda.save(flow.folder / 'modelsim_adaptations.json', adaptations)
        flow.finish()


def wait_driver(pid, created):
    try:
        p = eda.psutil.Process(pid)
    except eda.psutil.NoSuchProcess:
        return
    if p.create_time() != created or not any(a.replace('\\', '/').endswith('.scratch/report-verification/run_netlist_verification.py') for a in p.cmdline()):
        raise RuntimeError('Existing NET driver identity does not match queue barrier')
    print('FAQ GLS WAIT existing NET driver pid=' + str(pid), flush=True)
    p.wait(timeout=24 * 3600)
    print('FAQ GLS barrier released; existing NET driver ended (not a claim of NET PASS)', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'rtl', 'gate', 'check'))
    parser.add_argument('--dir', type=Path, required=True)
    parser.add_argument('--rtl-reference', type=Path)
    parser.add_argument('--wait-net-driver', type=int)
    parser.add_argument('--wait-created', type=float)
    args = parser.parse_args()
    folder = args.dir.resolve()
    if args.command == 'prepare':
        prepare(folder)
        return 0
    if args.command == 'check':
        check_capture(folder)
        print('FAQ GLS INDEPENDENT PASS ' + str(folder))
        return 0
    # Defaults protect a new native RTL slot; gate mode may need the measured
    # 10 GiB budget already used by the original single gate-level queue.
    os.environ.setdefault('AFDX_MEM_LIMIT_GB', '1' if args.command == 'rtl' else '10')
    os.environ.setdefault('AFDX_MEM_FLOOR_GB', '5')
    eda.MEMORY_LIMIT = eda.memory_bytes('AFDX_MEM_LIMIT_GB', 1 if args.command == 'rtl' else 10)
    eda.MEMORY_FLOOR = eda.memory_bytes('AFDX_MEM_FLOOR_GB', 5)
    if args.command == 'gate':
        if not args.rtl_reference:
            parser.error('gate requires a passing same-prepared RTL reference')
        reference = args.rtl_reference.resolve()
        summary = json.loads((reference / 'summary.json').read_text(encoding='utf-8'))
        if not summary.get('passed') or summary.get('mode') != 'rtl' or Path(summary['prepared']).resolve() != folder:
            raise RuntimeError('Invalid same-input RTL reference')
        verify_prepared(folder)
        check_capture(reference)
        if args.wait_net_driver is not None:
            if args.wait_created is None:
                parser.error('queue barrier needs PID creation time')
            wait_driver(args.wait_net_driver, args.wait_created)
        deadline = (datetime.now().astimezone() + timedelta(hours=9)).isoformat()
        gate = run_case(folder, 'gate', deadline)
        equality = {name: (reference / name).read_bytes() == (gate / name).read_bytes() for name in CAPTURES}
        result = dict(passed=all(equality.values()), rtl=str(reference), gate=str(gate),
                      exact_external_records=equality, prepared=str(folder))
        eda.save(gate / 'same_run_equivalence.json', result)
        eda.save(folder / 'equivalence.json', result)
        if not result['passed']:
            raise RuntimeError('Gate and same-stimulus RTL external captures differ')
        print('FAQ GLS SAME-INPUT RTL/VQM PASS ' + str(gate), flush=True)
    else:
        deadline = (datetime.now().astimezone() + timedelta(hours=2)).isoformat()
        reference = run_case(folder, 'rtl', deadline)
        eda.save(folder / 'rtl_reference.json', dict(passed=True, folder=str(reference)))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print('FAQ GLS ENTRY FAIL: ' + str(error), flush=True)
        raise SystemExit(1)
