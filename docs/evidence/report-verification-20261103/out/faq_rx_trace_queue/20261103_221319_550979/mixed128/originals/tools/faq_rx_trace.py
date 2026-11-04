"""Prepare/execute a reduced native RX observation experiment, never full acceptance.

prepare reads existing FAQ load vectors as data; it never imports faq_load.py
or invokes the old executable. run is an explicit separate command for the
parent's single native slot. A preserved original HDL FAIL may still produce a
successful diagnostic collection; functional_pass is always false here.
"""
import argparse
from collections import Counter, deque
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from modelsim_compat import adapt_text

SCHEMA = 'faq-rx-native-observation-v1'
TOP = 'tb_faq_rx_trace'
BASE_TB = 'tb/tb_fragmentation.v'
WRAPPER = 'tb/tb_faq_rx_trace.v'
TOOLS = ('tools/faq_rx_trace.py','tools/modelsim_compat.py','tools/process_guard.py')
AUTHORITY = ('hardware_spec.yaml','hardware_contract.yaml')
CAPTURES = ('tx_messages.txt','tx_a.txt','tx_b.txt','rx.txt','events.txt','rx_internal_trace.txt')
ALLOWED_VECTORS = {'config.txt','schedule.txt','payload.hex','injection.txt','window.txt','injection.hex'}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save_new(path,data):
    with Path(path).open('x',encoding='utf-8') as stream:
        json.dump(data,stream,indent=2,ensure_ascii=False)
        stream.write('\n')


def require(ok,message):
    if not ok:
        raise ValueError(message)


def select_inputs(source,messages=None):
    """Copy the original configuration/payload bank, taking only schedule prefix."""
    source=Path(source).resolve()
    manifest=json.loads((source/'faq_manifest.json').read_text(encoding='utf-8'))
    require(manifest['test']=='faq_load','Expected a FAQ load source case')
    name=manifest['metadata']['case']
    require(name in ('mixed128','long128'),'Expected B mixed128 or C long128')
    minimum={'mixed128':180,'long128':20}[name]
    messages=minimum if messages is None else messages
    files={}
    hashes={}
    require(set(manifest['vectors'])<=ALLOWED_VECTORS,'Unexpected source vector path')
    require({'config.txt','schedule.txt','payload.hex','injection.txt'}<=set(manifest['vectors']),
            'Missing required source input')
    for filename,expected in manifest['vectors'].items():
        path=source/'vectors'/filename
        require(sha(path)==expected,'Original vector identity mismatch: '+filename)
        files[filename]=path.read_bytes()
        hashes[filename]=expected
    schedule=files['schedule.txt'].splitlines(keepends=True)
    original_count,payload_count,original_target=map(int,schedule[0].split())
    require(original_count==original_target==manifest['metadata']['messages'],
            'Source target/message metadata disagree')
    require(len(schedule)==original_count+1,'Unexpected source schedule row count')
    require(minimum<=messages<=original_count,'Prefix must include at least '+str(minimum)+' source messages')
    require(1<=payload_count<=65536,'Default tb_fragmentation payload bank capacity exceeded')
    payload=bytes(int(value,16) for value in files['payload.hex'].split())
    require(len(payload)==payload_count,'Source payload bank count mismatch')
    require(files['injection.txt'].split()==[b'0',b'0'],'Diagnostic requires the original no-injection load')
    config_lines=files['config.txt'].splitlines()
    require(int(config_lines[0])==128 and len(config_lines)==129,'Keep all original 128 configuration rows')
    configured={int(row.split()[0]) for row in config_lines[1:]}
    plan=[]
    last_due=-1
    for serial,line in enumerate(schedule[1:messages+1],1):
        due,vlid,n,offset=map(int,line.split())
        require(due>=last_due and vlid in configured and 1<=n<=8192 and 0<=offset<=payload_count-n,
                'Invalid normal prefix source message')
        data=payload[offset:offset+n]
        plan.append(dict(serial=serial,due=due,vlid=vlid,length=n,offset=offset,
                         payload_sha256=hashlib.sha256(data).hexdigest()))
        last_due=due
    files['schedule.txt']=(f'{messages} {payload_count} {messages}\n'.encode('ascii')+
                           b''.join(schedule[1:messages+1]))
    facts=dict(source_case=str(source),case=name,source_messages=original_count,
               messages=messages,target=messages,source_message_prefix=True,
               source_schedule_rows_preserved_exactly=True,configuration_rows_preserved=128,
               payload_bank_preserved_bytes=payload_count,first_due=plan[0]['due'],last_due=plan[-1]['due'],
               last_due_ms=plan[-1]['due']*.000008,
               source_vector_sha256=hashes,source_manifest_sha256=sha(source/'faq_manifest.json'),
               prefix_plan=plan,omitted_source_messages=original_count-messages,
               full_default_case_acceptance=False,
               scope='Reduced native internal RX event diagnosis only; preserved HDL result is not replaced.')
    return files,facts


def compatible(relative,raw):
    text,records=adapt_text(relative,raw.decode('utf-8-sig'))
    text,count=re.subn(r'\$finish_and_return\(1\)','$fatal(1)',text)
    if count:
        records.append(dict(path=relative,action='portable_failure_exit',count=count))
    # Exactly the already-reviewed native explicit-open port adaptation.
    optional={'rtl/afdx_app_tx.v':('.read_data(memory_q));','.read_data(memory_q),.raw_write_data());'),
              'rtl/afdx_app_rx.v':('.data(q_data));','.data(q_data),.next_limit());')}
    if relative in optional:
        old,new=optional[relative]
        if text.count(old)==1:
            text=text.replace(old,new)
            records.append(dict(path=relative,action='explicit_open_optional_input'))
        else:
            require(text.count(new)==1,'Reviewed optional native port site changed: '+relative)
    return text.encode('utf-8'),records


def model_tools(home=None):
    home=home or os.environ.get('MODELSIM_HOME')
    executable=Path(home)/'vsim.exe' if home else shutil.which('vsim.exe')
    require(bool(executable),'Set MODELSIM_HOME or provide --modelsim-home')
    folder=Path(executable).resolve().parent
    result={name:str(folder/(name+'.exe')) for name in ('vlib','vlog','vsim')}
    require(all(Path(path).is_file() for path in result.values()),'Native ModelSim tools missing')
    return result


def prepare(source,folder,messages=None,home=None):
    folder=Path(folder).resolve()
    folder.mkdir(parents=True,exist_ok=False)
    try:
        source=Path(source).resolve()
        files,facts=select_inputs(source,messages)
        native=model_tools(home)
        paths=[*sorted((ROOT/'rtl').glob('*.v')),ROOT/BASE_TB,ROOT/WRAPPER,
               *(ROOT/name for name in TOOLS+AUTHORITY)]
        identities=[]
        adaptations=[]
        for path in paths:
            relative=path.relative_to(ROOT).as_posix()
            raw=path.read_bytes()
            original=folder/'originals'/relative
            original.parent.mkdir(parents=True,exist_ok=True)
            original.write_bytes(raw)
            entry=dict(path=relative,sha256=sha(path))
            if path.suffix=='.v':
                if relative!=WRAPPER:
                    require(raw==(source/'originals'/relative).read_bytes(),
                            'Current original differs from source load HDL: '+relative)
                compiled,changes=compatible(relative,raw)
                target=folder/'compile_sources'/relative
                target.parent.mkdir(parents=True,exist_ok=True)
                target.write_bytes(compiled)
                entry['compiled_sha256']=sha(target)
                adaptations.extend(changes)
            identities.append(entry)
        (folder/'vectors').mkdir()
        (folder/'source_vectors').mkdir()
        for filename,data in files.items():
            (folder/'vectors'/filename).write_bytes(data)
            shutil.copyfile(source/'vectors'/filename,folder/'source_vectors'/filename)
        shutil.copyfile(source/'faq_manifest.json',folder/'source_faq_manifest.json')
        legacy=[str(folder/'compile_sources'/path.relative_to(ROOT)) for path in paths
                if path.suffix=='.v' and path.relative_to(ROOT).as_posix()!=WRAPPER]
        commands=[dict(name='vlib',args=[native['vlib'],'work'],timeout=30),
                  dict(name='compile_legacy',args=[native['vlog'],'-vlog01compat','+define+AFDX_CE_DIV=2',*legacy],timeout=180),
                  dict(name='compile_wrapper',args=[native['vlog'],'-sv','+define+AFDX_CE_DIV=2',str(folder/'compile_sources'/WRAPPER)],timeout=180),
                  dict(name='simulation',args=[native['vsim'],'-batch',TOP,'-wlf','simulation.wlf','-do','do run.do'],timeout=900)]
        (folder/'run.do').write_text('onerror {quit -code 1}\nonbreak {quit -code 1}\nrun -all\nquit -code 0\n',encoding='ascii')
        save_new(folder/'commands.json',commands)
        save_new(folder/'modelsim_adaptations.json',adaptations)
        save_new(folder/'prefix_plan.json',facts)
        # The original generator is observed as bytes only, never imported.
        load_tool=ROOT/'tools/faq_load.py'
        require(sha(load_tool).startswith('d3d2f2f6'),'Frozen faq_load.py identity differs from requested d3d2f2f6')
        artifacts={name:sha(folder/name) for name in ('run.do','commands.json','modelsim_adaptations.json','prefix_plan.json')}
        manifest=dict(schema=SCHEMA,top=TOP,status='prepared_not_compiled_or_simulated',
                      created=datetime.now().astimezone().isoformat(),source_prefix=facts,
                      sources=identities,vectors={name:sha(folder/'vectors'/name) for name in files},
                      prepared_artifacts=artifacts,tools=native,
                      frozen_load_generator_sha256=sha(load_tool),
                      limits=dict(process_tree_gib=1,minimum_free_gib=5),
                      scope='Current original RTL and original tb_fragmentation with an observation-only native wrapper.',
                      sampling='One observation per original posedge, after NBA plus 1ns; public TB captures remain unchanged.',
                      trace=dict(file='rx_internal_trace.txt',max_records=200000,
                                 triggers='raw parser/engine/reassembly events, query/result/commit, bank lifecycle, output-block changes, high-water bucket changes',
                                 high_water=3072,ring_capacity=4096,
                                 record_tags=dict(P='raw parser event and frame geometry',D='engine descriptor take',
                                                  E='raw engine decision/event',Q='reassembly query/result/reservation',
                                                  S='ring/DQ/shared stream/app snapshot',B='bank admission/copy/output state',
                                                  C='context lifecycle/pending/age',T='truncation',Z='final footer')),
                      functional_pass=False,full_default_case_acceptance=False)
        save_new(folder/'trace_manifest.json',manifest)
        verify(folder)
        return manifest
    except Exception as exc:
        save_new(folder/'prepare_failure.json',dict(error=str(exc),phase='prepare',functional_pass=False))
        raise


def verify(folder):
    folder=Path(folder)
    manifest=json.loads((folder/'trace_manifest.json').read_text(encoding='utf-8'))
    require(manifest['schema']==SCHEMA and manifest['top']==TOP,'Unexpected prepared diagnostic')
    source=Path(manifest['source_prefix']['source_case'])
    require(sha(source/'faq_manifest.json')==manifest['source_prefix']['source_manifest_sha256'],
            'Original source case manifest drift')
    require(sha(folder/'source_faq_manifest.json')==manifest['source_prefix']['source_manifest_sha256'],
            'Prepared original case manifest drift')
    files,facts=select_inputs(source,manifest['source_prefix']['messages'])
    require(facts==manifest['source_prefix'],'Source prefix facts drift')
    for row in manifest['sources']:
        require(sha(ROOT/row['path'])==row['sha256'] and sha(folder/'originals'/row['path'])==row['sha256'],
                'Original or prepared source drift: '+row['path'])
        if 'compiled_sha256' in row:
            require(sha(folder/'compile_sources'/row['path'])==row['compiled_sha256'],
                    'Compatible source snapshot drift: '+row['path'])
    for filename,expected in manifest['vectors'].items():
        require((folder/'vectors'/filename).read_bytes()==files[filename] and sha(folder/'vectors'/filename)==expected,
                'Diagnostic vector drift: '+filename)
        require(sha(folder/'source_vectors'/filename)==facts['source_vector_sha256'][filename],
                'Archived source vector drift: '+filename)
    for filename,expected in manifest['prepared_artifacts'].items():
        require(sha(folder/filename)==expected,'Prepared command/plan drift: '+filename)
    require(sha(ROOT/'tools/faq_load.py')==manifest['frozen_load_generator_sha256'],'Frozen original load generator drift')
    return manifest


def number(value,base=16):
    return int(value,base) if re.fullmatch('[0-9a-fA-F]+',value) else None


def collect(folder):
    """Classify raw event sources only; never infer ring-full from merged bit7."""
    folder=Path(folder)
    counts=Counter()
    parse=Counter()
    engine=Counter()
    reassembly=Counter()
    recent=deque(maxlen=128)
    witnesses=[]
    first_reject=None
    first_query_failure=None
    failed_queries=set()
    serial=0
    headers=[]
    footers=[]
    max_cycle=0
    first_events=[]
    state_peaks=dict(occupied_a=0,occupied_b=0,trial_used_a=0,trial_used_b=0,dq=0,app_used=0)
    with (folder/'rx_internal_trace.txt').open(encoding='ascii') as stream:
        for line in stream:
            row=line.split()
            require(len(row)>=2,'Malformed diagnostic trace row')
            tag,cycle=row[0],int(row[1])
            require(tag in ('H','P','D','E','Q','S','B','C','T','Z'),'Unknown trace record tag')
            fields=dict(token.split('=',1) for token in row[2:])
            record=dict(tag=tag,cycle=cycle,fields=fields)
            counts[tag]+=1
            max_cycle=max(max_cycle,cycle)
            bad=False
            if tag=='H':
                headers.append(fields)
            elif tag=='Z':
                footers.append(fields)
            elif tag=='P':
                event=number(fields['ev'])
                if event:
                    parse[fields['net']+':'+format(event,'02x')]+=1
                    bad=bool(event&0xfe)
            elif tag=='E':
                for net in ('a','b'):
                    event=number(fields['ev_'+net])
                    if event:
                        engine[net.upper()+':'+format(event,'02x')]+=1
                        bad=True
            elif tag=='Q':
                if fields['query']=='1':
                    serial+=1
                if fields['result_valid']=='1' and fields['ok']=='0':
                    failed_queries.add(serial)
                    if first_query_failure is None:
                        first_query_failure=record
                event=number(fields['reject'])
                if event:
                    reassembly[format(event,'x')]+=1
                    bad=True
            elif tag=='S':
                for field in state_peaks:
                    value=number(fields[field])
                    if value is not None:
                        state_peaks[field]=max(state_peaks[field],value)
            if bad:
                if len(first_events)<32:
                    first_events.append(record)
                if first_reject is None:
                    first_reject=record
                    witnesses.extend(recent)
            if first_reject and cycle<=first_reject['cycle']+64 and len(witnesses)<512:
                witnesses.append(record)
            recent.append(record)
    valid_footer=(len(headers)==1 and headers[0].get('version')=='1' and len(footers)==1 and
                  footers[0].get('truncated')=='0' and not counts['T'] and
                  int(footers[0]['records'])==sum(value for key,value in counts.items() if key not in ('H','Z')))
    return dict(trace_complete=valid_footer,record_counts=dict(counts),max_cycle=max_cycle,
                raw_parser_events=dict(parse),raw_engine_events=dict(engine),
                raw_reassembly_reject_events=dict(reassembly),failed_query_count=len(failed_queries),
                first_reject=first_reject,first_query_failure=first_query_failure,
                first_rejection_events=first_events,first_reject_window=witnesses,
                sampled_state_peaks=state_peaks,
                peak_note='Peaks over event/change-triggered snapshots only; not an exhaustive per-cycle maximum.',
                sampling='post-NBA plus 1ns; raw source pulses precede merged public registers/capture by their documented pipeline stages',
                functional_pass=False,full_default_case_acceptance=False)


def run_case(folder,timeout=900):
    folder=Path(folder).resolve()
    reserved=('work','commands.jsonl','run_summary.json','initial_failure.json',*CAPTURES)
    require(not any((folder/name).exists() for name in reserved),'Refuse to overwrite an earlier native attempt')
    summary=dict(collection_success=False,functional_pass=False,full_default_case_acceptance=False,phase='verify')
    old={name:os.environ.get(name) for name in ('AFDX_MEM_LIMIT_GB','AFDX_MEM_FLOOR_GB')}
    try:
        verify(folder)
        os.environ['AFDX_MEM_LIMIT_GB']='1'
        os.environ['AFDX_MEM_FLOOR_GB']='5'
        from process_guard import run
        commands=json.loads((folder/'commands.json').read_text(encoding='utf-8'))
        for item in commands:
            summary['phase']=item['name']
            with (folder/'commands.jsonl').open('a',encoding='utf-8') as stream:
                stream.write(json.dumps(item)+'\n')
            with (folder/(item['name']+'.log')).open('x',encoding='utf-8') as stream:
                process=run(item['args'],cwd=folder,stdout=stream,stderr=subprocess.STDOUT,
                            timeout=timeout if item['name']=='simulation' else item['timeout'],
                            metrics=folder/(item['name']+'.resources.json'))
            log=(folder/(item['name']+'.log')).read_text(encoding='utf-8',errors='replace')
            require(process.returncode==0,item['name']+' returned '+str(process.returncode))
            require(not re.search(r'\*\* (?:Error|Fatal|Warning)|RAMCOLL|%Error',log),
                    'Native diagnostic in '+item['name']+'.log')
        summary['phase']='collection'
        summary['trace']=collect(folder)
        results=re.findall(r'\[RESULT\] tb_fragmentation (PASS|FAIL)[^\r\n]*',log)
        require(len(results)==1,'Original child HDL outcome missing/ambiguous')
        summary['original_hdl_outcome']=results[0]
        summary['original_result_lines']=re.findall(r'\[RESULT\][^\r\n]*',log)
        require(summary['trace']['trace_complete'],'Trace truncated or final footer missing')
        verify(folder)
        summary.update(collection_success=True,phase='collected')
    except Exception as exc:
        summary['error']=str(exc)
        save_new(folder/'initial_failure.json',summary)
    finally:
        for name,value in old.items():
            if value is None:
                os.environ.pop(name,None)
            else:
                os.environ[name]=value
        try:
            verify(folder)
            summary['source_or_input_drift']=False
        except Exception as exc:
            summary.update(collection_success=False,source_or_input_drift=True,drift_error=str(exc))
        save_new(folder/'run_summary.json',summary)
    return summary


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('prepare')
    p.add_argument('--source-case',type=Path,required=True)
    p.add_argument('--messages',type=int)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--modelsim-home',type=Path)
    p=sub.add_parser('run')
    p.add_argument('folder',type=Path)
    p.add_argument('--timeout',type=int,default=900)
    p=sub.add_parser('collect')
    p.add_argument('folder',type=Path)
    p.add_argument('--result',default='collection.json')
    args=parser.parse_args()
    if args.command=='prepare':
        manifest=prepare(args.source_case,args.out,args.messages,args.modelsim_home)
        print(json.dumps(dict(folder=str(args.out.resolve()),status=manifest['status'],top=TOP,
                              case=manifest['source_prefix']['case'],messages=manifest['source_prefix']['messages'],
                              last_due_ms=manifest['source_prefix']['last_due_ms'],
                              functional_pass=False,full_default_case_acceptance=False),indent=2))
        return 0
    if args.command=='run':
        result=run_case(args.folder,args.timeout)
        print(json.dumps({key:value for key,value in result.items() if key!='trace'},indent=2))
        return 0 if result['collection_success'] else 1
    verify(args.folder)
    result=collect(args.folder)
    save_new(args.folder/args.result,result)
    print(json.dumps({key:value for key,value in result.items() if key!='first_reject_window'},indent=2))
    return 0 if result['trace_complete'] else 1


if __name__=='__main__':
    raise SystemExit(main())
