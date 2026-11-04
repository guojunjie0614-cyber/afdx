"""Reconstructed RM-04: independent high-frame-count dual-GMII IC/RM experiment.

The historical tb_gbe_rm_psn and its old evidence were not found locally.
This new experiment does not reproduce or validate the report's old counts.
Only stimulus serialization uses rx_ref.Scenario; expected outcomes do not use
rx_ref.check, RTL state, arbitration probes, or observed delivery decisions.

Generate: python tools/gbe_rm_psn_ref.py generate CASE/vectors --pairs 16384
Check:    python tools/gbe_rm_psn_ref.py check CASE
Run:      python tools/gbe_rm_psn_ref.py run --runtime-source PATH --compiler PATH
The run command reuses the existing eLinx Verilator build/evidence adapter.
"""
import argparse
import bisect
import collections
import json
from pathlib import Path
import sys
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
from afdx_ref import fcs, ip_checksum, PREAMBLE
from rx_ref import Scenario

TOP = 'tb_gbe_rm_psn'
PROFILES = (2688, 16384)
STEP = 64
IC_SEQUENCE = (7, 8, 10, 13, 14, 14, 0, 1, 0, 2, 255, 1, 255, 2, 254, 1, 100, 99, 100, 101)


def payload(tag, n):
    return (tag.to_bytes(4, 'big') + bytes((tag*37+j)&255 for j in range(n)))[:n]


def workload(pairs):
    """Build source inputs only. Expected outcomes are computed by check()."""
    if pairs not in PROFILES:
        raise ValueError('pairs must be 2688 (full matrix) or 16384 (large)')
    scenario = Scenario(1)
    scenario.event(2, 'K 64')
    groups = []

    def group(kind, bodies, *, delay=0, phase=16, idx=0, ic=True, rm=True, skew=20):
        # Leave a bounded delivery/result window before the next group. This
        # is a frame-count stress test, not a line-rate throughput experiment.
        start = max(scenario.t, max(scenario.ends.values())+96, scenario.last_config+17)
        wire_length = len(bodies[0][1])+12
        end = start+wire_length-1
        end += (phase-(end-5)) % STEP
        start = end-wire_length+1
        frames = []
        for number, (net, body) in enumerate(bodies):
            first, last = scenario.send(body, net=net, when=start+number*delay, advance=False)
            frames.append(dict(net=net, start=first, end=last, wire=PREAMBLE+body+fcs(body)))
        groups.append(dict(kind=kind, frames=frames, idx=idx, ic=ic, rm=rm, skew=skew))
        scenario.t = max(scenario.ends.values())+400

    def pair(kind, tag, n, sn, vlid, idx, *, first='A', delay=0, phase=16, ic=True, skew=20):
        body = scenario.body(n, vlid=vlid, sn=sn, payload=payload(tag, n))
        bodies = []
        for net in (first, 'B' if first=='A' else 'A'):
            changed = bytearray(body)
            changed[11] = 0x20 if net=='A' else 0x40
            bodies.append((net, bytes(changed)))
        group(kind, bodies, delay=delay, phase=phase, idx=idx, ic=ic, skew=skew)
        return bodies[0]

    scenario.stage('large_pairs')
    for index in range(64):
        scenario.config(3000+index, index, ic=1, rm=1, skew=20)
    lengths = (4, 17, 18, 32, 64)
    for number in range(pairs):
        index = number % 64
        first = 'A' if (number//21)%2==0 else 'B'
        last_body = pair('flow', number, lengths[number % len(lengths)],
                         (number//64)%255+1, 3000+index, index,
                         first=first, delay=number%21, phase=(number//42)%64)
        if number % 16 == 15:
            # A same-network replay must fail IC, rather than being credited
            # to RM. Its PSN still updates and the next consecutive SN recovers.
            group('replay', [last_body], idx=index)

    scenario.stage('independent_psn')
    scenario.config(4100, 100, ic=1, rm=0, skew=20)
    serial = 0
    for sn in IC_SEQUENCE:
        for net in ('A', 'B'):
            body = scenario.body(18, vlid=4100, sn=sn, net=net,
                                 payload=payload(0xf0000000+serial, 18))
            group('ic', [(net, body)], idx=100, rm=False)
            serial += 1
    # Both PSNs finish at101. Deliberately diverge the network histories:
    # A103 passes (+2), B104 fails (+3), then each network recovers by +1.
    for net, sn in (('A',103), ('B',104), ('A',104), ('B',105)):
        body = scenario.body(18, vlid=4100, sn=sn, net=net,
                             payload=payload(0xf0000000+serial, 18))
        group('ic_asymmetric', [(net, body)], idx=100, rm=False)
        serial += 1

    scenario.stage('window_edges')
    scenario.config(4101, 101, ic=0, rm=1, skew=20)
    for number, (first, units) in enumerate((('A',20), ('B',20), ('A',21), ('B',21))):
        pair('window', 0xf1000000+number, 17, number+1, 4101, 101,
             first=first, delay=units*STEP, phase=16, ic=False)

    scenario.stage('time_wrap')
    scenario.config(4102, 102, ic=0, rm=1, skew=20)
    # Initial clock release is E5. Position the first EOF eight clocks before
    # the next 16-bit wrap and its peer twelve clocks after that same wrap.
    period = 65536*STEP
    wrap = 5+((scenario.t-5)//period+1)*period
    while wrap-8-71 < scenario.t:
        wrap += period
    scenario.t = wrap-8-71
    pair('wrap', 0xf2000000, 17, 1, 4102, 102,
         first='B', delay=20, phase=(wrap-8-5)%STEP, ic=False)
    return scenario, groups


def generate(folder, pairs=16384):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=False)
    scenario, groups = workload(pairs)
    info = scenario.write(folder)
    if info['bytes']>4000000 or max(info['segments_a'],info['segments_b'])>25000:
        raise ValueError('workload exceeds rx_core_suite capture capacities')
    info.update(schema='reconstructed-rm04-v1', pairs=pairs, groups=len(groups),
                reconstructed=True, historical_source_recovered=False,
                scope='frame-count stress, not throughput or historical count reproduction')
    (folder/'rm_psn_manifest.json').write_text(json.dumps(info, indent=2)+'\n', encoding='utf-8')
    return info


def decode(wire):
    """Independent wire validation; no DUT descriptors or legacy decoder."""
    if wire[:8]!=PREAMBLE:
        raise ValueError('preamble')
    frame = wire[8:]
    if not 64<=len(frame)<=1518 or zlib.crc32(frame[:-4])!=int.from_bytes(frame[-4:], 'little'):
        raise ValueError('frame length/FCS')
    body = frame[:-4]
    if body[:4]!=b'\x03\0\0\0' or body[12:15]!=b'\x08\0\x45' or body[23]!=17:
        raise ValueError('AFDX/IPv4/UDP header')
    if int.from_bytes(body[20:22], 'big')&0x3fff or ip_checksum(body[14:34]):
        raise ValueError('nonfragmented IP checksum/flags')
    size = int.from_bytes(body[38:40], 'big')-8
    if not 1<=size<=1471 or int.from_bytes(body[16:18], 'big')!=size+28:
        raise ValueError('UDP/IP length')
    if len(frame)!=47+max(size,17):
        raise ValueError('wire length')
    if body[40:42]!=b'\0\0':
        pseudo = body[26:34]+b'\0\x11'+body[38:40]
        if ip_checksum(pseudo+body[34:42+size]):
            raise ValueError('UDP checksum')
    return dict(vlid=int.from_bytes(body[4:6], 'big'), sn=body[42+max(size,17)],
                sport=int.from_bytes(body[34:36], 'big'), dport=int.from_bytes(body[36:38], 'big'),
                payload=body[42:42+size])


def check(folder):
    folder = Path(folder)
    manifest = json.loads((folder/'vectors/rm_psn_manifest.json').read_text())
    scenario, groups = workload(manifest['pairs'])
    checks = errors = 0
    failures = []

    def expect(ok, label):
        nonlocal checks, errors
        checks += 1
        if not ok:
            errors += 1
            if len(failures)<100:
                failures.append(label)

    def interval(values, times, first, last):
        return values[bisect.bisect_right(times, first):bisect.bisect_right(times, last)]

    expect(manifest.get('schema')=='reconstructed-rm04-v1' and manifest.get('reconstructed') is True,
           'explicit reconstructed experiment identity')
    captures = []
    for net in ('A', 'B'):
        actual = []
        for row in (folder/('dump_'+net.lower()+'.txt')).read_text().splitlines():
            fields = row.split()
            expect(len(fields)==4 and fields[0]==net, 'capture format '+net)
            if len(fields)!=4:
                continue
            start, length = map(int, fields[1:3])
            wire = bytes.fromhex(fields[3])
            expect(length==len(wire), 'capture byte count '+net)
            actual.append((start, wire))
            captures.append(dict(net=net, start=start, end=start+length-1, wire=wire))
        expected = [(start, bytes(scenario.payload[offset:offset+length]))
                    for start, offset, length in scenario.frames[net]]
        expect(actual==expected, 'all scheduled source bytes/times captured exactly '+net)
    captures.sort(key=lambda frame: (frame['end'], frame['net']))
    rows = [line.split() for line in (folder/'events.txt').read_text().splitlines() if line.strip()]
    pulses = [dict(cycle=int(row[1]), name=row[2], used=False) for row in rows if row[0]=='E']
    deliveries = [dict(cycle=int(row[1]), net=row[2], idx=int(row[3]),
                       sport=int(row[4],16), dport=int(row[5],16), n=int(row[6]),
                       payload=bytes.fromhex(row[7]), used=False)
                  for row in rows if row[0]=='D']
    configs = [(int(row[1]), ' '.join(row[2:])) for row in rows if row[0]=='C']
    expected_configs = [(cycle, command[2:]) for cycle, _, command in sorted(scenario.events) if command.startswith('C ')]
    expect(configs==expected_configs, 'configuration events equal independent source schedule')
    expect(any(row[:4]==['K','5','0000','64'] for row in rows), 'accelerated coarse clock anchored at release E5')
    probes = [line.split() for line in (folder/'rm_psn_probe.txt').read_text().splitlines() if line.strip()]
    takes = sorted((int(row[1]), row[2]) for row in probes if row[0]=='T')
    pulses.sort(key=lambda row: row['cycle'])
    deliveries.sort(key=lambda row: row['cycle'])
    pulse_times = [row['cycle'] for row in pulses]
    delivery_times = [row['cycle'] for row in deliveries]
    take_times = [row[0] for row in takes]
    busy = sum(int(row[2]) for row in probes if row[0]=='B')
    expect(busy>0, 'descriptors arrived while engine was busy')
    expect(len(takes)==len(captures), 'every source frame has one observed engine take')
    psn = {}
    matrix = set()
    reverse = crosses = wraps = ic_rejects = rm_drops = sn_wraps = 0
    for number, group in enumerate(groups):
        first = min(frame['end'] for frame in group['frames'])
        last = max(frame['end'] for frame in group['frames'])
        decoded = []
        expected_results = collections.Counter()
        expected_deliveries = 0
        for frame in group['frames']:
            info = decode(frame['wire'])
            decoded.append(info)
            matching = [pulse for pulse in interval(pulses, pulse_times, frame['end'], frame['end']+32)
                        if not pulse['used'] and pulse['name']==frame['net'].lower()+'_good']
            expect(len(matching)==1, 'one good parser event per source frame group '+str(number))
            for pulse in matching:
                pulse['used'] = True
            key = (group['idx'], frame['net'])
            previous = psn.get(key)
            sn = info['sn']
            next_sn = 1 if previous in (None,255) else previous+1
            second = 1 if next_sn==255 else next_sn+1
            valid = not group['ic'] or previous is None or sn==0 or sn in (next_sn,second)
            if group['ic']:
                sn_wraps += previous==255 and sn==1
                psn[key] = sn
            if not valid:
                expected_results[frame['net'].lower()+'_ic'] += 1
                ic_rejects += 1
            else:
                expected_deliveries += 1
        if group['rm'] and expected_deliveries==2:
            a, b = group['frames']
            # These groups either lie well within SkewMax or align both EOFs
            # at phase16 so E+1..E+16 cannot straddle a clock-unit boundary.
            elapsed = abs((a['end']-5)//STEP-(b['end']-5)//STEP)
            if elapsed<=group['skew']:
                expected_deliveries = 1
                expected_results['rm_drop'] += 1
                rm_drops += 1
        expected_results['deliver'] += expected_deliveries
        expected_results += collections.Counter()  # Remove zero-count entries.
        result_pulses = [pulse for pulse in interval(pulses, pulse_times, first, last+150) if not pulse['used']]
        expect(collections.Counter(pulse['name'] for pulse in result_pulses)==expected_results,
               'independent IC/RM decisions group '+str(number))
        for pulse in result_pulses:
            pulse['used'] = True
        output = [delivery for delivery in interval(deliveries, delivery_times, first, last+450) if not delivery['used']]
        expect(len(output)==expected_deliveries, 'complete application delivery count group '+str(number))
        for delivery in output:
            expect(delivery['idx']==group['idx'] and delivery['sport']==decoded[0]['sport'] and
                   delivery['dport']==decoded[0]['dport'] and delivery['n']==len(decoded[0]['payload']) and
                   delivery['payload']==decoded[0]['payload'] and
                   delivery['net'] in {frame['net'] for frame in group['frames']},
                   'full source-derived delivery metadata/payload group '+str(number))
            delivery['used'] = True
        if expected_deliveries==2:
            expect({delivery['net'] for delivery in output}=={'A','B'}, 'out-of-window copies delivered once each')
        if group['kind']=='flow':
            a, b = group['frames']
            matrix.add((a['net'], b['end']-a['end'], (a['end']-5)%STEP))
            selected = [net for cycle, net in interval(takes, take_times, first, last+150)]
            expect(len(selected)==2, 'two frame arbitration observations per flow pair')
            if selected and a['end']<b['end'] and selected[0]==b['net']:
                reverse += 1
            crosses += (a['end']-5)//STEP!=(b['end']-5)//STEP
        if group['kind']=='wrap':
            a, b = group['frames']
            wraps += ((a['end']-5)//STEP)&65535 > (((b['end']-5)//STEP)&65535)
    expect(all(pulse['used'] for pulse in pulses), 'no extra classification/result/error pulses')
    expect(all(delivery['used'] for delivery in deliveries), 'no extra/partial/duplicate application deliveries')
    expect(matrix=={(net, delay, phase) for net in ('A','B') for delay in range(21) for phase in range(64)},
           'complete both-order x gap0..20 x all64 clock phases matrix')
    expect(reverse>0 and crosses>0 and wraps==1, 'reversed arbitration, coarse boundary and16-bit wrap reached')
    expect(ic_rejects>0 and rm_drops>0 and sn_wraps>=2, 'IC/RM rejects and both-network PSN wrap exercised independently')
    return dict(passed=errors==0, checks=checks, errors=errors, failures=failures,
                reconstructed=True, historical_counts_reproduced=False, pairs=manifest['pairs'],
                frames=len(captures), deliveries=len(deliveries), matrix_points=len(matrix),
                reversed_pairs=reverse, coarse_cross_pairs=crosses, wrap_pairs=wraps,
                busy_arrivals=busy, sn_wraps=sn_wraps, expected_ic_rejects=ic_rejects, expected_rm_drops=rm_drops)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    vectors = commands.add_parser('generate')
    vectors.add_argument('folder', type=Path)
    vectors.add_argument('--pairs', type=int, choices=PROFILES, default=16384)
    checker = commands.add_parser('check')
    checker.add_argument('folder', type=Path)
    runner = commands.add_parser('run')
    runner.add_argument('--runtime-source', type=Path, required=True)
    runner.add_argument('--compiler', type=Path, required=True)
    runner.add_argument('--out', type=Path)
    runner.add_argument('--pairs', type=int, choices=PROFILES, default=16384)
    runner.add_argument('--build-jobs', type=int, choices=range(1,5), default=2)
    runner.add_argument('--timeout', type=int, default=3600)
    args = parser.parse_args()
    if args.command=='generate':
        print(json.dumps(generate(args.folder, args.pairs), indent=2))
        return 0
    if args.command=='check':
        result = check(args.folder)
        (args.folder/'rm_psn_check.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
        print(json.dumps(result, indent=2))
        return 0 if result['passed'] else 1
    from run_open_verilator import Batch

    class RMBatch(Batch):
        def prepare(self, top, folder):
            if top!=TOP:
                raise ValueError('unexpected top')
            generate(folder/'vectors', args.pairs)

        def check(self, top, folder):
            self.pyjob(folder, 'check', 'gbe_rm_psn_ref.py', 'check', folder)
            return json.loads((folder/'rm_psn_check.json').read_text())

    args.profile = 'fragmentation1030'
    args.workers = 1
    batch = RMBatch(args)
    return batch.finish([batch.run(TOP)])


if __name__=='__main__':
    raise SystemExit(main())
