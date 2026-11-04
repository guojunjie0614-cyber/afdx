"""Focused public-GMII fault/VL isolation using an existing tb_fragmentation exe.

prepare verifies actual Verilator S dependencies and creates fresh input files.
run launches only that copied executable, with 1 GiB process-tree / 5 GiB free
memory guards. check launches no HDL. This measures GMII-to-application bounded
progress, NOT application-input-to-output 2 ms latency or line-rate throughput.
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
import struct
import subprocess
import sys
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
import fragment_ref as ref

DEFAULT_SOURCE = ROOT/'out/open_verilator/20261103_162731_314847/tb_fragmentation'
HEALTHY = 0x500
FAULTS = (0x501, 0x502, 0x503, 0x504)
PROGRESS_BOUND = 50000
ANALYSIS = ('tools/faq_fault.py', 'tools/fragment_ref.py', 'tools/process_guard.py',
            'hardware_spec.yaml', 'hardware_contract.yaml')
SCHEMA = 'faq-fault-isolation-v1'


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save_new(path, data):
    with Path(path).open('x', encoding='utf-8') as stream:
        json.dump(data, stream, indent=2, ensure_ascii=False)
        stream.write('\n')


def pattern(tag, n):
    return (tag.to_bytes(4, 'big')+bytes((tag*29+i*17+i//256)&255 for i in range(n)))[:n]


def rows(path):
    return [line.split() for line in Path(path).read_text(encoding='ascii').splitlines() if line.strip()]


def repair(frame, *, sn=None, offset=None):
    frame = bytearray(frame)
    if offset is not None:
        frame[20:22] = struct.pack('!H', offset)
        frame[24:26] = b'\0\0'
        frame[24:26] = struct.pack('!H', ref.checksum(frame[14:34]))
    if sn is not None:
        frame[-5] = sn
    frame[-4:] = struct.pack('<I', zlib.crc32(frame[:-4]))
    return bytes(frame)


def make_plan():
    """All source bytes, intended messages and timing derive from this plan."""
    initial = pattern(1, 32)
    commands, expected, stages = [], [], []
    wire = bytearray()
    cursor = 0
    healthy_sn = 1  # Public initial application transmission uses frame SN0.

    def emit(stage, name, frame, *, net=1, gap=6000):
        nonlocal cursor
        frame = bytearray(frame)
        if net==2:
            frame[11] = 0x40
            frame[-4:] = struct.pack('<I', zlib.crc32(frame[:-4]))
        raw = ref.PREAMBLE+bytes(frame)
        first = cursor+gap+2
        last = first+len(raw)-1
        command = dict(stage=stage, name=name, net=net, offset=len(wire),
                       length=len(raw), gap=gap, first_relative=first,
                       last_relative=last, wire_hex=raw.hex())
        wire.extend(raw)
        commands.append(command)
        cursor = last
        return len(commands)-1

    def normal(stage, name, vlid, tag, n, sn, ident, *, first_gap=6000, healthy=False):
        data = pattern(tag, n)
        frames = ref.build(data, vlid=vlid, ident=ident, sn=sn)
        first_index = len(commands)
        for index, frame in enumerate(frames):
            emit(stage, name, frame, gap=first_gap if index==0 else 512)
        expected.append(dict(stage=stage, name=name, vlid=vlid, payload_hex=data.hex(),
                             healthy=healthy, completion_index=len(commands)-1))
        return first_index, len(frames)

    def health(stage, which):
        nonlocal healthy_sn
        n = (64, 1472, 32)[which]
        _, count = normal(stage, 'healthy_'+str(which), HEALTHY,
                          10+stage*3+which, n, healthy_sn, 0x7000+stage*3+which,
                          healthy=True)
        for _ in range(count):
            healthy_sn = 1 if healthy_sn==255 else healthy_sn+1

    for stage, kind in enumerate(('missing_until_late_tail', 'bad_fcs_tail', 'replay', 'bad_offset')):
        vlid = FAULTS[stage]
        original = pattern(100+stage*10, 1472)
        frames = ref.build(original, vlid=vlid, ident=0x6000+stage*2, sn=1)
        opening = emit(stage, kind+'_first', frames[0])
        health(stage, 0)
        if stage==1:
            bad = bytearray(frames[1])
            bad[34] ^= 1  # Corrupt actual tail data without repairing FCS.
            emit(stage, 'bad_fcs_tail', bad, gap=512)
        elif stage==2:
            emit(stage, 'same_network_replay', frames[0], gap=512)
        elif stage==3:
            emit(stage, 'bad_offset_tail', repair(frames[1], offset=1), gap=512)
        health(stage, 1)
        if stage==2:
            emit(stage, 'cross_network_duplicate', frames[0], net=2, gap=512)
            # A bad forward jump is rejected by IC but still replaces A's
            # PSN1 with PSN7. The later legal tail must therefore use SN8.
            emit(stage, 'replay_with_bad_sequence_jump', repair(frames[0],sn=7), gap=512)
        health(stage, 2)
        if stage<3:
            tail = repair(frames[1],sn=8) if stage==2 else frames[1]
            closing = emit(stage, 'late_valid_tail', tail, gap=12000)
            expected.append(dict(stage=stage, name='original_completed_after_health', vlid=vlid,
                                 payload_hex=original.hex(), healthy=False, completion_index=closing))
            recovery_sn = 9 if stage==2 else 3
        else:
            # The valid but wrong-offset SN2 reaches IC, which advances PSN
            # even though admission rejects it. Recovery starts at SN3.
            closing = len(commands)
            recovery_sn = 3
        recovery_first, _ = normal(stage, 'new_id_recovery', vlid, 101+stage*10,
                                    1472, recovery_sn, 0x6001+stage*2,
                                    first_gap=12000 if stage==3 else 6000)
        if stage==3:
            closing = recovery_first
        stages.append(dict(stage=stage, kind=kind, fault_vlid=vlid, open_index=opening,
                           close_index=closing, expected_healthy_messages=3,
                           original_must_remain_absent=stage==3))
    expected.sort(key=lambda message: message['completion_index'])
    return dict(schema=SCHEMA, initial_payload_hex=initial.hex(),
                config=[(vl,1000,1471,1000,2000) for vl in (HEALTHY,)+FAULTS],
                commands=commands, injection_hex=bytes(wire).hex(), expected=expected,
                stages=stages, injection_cycles=cursor, progress_bound_cycles=PROGRESS_BOUND,
                scope='public GMII-to-application isolation and bounded progress; no 2ms application-input latency claim')


def independent_model(plan):
    """Independent IC/RM plus sequential reassembly; no DUT output/state input.

    Bad FCS does not advance IC. IC failures DO advance PSN. Reassembly
    admission failures do not refresh accepted RM history. Wide separation
    from SkewMax makes the coarse timestamp phase irrelevant in this matrix.
    """
    psn = {(HEALTHY,1):0, (HEALTHY,2):0}
    rm = {HEALTHY:(0,-1000000)}
    contexts = {}
    outputs = []
    events = collections.Counter(rm_drop=1)  # Initial public A/B SN0 pair.
    max_contexts = 0
    for index, command in enumerate(plan['commands']):
        raw = bytes.fromhex(command['wire_hex'])
        frame = raw[8:]
        net = command['net']
        prefix = 'a_' if net==1 else 'b_'
        if raw[:8]!=ref.PREAMBLE or not 64<=len(frame)<=1518:
            events[prefix+'len'] += 1
            continue
        if zlib.crc32(frame[:-4])!=int.from_bytes(frame[-4:], 'little'):
            events[prefix+'fcs'] += 1
            continue
        try:
            parsed = ref.decode(raw)
        except ValueError:
            events[prefix+'hdr'] += 1
            continue
        vlid, sn = parsed['vlid'], parsed['sn']
        if vlid not in (HEALTHY,)+FAULTS:
            raise ValueError('unconfigured source VL')
        key = (vlid,net)
        previous = psn.get(key)
        next_sn = 1 if previous in (None,255) else previous+1
        second = 1 if next_sn==255 else next_sn+1
        ic_ok = previous is None or sn==0 or sn in (next_sn,second)
        psn[key] = sn
        if not ic_ok:
            events[prefix+'ic'] += 1
            continue
        end = command['last_relative']
        if vlid in rm:
            old_sn, old_end = rm[vlid]
            forward = sn!=old_sn and (sn==0 or old_sn==0 or 1<=(sn-old_sn)%255<=127)
            if not forward:
                elapsed = end-old_end
                # Include both possible coarse-unit boundaries and pipeline
                # phase. Do not silently pick a timestamp to fit a DUT result.
                upper = (elapsed+32+4095)//4096
                lower = max(0,(elapsed-32)//4096)
                if upper<=20:
                    events['rm_drop'] += 1
                    continue
                if lower<=20:
                    raise ValueError('source plan straddles an ambiguous RM threshold')
        start = parsed['offset']
        data = parsed['data']
        last = start+len(data)
        context_key = tuple(parsed[field] for field in ('vlid','src','dst','protocol','ident'))
        if not parsed['mf'] and start==0:
            udp = data
        else:
            if start==0:
                total = int.from_bytes(data[4:6], 'big') if len(data)>=8 else 0
                if context_key in contexts or not parsed['mf'] or not 9<=total<=8200 or last>=total or last%8:
                    events[prefix+'ovf'] += 1
                    continue
                contexts[context_key] = dict(data=data,total=total)
                max_contexts = max(max_contexts,len(contexts))
            else:
                context = contexts.get(context_key)
                if (context is None or start!=len(context['data']) or last>context['total'] or
                        (parsed['mf'] and (last>=context['total'] or last%8)) or
                        (not parsed['mf'] and last!=context['total'])):
                    events[prefix+'ovf'] += 1
                    continue
                context['data'] += data
            rm[vlid] = (sn,end)
            if parsed['mf']:
                continue
            udp = contexts.pop(context_key)['data']
        if len(udp)<9 or len(udp)>8200 or int.from_bytes(udp[4:6],'big')!=len(udp):
            raise ValueError('source plan completed an invalid UDP length')
        if udp[6:8]!=b'\0\0' and ref.udp_sum(parsed['src'],parsed['dst'],udp):
            events[prefix+'ovf'] += 1
            continue
        rm[vlid] = (sn,end)
        outputs.append(dict(vlid=vlid,payload_hex=udp[8:].hex(),completion_index=index))
    intended = [(m['vlid'],m['payload_hex'],m['completion_index']) for m in plan['expected']]
    actual = [(m['vlid'],m['payload_hex'],m['completion_index']) for m in outputs]
    if actual!=intended:
        raise ValueError('independent protocol model disagrees with intended source-message plan')
    if dict(events)!=dict(rm_drop=2,a_fcs=1,a_ic=2,a_ovf=1):
        raise ValueError('unexpected source-plan fault classification: '+str(events))
    return dict(completed_messages=len(outputs),events=dict(events),live_contexts=len(contexts),max_contexts=max_contexts,
                final_psn={str(key):value for key,value in sorted(psn.items())})


def vector_files(plan):
    initial = bytes.fromhex(plan['initial_payload_hex'])
    wire = bytes.fromhex(plan['injection_hex'])
    if len(initial)>65536 or len(wire)>262144:
        raise ValueError('tb_fragmentation static input capacity exceeded')
    config = str(len(plan['config']))+'\n'+''.join(' '.join(map(str,row))+'\n' for row in plan['config'])
    schedule = f'1 {len(initial)} 1\n0 {HEALTHY} {len(initial)} 0\n'
    injection = f'{len(plan["commands"])} {len(wire)}\n'+''.join(
        f'{c["net"]} {c["offset"]} {c["length"]} {c["gap"]}\n' for c in plan['commands'])
    hex_lines = lambda data: ''.join(f'{byte:02x}\n' for byte in data)
    return {'config.txt':config,'schedule.txt':schedule,'payload.hex':hex_lines(initial),
            'injection.txt':injection,'injection.hex':hex_lines(wire)}


def source_identity(source):
    source = Path(source).resolve()
    build = json.loads((source/'build.json').read_text(encoding='utf-8'))
    if build['top']!='tb_fragmentation' or build['parameters']:
        raise ValueError('requires default-capacity tb_fragmentation executable')
    if 'elinx3.0' not in build['verilator'].lower() or Path(build['verilator']).name.lower()!='verilator.exe':
        raise ValueError('requires the eLinx bundled Verilator executable')
    if '-DAFDX_CE_DIV=2' not in build['commands'][0]:
        raise ValueError('requires the recorded CE2 build configuration')
    if not json.loads((source/'summary.json').read_text(encoding='utf-8')).get('passed'):
        raise ValueError('source executable case has no successful completed run')
    executable = source/'simulation.exe'
    if Path(build['executable']).resolve()!=executable:
        raise ValueError('build executable path differs')
    dat = source/'obj/Vsim__verFiles.dat'
    batch = source.parent
    dependencies, external = [], []
    for line in dat.read_text(encoding='utf-8').splitlines():
        match = re.match(r'^S\s+(\d+)\s+.*"([^"]+)"$',line)
        if not match:
            continue
        compiled = Path(match[2])
        try:
            relative = compiled.relative_to(batch/'sources')
        except ValueError:
            if compiled.suffix in ('.v','.vh'):
                raise ValueError('unexpected external HDL S dependency: '+str(compiled))
            external.append(line)
            continue
        if relative.suffix not in ('.v','.vh') or relative.parts[0] not in ('rtl','tb'):
            raise ValueError('unexpected actual S source dependency: '+str(relative))
        original, current = batch/'originals'/relative, ROOT/relative
        if current.read_bytes()!=original.read_bytes():
            raise ValueError('compiled/current original source mismatch: '+str(relative))
        if compiled.stat().st_size!=int(match[1]):
            raise ValueError('compiled S source byte count changed: '+str(compiled))
        # These actual dependencies require only the bundled simulator's
        # documented fatal-exit spelling adaptation and newline/BOM decoding.
        # No other semantic source transformation is accepted for this reuse.
        adapted = re.sub(r'\$finish_and_return\(1\)', '$fatal(1)',current.read_text(encoding='utf-8-sig'))
        if compiled.read_text(encoding='utf-8-sig')!=adapted:
            raise ValueError('compiled S text differs from the exact supported current-source adaptation: '+str(relative))
        dependencies.append(dict(path=relative.as_posix(),sha256=digest(current),
                                 compiled=str(compiled),compiled_sha256=digest(compiled)))
    paths = {row['path'] for row in dependencies}
    required_rtl = {path.relative_to(ROOT).as_posix() for path in (ROOT/'rtl').glob('*.v')}
    if paths!=required_rtl|{'tb/tb_fragmentation.v'}:
        raise ValueError('actual S dependencies must contain the full current RTL and exactly tb_fragmentation')
    return dict(source=str(source),executable=str(executable),executable_sha256=digest(executable),
                dependencies=sorted(dependencies,key=lambda row:row['path']),external_S_records=external,
                dependency_manifest_sha256=digest(dat),build_sha256=digest(source/'build.json'))


def prepare(source, folder):
    folder = Path(folder).resolve()
    folder.mkdir(parents=True,exist_ok=False)
    try:
        identity = source_identity(source)
        plan = make_plan()
        modeled = independent_model(plan)
        vectors = vector_files(plan)
        (folder/'vectors').mkdir()
        for name, text in vectors.items():
            (folder/'vectors'/name).write_text(text,encoding='ascii')
        shutil.copyfile(identity['executable'],folder/'simulation.exe')
        for row in identity['dependencies']:
            target = folder/'originals'/row['path']
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(ROOT/row['path'],target)
        analysis = []
        for relative in ANALYSIS:
            target = folder/'analysis_sources'/relative
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(ROOT/relative,target)
            analysis.append(dict(path=relative,sha256=digest(ROOT/relative)))
        save_new(folder/'source_plan.json',plan)
        manifest = dict(schema=SCHEMA,status='prepared_not_simulated',source_identity=identity,
                        prepared=datetime.now().astimezone().isoformat(),analysis=analysis,
                        vector_sha256={name:digest(folder/'vectors'/name) for name in vectors},
                        source_plan_sha256=digest(folder/'source_plan.json'),
                        model=modeled,normal_healthy_deliveries=13,all_expected_deliveries=20,
                        injection_frames=len(plan['commands']),injection_bytes=len(bytes.fromhex(plan['injection_hex'])),
                        injection_cycles=plan['injection_cycles'],
                        limits=dict(process_tree_gib=1,minimum_free_gib=5),scope=plan['scope'],
                        limitations=['GMII injection times follow the frozen public-pin file driver; this reused TB does not capture its injected GMII input separately.',
                                     'No context timeout/cleanup claim; wrong-offset context intentionally remains incomplete.',
                                     'This is isolation/bounded progress, not application-input 2ms latency or throughput.'])
        save_new(folder/'faq_fault_manifest.json',manifest)
        return manifest
    except Exception as exc:
        save_new(folder/'prepare_failure.json',dict(error=str(exc),phase='prepare',passed=False))
        raise


def verify_prepared(folder):
    folder = Path(folder)
    manifest = json.loads((folder/'faq_fault_manifest.json').read_text(encoding='utf-8'))
    if manifest['schema']!=SCHEMA:
        raise ValueError('unexpected prepared experiment')
    if source_identity(manifest['source_identity']['source'])!=manifest['source_identity']:
        raise ValueError('original executable or actual S dependencies drifted')
    if digest(folder/'simulation.exe')!=manifest['source_identity']['executable_sha256']:
        raise ValueError('prepared executable drifted')
    for row in manifest['source_identity']['dependencies']:
        if digest(folder/'originals'/row['path'])!=row['sha256']:
            raise ValueError('prepared original source drifted: '+row['path'])
    for row in manifest['analysis']:
        if digest(ROOT/row['path'])!=row['sha256'] or digest(folder/'analysis_sources'/row['path'])!=row['sha256']:
            raise ValueError('analysis source drifted: '+row['path'])
    for name, expected in manifest['vector_sha256'].items():
        if digest(folder/'vectors'/name)!=expected:
            raise ValueError('prepared input drifted: '+name)
    if digest(folder/'source_plan.json')!=manifest['source_plan_sha256']:
        raise ValueError('prepared source plan drifted')
    return manifest


def public_checks(folder):
    """Check only source-plan facts and public output captures; no DUT state."""
    folder = Path(folder)
    plan = make_plan()
    modeled = independent_model(plan)
    checks = errors = 0
    failures = []

    def expect(ok, label):
        nonlocal checks,errors
        checks += 1
        if not ok:
            errors += 1
            if len(failures)<100:
                failures.append(label)
        return bool(ok)

    for name, text in vector_files(plan).items():
        expect((folder/'vectors'/name).read_text(encoding='ascii')==text,'independent exact source input '+name)
    initial = bytes.fromhex(plan['initial_payload_hex'])
    tx = rows(folder/'tx_messages.txt')
    epochs = [int(row[1]) for row in tx if row[0]=='E']
    sent = [list(map(int,row)) for row in tx if row[0]!='E']
    expect(len(epochs)==1 and len(sent)==1,'one public application baseline before GMII injection')
    if sent:
        start,end,vlid,n = sent[0]
        expect(vlid==HEALTHY and n==len(initial) and end-start+1==n+2,'baseline public application framing')
    baseline_frames = []
    for net in ('a','b'):
        frames = rows(folder/('tx_'+net+'.txt'))
        expect(len(frames)==1,'only one planned baseline TX frame on '+net)
        for timestamp, raw in frames:
            decoded = ref.decode(bytes.fromhex(raw))
            expect(decoded['vlid']==HEALTHY and decoded['sn']==0 and not decoded['mf'] and
                   decoded['offset']==0 and decoded['src']==0x0a000101 and decoded['dst']==0xe0e00500,
                   'baseline independent wire header/SN '+net)
            udp = decoded['data']
            expect(udp[:4]==struct.pack('!HH',1000,2000) and int.from_bytes(udp[4:6],'big')==len(udp) and
                   udp[8:]==initial and (udp[6:8]==b'\0\0' or ref.udp_sum(decoded['src'],decoded['dst'],udp)==0),
                   'baseline independent wire payload/UDP '+net)
            baseline_frames.append(decoded)
    if len(baseline_frames)==2:
        expect(all(baseline_frames[0][key]==baseline_frames[1][key]
                   for key in ('vlid','ident','sn','offset','mf','data')),'baseline A/B identity')
    delivered = []
    for first,last,vlid,raw in rows(folder/'rx.txt'):
        first,last,vlid = int(first),int(last),int(vlid,16)
        data = bytes.fromhex(raw)
        expect(last-first+1==len(data)+2,'continuous complete VLID+payload output')
        delivered.append(dict(first=first,last=last,vlid=vlid,payload_hex=data.hex()))
    expected = [dict(vlid=HEALTHY,payload_hex=initial.hex())]+plan['expected']
    expect([(m['vlid'],m['payload_hex']) for m in delivered]==[(m['vlid'],m['payload_hex']) for m in expected],
           'all planned complete messages exactly once; no partial, wrong-VL, duplicate or malformed output')
    healthy_progress = []
    if delivered:
        # tb_fragmentation observes the baseline valid falling at last+1,
        # waits2000 negative edges, then enables injection at last+2001.
        # Its per-command wait/drive/deassert loops give relative times below.
        anchor = delivered[0]['last']+2001
        by_name = {}
        for actual,intended in zip(delivered[1:],plan['expected']):
            completion = plan['commands'][intended['completion_index']]
            eof = anchor+completion['last_relative']
            expect(actual['first']>eof-2,'no application prefix before complete source datagram')
            if intended['healthy']:
                latency = actual['last']-eof
                expect(0<latency<=PROGRESS_BOUND,'healthy GMII-to-application bounded completion')
                healthy_progress.append(latency)
                by_name[(intended['stage'],intended['name'])] = actual
        for stage in plan['stages']:
            opening = anchor+plan['commands'][stage['open_index']]['last_relative']
            closing = anchor+plan['commands'][stage['close_index']]['first_relative']
            outputs = [by_name.get((stage['stage'],'healthy_'+str(i))) for i in range(3)]
            expect(all(message and opening<message['first']<=message['last']<closing-2 for message in outputs),
                   'three healthy messages complete during fault-context interval '+stage['kind'])
    expect(len(healthy_progress)==12,'all twelve interleaved healthy messages satisfy progress/isolation')
    observed_events = collections.Counter()
    finals = []
    for row in rows(folder/'events.txt'):
        if row[0]=='FINAL':
            finals.append(list(map(int,row[1:])))
            continue
        cycle,tx_event,ev_a,ev_b,app,rm = row
        expect(int(tx_event,16)&0x1e==0 and int(app,16)==0,'no unrelated application/TX rejection')
        for net,value in (('a',int(ev_a,16)),('b',int(ev_b,16))):
            for bit,name in enumerate(('good','fcs','len','hdr','unk','cfg','ic','ovf')):
                if bit and value&(1<<bit):
                    observed_events[net+'_'+name] += 1
        if int(rm,16):
            observed_events['rm_drop'] += 1
    expect(dict(observed_events)==modeled['events'],'independent exact FCS/IC/RM/offset admission rejection ledger')
    expect(finals==[[len(expected),0,0]],'final complete-delivery/drop totals')
    return dict(passed=errors==0,checks=checks,errors=errors,failures=failures,
                expected_deliveries=len(expected),observed_deliveries=len(delivered),
                healthy_during_fault_deliveries=len(healthy_progress),
                max_healthy_gmii_completion_cycles=max(healthy_progress,default=None),
                progress_bound_cycles=PROGRESS_BOUND,events=dict(observed_events),
                source_plan_model=modeled,scope=plan['scope'],
                timing_note='Injected GMII timing is derived from the frozen public file-driver schedule, with a two-cycle conservative boundary margin; not an application-input latency metric.')


def check_case(folder, result_name='faq_fault_check.json'):
    folder = Path(folder)
    try:
        verify_prepared(folder)
        result = public_checks(folder)
        verify_prepared(folder)
    except Exception as exc:
        result = dict(passed=False,error=str(exc),errors=1,phase='independent_check')
    save_new(folder/result_name,result)
    return result


def run_case(folder, timeout=180):
    folder = Path(folder).resolve()
    reserved = ('simulation.log','run_summary.json','initial_failure.json','command.json',
                'faq_fault_check.json','tx_messages.txt','tx_a.txt','tx_b.txt','rx.txt','events.txt')
    if any((folder/name).exists() for name in reserved):
        raise ValueError('run requires an unexecuted prepared directory; preserve earlier attempts')
    outcome = dict(passed=False,phase='verify_prepared',limits=dict(process_tree_gib=1,minimum_free_gib=5))
    old = {name:os.environ.get(name) for name in ('AFDX_MEM_FLOOR_GB','AFDX_MEM_LIMIT_GB')}
    try:
        verify_prepared(folder)
        os.environ['AFDX_MEM_FLOOR_GB'] = '5'
        os.environ['AFDX_MEM_LIMIT_GB'] = '1'
        from process_guard import run
        outcome['phase'] = 'simulation'
        command = [str(folder/'simulation.exe')]
        save_new(folder/'command.json',dict(command=command,cwd=str(folder),timeout_seconds=timeout))
        with (folder/'simulation.log').open('x',encoding='utf-8') as stream:
            process = run(command,cwd=folder,stdout=stream,stderr=subprocess.STDOUT,timeout=timeout,
                          metrics=folder/'simulation.resources.json')
        log = (folder/'simulation.log').read_text(encoding='utf-8',errors='replace')
        outcome['returncode'] = process.returncode
        outcome['results'] = re.findall(r'\[RESULT\][^\r\n]*',log)
        if process.returncode or not re.search(r'\[RESULT\] tb_fragmentation PASS errors=0 deliveries=20\b',log) or re.search(r'\[FAIL\]|\[RESULT\].*FAIL|RAMCOLL|%Error|\*\* (?:Error|Fatal)',log):
            raise ValueError('HDL did not complete the expected positive experiment')
        outcome['phase'] = 'independent_check'
        checked = check_case(folder)
        outcome['check'] = checked
        if not checked['passed']:
            raise ValueError('independent fault-isolation check failed')
        verify_prepared(folder)
        outcome.update(passed=True,phase='complete')
    except Exception as exc:
        outcome['error'] = str(exc)
        if not (folder/'initial_failure.json').exists():
            save_new(folder/'initial_failure.json',outcome)
    finally:
        for name,value in old.items():
            if value is None:
                os.environ.pop(name,None)
            else:
                os.environ[name] = value
        # Record drift even if the simulator failed first; never hide that
        # first failure by rewriting it into a later successful recheck.
        try:
            verify_prepared(folder)
            outcome['source_and_input_drift'] = False
        except Exception as exc:
            outcome['source_and_input_drift'] = True
            outcome['drift_error'] = str(exc)
            outcome['passed'] = False
            if not (folder/'initial_failure.json').exists():
                save_new(folder/'initial_failure.json',outcome)
        save_new(folder/'run_summary.json',outcome)
    return outcome


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command',required=True)
    prepare_args = sub.add_parser('prepare')
    prepare_args.add_argument('--source',type=Path,default=DEFAULT_SOURCE)
    prepare_args.add_argument('--out',type=Path,required=True)
    run_args = sub.add_parser('run')
    run_args.add_argument('folder',type=Path)
    run_args.add_argument('--timeout',type=int,default=180)
    check_args = sub.add_parser('check')
    check_args.add_argument('folder',type=Path)
    check_args.add_argument('--result',default='faq_fault_check.json')
    args = parser.parse_args()
    if args.command=='prepare':
        result = prepare(args.source,args.out)
        brief = {key:result[key] for key in ('status','injection_frames','injection_bytes',
                 'injection_cycles','all_expected_deliveries','limits','scope')}
        brief['folder'] = str(args.out.resolve())
        print(json.dumps(brief,indent=2,ensure_ascii=False))
        return 0
    if args.command=='run':
        result = run_case(args.folder,args.timeout)
    else:
        result = check_case(args.folder,args.result)
    print(json.dumps(result,indent=2,ensure_ascii=False))
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
