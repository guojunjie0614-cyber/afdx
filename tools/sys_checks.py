"""Coverage assertions for T5; all evidence is reconstructed from records."""
import bisect
import collections
from sys_ref import COUNTERS


def coverage(test, sysrows, endpoints, expected, writes, reads, samples, expect):
    messages = [m for ep in endpoints.values() for m in ep['messages']]
    accepted = [m for m in messages if m['result'] == 'accept']
    pulses = collections.Counter(name for ep in endpoints.values() for name, times in ep['pulses'].items() for _ in times)
    stages = {p[2] for _, _, p in sysrows if p[0] == 'P'}
    for number, ep in endpoints.items():
        expect(any(m['result'] == 'accept' for m in ep['messages']), f'coverage ES{number} sends traffic')
        expect(bool(ep['deliveries']), f'coverage ES{number} receives traffic')
    expect(endpoints[1]['releases'] and endpoints[2]['releases'] and
           (endpoints[2]['releases'][0]-endpoints[1]['releases'][0]) % 8 != 0 and
           endpoints[2]['releases'][0] > endpoints[1]['releases'][0], 'coverage independent initial reset phases')
    for link in range(4):
        expect(any(p[0] == 'L' and int(p[2]) == link and int(p[3]) % 8 for _, _, p in sysrows),
               f'coverage link {link} non-byte delay')
    if test == 'tb_sys_basic':
        for number, ep in endpoints.items():
            good = [m for m in ep['messages'] if m['result'] == 'accept']
            expect(len({m['vl'] for m in good}) >= 4, f'basic ES{number} four VLs')
            expect(len({m['words'][1] for m in good}) >= 4, f'basic ES{number} distinct BAGs')
            expect(len({(m['words'][0]>>9)&2047 for m in good}) >= 4, f'basic ES{number} distinct maximums')
            expect({1, 17, 18, 1471} <= {m['n'] for m in good} and len({m['n'] for m in good}) >= 5,
                   f'basic ES{number} length matrix')
            expect({m['pen'] for m in good} == {0, 1}, f'basic ES{number} port overrides')
            expect({1, 2, 3} <= {(m['words'][0]>>1)&3 for m in good}, f'basic ES{number} A/B/AB')
            expect(all(m['uid']&255 and m['uid']>>8 for m in good), f'basic ES{number} USER_ID two nonzero bytes')
    elif test == 'tb_sys_fault':
        for net in ('a', 'b'):
            for name in ('fcs', 'len', 'hdr', 'unk', 'ic', 'cfg'):
                expect(pulses[net+'_'+name] > 0, f'fault {net}_{name} exercised')
        expect(pulses['rm_drop'] > 0, 'fault redundancy rejection exercised')
        expect(len(stages) >= 8, 'fault six fault stages plus loss and config')
        modes = {p[4] for _, _, p in sysrows if p[0] == 'A'}
        expect({'drop', 'hold', 'xor'} <= modes and any(p[0]=='R' for _, _, p in sysrows), 'fault drop/xor/hold/replay')
        expect(sum(p[0]=='J' for _, _, p in sysrows) >= 8, 'fault malformed injections on both networks')
        seen = {COUNTERS[r['addr']] for r in reads if r['addr'] in COUNTERS and r['value']}
        expect({'a_fcs', 'b_fcs', 'a_len', 'b_len', 'a_hdr', 'b_hdr', 'a_unk', 'b_unk',
                'a_cfg', 'b_cfg', 'a_ic', 'b_ic', 'rm_drop'} <= seen, 'fault counters observed nonzero')
        expect({'gdrop_a','gdrop_b'}<=stages and {'a_gdrop','b_gdrop'}<=seen,
               'fault both adapter overflow counters observed nonzero')
        for stage in ('ip_hdr', 'udp_hdr'):
            expect(stage in stages, 'fault distinct '+stage+' phase')
            for number, ep in endpoints.items():
                for net in ('a', 'b'):
                    expect(ep['pulse_stages'][stage][net+'_hdr'] == 1,
                           f'fault {stage} ES{number} {net} exactly one header rejection')
        marks = [(c,p[2]) for c,_,p in sysrows if p[0]=='P']
        reverse_counters = {name:address for address,name in COUNTERS.items()}
        for k,(start,stage) in enumerate(marks):
            end = marks[k+1][0] if k+1<len(marks) else 1<<60
            for number,ep in endpoints.items():
                for name,amount in ep['pulse_stages'][stage].items():
                    if amount and name in reverse_counters:
                        last=max(c for c in ep['pulses'][name] if start<=c<end)
                        expect(any(r['es']==number and r['addr']==reverse_counters[name] and last<r['cycle']<end for r in reads),
                               f'fault {stage} ES{number} reads final {name} count')
    elif test == 'tb_sys_delay':
        differences = []; edges = set(); outside = []
        for m in accepted:
            fs = sorted((f for f in m['copies'] if f['effective']), key=lambda f:f['net'])
            if len(fs) != 2:
                continue
            a, b = fs; differences.append(b['end']-a['end'])
            destination = endpoints[2 if m['es']==1 else 1]
            clocks = destination['clocks']; times = [x[0] for x in clocks]
            def now(c):
                k, value, step = clocks[bisect.bisect_right(times, c)-1]
                return (value+(c-k)//step)&65535
            # F is the first low cycle, while the RX checker's e is F-1.
            arrivals = [{now(f['end']+offset) for offset in range(16)} for f in (a,b)]
            if len(arrivals[0]) == len(arrivals[1]) == 1:
                first, second = (a,b) if a['end'] <= b['end'] else (b,a)
                delta = (now(second['end'])-now(first['end']))&65535
                skew = (first['control']>>5)&4095
                if delta == skew:
                    expect(a.get('queue_wait')==b.get('queue_wait')==0,'delay exact boundary has no adapter queue wait')
                    expect(len(m['deliveries']) == 1, 'delay exact skew delivers once')
                    edges.add('at')
                if delta == skew+1:
                    expect(a.get('queue_wait')==b.get('queue_wait')==0,'delay outside boundary has no adapter queue wait')
                    expect(len(m['deliveries']) == 2, 'delay skew+1 delivers twice')
                    edges.add('over')
            if 'outside' in m['stage']:
                outside.append((m, abs(b['end']-a['end'])))
        expect(any(d==0 for d in differences) and any(d>15 for d in differences) and any(d < -15 for d in differences),
               'delay equal/A earlier/B earlier')
        expect(edges == {'at','over'}, 'delay unique coarse-time exact boundary pairs')
        expect(bool(outside), 'delay explicit outside stage')
        for m, delta in outside:
            others = [x for x in accepted if x['es']==m['es'] and x['vl']==m['vl'] and x['stage']==m['stage'] and x['cycle']>m['cycle']]
            if others:
                nxt = min(others, key=lambda x:x['cycle'])
                expect(nxt['cycle']-m['cycle'] > delta+10000, 'delay outside isolation gap')
    elif test == 'tb_sys_load':
        cfg_indices = {int(p[3],16) for _,_,p in endpoints[2]['rxrows'] if p[0]=='C' and p[2]=='cfg'}
        expect(len(cfg_indices) == 4096, 'load ES2 configures all 4096 receive VLs')
        es1 = [m for m in accepted if m['es']==1]
        expect(len({m['vl'] for m in es1}) == 128, 'load ES1 all 128 TX VLs')
        used = {d['idx'] for d in endpoints[2]['deliveries']}
        expect(len(used) >= 256 and {0,4095} <= used, 'load receive indices cover 0/4095 plus 254')
        small = [m for m in es1 if ((m['words'][0]>>9)&2047)==153]
        expect(len({m['vl'] for m in small}) >= 16 and any(m['w_limit']==33160 for m in small), 'load 16 by 153 P7 window')
        expect(all(pulses[n] for n in ('drop_dis','drop_full','drop_long','drop_nopage')), 'load all TX rejection classes')
        expect(any(r['addr']==0x40 and r['value']>300 for r in reads), 'load accept counter exceeds 300')
        a = endpoints[1]['tx']; b = endpoints[2]['tx']
        expect(any(x['start']<y['end'] and y['start']<x['end'] for x in a for y in b), 'load simultaneous directions')
    elif test == 'tb_sys_cfg':
        for segment in (0x3,0x80,0x1400,0x21000,0x30000):
            size = 1 if segment < 0x100 else (0x400 if segment == 0x1400 else 0x1000)
            expect(any(segment<=w['addr']<segment+size for w in writes), f'cfg unmapped write {segment:x}')
            expect(any(segment<=r['addr']<segment+size and r['value']==0 for r in reads), f'cfg unmapped read {segment:x}')
        expect({0,1,2} <= {r['addr'] for r in reads}, 'cfg VERSION/STATUS/USER_ID reads')
        expect(any(w['addr']==2 and any(r['es']==w['es'] and r['addr']==2 and r['cycle']==w['cycle'] for r in reads) for w in writes),
               'cfg same-cycle USER_ID read/write')
        for name in ('tx','map','cfg'):
            subset = [w for w in writes if w['table']==name and w['rewrite']]
            expect(len(subset)>=200 and any(w['wait']>=2 for w in subset), f'cfg {name} >=200 writes with actual contention')
        expect({w['index']%8 for w in writes if w['table']=='tx' and w['rewrite']} >= set(range(6)), 'cfg all six TX words rewritten')
        for address in (0x40,0x45,0x48,0x59):
            found = False
            for number, ep in endpoints.items():
                times = {r['cycle'] for r in reads if r['es']==number and r['addr']==address}
                found |= any(t-1 in times and t in times for t in times) and any(
                    p in times or p+1 in times for p in ep['pulses'][COUNTERS[address]])
            expect(found, f'cfg counter {address:x} read every cycle around pulses')
        marks=[(c,p[2]) for c,_,p in sysrows if p[0]=='P']
        changes=[w for w in writes if w['table']=='tx' and not w['rewrite'] and w['index']%8==0 and
                 any(name=='new_value' and c<=w['cycle'] and not any(c<cc<=w['cycle'] for cc,_ in marks) for c,name in marks)]
        expect(any(w['wait']>=2 for w in changes),'cfg new-value write actually blocked')
        affected=[m for m in messages if m['stage']=='new_value']
        expect(any(m['result']=='drop_long' for m in affected) and any(m['result']=='accept' for m in affected),
               'cfg changed max_payload alters probe admission and preserves shorter messages')
    elif test == 'tb_sys_reset':
        for number, ep in endpoints.items():
            expect(len(ep['resets'])>=2, f'reset ES{number} reset during traffic')
            for z in ep['resets'][1:]:
                following = min((i for i in ep['inits'] if i>z), default=1<<60)
                zero = {r['addr'] for r in reads if r['es']==number and z<r['cycle']<following and r['value']==0}
                expect(set(COUNTERS)|{2} <= zero, f'reset ES{number} all counters and USER_ID read zero before init')
            expect(ep['pulses']['a_unk'] or ep['pulses']['b_unk'], f'reset ES{number} unknown before reconfiguration')
    elif test == 'tb_sys_ovf':
        for number, ep in endpoints.items():
            expect(ep['params']['RX_RING_AW']==9, 'ovf 512-byte ring parameter')
            fs = expected[number]
            for net in ('A','B'):
                big = [f for f in fs if f['net']==net and f['info'].get('n',0)>512]
                expect(bool(big) and len(ep['pulses'][net.lower()+'_ovf'])==len(big), f'ovf ES{number} {net} exact oversize count')
                for a,b in zip(big,big[1:]):
                    expect(any(a['end']<d['cycle']<b['start'] and d['n']<=512 for d in ep['deliveries']), 'ovf normal delivery separates oversized frames')
            expect(all(d['n']<=512 for d in ep['deliveries']), 'ovf no oversized application delivery')
    elif test == 'tb_sys_net':
        last = max([c for c,_,_ in sysrows]+[f['end'] for ep in endpoints.values() for f in ep['rx']])
        expect(last<=200000, 'net at most 200000 cycles')
        expect(pulses['a_fcs']+pulses['b_fcs']>=1, 'net FCS fault included')
