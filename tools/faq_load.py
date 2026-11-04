"""Bounded, independently checked FAQ sustained-load experiments.

prepare and selftest never execute HDL. Each run consumes one parent-assigned
simulator slot and reuses the byte-bound tb_fragmentation executable. All
single-configuration cases have 16 ms warmup, >=100 ms measurement, and 12 ms
continued injection; completion/drain is recorded separately. These are explicit
admissible network plans, not a claim that all hardware capacity maxima can be
multiplied together. Verilator supplies two-state RTL evidence, not X/GLS proof.
"""
import argparse
from collections import defaultdict, deque
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import sys
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import fragment_ref as ref

DEFAULT_SOURCE = ROOT / 'out/open_verilator/20261103_162731_314847/tb_fragmentation'
CASES = ('short128', 'mixed128', 'long128')
CAPACITY = 65536
CYCLES_PER_MS = 125000
WARM = 16 * CYCLES_PER_MS
WINDOW = 100 * CYCLES_PER_MS
INJECT_END = 128 * CYCLES_PER_MS
CAPTURES = ('tx_messages.txt', 'rx.txt', 'tx_a.txt', 'tx_b.txt', 'events.txt')
ANALYSIS = ('tools/faq_load.py', 'tools/fragment_ref.py', 'tools/process_guard.py',
            'tools/verilator_build.py', 'hardware_spec.yaml', 'hardware_contract.yaml')


def stamp():
    return datetime.now().strftime('%Y%m%d_%H%M%S_%f')


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def rows(path):
    with path.open(encoding='ascii') as stream:
        for line in stream:
            if line.strip():
                yield line.split()


def require(ok, label):
    if not ok:
        raise ValueError(label)


def binary_identity(source):
    """Bind actual Verilator S inputs, including its isolated fatal adaptation."""
    source = source.resolve()
    build_path = source / 'build.json'
    build = json.loads(build_path.read_text(encoding='utf-8'))
    require(build['top'] == 'tb_fragmentation' and build['parameters'] == [],
            'Expected default-capacity tb_fragmentation build')
    command = build['commands'][0]
    require('-DAFDX_CE_DIV=2' in command and '--timing' in command and '--assert' in command,
            'Missing known CE2/timing/assert build settings')
    depfile = source / 'obj/Vsim__verFiles.dat'
    batch = source.parent
    dependencies = []
    for line in depfile.read_text(encoding='utf-8').splitlines():
        match = re.match(r'^S\s+.*"([^"]+)"$', line)
        if not match:
            continue
        compiled = Path(match[1])
        try:
            relative = compiled.relative_to(batch / 'sources')
        except ValueError:
            require(compiled.name in ('verilator', 'verilator.exe'),
                    'Unexpected external S dependency: ' + str(compiled))
            continue
        require(relative.suffix in ('.v', '.vh') and relative.parts[0] in ('rtl', 'tb'),
                'Unexpected HDL dependency: ' + str(relative))
        original, current = batch / 'originals' / relative, ROOT / relative
        require(original.read_bytes() == current.read_bytes(),
                'Compiled original differs from current source: ' + str(relative))
        # The existing builder normalizes text and replaces only this assertion
        # exit in these dependencies. No task/fork/include adaptation is needed
        # by tb_fragmentation. Reject any other compiled-source transformation.
        adapted = original.read_text(encoding='utf-8-sig').replace('$finish_and_return(1)', '$fatal(1)')
        require(compiled.read_text(encoding='utf-8') == adapted,
                'Unexplained actual compiled-source transformation: ' + str(relative))
        dependencies.append(dict(path=relative.as_posix(), sha256=digest(current),
                                 compiled_path=str(compiled), compiled_sha256=digest(compiled)))
    paths = {r['path'] for r in dependencies}
    rtl = {p.relative_to(ROOT).as_posix() for p in (ROOT / 'rtl').glob('*.v')}
    require(paths == rtl | {'tb/tb_fragmentation.v'}, 'Incomplete actual RTL/TB S dependency set')
    executable = source / 'simulation.exe'
    require(Path(build['executable']).resolve() == executable.resolve(), 'Build executable path mismatch')
    return dict(source=str(source), executable=str(executable), executable_sha256=digest(executable),
                build_sha256=digest(build_path), dependency_manifest_sha256=digest(depfile),
                dependencies=sorted(dependencies, key=lambda r: r['path']), ce_div=2,
                transformation='UTF-8/newline normalization and finish_and_return(1) -> fatal(1) only')


def payload_bank():
    return b''.join(hashlib.sha256(b'AFDX FAQ load seed 20261103:' + struct.pack('!I', i)).digest()
                    for i in range(CAPACITY // 32))


def occupancy(intervals, capacity):
    """Weighted half-open reservations, end-before-start at coincident edges."""
    edges = []
    for record in intervals:
        require(record['last'] > record['first'], 'Invalid storage reservation lifetime')
        edges.extend(((record['first'], record['units'], record['index']),
                      (record['last'], -record['units'], record['index'])))
    current, peak, witness = 0, 0, None
    active = set()
    for cycle, change, index in sorted(edges):
        current += change
        if change > 0:
            active.add(index)
        else:
            active.remove(index)
        require(current >= 0, 'Negative independent storage reservation count')
        if current > peak:
            peak = current
            witness = dict(cycle=cycle, units=peak, messages=sorted(active))
    require(current == 0 and not active, 'Unreleased independent storage reservations')
    return dict(peak=peak, capacity=capacity, margin=capacity-peak, fits=peak <= capacity, peak_witness=witness)


def planned_storage(case, configs, schedule):
    # These are declared case-planning hypotheses, subsequently checked from
    # public pins. They are neither the official 2ms criterion nor an invented
    # long-message completion gate. Page residence uses whole messages despite
    # actual page-by-page reclamation, so it overcounts real allocation.
    first_frame_budget = 25000  # 200us, leaving app conservative-ready headroom.
    app = [dict(first=m['due']+2, last=m['due']+2+first_frame_budget+16,
                units=m['n']+2, index=m['index']) for m in schedule]
    app_bound = occupancy(app, 32768)
    short_hold = 250000+64 if case == 'mixed128' else first_frame_budget+1526+64
    pages = [dict(first=m['due']+2, last=m['due']+2+short_hold,
                  units=(m['n']+511)//512, index=m['index']) for m in schedule if m['n'] <= 1471]
    short_pages = occupancy(pages, 256)
    long_residence_budget = 750000 if case == 'long128' else None  # 6ms page-residence planning bound, not official long latency.
    if case == 'long128':
        long_intervals = [dict(first=m['due']+2, last=m['due']+2+long_residence_budget+64,
                               units=16, index=m['index']) for m in schedule]
        long_pages = occupancy(long_intervals, 256)['peak']
    else:
        long_pages = sum((c['max_application_payload']+511)//512 for c in configs if c['max_application_payload'] > 1471)
    total = short_pages['peak']+long_pages
    require(total <= 256 and app_bound['peak'] <= 24576, 'Preflight transient storage exceeds pool or conservative-ready allowance')
    return dict(tx_page_bytes=512, tx_pool_pages=256, tx_pool_bytes=131072,
                application_ring_bytes=32768, app_conservative_ready_used_limit=24576,
                first_frame_from_public_first_budget_cycles=first_frame_budget,
                app_retirement_guard_cycles=16, page_return_guard_cycles=64,
                planned_app_tx_byte_envelope=app_bound, short_full_message_page_envelope=short_pages,
                planned_long_page_envelope=long_pages,
                long_page_residence_budget_cycles=long_residence_budget,
                planned_total_page_upper_bound=total, planned_page_margin=256-total,
                page_assumptions='A/B: all short pages reserved until stated lifetime; one full 16-page message per long VL. C: whole messages reserved for a declared 6ms page-residence budget+64 cycles, verified against captured EOF; this is resource-plan safety, not an official long completion limit.',
                app_assumptions='Reserve n+2 bytes from public first-valid until first GMII SOF+16; require first SOF within declared 200us case-planning budget.',
                return_guard_basis='Normal valid traffic has no rollback; page-return FIFO, ret_valid and free-ret1 pending retire long before 64 clocks after final GMII EOF (afdx_tx_builder.v:162-174,374-404; afdx_tx_free.v:48-56,113-133).',
                interpretation='Conservative scenario storage envelopes, not internal counter measurements or official latency formulae.')


def make_plan(case):
    require(case in CASES, 'Unknown FAQ load case')
    WARM = 16 * CYCLES_PER_MS
    WINDOW = (128 if case == 'long128' else 100) * CYCLES_PER_MS
    INJECT_END = WARM + WINDOW + 12 * CYCLES_PER_MS
    bank = payload_bank()
    configs, schedule = [], []
    for index in range(128):
        long = case == 'long128' or (case == 'mixed128' and index >= 124)
        n = 8192 if long else 1471
        bag = 125000 if long else 250000
        period = 8000000 if case == 'long128' else (1000000 if long else (250000 if case == 'short128' else 500000))
        if case == 'long128':
            phase = index * 62500
        elif case == 'short128':
            phase = index * period // 128
        elif long:
            phase = (index - 124) * 250000
        else:
            # Reserve [0,8194+setup] of each millisecond for a possible long
            # input; 31 shorts occupy disjoint slots thereafter. Four long VLs
            # are separated by 2ms and never require 16 simultaneous 8KiB jobs.
            phase = (index // 31) * 125000 + 12000 + (index % 31) * 3500
        cfg = dict(index=index, vl=0x100 + index, bag_cycles=bag, bag_us=bag // 125,
                   lmax=1471, max_application_payload=n, period_cycles=period,
                   phase_cycles=phase, sport=1000, dport=2000,
                   src=0x0a000101 + index, dst=0xe0e00000 | (0x100 + index))
        configs.append(cfg)
        for repeat, due in enumerate(range(phase, INJECT_END, period)):
            offset = (index * 13007 + repeat * 7919) % (CAPACITY - n + 1)
            schedule.append(dict(due=due, vl=cfg['vl'], n=n, offset=offset, repeat=repeat))
    schedule.sort(key=lambda m: (m['due'], m['vl']))
    for index, m in enumerate(schedule):
        m['index'] = index
    files = {
        'config.txt': str(len(configs)) + '\n' + ''.join(
            f"{c['vl']} {c['bag_us']} {c['lmax']} {c['sport']} {c['dport']}\n" for c in configs),
        'schedule.txt': f'{len(schedule)} {len(bank)} {len(schedule)}\n' + ''.join(
            f"{m['due']} {m['vl']} {m['n']} {m['offset']}\n" for m in schedule),
        'payload.hex': ''.join(f'{b:02x}\n' for b in bank),
        'injection.txt': '0 0\n',
        'window.txt': f'{WARM} {WARM + WINDOW}\n',
    }
    # All intended inputs fit without TB serialization moving their phase.
    require(all(b['due'] - a['due'] >= a['n'] + 4 for a, b in zip(schedule, schedule[1:])),
            'Planned application streams overlap')
    for cfg in configs:
        ms = [m for m in schedule if m['vl'] == cfg['vl']]
        require(len(ms) >= 2 and max(m['n'] for m in ms) == cfg['max_application_payload'],
                'Per-VL repeated maximum-payload coverage')
        require(sum(WARM <= m['due'] < WARM + WINDOW for m in ms) >= (2 if case == 'long128' else 12),
                'Per-VL full-window repeated samples')
        require(cfg['period_cycles'] >= (6 if cfg['max_application_payload'] > 1471 else 1) * cfg['bag_cycles'],
                'Long datagram recurrence must clear all per-fragment BAG slots')
    wire_cycles = sum(sum(len(f) + 8 + 12 for f in golden_frames(
        bank[:c['max_application_payload']], c, 0, 0, 'a')) / c['period_cycles'] for c in configs)
    require(wire_cycles < 1, 'Inadmissible planned 1Gbps wire load')
    metadata = dict(case=case, directions=1, endpoints=2, networks='AB', active_tx_vls=128,
                    long_vls=sum(c['max_application_payload'] > 1471 for c in configs),
                    configured_max_reassembly_contexts=16, maximum_concurrent_long_datagrams=16,
                    warmup_cycles=WARM, measurement_cycles=WINDOW, measurement_ms=WINDOW // CYCLES_PER_MS,
                    continued_injection_after_measurement_cycles=INJECT_END - WARM - WINDOW,
                    injection_end_relative=INJECT_END, messages=len(schedule),
                    physical_frames_per_network=sum(6 if m['n'] > 1471 else 1 for m in schedule),
                    payload_bank_bytes=len(bank), payload_bytes_offered=sum(m['n'] for m in schedule),
                    planned_payload_mbps=sum(c['max_application_payload'] * 1000 / c['period_cycles'] for c in configs),
                    planned_wire_mbps_including_preamble_ifg=wire_cycles * 1000,
                    configured_vls=configs, transient_storage=planned_storage(case, configs, schedule),
                    arrival_contract='One deterministic periodic stream per VL; no overlapping input slots; public first valid is due+epoch+2.',
                    timing_contract='Short public-first-valid to public-last-byte <=2ms; long completion raw and separate.',
                    jitter_contract='Raw range by VL and payload. Internal <=50us and official <100us comparisons are separate; no unconditional BAG subtraction or negative clamping.',
                    event_observability=dict(captured='TX rejects, source app rejects/overflow, destination network errors and RM duplicate pulses',
                                             not_captured='Destination ev_app overflow pin is not logged by the existing executable; any lost/truncated/corrupt output still fails exact delivery checking.'),
                    scope='Explicit normal network plan; no claim of arbitrary overload, bidirectional traffic, four-state X, or full-top VQM coverage.')
    return configs, schedule, bank, files, metadata


def golden_frames(payload, cfg, ident, sn, net):
    frames = ref.build(payload, vlid=cfg['vl'], ident=ident, sn=sn, lmax=cfg['lmax'],
                       net=net.upper(), src=cfg['src'], dst=cfg['dst'],
                       sport=cfg['sport'], dport=cfg['dport'], udp_checksum=False)
    result = []
    for frame in frames:
        body = bytearray(frame[:-4])
        body[9:11] = b'\0\0'  # Known power-on user_id=0, not ref.build's user_id=1.
        result.append(bytes(body) + struct.pack('<I', zlib.crc32(body)))
    return result


def prepare(case, source, folder):
    identity = binary_identity(source)
    configs, schedule, bank, files, metadata = make_plan(case)
    folder.mkdir(parents=True, exist_ok=False)
    vectors = folder / 'vectors'
    vectors.mkdir()
    for name, text in files.items():
        (vectors / name).write_text(text, encoding='ascii')
    analysis = []
    for rel in ANALYSIS:
        dst = folder / 'analysis_sources' / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / rel, dst)
        analysis.append(dict(path=rel, sha256=digest(ROOT / rel)))
    for row in identity['dependencies']:
        dst = folder / 'originals' / row['path']
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / row['path'], dst)
    manifest = dict(test='faq_load', created=datetime.now().astimezone().isoformat(),
                    status='prepared_not_simulated', seed=20261103, metadata=metadata,
                    binary_identity=identity, analysis_sources=analysis,
                    vectors={name: digest(vectors / name) for name in files},
                    requirements=[
                        dict(id='continuous100ms', state='implemented', checker='one immutable configuration, epoch-relative 100ms window and every-VL recurrence'),
                        dict(id='max_payload_each_vl', state='implemented', checker='independent periodic schedule and complete source-byte delivery ledger'),
                        dict(id='wire', state='implemented', checker='exact independent IPv4/UDP/offset/MF/ID/SN/FCS and A/B frame matrix, BAG and context occupancy'),
                        dict(id='integrity', state='implemented', checker='complete once-only delivery, zero abnormal events, exact redundancy count'),
                        dict(id='timing', state='implemented', checker='public first-valid to last-byte, first-frame witnesses, raw and remaining-BAG statistics')])
    save(folder / 'faq_manifest.json', manifest)
    verify_prepared(folder, 'prepare')
    return manifest


def verify_prepared(folder, phase):
    manifest = json.loads((folder / 'faq_manifest.json').read_text(encoding='utf-8'))
    failures = []
    try:
        require(manifest['test'] == 'faq_load', 'Wrong manifest kind')
        require(binary_identity(Path(manifest['binary_identity']['source'])) == manifest['binary_identity'],
                'Executable/build/actual S dependency identity changed')
        for row in manifest['binary_identity']['dependencies']:
            require(digest(folder / 'originals' / row['path']) == row['sha256'], 'Prepared HDL snapshot drift: ' + row['path'])
        for row in manifest['analysis_sources']:
            require(digest(ROOT / row['path']) == row['sha256'] and
                    digest(folder / 'analysis_sources' / row['path']) == row['sha256'],
                    'Checker/spec/contract source drift: ' + row['path'])
        _, _, _, files, metadata = make_plan(manifest['metadata']['case'])
        require(metadata == manifest['metadata'], 'Independently reconstructed plan differs')
        require(set(p.name for p in (folder / 'vectors').iterdir()) == set(files), 'Unexpected or missing vector file')
        for name, text in files.items():
            require((folder / 'vectors' / name).read_text(encoding='ascii') == text and
                    digest(folder / 'vectors' / name) == manifest['vectors'][name], 'Input plan/bytes drift: ' + name)
    except Exception as exc:
        failures.append(str(exc))
    records = folder / 'identity'
    records.mkdir(exist_ok=True)
    save(records / (stamp() + '_' + phase + '.json'), dict(phase=phase, passed=not failures, failures=failures))
    require(not failures, '; '.join(failures))
    return manifest


def stats(samples):
    if not samples:
        return dict(samples=0, min_cycles=None, max_cycles=None, range_cycles=None)
    minimum = min(samples, key=lambda s: s['cycles'])
    maximum = max(samples, key=lambda s: s['cycles'])
    return dict(samples=len(samples), min_cycles=minimum['cycles'], max_cycles=maximum['cycles'],
                range_cycles=maximum['cycles'] - minimum['cycles'], min_witness=minimum, max_witness=maximum)


def overlap(first, stop, begin, end):
    return max(0, min(stop, end) - max(first, begin))


def check_capture(folder, case):
    """Expected messages and bytes come only from make_plan, never DUT outcomes."""
    configs, schedule, bank, _, metadata = make_plan(case)
    WARM, WINDOW, INJECT_END = metadata['warmup_cycles'], metadata['measurement_cycles'], metadata['injection_end_relative']
    by_vl = {c['vl']: c for c in configs}
    checks, failures = 0, []

    def expect(ok, label):
        nonlocal checks
        checks += 1
        if not ok:
            raise ValueError(label)

    txrows = list(rows(folder / 'tx_messages.txt'))
    expect(bool(txrows) and txrows[0][0] == 'E' and len(txrows[0]) == 2, 'One initial public schedule epoch')
    epoch = int(txrows[0][1])
    expect(len(txrows) == len(schedule) + 1, 'All planned public TX messages recorded exactly once')
    begin, end = epoch + WARM, epoch + WARM + WINDOW
    inputs, rx_by_vl = {}, defaultdict(deque)
    for planned, row in zip(schedule, txrows[1:]):
        expect(len(row) == 4, 'Public input record shape')
        first, last, vl, n = map(int, row)
        i = planned['index']
        expect((vl, n) == (planned['vl'], planned['n']), f'Input VL/length/order {i}')
        expect(first == epoch + planned['due'] + 2, f'Input exact periodic phase/no ready delay {i}')
        expect(last - first + 1 == n + 2, f'Continuous VLID+payload input {i}')
        inputs[i] = dict(first=first, last=last, planned=planned)
        rx_by_vl[vl].append(i)
    expect(min(m['first'] for m in inputs.values()) < begin and max(m['first'] for m in inputs.values()) >= end,
           'Actual public input spans the complete 100ms window')
    deliveries = {}
    previous_rx_end = -1
    for row in rows(folder / 'rx.txt'):
        expect(len(row) == 4, 'Public output record shape')
        first, last = int(row[0]), int(row[1])
        raw = bytes.fromhex(row[2] + row[3])
        expect(len(raw) >= 3 and last - first + 1 == len(raw), 'Complete continuous public output')
        vl = int.from_bytes(raw[:2], 'big')
        expect(vl in by_vl and bool(rx_by_vl[vl]), 'No unknown/extra/duplicate delivery')
        i = rx_by_vl[vl].popleft()
        p = schedule[i]
        expect(raw[2:] == bank[p['offset']:p['offset'] + p['n']], f'Exact full source bytes/order {i}')
        expect(first > previous_rx_end, 'No overlapping public outputs')
        previous_rx_end = last
        value = last - inputs[i]['first']
        expect(value > 0, f'Delivery follows its public input {i}')
        if p['n'] <= 1471:
            expect(value <= 250000, f'All-message short public first-valid -> last-byte <=2ms {i}')
        deliveries[i] = dict(first=first, last=last, cycles=value, index=i, vl=vl, n=p['n'])
    expect(not any(rx_by_vl.values()) and len(deliveries) == len(schedule), 'Every input delivered exactly once')
    expect(min(d['first'] for d in deliveries.values()) < begin and max(d['last'] for d in deliveries.values()) >= end,
           'Actual deliveries span complete 100ms window')

    wire_metrics, first_wire, final_wire = {}, {}, {}
    trace_a = None
    for net in ('a', 'b'):
        expected = defaultdict(deque)
        for p in schedule:
            expected[p['vl']].append(p['index'])
        state, sn, previous = {}, defaultdict(int), {}
        ident = 0
        trace, intervals = [], []
        contexts, peak_contexts, context_ranges = {}, 0, []
        previous_global_end = -13
        wire_bytes = 0
        frame_count = 0
        for row in rows(folder / ('tx_' + net + '.txt')):
            expect(len(row) == 2, 'GMII capture shape')
            t, wire = int(row[0]), bytes.fromhex(row[1])
            expect(wire.startswith(ref.PREAMBLE), 'Exact preamble and SFD')
            f = ref.decode(wire)  # Independent checksum/FCS/header validation.
            vl = f['vlid']
            expect(vl in by_vl, 'Configured VL on wire')
            expect(t >= previous_global_end + 13, 'Physical frame IFG >=12 cycles')
            previous_global_end = t + len(wire) - 1
            if vl not in state:
                expect(bool(expected[vl]), 'No extra wire datagram')
                i = expected[vl][0]
                p = schedule[i]
                fs = golden_frames(bank[p['offset']:p['offset'] + p['n']], by_vl[vl], ident, sn[vl], net)
                state[vl] = dict(index=i, frames=fs, fragment=0, ident=ident, first=t)
                ident = (ident + 1) & 65535
                expect(t > inputs[i]['last'], f'Wire frame follows complete public input {i}')
                if net == 'a':
                    prior = previous.get(vl)
                    deadline = prior + by_vl[vl]['bag_cycles'] if prior is not None else None
                    remaining = deadline - inputs[i]['last'] if deadline is not None and deadline > inputs[i]['last'] else 0
                    first_wire[i] = dict(start=t, previous_frame_start=prior, eligibility_deadline=deadline,
                                         remaining_from_public_input_end=remaining, first_after_reset=prior is None)
                if p['n'] > 1471:
                    expect(vl not in contexts, 'At most one incomplete long datagram per VL')
                    contexts[vl] = (i, t)
                    peak_contexts = max(peak_contexts, len(contexts))
                    expect(len(contexts) <= 16, 'No more than 16 concurrent reassembly contexts')
            s = state[vl]
            pos = s['fragment']
            expect(wire == ref.PREAMBLE + s['frames'][pos],
                   f'Exact expected Ethernet/IP/UDP/payload/ID/SN/offset/MF/FCS {net}/{s["index"]}/{pos}')
            if vl in previous:
                delta = t - previous[vl]
                expect(delta >= by_vl[vl]['bag_cycles'], f'Per-fragment BAG {net}/{vl:04x}')
                intervals.append(dict(cycles=delta - by_vl[vl]['bag_cycles'], vl=vl,
                                      previous_start=previous[vl], start=t, index=s['index']))
            previous[vl] = t
            trace.append((s['index'], pos, t, f['ident'], f['sn']))
            sn[vl] = 1 if sn[vl] == 255 else sn[vl] + 1
            s['fragment'] += 1
            wire_bytes += overlap(t, t + len(wire), begin, end)
            frame_count += 1
            if s['fragment'] == len(s['frames']):
                if net == 'a':
                    final_wire[s['index']] = dict(start=t, end=previous_global_end)
                if vl in contexts:
                    i, start = contexts.pop(vl)
                    context_ranges.append(dict(index=i, first=start, last=previous_global_end))
                expect(deliveries[s['index']]['first'] > previous_global_end,
                       'Public delivery follows final complete GMII frame')
                expected[vl].popleft()
                del state[vl]
        expect(not state and not contexts and not any(expected.values()), 'No missing or incomplete wire messages')
        expect(frame_count == metadata['physical_frames_per_network'], 'Exact independent frame count')
        if net == 'a':
            trace_a = trace
        else:
            expect(trace == trace_a, 'A/B identical datagram/fragment/ID/SN matrix and simultaneous starts')
        wire_metrics[net] = dict(frames=frame_count, first_cycle=trace[0][2], last_cycle=previous_global_end,
                                 observed_window_wire_mbps=wire_bytes * 1000 / WINDOW,
                                 interval_minus_fragment_BAG=stats(intervals),
                                 peak_incomplete_long_datagrams=peak_contexts,
                                 long_context_intervals=context_ranges)

    resource_plan = metadata['transient_storage']
    app_reservations, rx_reservations, page_reservations = [], [], []
    same_vl_inputs = defaultdict(list)
    for i, source in inputs.items():
        p = source['planned']
        expect(first_wire[i]['start'] - source['first'] <= resource_plan['first_frame_from_public_first_budget_cycles'],
               f'Declared 200us first-SOF service assumption for safe app transient storage {i}')
        app_reservations.append(dict(index=i, first=source['first'], last=first_wire[i]['start']+16, units=p['n']+2))
        page_reservations.append(dict(index=i, first=source['first'], last=final_wire[i]['end']+65, units=(p['n']+511)//512))
        rx_reservations.append(dict(index=i, first=final_wire[i]['start'], last=deliveries[i]['last']+1, units=p['n']+2))
        if resource_plan['long_page_residence_budget_cycles'] is not None:
            expect(final_wire[i]['end'] - source['first'] <= resource_plan['long_page_residence_budget_cycles'],
                   f'Declared C 6ms whole-message page-residence planning bound {i}')
        same_vl_inputs[p['vl']].append(i)
    for vl, ids in same_vl_inputs.items():
        if by_vl[vl]['max_application_payload'] > 1471:
            for a, b in zip(ids, ids[1:]):
                expect(final_wire[a]['end']+64 < inputs[b]['first'],
                       f'One outstanding long datagram per VL, including page-return guard {vl:04x}')
    observed_storage = dict(tx_page_envelope=occupancy(page_reservations, 256),
                            app_tx_byte_envelope=occupancy(app_reservations, 32768),
                            app_rx_byte_envelope=occupancy(rx_reservations, 32768),
                            planning_assumptions=resource_plan,
                            interpretation='Conservative complete-message reservations from public pins; not DUT allocation/admission observations.')
    expect(observed_storage['tx_page_envelope']['fits'], 'Observed conservative TX page envelope <=128KiB/256 pages')
    expect(observed_storage['app_tx_byte_envelope']['peak'] <= 24576,
           'Observed conservative TX app envelope below 32KiB and conservative-ready limit')
    expect(observed_storage['app_rx_byte_envelope']['fits'], 'Observed conservative RX app envelope <=32KiB')

    finals, redundant = [], 0
    event_first = event_last = None
    for row in rows(folder / 'events.txt'):
        if row[0] == 'FINAL':
            expect(len(row) == 4, 'Final event counters shape')
            finals.append(tuple(map(int, row[1:])))
            continue
        expect(not finals and len(row) == 6, 'Ordered event capture shape')
        t = int(row[0])
        tx, a, b, app, rm = (int(v, 16) for v in row[1:])
        expect(not (tx & 0x1e) and not (a & 0xfe) and not (b & 0xfe) and app == 0,
               f'No TX/RX/application rejection, overflow or abnormal event at {t}')
        expect(rm in (0, 1), 'Redundancy pulse is Boolean')
        redundant += rm
        event_first = t if event_first is None else event_first
        event_last = t
    expect(finals == [(len(schedule), 0, 0)], 'Final delivery count and zero long/application drops')
    expect(redundant == metadata['physical_frames_per_network'], 'Exactly one A/B duplicate rejection per physical frame')

    grouped = defaultdict(list)
    for i, d in deliveries.items():
        grouped[d['vl'], d['n']].append(d)
    group_metrics = []
    short_groups, long_groups = [], []
    internal_ok, raw100_ok = True, True
    for (vl, n), ds in sorted(grouped.items()):
        ds.sort(key=lambda d: d['index'])
        measured = [d for d in ds if begin <= inputs[d['index']]['first'] < end]
        raw, measured_raw = stats(ds), stats(measured)
        cfg = by_vl[vl]
        expect(n == cfg['max_application_payload'] and len(measured) >= (2 if case == 'long128' else 12),
               f'Each VL repeated declared maximum payload throughout window {vl:04x}')
        output_in_window = [d for d in ds if begin <= d['last'] < end]
        wire_in_window = [d for d in ds if begin <= first_wire[d['index']]['start'] < end]
        minimum_window_count = 2 if case == 'long128' else WINDOW // cfg['period_cycles'] - 1
        expect(len(output_in_window) >= minimum_window_count and len(wire_in_window) >= minimum_window_count,
               f'Every VL has sustained wire transmission and delivery within the full measurement window {vl:04x}')
        input_intervals = [dict(index=b['index'], cycles=inputs[b['index']]['first'] - inputs[a['index']]['first'])
                           for a, b in zip(ds, ds[1:])]
        wire_first_intervals = [dict(index=b['index'], cycles=first_wire[b['index']]['start'] - first_wire[a['index']]['start'])
                                for a, b in zip(ds, ds[1:])]
        output_intervals = [dict(index=b['index'], cycles=b['last'] - a['last']) for a, b in zip(ds, ds[1:])]
        expect(all(v['cycles'] == cfg['period_cycles'] for v in input_intervals), 'Actual per-VL periodic source recurrence')
        first = ds[0]
        witness = first_wire[first['index']]
        expect(witness['first_after_reset'] and witness['remaining_from_public_input_end'] == 0,
               'True first frame has no prior same-VL BAG deadline')
        adjusted = [dict(index=d['index'], vl=vl, n=n,
                         cycles=d['cycles'] - first_wire[d['index']]['remaining_from_public_input_end']) for d in ds]
        project50 = raw['range_cycles'] <= 6250
        compare100 = raw['range_cycles'] < 12500
        # Long message completion and its variation are informational; the
        # ordinary short-message thresholds are not imposed on fragmented data.
        if n <= 1471:
            internal_ok = internal_ok and project50
            raw100_ok = raw100_ok and compare100
            expect(compare100, f'Short same-VL/same-Payload raw range <100us comparison {vl:04x}')
        group = dict(vl=vl, payload_bytes=n, configured_max_payload=cfg['max_application_payload'],
                     message_period_cycles=cfg['period_cycles'], fragment_BAG_cycles=cfg['bag_cycles'],
                     all_messages=raw, measurement_messages=measured_raw,
                     output_messages_ending_in_window=len(output_in_window), first_fragments_in_window=len(wire_in_window),
                     actual_input_intervals=stats(input_intervals), actual_first_fragment_intervals=stats(wire_first_intervals),
                     actual_output_intervals=stats(output_intervals),
                     true_first_message=first, first_frame_BAG=witness,
                     raw_min_is_true_first=raw['min_cycles'] == first['cycles'],
                     remaining_BAG_removed_from_public_input_end=stats(adjusted),
                     signed_raw_range_minus_full_BAG_cycles=raw['range_cycles'] - cfg['bag_cycles'],
                     internal_50us_raw_comparison=project50, official_100us_raw_comparison=compare100,
                     comparisons_applied_to_acceptance=n <= 1471,
                     no_official_negative_clamp_or_unconditional_BAG_subtraction=True)
        group_metrics.append(group)
        (long_groups if n > 1471 else short_groups).extend(ds)
    expect(len(group_metrics) == 128, 'All 128 active VLs covered')
    regions = {}
    for name, lo, hi in (('warmup', epoch, begin), ('measurement', begin, end),
                         ('continued_injection', end, epoch + INJECT_END)):
        ins = [m for m in inputs.values() if lo <= m['first'] < hi]
        outs = [d for d in deliveries.values() if lo <= d['last'] < hi]
        injection = sum(overlap(m['first'] + 2, m['last'] + 1, lo, hi) for m in inputs.values())
        received = sum(overlap(d['first'] + 2, d['last'] + 1, lo, hi) for d in deliveries.values())
        regions[name] = dict(begin_cycle=lo, end_cycle=hi, cycles=hi - lo,
                             input_messages_starting=len(ins), delivered_messages_ending=len(outs),
                             injected_payload_bytes=injection, delivered_payload_bytes=received,
                             inject_payload_mbps=injection * 1000 / (hi - lo),
                             delivered_payload_mbps=received * 1000 / (hi - lo))
    last_input = max(m['last'] for m in inputs.values())
    last_output = max(d['last'] for d in deliveries.values())
    return dict(passed=True, errors=0, checks=checks, failures=failures, case=case,
                epoch=epoch, configuration_count=1, reset_count=1, window=regions,
                messages=len(schedule), delivered=len(deliveries), redundancy_rejections=redundant,
                public_input_first=min(m['first'] for m in inputs.values()), public_input_last=last_input,
                public_output_first=min(d['first'] for d in deliveries.values()), public_output_last=last_output,
                drain_after_last_public_input_cycles=last_output - last_input,
                drain=dict(begin_cycle=last_input + 1, end_cycle=last_output + 1,
                           cycles=last_output - last_input,
                           subsequent_TB_quiet_cycles=22000,
                           quiet_evidence='Pinned TB waits 2000+20000 cycles after target completion; FINAL row has no cycle timestamp.'),
                captured_event_observability=metadata['event_observability'], transient_storage=observed_storage,
                short_public_completion=stats(short_groups), long_public_completion_informational=stats(long_groups),
                internal_short_50us_target_passed=internal_ok if short_groups else None,
                short_raw_100us_comparison_passed=raw100_ok if short_groups else None,
                official_FAQ_first_frame_BAG_interpretation='raw comparisons and explicit remaining-eligibility statistics; not a claim that range-minus-full-BAG is universally valid',
                groups=group_metrics, wire=wire_metrics, event_first=event_first, event_last=event_last,
                limitations=['Two-state RTL; no X-propagation or VQM evidence.',
                            'One traffic direction with simultaneous A/B redundancy.',
                            'Long completion and long jitter are reported raw without applying ordinary short-message 2ms/100us gates.',
                            'Internal 50us target is reported separately from <100us raw comparison.'])


def hdl_result(folder):
    text = (folder / 'simulation.log').read_text(encoding='utf-8', errors='replace')
    require(re.search(r'\[RESULT\]\s+tb_fragmentation PASS errors=0 deliveries=\d+', text) is not None,
            'Missing real HDL PASS result')
    require(not re.search(r'\[FAIL\]|\bFAIL\b|RAMCOLL|%Error|%Warning|\$stop|Assertion failed', text),
            'HDL failure/assertion/diagnostic in simulation.log')
    return text


def check(folder):
    folder = folder.resolve()
    require((folder / 'run.json').exists(), 'No real run record; synthetic selftest is not HDL evidence')
    attempts = folder / 'checks'
    attempts.mkdir(exist_ok=True)
    output = attempts / stamp()
    output.mkdir()
    try:
        manifest = verify_prepared(folder, 'before_check')
        execution = json.loads((folder / 'run.json').read_text(encoding='utf-8'))
        require(execution['status'] == 'hdl_pass' and execution['returncode'] == 0, 'Run did not complete successfully')
        hdl_result(folder)
        captured = {name: digest(folder / name) for name in (*CAPTURES, 'simulation.log')}
        require(captured == execution['capture_sha256'], 'Real capture changed since execution')
        result = check_capture(folder, manifest['metadata']['case'])
        verify_prepared(folder, 'after_check')
        require(captured == {name: digest(folder / name) for name in captured}, 'Capture changed during analysis')
        result.update(capture_sha256=captured, check_output=str(output), evidence_kind='actual HDL execution',
                      executable_sha256=manifest['binary_identity']['executable_sha256'])
    except Exception as exc:
        result = dict(passed=False, errors=1, failures=[str(exc)], check_output=str(output))
    save(output / 'summary.json', result)
    return result


def run(folder, timeout):
    folder = folder.resolve()
    manifest = verify_prepared(folder, 'before_run')
    require(not any((folder / n).exists() for n in (*CAPTURES, 'simulation.log', 'run.json')),
            'Execution evidence exists; prepare a new isolated run directory')
    execution = dict(status='started', command=[manifest['binary_identity']['executable']],
                     cwd=str(folder), timeout_seconds=timeout, memory_tree_limit_bytes=1024**3,
                     available_memory_floor_bytes=5 * 1024**3, started=datetime.now().astimezone().isoformat())
    save(folder / 'run.json', execution)
    from process_guard import run as guarded_run
    old = {name: os.environ.get(name) for name in ('AFDX_MEM_LIMIT_GB', 'AFDX_MEM_FLOOR_GB')}
    try:
        os.environ['AFDX_MEM_LIMIT_GB'], os.environ['AFDX_MEM_FLOOR_GB'] = '1', '5'
        with (folder / 'simulation.log').open('w', encoding='utf-8') as stream:
            process = guarded_run(execution['command'], cwd=folder, stdout=stream, stderr=-2,
                                  timeout=timeout, metrics=folder / 'simulation.resources.json')
        execution['returncode'] = process.returncode
        require(process.returncode == 0, 'Simulator exit was not zero')
        hdl_result(folder)
        verify_prepared(folder, 'after_run')
        execution.update(status='hdl_pass', capture_sha256={n: digest(folder / n) for n in (*CAPTURES, 'simulation.log')})
    except Exception as exc:
        execution.update(status='failed', failure=str(exc))
        raise
    finally:
        execution['ended'] = datetime.now().astimezone().isoformat()
        save(folder / 'run.json', execution)
        for name, value in old.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
    return check(folder)


def selftest(base):
    """Generate independent ideal traces, then prove corruption is rejected.

    This is deliberately labelled synthetic, never supplied with run.json, and
    cannot enter check() as execution evidence. It neither launches nor mocks HDL.
    """
    import heapq
    base.mkdir(parents=True, exist_ok=False)

    def frame_factory(data, cfg, ident, sn, net):
        # Separate serialization from golden_frames/ref.build: ordinary UDP
        # header, manual IP word sum, Ethernet header and Ethernet CRC.
        udp = struct.pack('!HHHH', 1000, 2000, len(data) + 8, 0) + data
        pos, result = 0, []
        while pos < len(udp):
            count = len(udp) - pos if len(udp) - pos <= 1479 else 1472
            flags = (8192 if pos + count < len(udp) else 0) | (pos // 8)
            ip = bytearray(struct.pack('!BBHHHBBHII', 0x45, 0, count + 20, ident, flags,
                                       1, 17, 0, cfg['src'], cfg['dst']))
            total = sum(int.from_bytes(ip[j:j+2], 'big') for j in range(0, 20, 2))
            while total > 65535:
                total = (total & 65535) + (total >> 16)
            ip[10:12] = struct.pack('!H', total ^ 65535)
            eth = bytes.fromhex('03000000') + struct.pack('!H', cfg['vl'])
            eth += bytes.fromhex('0200000000') + bytes([32 if net == 'a' else 64]) + bytes.fromhex('0800')
            body = eth + ip + udp[pos:pos+count]
            body += bytes(max(0, 59 - len(body))) + bytes([sn])
            result.append(ref.PREAMBLE + body + struct.pack('<I', zlib.crc32(body)))
            sn = 1 if sn == 255 else sn + 1
            pos += count
        return result

    positives = []
    for case in CASES:
        folder = base / case
        folder.mkdir()
        configs, plan, bank, _, _ = make_plan(case)
        cfg = {c['vl']: c for c in configs}
        epoch, tx, pending = 70000, ['E 70000'], []
        for p in plan:
            first = epoch + p['due'] + 2
            tx.append(f"{first} {first+p['n']+1} {p['vl']} {p['n']}")
            heapq.heappush(pending, (first + 2*p['n'] + 128, p['index'], 0))
        (folder / 'tx_messages.txt').write_text('\n'.join(tx) + '\n', encoding='ascii')
        state, sns, previous = {}, defaultdict(int), {}
        ident, free = 0, 0
        wires, complete, event_times = {'a': [], 'b': []}, [], []
        while pending:
            ready, i, fragment = heapq.heappop(pending)
            p = plan[i]
            vl = p['vl']
            eligible = max(ready, previous.get(vl, -cfg[vl]['bag_cycles']) + cfg[vl]['bag_cycles'])
            if eligible > ready:
                heapq.heappush(pending, (eligible, i, fragment))
                continue
            t = max(eligible, free)
            if fragment == 0:
                state[i] = {net: frame_factory(bank[p['offset']:p['offset']+p['n']], cfg[vl], ident, sns[vl], net)
                            for net in ('a', 'b')}
                ident = (ident + 1) & 65535
            for net in ('a', 'b'):
                wires[net].append(f"{t} {state[i][net][fragment].hex()}")
            frame = state[i]['a'][fragment]
            stop = t + len(frame) - 1
            event_times.append(stop + 16)
            previous[vl], free = t, stop + 13
            sns[vl] = 1 if sns[vl] == 255 else sns[vl] + 1
            if fragment + 1 < len(state[i]['a']):
                heapq.heappush(pending, (t + cfg[vl]['bag_cycles'], i, fragment + 1))
            else:
                complete.append((stop + 128, i))
        for net in ('a', 'b'):
            (folder / ('tx_' + net + '.txt')).write_text('\n'.join(wires[net]) + '\n', encoding='ascii')
        output, free = [], 0
        for ready, i in sorted(complete):
            p = plan[i]
            first = max(ready, free)
            last = first + p['n'] + 1
            output.append(f"{first} {last} {p['vl']:04x} {bank[p['offset']:p['offset']+p['n']].hex()}")
            free = last + 2
        (folder / 'rx.txt').write_text('\n'.join(output) + '\n', encoding='ascii')
        events = ''.join(f'{t} 00 00 00 00 1\n' for t in sorted(event_times))
        (folder / 'events.txt').write_text(events + f'FINAL {len(plan)} 0 0\n', encoding='ascii')
        result = check_capture(folder, case)
        save(folder / 'synthetic_positive.json', result)
        positives.append(dict(case=case, checks=result['checks'], messages=result['messages'],
                              internal_50us=result['internal_short_50us_target_passed'],
                              peak_contexts=result['wire']['a']['peak_incomplete_long_datagrams']))
    folder = base / 'mixed128'
    controls = []

    def rejected(label, name, mutate, case='mixed128'):
        path = base / case / name
        original = path.read_bytes()
        try:
            text = mutate(original.decode('ascii').splitlines())
            path.write_text('\n'.join(text) + '\n', encoding='ascii')
            try:
                check_capture(base / case, case)
            except Exception as exc:
                controls.append(dict(label=label, case=case, rejected=True, reason=str(exc)))
            else:
                raise AssertionError('Accepted synthetic corruption: ' + label)
        finally:
            path.write_bytes(original)

    def change_payload(lines):
        fields = lines[0].split()
        fields[3] = ('00' if fields[3][:2] != '00' else '01') + fields[3][2:]
        lines[0] = ' '.join(fields)
        return lines

    def wire_change(lines, kind):
        fields = lines[0].split()
        raw = bytearray.fromhex(fields[1])
        if kind == 'fcs':
            raw[-1] ^= 1
        elif kind == 'id':
            raw[26] ^= 1
        elif kind == 'sn':
            raw[-5] ^= 1
        elif kind == 'offset':
            raw[29] ^= 1
        if kind in ('id', 'offset'):
            raw[32:34] = b'\0\0'
            total = sum(int.from_bytes(raw[j:j+2], 'big') for j in range(22, 42, 2))
            while total > 65535:
                total = (total & 65535) + (total >> 16)
            raw[32:34] = struct.pack('!H', total ^ 65535)
        if kind != 'fcs':
            raw[-4:] = struct.pack('<I', zlib.crc32(raw[8:-4]))
        fields[1] = raw.hex()
        lines[0] = ' '.join(fields)
        return lines

    def move_input(lines):
        fields = lines[1].split()
        fields[0], fields[1] = str(int(fields[0]) + 1), str(int(fields[1]) + 1)
        lines[1] = ' '.join(fields)
        return lines

    def overflow(lines):
        lines[0] = lines[0].replace('00 00 00 00 1', '00 00 00 2 1')
        return lines

    def skew(lines):
        fields = lines[0].split()
        fields[0] = str(int(fields[0]) + 1)
        lines[0] = ' '.join(fields)
        return lines

    def long_short_latency(lines):
        fields = lines[0].split()
        fields[0], fields[1] = str(int(fields[0]) + 250001), str(int(fields[1]) + 250001)
        lines[0] = ' '.join(fields)
        return lines

    rejected('missing_delivery', 'rx.txt', lambda xs: xs[:-1])
    rejected('duplicate_delivery', 'rx.txt', lambda xs: xs + [xs[-1]])
    rejected('wrong_payload', 'rx.txt', change_payload)
    for kind in ('fcs', 'id', 'sn', 'offset'):
        rejected(kind, 'tx_a.txt', lambda xs, k=kind: wire_change(xs, k))
    rejected('input_phase_drift', 'tx_messages.txt', move_input)
    rejected('application_overflow', 'events.txt', overflow)

    def unknown_vl_rejection(lines):
        lines[0] = lines[0].replace('00 00 00 00 1', '00 00 00 1 1')
        return lines

    rejected('source_app_unknown_VL_bit0', 'events.txt', unknown_vl_rejection)
    rejected('missing_AB_rejection', 'events.txt', lambda xs: xs[1:])
    rejected('AB_start_skew', 'tx_b.txt', skew)
    rejected('short_latency', 'rx.txt', long_short_latency)

    def break_BAG(lines):
        fields = lines[128].split()
        fields[0] = str(int(fields[0]) - 1)
        lines[128] = ' '.join(fields)
        return lines

    def break_jitter(lines):
        last_short = max(i for i, line in enumerate(lines) if len(line.split()[3]) == 2942)
        for i in range(last_short, len(lines)):
            fields = lines[i].split()
            fields[0], fields[1] = str(int(fields[0]) + 15000), str(int(fields[1]) + 15000)
            lines[i] = ' '.join(fields)
        return lines

    rejected('BAG_one_cycle_short', 'tx_a.txt', break_BAG, case='short128')
    rejected('raw_short_jitter_100us', 'rx.txt', break_jitter)
    rejected('truncated_wire_capture', 'tx_b.txt', lambda xs: xs[:-1])
    summary = dict(passed=True, evidence_kind='synthetic only; no HDL executed', positives=positives,
                   corruption_controls=controls, output=str(base))
    save(base / 'summary.json', summary)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    prep = sub.add_parser('prepare', help='Generate and identity-check only; never execute HDL')
    prep.add_argument('--case', choices=(*CASES, 'all'), default='all')
    prep.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    prep.add_argument('--out', type=Path)
    for name in ('run', 'check'):
        command = sub.add_parser(name)
        command.add_argument('folder', type=Path)
        if name == 'run':
            command.add_argument('--timeout', type=int, default=1800)
    synthetic = sub.add_parser('selftest', help='Full-size synthetic positive and corruption checks; no HDL')
    synthetic.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.action == 'selftest':
        output = (args.out or ROOT / 'out/faq_load_selftest' / stamp()).resolve()
        print(json.dumps(selftest(output), indent=2))
        return 0
    if args.action == 'prepare':
        base = (args.out or ROOT / 'out/faq_load' / stamp()).resolve()
        chosen = CASES if args.case == 'all' else (args.case,)
        if args.case == 'all':
            base.mkdir(parents=True, exist_ok=False)
        outputs = []
        for case in chosen:
            folder = base / case if args.case == 'all' else base
            manifest = prepare(case, args.source, folder)
            outputs.append(dict(folder=str(folder), status=manifest['status'], metadata=manifest['metadata']))
        print(json.dumps(outputs, indent=2))
        return 0
    result = run(args.folder, args.timeout) if args.action == 'run' else check(args.folder)
    print(json.dumps({k: v for k, v in result.items() if k not in ('groups', 'wire')}, indent=2))
    return int(not result['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
