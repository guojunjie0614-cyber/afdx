"""Black-box system reconstruction from thirteen text records only.

The stimulus file and DUT implementation are never opened.  Source captures are
bound to accepted application messages, transformed by the recorded links, then
matched to destination deliveries.  The four existing core checkers are separate.
"""
import argparse
import bisect
import collections
import json
import sys
from pathlib import Path
sys.dont_write_bytecode = True
from rx_ref import decode

COUNTERS = dict(zip(range(0x40, 0x47), ('accept', 'drop_dis', 'drop_full',
    'drop_long', 'drop_nopage', 'tx_a', 'tx_b')))
COUNTERS.update({0x48+i: 'a_'+name for i, name in enumerate(
    ('good', 'fcs', 'len', 'hdr', 'unk', 'cfg', 'ic', 'ovf'))})
COUNTERS.update({0x50+i: 'b_'+name for i, name in enumerate(
    ('good', 'fcs', 'len', 'hdr', 'unk', 'cfg', 'ic', 'ovf'))})
COUNTERS.update({0x58: 'rm_drop', 0x59: 'deliver'})
# Event pulses pass two pipeline registers before reaching the counters, so a pulse at
# cycle p is first visible to a read issued at cycle p + 1 + COUNTER_LAG.
COUNTER_LAG = 2
COUNTERS.update({0x5a: 'a_gdrop', 0x5b: 'b_gdrop'})


def rows(path):
    result = []
    for number, line in enumerate(path.read_text(encoding='ascii').splitlines(), 1):
        p = line.split()
        if p:
            if len(p) < 2:
                raise ValueError(f'{path.name}:{number}: missing cycle')
            result.append((int(p[1]), number, p))
    return sorted(result)


def captures(folder, expect):
    result = []
    for net in ('A', 'B'):
        for line in (folder / f'dump_{net.lower()}.txt').read_text(encoding='ascii').splitlines():
            p = line.split()
            netname, start, count, raw = p
            wire = bytes.fromhex(raw)
            expect(netname == net and len(wire) == int(count) and raw == raw.lower(), 'S3 capture format')
            result.append(dict(net=net, start=int(start), end=int(start)+int(count), wire=wire))
    return sorted(result, key=lambda f: (f['start'], f['net']))


def table(address):
    if address >> 10 == 4:
        return 'tx', address & 1023
    if address >> 16 == 1:
        return 'map', address & 65535
    if address >> 12 == 32:
        return 'cfg', address & 4095
    return None, None


def endpoint(folder, number, expect):
    txrows = rows(folder/f'es{number}_tx/events.txt')
    rxrows = rows(folder/f'es{number}_rx/events.txt')
    ep = dict(number=number, txrows=txrows, rxrows=rxrows,
              tx=captures(folder/f'es{number}_tx', expect),
              rx=captures(folder/f'es{number}_rx', expect),
              resets=[c for c, _, p in txrows if p[0] == 'Z'],
              releases=[c for c, _, p in txrows if p[0] == 'R'],
              inits=[c for c, _, p in rxrows if p[0] == 'I'],
              params={p[2]: int(p[3]) for _, _, p in txrows+rxrows if p[0] == 'G'})
    expect(ep['resets'] == [c for c, _, p in rxrows if p[0] == 'Z'], f'S5 ES{number} shared reset records')
    expect(ep['releases'] == [c for c, _, p in rxrows if p[0] == 'R'], f'S5 ES{number} shared release records')
    ep['pulses'] = collections.defaultdict(list)
    ep['pulse_stages'] = collections.defaultdict(collections.Counter)
    stage = 'initial'
    for c, _, p in sorted(txrows+rxrows):
        if p[0] == 'P':
            stage = p[2]
        elif p[0] == 'E':
            ep['pulses'][p[2]].append(c)
            ep['pulse_stages'][stage][p[2]] += 1
    messages, pending, cfg = [], [], {}
    epoch, uid, stage = 0, 0, 'initial'
    for c, _, p in txrows:
        if p[0] == 'Z':
            epoch += 1; cfg = {}; uid = 0; pending = []
        elif p[0] == 'P':
            stage = p[2]
        elif p[0] == 'U':
            uid = int(p[2], 16)
        elif p[0] == 'C':
            expect(p[2] == 'tx', 'S1 TX table name')
            cfg[int(p[3], 16)] = int(p[4], 16)
        elif p[0] == 'M':
            vl, n, pen = map(int, p[2:5]); body = bytes.fromhex(p[7])
            words = [cfg.get(vl*8+w, 0) for w in range(6)]
            limit = 5000 + sum((20+47+max((cfg.get(v*8, 0)>>9)&2047, 17))
                              for v in range(128) if cfg.get(v*8, 0)&1 and cfg.get(v*8, 0)&6)
            m = dict(index=len(messages), es=number, cycle=c, epoch=epoch,
                     stage=stage, vl=vl, n=n, pen=pen, sport=int(p[5], 16),
                     dport=int(p[6], 16), payload=body, words=words, uid=uid,
                     result=None, frame=None, deliveries=[], copies=[], w_limit=limit)
            expect(len(body) == n, 'S1 M byte count')
            messages.append(m); pending.append(m)
        elif p[0] == 'E' and p[2] not in ('tx_a', 'tx_b'):
            expect(len(pending) >= 1, f'S1 ES{number} queued M available at {c}')
            if pending:
                m = pending.pop(0); m['result'] = p[2]; m['event'] = c
                expect(0 < c-m['cycle'] <= 96, f'S1 M/result causality ES{number} M{m["index"]}')
    expect(not pending, f'S1 ES{number} final M outcome')
    ep['messages'] = messages
    available = collections.defaultdict(collections.deque)
    for m in messages:
        if m['result'] == 'accept':
            available[m['epoch'], m['words'][2]&65535].append(m)
    groups = []
    for f in ep['tx']:
        f['epoch'] = bisect.bisect_right(ep['resets'], f['start'])
        f['info'] = decode(f['wire'])
        if groups and groups[-1]['start'] == f['start']:
            group = groups[-1]
        else:
            group = dict(start=f['start'], end=f['end'], frames=[], epoch=f['epoch'])
            groups.append(group)
        group['frames'].append(f)
    last = {}
    for group in groups:
        first = group['frames'][0]
        key = (group['epoch'], first['info'].get('vlid'))
        expect(bool(available[key]), f'S1 source frame has accepted M ES{number} S={group["start"]}')
        if not available[key]:
            continue
        m = available[key].popleft(); m['frame'] = group; group['message'] = m
        m['previous'] = last.get((m['epoch'], m['vl']))
        last[m['epoch'], m['vl']] = group
        expect(m['cycle'] < group['start'], f'S1 M precedes TX ES{number} M{m["index"]}')
        for f in group['frames']:
            f['message'] = m
            info = f['info']
            expect(info.get('payload') == m['payload'] and info.get('n') == m['n'], 'S1 TX payload equals accepted M')
            expect(info.get('sport') == (m['sport'] if m['pen'] else m['words'][5]>>16), 'S1 TX source port')
            expect(info.get('dport') == (m['dport'] if m['pen'] else m['words'][5]&65535), 'S1 TX destination port')
    ep['groups'] = groups
    ep['deliveries'] = []
    for c, _, p in rxrows:
        if p[0] == 'D':
            body = bytes.fromhex(p[7])
            ep['deliveries'].append(dict(cycle=c, net=p[2], idx=int(p[3]),
                sport=int(p[4], 16), dport=int(p[5], 16), n=int(p[6]), payload=body))
            expect(len(body) == int(p[6]), 'S1 D byte count')
    ep['clocks'] = [(c, int(p[2], 16), int(p[3])) for c, _, p in rxrows if p[0] == 'K']
    return ep


def annotate_receiver(ep, frames):
    cfg, mapping, cursor, init = {}, {}, 0, False
    timeline = ep['rxrows']
    for f in sorted(frames, key=lambda x: (x['start'], x['net'])):
        while cursor < len(timeline) and timeline[cursor][0] <= f['start']:
            _, _, p = timeline[cursor]; cursor += 1
            if p[0] == 'Z':
                cfg = {}; mapping = {}; init = False
            elif p[0] == 'I':
                init = True
            elif p[0] == 'C':
                (mapping if p[2] == 'map' else cfg)[int(p[3], 16)] = int(p[4], 16)
        info = f['info'] = decode(f['wire'])
        value = mapping.get(info.get('vlid'), 0)
        f['idx'] = value & 4095
        f['control'] = cfg.get(f['idx'], 0)
        bit = 2 if f['net'] == 'A' else 4
        f['valid_config'] = bool(init and value&4096 and f['control']&1 and f['control']&bit and
                                 info.get('n', 1<<30) <= ((f['control']>>17)&2047))
        f['effective'] = bool(f.get('original') and f.get('mode') == 'pass' and f['valid_config'] and
                              info.get('n', 1<<30) <= 1<<ep['params'].get('RX_RING_AW', 12))
        if f.get('message'):
            f['message']['copies'].append(f)


def reconstruct_links(sysrows, endpoints, expect):
    expected = {1: [], 2: []}; link_rows = {i: [] for i in range(4)}
    actions_stages = set(); stage = 'initial'
    for c, _, p in sysrows:
        if p[0] == 'P':
            stage = p[2]
        elif p[0] in ('L', 'A', 'R', 'J'):
            link = int(p[2]); expect(link in link_rows, 'S3 link id')
            if link in link_rows:
                link_rows[link].append((c, p, stage))
            if p[0] in ('R', 'J') or p[0] == 'A' and p[4] != 'pass':
                actions_stages.add(stage)
    for link in range(4):
        source = endpoints[1 if link < 2 else 2]
        destination = endpoints[2 if link < 2 else 1]
        net = 'AB'[link%2]
        tx = [f for f in source['tx'] if f['net'] == net]
        delays = [(c, int(p[3])) for c, p, _ in link_rows[link] if p[0] == 'L']
        action = {}
        for c, p, _ in link_rows[link]:
            if p[0] == 'A':
                action[int(p[3])] = (c, p[4], int(p[5]), int(p[6], 16))
        transformed = []
        for number, f in enumerate(tx, 1):
            ds = [d for c, d in delays if c <= f['start']]
            expect(bool(ds), f'S3 link {link} delay declared before frame {number}')
            delay = ds[-1] if ds else 0
            at, mode, byte, mask = action.get(number, (0, 'pass', 0, 0))
            expect(at <= f['start'], f'S3 link {link} timely action {number}')
            expect(mode in ('pass', 'drop', 'xor', 'hold'), 'S3 action mode')
            if mode in ('drop', 'hold'):
                continue
            wire = bytearray(f['wire'])
            if mode == 'xor':
                expect(0 <= byte < len(wire), 'S3 xor byte in frame')
                if 0 <= byte < len(wire):
                    wire[byte] ^= mask
            transformed.append(dict(net=net, start=f['start']+delay,
                end=f['end']+delay, wire=bytes(wire), source=f, link=link,
                number=number, original=True, mode=mode, message=f.get('message')))
        for c, p, _ in link_rows[link]:
            if p[0] == 'R':
                number, start = int(p[3]), int(p[4])
                expect(1 <= number <= len(tx), f'S3 replay source link {link}')
                if not 1 <= number <= len(tx):
                    continue
                f = tx[number-1]
                expect(f['end'] <= c and start >= c, 'S3 replay after complete capture')
                transformed.append(dict(net=net, start=start, end=start+len(f['wire']), wire=f['wire'],
                    source=f, link=link, number=number, original=False, mode='replay', message=f.get('message')))
            elif p[0] == 'J':
                start, count = int(p[3]), int(p[4]); wire = bytes.fromhex(p[5])
                expect(len(wire) == count and start >= c and p[5] == p[5].lower(), 'S3 insertion format')
                transformed.append(dict(net=net, start=start, end=start+count, wire=wire,
                    source=None, link=link, original=False, mode='insert', message=None))
        transformed.sort(key=lambda f: f['start'])
        for a, b in zip(transformed, transformed[1:]):
            expect(b['start']-a['end'] >= 12, f'S3 link {link} output gap')
        # A receive monitor ignores the entire physical segment intersecting reset.
        intervals = list(zip(destination['resets'], destination['releases']))
        retained = [f for f in transformed if not any(f['start'] < r and f['end'] > z for z, r in intervals)]
        actual = [f for f in destination['rx'] if f['net'] == net]
        expect(len(actual) == len(retained), f'S3 link {link} frame count expected={len(retained)} actual={len(actual)}')
        for a, b in zip(actual, retained):
            expect(a['start'] == b['start'] and a['wire'] == b['wire'], f'S3 link {link} bytes/start {b["start"]}')
        expected[destination['number']].extend(retained)
    for number, frames in expected.items():
        annotate_receiver(endpoints[number], frames)
    return expected, actions_stages


def bus_checks(sysrows, endpoints, expect):
    requests, responses, writes = collections.defaultdict(list), collections.defaultdict(list), []
    for c, _, p in sysrows:
        if p[0] == 'Q':
            es, address = int(p[2]), int(p[3], 16)
            requests[es, c, address].append(p)
        elif p[0] == 'V':
            es, address, value, t = int(p[2]), int(p[3], 16), int(p[4], 16), int(p[5])
            responses[es, t, address].append((c, value))
        elif p[0] == 'W':
            es, address, value, u = int(p[2]), int(p[3], 16), int(p[4], 16), int(p[5])
            rewrite = int(p[6]) if len(p)>6 else 0
            name, index = table(address)
            writes.append(dict(cycle=c, es=es, addr=address, value=value, u=u, wait=u-c,
                               table=name, index=index, rewrite=rewrite))
            expect(1 <= u-c <= 64 if name else u == c, f'S5 write latency ES{es} t={c} u={u}')
            ep = endpoints[es]
            latest_reset = max((z for z in ep['resets'] if z <= c), default=-1)
            expect(any(latest_reset < i <= c for i in ep['inits']), f'S5 write while not ready ES{es} t={c}')
    expect(set(requests) == set(responses), 'S5 every read has exactly a matching response')
    for es in endpoints:
        ordered = sorted((w for w in writes if w['es'] == es), key=lambda w:w['cycle'])
        for a, b in zip(ordered, ordered[1:]):
            expect(b['cycle'] > a['u'], f'S5 ES{es} accepts no overlapping or duplicate write')
    nonzero = {1: {}, 2: {}}; reads = []
    for (es, t, address), req in sorted(requests.items()):
        ep = endpoints[es]
        replies = responses.get((es, t, address), [])
        expect(len(req) == len(replies) == 1, f'S5 unique read ES{es} t={t}')
        if not replies:
            continue
        c, value = replies[0]
        expect(c == t+2, f'S5 read response exactly t+2 ES{es} t={t} got={c}')
        reset = max((z for z in ep['resets'] if z <= t), default=-1)
        if address in COUNTERS:
            times = ep['pulses'][COUNTERS[address]]
            expected = max(0, bisect.bisect_left(times, t-COUNTER_LAG)-bisect.bisect_right(times, reset)) & 0xffffffff
            if value:
                nonzero[es][COUNTERS[address]] = max(value, nonzero[es].get(COUNTERS[address], 0))
            expect(value == expected, f'S4 ES{es} {COUNTERS[address]} t={t}: got={value} expected={expected}')
        else:
            if address == 0:
                expected = 0xc3110000
            elif address == 1:
                expected = int(any(reset < i <= t for i in ep['inits']))
            elif address == 2:
                candidates = [w for w in writes if w['es'] == es and w['addr'] == 2 and reset < w['cycle'] < t]
                expected = (candidates[-1]['value'] & 65535) if candidates else 0
            else:
                expected = 0
            expect(value == expected, f'S5 ES{es} register {address:x} t={t}: got={value:x} expected={expected:x}')
        reads.append(dict(es=es, cycle=t, response=c, addr=address, value=value))
    # C and U are independently recorded by the endpoint; original-value runtime
    # rewrites are intentionally absent from the core record, and checked here.
    for w in writes:
        ep = endpoints[w['es']]
        if w['table']:
            core = ep['txrows'] if w['table'] == 'tx' else ep['rxrows']
            val = w['value'] & (8191 if w['table'] == 'map' else 0xffffffff)
            if w['rewrite']:
                history = [int(p[4], 16) for c, _, p in core if c <= w['cycle'] and p[0] == 'C' and
                           p[2] == w['table'] and int(p[3], 16) == w['index']]
                expect(bool(history) and history[-1] == val, 'S5 runtime rewrite is original value')
            else:
                expect(any(c == w['u'] and p[0] == 'C' and p[2] == w['table'] and int(p[3], 16) == w['index'] and
                           int(p[4], 16) == val for c, _, p in core), 'S5 W/C core acceptance correspondence')
        elif w['addr'] == 2:
            expect(any(c == w['cycle']+1 and p[0] == 'U' and int(p[2], 16) == w['value']&65535
                       for c, _, p in ep['txrows']), 'S5 W/U update correspondence')
    return writes, reads, nonzero


def delivery_checks(test, endpoints, expected, action_stages, expect):
    samples = []; over = []; either = 0
    def quota(message):
        effective = [f for f in message['copies'] if f['effective']]
        return (1 if effective and effective[0]['control']&16 and 'outside' not in message['stage']
                else len(effective))
    for number, ep in endpoints.items():
        candidates = expected[number]
        used = set(); order = {}
        for d in sorted(ep['deliveries'], key=lambda d: d['cycle']):
            fits = [f for f in candidates if id(f) not in used and f['net'] == d['net'] and
                    f['idx'] == d['idx'] and f['end'] < d['cycle'] and
                    f['info'].get('sport') == d['sport'] and f['info'].get('dport') == d['dport'] and
                    f['info'].get('payload') == d['payload'] and f.get('message')]
            # Equal application payloads can recur.  A stale redundant copy of
            # an already-completed message must not steal a later D on that net.
            fits.sort(key=lambda f: (len(f['message']['deliveries']) >= (2 if test=='tb_sys_reset' else quota(f['message'])),
                d['cycle']-f['end'] > 15000,
                any(x['net'] == d['net'] for x in f['message']['deliveries']), f['end']))
            expect(bool(fits), f'S1 ES{number} D={d["cycle"]} has accepted source M')
            if not fits:
                continue
            f = fits[0]; used.add(id(f)); m = f['message']
            d['message'] = m; d['frame'] = f
            expect(not any(x['net'] == d['net'] for x in m['deliveries']), f'S1 same source copy delivered twice ES{m["es"]} M{m["index"]}')
            m['deliveries'].append(d)
            key = (m['es'], m['epoch'], m['vl'])
            expect(m['index'] >= order.get(key, -1), f'S2 out-of-order source ES{m["es"]} VL{m["vl"]} M{m["index"]}')
            order[key] = m['index']
            group = m['frame']; prev = m.get('previous')
            # J7 excludes W when this VL has no preceding transmitted frame.
            waiting = group['start']-max(m['cycle'], prev['start']+m['words'][1]) if prev else None
            latency = d['cycle']-f['end']; total = d['cycle']-m['cycle']
            if waiting is not None:
                expect(0 <= waiting <= 4*m['w_limit'], f'S6 hard waiting bound ES{m["es"]} M{m["index"]}: W={waiting} limit={m["w_limit"]}')
            expect(0 < latency <= 15000 and total > 0, f'S6 receive latency ES{number} D={d["cycle"]}: {latency}')
            row = dict(stage=m['stage'], es=m['es'], vl=m['vl'], message=m['index'],
                       M=m['cycle'], S=group['start'], F=f['end'], D=d['cycle'],
                       W=waiting, rx=latency, e2e=total, limit=m['w_limit'])
            samples.append(row)
            if waiting is not None and waiting > m['w_limit']:
                row = row.copy()
                preceding = [g for g in endpoints[m['es']]['groups'] if g['start'] < group['start']][-4:]
                row['preceding'] = [dict(S=g['start'], end=g['end'], vl=g.get('message', {}).get('vl')) for g in preceding]
                over.append(row)
        for source in endpoints.values():
            if source['number'] == number:
                continue
            for m in source['messages']:
                if m['result'] != 'accept':
                    expect(not m['deliveries'], 'S1 rejected M never delivered')
                    continue
                effective = [f for f in m['copies'] if f['effective']]
                rm = bool(effective and effective[0]['control']&16)
                outside = 'outside' in m['stage']
                expected_count = len(effective) if outside or not rm else 1
                if test != 'tb_sys_reset':
                    expect(len(m['deliveries']) == expected_count,
                        f'S1 source ES{m["es"]} M{m["index"]} stage={m["stage"]}: D={len(m["deliveries"])} expected={expected_count}')
                if not m['deliveries'] or not effective:
                    continue
                if m['stage'] not in action_stages or test == 'tb_sys_delay':
                    effective.sort(key=lambda f: (f['end'], f['net']))
                    if len(effective) == 2 and 0 < effective[1]['end']-effective[0]['end'] < 16:
                        either += 1
                    else:
                        want = [f['net'] for f in effective[:expected_count]]
                        got = [d['net'] for d in sorted(m['deliveries'], key=lambda d: d['cycle'])]
                        expect(got == want, f'S1 earlier network source ES{m["es"]} M{m["index"]}: {got}/{want}')
    latency = {}
    for stage in sorted({r['stage'] for r in samples}):
        values = [r for r in samples if r['stage'] == stage]
        stats = dict(samples=len(values), limit_min=min(r['limit'] for r in values), limit_max=max(r['limit'] for r in values))
        for key in ('W', 'rx', 'e2e'):
            measured = [r[key] for r in values if r[key] is not None]
            stats[key+'_samples'] = len(measured)
            stats[key+'_max'] = max(measured) if measured else None
            stats[key+'_mean'] = sum(measured)/len(measured) if measured else None
        stats['w_over'] = sum(r['W'] is not None and r['W'] > r['limit'] for r in values)
        latency[stage] = stats
    return samples, latency, over, either


def check(test, folder):
    folder = Path(folder); items = errors = 0; diagnostics = []
    def expect(ok, label):
        nonlocal items, errors
        items += 1
        if not ok:
            errors += 1
            if len(diagnostics) < 50:
                diagnostics.append(label)
    sysrows = rows(folder/'sys_events.txt')
    allowed = {'G', 'P', 'W', 'Q', 'V', 'L', 'A', 'R', 'J', 'E', 'F', 'O'}
    for _, _, p in sysrows:
        expect(p[0] in allowed, 'S5 recognized system row '+p[0])
    endpoints = {number: endpoint(folder, number, expect) for number in (1, 2)}
    shared_params={p[2]:int(p[3]) for _,_,p in sysrows if p[0]=='G'}
    stage='initial'
    for ep in endpoints.values():ep['params'].update(shared_params)
    for c,_,p in sysrows:
        if p[0]=='P':stage=p[2]
        elif p[0]=='E':
            es,name=int(p[2]),p[3]
            expect(es in endpoints and name in ('a_gdrop','b_gdrop'),'S4 adapter pulse record')
            if es in endpoints:
                endpoints[es]['pulses'][name].append(c)
                endpoints[es]['pulse_stages'][stage][name]+=1
    import gmii_ref
    gmii=gmii_ref.prepare(test,folder,endpoints,sysrows)
    expected,action_stages=gmii['expected'],gmii['actions']
    for number,frames in expected.items():annotate_receiver(endpoints[number],frames)
    writes, reads, nonzero = bus_checks(sysrows, endpoints, expect)
    samples, latency, over, either = delivery_checks(test, endpoints, expected, action_stages, expect)
    from sys_checks import coverage
    coverage(test, sysrows, endpoints, expected, writes, reads, samples, expect)
    performance={}
    if test=='tb_sys_perf':
        from perf_ref import measure
        performance=measure(sysrows,endpoints,gmii,samples,expect)
    summary = dict(test=test, items=items, errors=errors, either=either, w_over=len(over),
        latency=latency, w_over_rows=sorted(over, key=lambda r: r['W'], reverse=True),
        endpoints={f'es{n}': dict(messages=len(ep['messages']),
            accepted=sum(m['result']=='accept' for m in ep['messages']), deliveries=len(ep['deliveries']),
            counter_nonzero=nonzero[n], max_write_wait=max((w['wait'] for w in writes if w['es']==n), default=0),
            pulse_stages={s:dict(v) for s,v in ep['pulse_stages'].items()}) for n, ep in endpoints.items()},
        rewrites={name:dict(count=sum(w['table']==name and w['rewrite'] for w in writes),
            max_wait=max((w['wait'] for w in writes if w['table']==name and w['rewrite']), default=0)) for name in ('tx','map','cfg')},
        performance=performance,gmii=gmii['report'],diagnostics=diagnostics)
    for label in diagnostics:
        print('[CHECK_FAIL] '+label)
    print(f'[CHECK] {test} {"PASS" if not errors else "FAIL"} items={items} errors={errors} either={either} w_over={len(over)}')
    return summary


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='action', required=True)
    p = sub.add_parser('check'); p.add_argument('--test', required=True); p.add_argument('--dir', type=Path, required=True)
    args = ap.parse_args()
    result = check(args.test, args.dir)
    (args.dir/'sys_check_summary.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    return int(result['errors']+result.get('gmii',{}).get('errors',0) != 0)


if __name__ == '__main__':
    raise SystemExit(main())
