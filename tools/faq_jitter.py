"""Offline short-message FAQ jitter evidence from an existing fixed capture.

Run with Python -I. No HDL, generators or existing report files are changed.
Raw latency is public application first valid -> public receive last byte.
A VL's first message is tracked over the complete reset epoch, across stages.
BAG diagnostics retain signed due-minus-reference differences; they are not an
asserted official FAQ formula. C1561 supplies no new long-message latency rule.
"""
import argparse
import bisect
import collections
import csv
from datetime import datetime
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CAPTURE = ROOT / 'out/sim/tb_sys_perf/20261103_175508_684130'
CYCLE_NS = 8


def require(ok, text):
    if not ok:
        raise ValueError(text)


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest().upper()


class Inputs:
    def __init__(self):
        self.files = {}

    def bind(self, path):
        path = path.resolve()
        if str(path) not in self.files:
            self.files[str(path)] = dict(path=str(path), bytes=path.stat().st_size,
                                         sha256=digest(path))

    def rows(self, path):
        # Hash the bytes actually parsed, streaming without read_text/splitlines.
        value = hashlib.sha256()
        with path.open('rb') as stream:
            for number, line in enumerate(stream, 1):
                value.update(line)
                parts = line.decode('ascii').split()
                if parts:
                    yield number, parts
        self.files[str(path.resolve())] = dict(path=str(path.resolve()),
            bytes=path.stat().st_size, sha256=value.hexdigest().upper())


def checksum(data):
    if len(data) % 2:
        data += b'\0'
    total = sum(struct.unpack('!' + 'H' * (len(data) // 2), data))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return (~total) & 65535


def decode_short(wire):
    require(wire[:8] == b'\x55' * 7 + b'\xd5', 'eight-byte GMII preamble/SFD')
    body = wire[8:]
    require(len(body) >= 64, 'short frame minimum length')
    require(struct.pack('<I', zlib.crc32(body[:-4])) == body[-4:], 'Ethernet FCS')
    body = body[:-4]
    require(body[:4] == b'\x03\0\0\0' and body[12:15] == b'\x08\x00\x45'
            and body[23] == 17, 'AFDX Ethernet/IPv4/UDP header')
    require(checksum(body[14:34]) == 0, 'IPv4 checksum')
    require(int.from_bytes(body[20:22], 'big') & 0x3fff == 0, 'short unfragmented frame only')
    n = int.from_bytes(body[38:40], 'big') - 8
    require(1 <= n <= 1471 and int.from_bytes(body[16:18], 'big') == n + 28
            and len(wire) == 8 + 47 + max(n, 17), 'short payload/frame length')
    if body[40:42] != b'\0\0':
        require(checksum(body[26:34] + b'\0\x11' + body[38:40] + body[34:42+n]) == 0,
                'UDP checksum')
    return int.from_bytes(body[4:6], 'big'), n, body[42:42+n]


def read_sender(folder, es, inputs):
    messages = []
    pending_public = collections.deque()
    pending_outcome = collections.deque()
    cfg = {}
    resets = []
    stage = 'initial'
    epoch = 0
    counts = collections.Counter()
    for line, p in inputs.rows(folder / f'es{es}_tx/events.txt'):
        kind, cycle = p[0], int(p[1])
        if kind == 'Z':
            require(not pending_public and not pending_outcome, 'no pending message across reset')
            epoch += 1
            resets.append(cycle)
            cfg.clear()
        elif kind == 'P':
            stage = p[2]
        elif kind == 'C' and p[2] == 'tx':
            cfg[int(p[3], 16)] = int(p[4], 16)
        elif kind == 'A':
            require(len(p) == 8, 'public TX A record fields')
            vlid, n, payload = int(p[2], 16), int(p[3]), bytes.fromhex(p[4])
            candidates = [i for i in range(128) if cfg.get(i*8, 0) & 1
                          and cfg.get(i*8+2, -1) & 65535 == vlid]
            require(bool(candidates), 'public VLID has enabled TX configuration')
            vl = min(candidates)
            first = int(p[5])
            require(len(payload) == n and 1 <= n <= 1471, 'short public TX payload length')
            require(cycle - first + 1 == n + 2, 'continuous public VLID + payload bytes')
            pending_public.append(dict(id=f'es{es}:{len(messages)+len(pending_public)+1}',
                es=es, direction=f'es{es}_to_es{3-es}', epoch=epoch, stage=stage,
                vl=vl, vlid=vlid, n=n, payload=payload, payload_sha256=hashlib.sha256(payload).hexdigest(),
                public_first=first, public_last=cycle, public_line=line,
                stalls=int(p[6]), maxstall=int(p[7]), bag=cfg.get(vl*8+1, 0)))
            counts['public_A'] += 1
        elif kind == 'M':
            require(len(p) == 12 and bool(pending_public), 'M has a pending public A')
            m = pending_public.popleft()
            require((int(p[2]), int(p[3]), bytes.fromhex(p[7])) == (m['vl'], m['n'], m['payload']),
                    'independent public A versus M VL/configuration/length/payload')
            require((int(p[8]), int(p[10]), int(p[11]), int(p[9])) ==
                    (m['public_first'], m['public_last'], m['stalls'], m['maxstall']),
                    'public A versus M first/last/stall timestamps')
            require(cycle >= m['public_last'], 'internal M follows public last')
            m.update(core_M=cycle, core_line=line, tx={}, rx={}, core_tx={})
            messages.append(m)
            pending_outcome.append(m)
            counts['core_M'] += 1
        elif kind == 'E' and p[2] in ('accept', 'drop_dis', 'drop_full', 'drop_long', 'drop_nopage'):
            require(bool(pending_outcome), 'outcome has pending M')
            m = pending_outcome.popleft()
            require(p[2] == 'accept', 'fixed capture contains dropped message')
            m['accept_cycle'] = cycle
            counts['accepted'] += 1
    require(not pending_public and not pending_outcome, 'all public/M records accounted for')
    require(bool(messages), 'sender has messages')
    return messages, resets, dict(counts)


def match_deliveries(folder, es, messages, resets, inputs):
    queues = collections.defaultdict(collections.deque)
    for m in messages:
        queues[m['epoch'], m['vlid'], m['n'], m['payload']].append(m)
    reverse = {}
    mapping = {}
    counts = collections.Counter()
    for line, p in inputs.rows(folder / f'es{3-es}_rx/events.txt'):
        cycle = int(p[1])
        if p[0] == 'Z':
            reverse.clear()
            mapping.clear()
        elif p[0] == 'C' and p[2] == 'map':
            vlid, value = int(p[3], 16), int(p[4], 16)
            if vlid in mapping and reverse.get(mapping[vlid]) == vlid:
                reverse.pop(mapping[vlid])
            if value & 4096:
                idx = value & 4095
                require(idx not in reverse or reverse[idx] == vlid, 'unique enabled RX VLID mapping')
                mapping[vlid] = idx
                reverse[idx] = vlid
        elif p[0] == 'D':
            require(len(p) == 10, 'D has real public receive timestamps')
            idx, n, payload = int(p[3]), int(p[6]), bytes.fromhex(p[7])
            require(idx in reverse, 'RX index independently maps to configured VLID')
            vlid = reverse[idx]
            key = bisect.bisect_right(resets, cycle), vlid, n, payload
            require(bool(queues.get(key)), 'delivery matches source VLID + exact length + payload')
            m = queues[key].popleft()
            first, last = int(p[8]), int(p[9])
            require(len(payload) == n and last - first + 1 == n + 2, 'continuous public receive bytes')
            require(last >= m['public_last'] and p[2] in ('A', 'B'), 'delivery causality/network')
            m.update(rx_public_first=first, rx_public_last=last, rx_line=line,
                     rx_index=idx, winner=p[2], raw_latency=last-m['public_first'])
            counts['matched_D'] += 1
    require(all(not q for q in queues.values()), 'every public message delivered exactly once')
    return dict(counts)


def match_frames(folder, es, messages, resets, inputs, kind, net):
    dest = 3-es if kind == 'rx' else es
    branch = f'es{dest}_gmii_{kind}' if kind in ('tx', 'rx') else f'es{es}_tx'
    queues = collections.defaultdict(collections.deque)
    for m in messages:
        queues[m['epoch'], m['vlid'], m['n'], m['payload']].append(m)
    count = 0
    for line, p in inputs.rows(folder / branch / f'dump_{net.lower()}.txt'):
        require(len(p) == 4 and p[0] == net, 'GMII/core capture row')
        start, size, wire = int(p[1]), int(p[2]), bytes.fromhex(p[3])
        require(size == len(wire), 'captured byte count')
        vlid, n, payload = decode_short(wire)
        key = bisect.bisect_right(resets, start), vlid, n, payload
        require(bool(queues.get(key)), 'frame matches public VLID + exact payload')
        m = queues[key].popleft()
        frame = dict(start=start, sfd=start+7, last=start+size-1, bytes=size,
                     sha256=hashlib.sha256(wire).hexdigest(), line=line)
        if kind == 'rx':
            require(frame['sha256'] == m['tx'][net]['sha256'], 'TX/RX link byte identity')
            require(start >= m['tx'][net]['start'], 'nonnegative observed link delay')
        m[kind][net] = frame
        count += 1
    require(all(not q for q in queues.values()), 'complete per-network frame count')
    return count


def classify(messages):
    previous = {}
    for m in sorted(messages, key=lambda row: (row['public_first'], row['id'])):
        key = m['es'], m['epoch'], m['vlid']
        prev = previous.get(key)
        m['first_for_vl_epoch'] = prev is None
        m['previous_id'] = prev['id'] if prev else None
        m['in_window'] = False  # Filled independently from explicit F markers.
        if prev:
            require(all(prev['tx'][net]['start'] < m['tx'][net]['start'] for net in ('A', 'B')),
                    'same-VL transmitted frames preserve public order')
            # This matches perf_ref.measure's prior slow-line start anchor.
            prior_slow = min(prev['core_tx'][net]['start'] for net in ('A', 'B'))
            due = prior_slow + m['bag']
            core_signed = due - m['core_M']
            public_signed = due - m['public_first']
            # Physical waiting is zero after the eligibility time has passed.
            # Signed residuals and every adjusted latency remain unmodified.
            core_wait = core_signed if core_signed > 0 else 0
            public_wait = public_signed if public_signed > 0 else 0
            m.update(previous_core_tx_start=prior_slow, eligibility_cycle=due,
                core_due_minus_M_signed=core_signed, public_due_minus_first_signed=public_signed,
                remaining_wait_at_M=core_wait, remaining_wait_at_public_first=public_wait)
        else:
            m.update(previous_core_tx_start=None, eligibility_cycle=None,
                core_due_minus_M_signed=None, public_due_minus_first_signed=None,
                remaining_wait_at_M=0, remaining_wait_at_public_first=0)
        m['raw_minus_core_wait'] = m['raw_latency'] - m['remaining_wait_at_M']
        m['raw_minus_public_wait'] = m['raw_latency'] - m['remaining_wait_at_public_first']
        m['winner_observed_link_delay'] = m['rx'][m['winner']]['start'] - m['tx'][m['winner']]['start']
        previous[key] = m


def witness(m):
    return {k: v for k, v in m.items() if k != 'payload'}


def metric(rows, name):
    if not rows:
        return dict(samples=0, minimum=None, maximum=None, range_cycles=None,
                    range_us=None, min_id=None, max_id=None)
    lo = min(rows, key=lambda m: (m[name], m['public_first'], m['id']))
    hi = min(rows, key=lambda m: (-m[name], m['public_first'], m['id']))
    result = dict(samples=len(rows), minimum=lo[name], maximum=hi[name],
                  minimum_us=lo[name]*CYCLE_NS/1000, maximum_us=hi[name]*CYCLE_NS/1000,
                  range_cycles=hi[name]-lo[name], range_us=(hi[name]-lo[name])*CYCLE_NS/1000,
                  min_id=lo['id'], max_id=hi['id'])
    if name == 'raw_latency':
        enough = len(rows) >= 2
        result.update(repeat_group=enough,
            official_jitter_lt_100us=(hi[name]-lo[name] < 12500) if enough else None,
            project_jitter_le_50us=(hi[name]-lo[name] <= 6250) if enough else None,
            sample_limitation=None if enough else 'one sample; group jitter is not established')
    return result


def make_groups(messages, by_stage):
    buckets = collections.defaultdict(list)
    for m in messages:
        key = (m['direction'], m['epoch'], m['vlid'], m['n'])
        if by_stage:
            key = (m['stage'],) + key
        buckets[key].append(m)
    result = []
    for key, rows in sorted(buckets.items()):
        direction, epoch, vlid, n = key[-4:]
        first = [m for m in rows if m['first_for_vl_epoch']]
        subsequent = [m for m in rows if not m['first_for_vl_epoch']]
        cohorts = dict(all=rows, first=first, subsequent=subsequent,
            subsequent_waiting_at_public=[m for m in subsequent if m['remaining_wait_at_public_first'] > 0],
            subsequent_no_wait_at_public=[m for m in subsequent if m['remaining_wait_at_public_first'] == 0],
            measurement_window=[m for m in rows if m['in_window']])
        record = dict(direction=direction, epoch=epoch, vlid=vlid, payload_length=n,
                      vl_indices=sorted({m['vl'] for m in rows}),
                      stage=key[0] if by_stage else None,
                      stages=sorted({m['stage'] for m in rows}), cohorts={})
        for cohort, samples in cohorts.items():
            record['cohorts'][cohort] = {name: metric(samples, name) for name in
                ('raw_latency', 'raw_minus_core_wait', 'raw_minus_public_wait')}
        result.append(record)
    return result


def summarize_groups(groups, all_messages):
    lookup = {m['id']: m for m in all_messages}
    result = {}
    for cohort in ('all', 'first', 'subsequent', 'subsequent_waiting_at_public',
                   'subsequent_no_wait_at_public', 'measurement_window'):
        candidates = [(g, g['cohorts'][cohort]['raw_latency']) for g in groups]
        repeated = [(g, s) for g, s in candidates if s['samples'] >= 2]
        singletons = sum(s['samples'] == 1 for _, s in candidates)
        record = dict(nonempty_groups=sum(s['samples'] > 0 for _, s in candidates),
            repeated_groups=len(repeated), insufficient_singleton_groups=singletons,
            samples=sum(s['samples'] for _, s in candidates),
            official_fail_groups=sum(s['official_jitter_lt_100us'] is False for _, s in repeated),
            project_fail_groups=sum(s['project_jitter_le_50us'] is False for _, s in repeated))
        if repeated:
            group, stats = max(repeated, key=lambda item: item[1]['range_cycles'])
            record['worst'] = dict(group={k: v for k, v in group.items() if k != 'cohorts'},
                stats=stats, minimum=witness(lookup[stats['min_id']]), maximum=witness(lookup[stats['max_id']]))
        else:
            record['worst'] = None
        result[cohort] = record
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path, default=DEFAULT_CAPTURE)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    folder = args.capture.resolve()
    require(folder.is_dir(), 'capture directory exists')
    inputs = Inputs()
    for name in ('summary.json', 'check_summary.json'):
        inputs.bind(folder / name)
    native = json.loads((folder / 'summary.json').read_text(encoding='utf-8-sig'))
    check = json.loads((folder / 'check_summary.json').read_text(encoding='utf-8-sig'))
    require(native.get('name') == 'tb_sys_perf' and native.get('passed') is True and native.get('errors') == 0,
            'completed passing fixed native capture required')
    require(check.get('test') == 'tb_sys_perf' and check.get('errors') == 0,
            'completed independent fixed check required')
    # Verify the archived sources that actually belong to this run. Current
    # working-tree drift is reported separately and does not rewrite provenance.
    source_identity = []
    for i, saved in enumerate(native['inputs']):
        current = Path(saved['path'])
        archive = folder / 'sources' / f'{i}_{current.name}'
        actual = digest(archive)
        require(actual.lower() == saved['sha256'].lower(), 'archived source identity: ' + str(archive))
        source_identity.append(dict(original=str(current), archived=str(archive), sha256=actual,
            current_matches_archive=current.is_file() and digest(current) == actual))
    for name in ('modelsim_adaptations.json', 'run.do', 'compile_rtl.log', 'compile.log', 'simulation.log'):
        if (folder / name).is_file():
            inputs.bind(folder / name)
    for path in sorted((folder / 'compile_sources').rglob('*')):
        if path.suffix in ('.v', '.vh'):
            inputs.bind(path)
    windows = {}
    stage_markers = []
    clock_ns = None
    for line, p in inputs.rows(folder / 'sys_events.txt'):
        if p[0] == 'F' and p[2] in ('begin', 'end'):
            windows.setdefault(p[3], {})[p[2]] = int(p[1])
        elif p[0] == 'P':
            stage_markers.append(dict(cycle=int(p[1]), stage=p[2], line=line))
        elif p[0] == 'G' and p[2] == 'CLOCK_NS':
            clock_ns = int(p[3])
    require(clock_ns == CYCLE_NS, 'capture explicitly records an 8ns clock')
    all_messages, counts = [], {}
    for es in (1, 2):
        messages, resets, sender_counts = read_sender(folder, es, inputs)
        require(len(messages) == check['reports'][f'es{es}_tx']['messages'],
                'full captured sender count agrees with completed independent report')
        sender_counts.update(match_deliveries(folder, es, messages, resets, inputs))
        for kind in ('tx', 'rx', 'core_tx'):
            for net in ('A', 'B'):
                sender_counts[f'{kind}_{net}'] = match_frames(folder, es, messages, resets, inputs, kind, net)
        classify(messages)
        for m in messages:
            window = windows.get(m['stage'], {})
            m['in_window'] = bool(set(window) == {'begin', 'end'} and window['begin'] <= m['public_first'] < window['end'])
        all_messages.extend(messages)
        counts[f'es{es}'] = sender_counts
    stage_groups = make_groups(all_messages, True)
    global_groups = make_groups(all_messages, False)
    firsts = [witness(m) for m in all_messages if m['first_for_vl_epoch']]
    stage_summary = summarize_groups(stage_groups, all_messages)
    global_summary = summarize_groups(global_groups, all_messages)
    stages = {}
    for stage in sorted({m['stage'] for m in all_messages}):
        rows = [m for m in all_messages if m['stage'] == stage]
        stages[stage] = dict(messages=len(rows), true_first=sum(m['first_for_vl_epoch'] for m in rows),
            subsequent=sum(not m['first_for_vl_epoch'] for m in rows),
            waiting_at_public=sum(m['remaining_wait_at_public_first'] > 0 for m in rows),
            window=windows.get(stage))
    output = args.out.resolve() if args.out else ROOT / 'out/faq_jitter' / datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    require(not output.exists(), 'output directory must be new; existing reports are never overwritten')
    output.mkdir(parents=True)
    def save(name, data):
        (output / name).write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    save('stage_groups.json', stage_groups)
    save('cross_stage_groups.json', global_groups)
    save('first_frames.json', firsts)
    fields = ['id', 'direction', 'epoch', 'stage', 'vl', 'vlid', 'n', 'payload_sha256',
        'first_for_vl_epoch', 'previous_id', 'in_window', 'public_line', 'core_line', 'rx_line',
        'public_first', 'public_last', 'core_M', 'accept_cycle', 'rx_public_first', 'rx_public_last',
        'raw_latency', 'winner', 'winner_observed_link_delay', 'bag', 'previous_core_tx_start',
        'eligibility_cycle', 'core_due_minus_M_signed', 'public_due_minus_first_signed',
        'remaining_wait_at_M', 'remaining_wait_at_public_first', 'raw_minus_core_wait', 'raw_minus_public_wait']
    with (output / 'samples.tsv').open('w', encoding='utf-8', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, delimiter='\t', extrasaction='ignore')
        writer.writeheader()
        writer.writerows(all_messages)
    summary = dict(schema='FAQ-short-offline-v1', completed=True, analysis_integrity_passed=True,
        generated=datetime.now().astimezone().isoformat(), capture=str(folder), output=str(output),
        script=dict(path=str(Path(__file__).resolve()), sha256=digest(Path(__file__))),
        source_capture=dict(passed=native['passed'], checks=native.get('checks'), errors=native['errors'],
            independent_items=check.get('items'), independent_errors=check['errors'],
            verification_profile=native.get('verification_profile'), ce_div=native.get('ce_div'),
            jobs=[{k: job.get(k) for k in ('name', 'command', 'cwd', 'exit_code')} for job in native.get('jobs', [])]),
        clock_ns=CYCLE_NS, definitions=dict(
            primary='raw_latency = real public receive_last - independent public A first_valid; no BAG or link subtraction',
            true_first='earliest source message per (source endpoint, real reset epoch, public VLID), across all stages and windows',
            repeated_group='same direction, epoch, public VLID and payload length; per-stage and complete cross-stage populations reported separately',
            official='raw group max-min <100us (strictly <12500 cycles at 8ns)',
            project='raw group max-min <=50us (<=6250 cycles at 8ns)',
            due='previous same-VL internal slow-line TX start + current configured BAG; diagnostic perf_ref.measure anchor',
            signed_residuals='due-core_M and due-public_first are retained with their sign; first has no previous BAG deadline',
            waiting='physical remaining eligibility wait is the positive signed residual, otherwise zero; first has zero BAG wait',
            adjusted='raw minus core wait / raw minus public wait are separate diagnostics; negative adjusted values are retained',
            limit='threshold statements apply to jitter range, not individual raw latency; singleton groups receive no pass verdict',
            short_only='C1561: 既然已经分片，不再受单帧限制。 No long-message latency formula is inferred or tested.'),
        matching='independent public A VLID+exact payload -> configured core M; receiver C map -> D VLID+exact payload; both GMII networks TX/RX FCS/header/length/payload and complete counts verified',
        counts=counts, total_messages=len(all_messages), true_first_messages=len(firsts),
        stage_markers=stage_markers, stages=stages,
        stage_group_count=len(stage_groups), cross_stage_group_count=len(global_groups),
        stage_cohorts=stage_summary, cross_stage_cohorts=global_summary,
        raw_latency_all=metric(all_messages, 'raw_latency'),
        raw_latency_first=metric([m for m in all_messages if m['first_for_vl_epoch']], 'raw_latency'),
        diagnostic_negative_adjusted_counts={name: sum(m[name] < 0 for m in all_messages)
            for name in ('raw_minus_core_wait', 'raw_minus_public_wait')},
        source_identity=source_identity, inputs=list(inputs.files.values()))
    # The heterogeneous all/first distributions above are descriptive only.
    # Their ranges are not same-(VL,n) threshold verdicts.
    for name in ('raw_latency_all', 'raw_latency_first'):
        for field in ('repeat_group', 'official_jitter_lt_100us', 'project_jitter_le_50us', 'sample_limitation'):
            summary[name].pop(field, None)
        summary[name]['scope'] = 'heterogeneous descriptive distribution; not a same-(VL,n) jitter verdict'
    summary['outputs'] = [dict(path=str(p), bytes=p.stat().st_size, sha256=digest(p))
                          for p in sorted(output.iterdir())]
    save('summary.json', summary)
    print('FAQ OFFLINE ANALYSIS COMPLETE', output)
    print('MESSAGES', len(all_messages), 'TRUE_FIRST', len(firsts),
          'STAGE_GROUPS', len(stage_groups), 'CROSS_STAGE_GROUPS', len(global_groups))
    for scope, cohorts in (('per_stage', stage_summary), ('cross_stage', global_summary)):
        for cohort, record in cohorts.items():
            worst = record['worst']
            print(scope, cohort, 'samples', record['samples'], 'repeat_groups', record['repeated_groups'],
                'singletons', record['insufficient_singleton_groups'],
                'worst_raw_jitter_cycles', worst['stats']['range_cycles'] if worst else 'NA',
                'worst_raw_jitter_us', worst['stats']['range_us'] if worst else 'NA',
                'official_fail_groups', record['official_fail_groups'],
                'project_fail_groups', record['project_fail_groups'])
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
