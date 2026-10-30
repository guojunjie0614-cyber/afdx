"""T65 UCDB collection; never calls T64 mutation/publish/collection functions."""
import csv
import hashlib
import json
from pathlib import Path
import queue
import re
import subprocess
import threading
import time
import psutil
from t65_run import ROOT,BASE,EVID,MS,load,save,sha,now,original_check,resources,terminate_tree
from t65_check import check

RAW=EVID/'raw'
WORK=BASE/'coverage'
METRICS=['Statements','Branches','Conditions','Expressions','FSM States','FSM Transitions','Toggles']

def vc(label,args,ucdb):
    args=list(map(str,args));command=[str(MS/'vcover.exe'),*args]
    log=RAW/(label+'_command.txt');meta=WORK/(label+'.json')
    key=dict(command=command,source_sha256=sha(ucdb))
    output=Path(args[args.index('-output')+1]) if '-output' in args else (Path(args[3]) if args[0]=='merge' else None)
    if meta.exists() and log.exists():
        old=load(meta)
        if old.get('key')==key and old.get('log_sha256')==sha(log) and (output is None or output.exists() and old.get('output_sha256')==sha(output)):
            return log.read_text(encoding='utf-8')
    resources()
    p=subprocess.run(command,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=600,creationflags=subprocess.CREATE_NO_WINDOW)
    text=p.stdout.decode('utf-8',errors='replace');log.write_text(text,encoding='utf-8')
    assert p.returncode==0 and not re.search(r'\*\* (Error|Fatal|Warning):',text),(label,p.returncode)
    save(meta,dict(key=key,exit_code=p.returncode,log_sha256=sha(log),output_sha256=sha(output) if output else None))
    return text

def names(text):
    return {s.strip() for s in text.splitlines() if re.fullmatch(r'tb_\w+_\d{8}_\d{6}_\d+',s.strip())}

def native(ucdb,label):
    """Stop at first instance scope, with an OS process identity check and 90s limit."""
    target=WORK/(label+'_du_native.txt');meta=WORK/(label+'_dump.json')
    if meta.exists() and target.exists() and load(meta).get('source_sha256')==sha(ucdb) and load(meta).get('sha256')==sha(target):
        return parse_native(target)
    resources()
    command=[str(MS/'vcover.exe'),'dump',str(ucdb),'-canonical']
    p=subprocess.Popen(command,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
    proc=psutil.Process(p.pid);created=proc.create_time();q=queue.Queue()
    def reader():
        for line in iter(p.stdout.readline,b''):q.put(line)
        q.put(None)
    threading.Thread(target=reader,daemon=True).start()
    start=time.monotonic();scope=False;boundary=False;scope_offset=0;reason='complete'
    with target.open('wb') as out:
        try:
            while True:
                line=q.get(timeout=max(.01,90-(time.monotonic()-start)))
                if line is None:break
                if line.strip().endswith(b'Scope -'):
                    scope=True;scope_offset=out.tell()
                elif line.startswith(b'Cover item -'):scope=False
                if scope and re.match(rb'^Name\s*:',line):
                    name=line.split(b':',1)[1].strip()
                    if not name.startswith(b'work.'):
                        boundary=True;out.seek(scope_offset);out.truncate()
                        assert proc.create_time()==created and proc.cmdline()==command, 'Dump process identity changed'
                        terminate_tree(proc,created);reason='all_DU_written_before_first_instance';break
                out.write(line)
        except queue.Empty:
            terminate_tree(proc,created);reason='90s_timeout'
    p.wait(timeout=15)
    save(meta,dict(pid=p.pid,created=created,command=command,source_sha256=sha(ucdb),sha256=sha(target),
                   boundary=boundary,reason=reason,exit_code=p.returncode,identity_verified=boundary,seconds=time.monotonic()-start))
    assert reason!='90s_timeout' and (boundary or p.returncode==0),reason
    return parse_native(target)

def parse_native(path):
    items={};scope={};block=[]
    def consume(block):
        nonlocal scope
        text=''.join(block)
        pairs=dict(re.findall(r'^\s*(Name|Type|Count)\s*:\s*(.*?)\s*$',text,re.M))
        src=re.search(r'File info\s*:\s*name = (.*?) line = (\d+)',text)
        if block[0].strip().endswith('Scope -'):
            scope=dict(pairs,raw=text);return
        if not block[0].startswith('Cover item -') or 'Count' not in pairs:return
        key=scope.get('Name','')+'/'+pairs.get('Name','')
        if pairs.get('Type') in ('UCDB_BRANCHBIN','UCDB_STMTBIN','UCDB_FSMBIN'):
            items[key]=dict(count=int(pairs['Count']),type=pairs['Type'],scope_type=scope.get('Type'),
                            line=int(src[2]) if src else None,raw=scope.get('raw','')+text)
    for line in Path(path).read_text(encoding='utf-8',errors='replace').splitlines(keepends=True):
        if line.strip().endswith('Scope -') or line.startswith('Cover item -'):
            if block:consume(block)
            block=[line]
        else:block.append(line)
    if block:consume(block)
    assert len(items)>1000,'Native DU prefix incomplete'
    return items

def missed_terms(text):
    section=None;line=None;found=set()
    for row in text.splitlines():
        h=re.match(r'^(Condition|Expression) Coverage:',row)
        if h:section=h[1]+'s'
        elif re.match(r'^\w+ Coverage:',row):section=None
        h=re.match(r'^Line\s+(\d+) Item\s+\d+',row)
        if h:line=int(h[1])
        m=re.match(r'^\s*(.*?)\s+N\s{2,}',row)
        if m and section:found.add((section,line,m[1].strip()))
    return found

def metric(h,t):
    return dict(covered=h,total=t,missed=t-h,percent=(h*10000//t)/100 if t else None)

def collect():
    RAW.mkdir(parents=True,exist_ok=True);WORK.mkdir(parents=True,exist_ok=True)
    original_check();resources()
    frozen=load(BASE/'freeze.json');t64=load(ROOT/'docs/evidence/t64_f1_coverage/coverage.json')
    base_ucdb=ROOT/frozen['t64_collection']['merged_ucdb']
    assert sha(base_ucdb)==frozen['t64_collection']['merged_sha256']
    attempts=load(BASE/'attempts.json');selected={}
    for a in attempts:
        if a['mutant']==0 and a['passed']:selected[a['test']]=a
    inputs=[]
    for test,a in sorted(selected.items()):
        folder=Path(a['folder']);summary=load(folder/'summary.json')
        indep=check(folder,test)
        assert indep['passed'],(test,indep)
        assert summary['passed'] and a['exit_code']==0 and not any(summary['simulation_diagnostics'].values())
        for entry in summary['inputs']:assert sha(entry['path'])==entry['sha256'],('source drift',test,entry['path'])
        jobs={j['name']:j for j in summary['jobs']}
        assert '+cover=sbceft' in jobs['compile_rtl']['command']
        assert not any('+cover=' in s for s in jobs['compile']['command'])
        assert '-coverage' in jobs['simulation']['command'] and '-batch' in jobs['simulation']['command']
        for label in ('compile','compile_rtl'):
            assert re.search(r'Errors: 0, Warnings: 0',Path(jobs[label]['log']).read_text(encoding='utf-8-sig'))
        sim=Path(jobs['simulation']['log']).read_text(encoding='utf-8-sig')
        assert not re.search(r'\*\* (?:Error|Fatal|Warning)|RAMCOLL',sim)
        assert re.findall(r'\[RESULT\].*',sim)[-1].startswith('[RESULT] '+test+' PASS checks=')
        ucdb=folder/'coverage.ucdb'
        assert sha(ucdb)==a['ucdb_sha256']
        text=vc(test+'_testnames',['testnames',ucdb],ucdb)
        expected_name=test+'_'+folder.name
        assert names(text)=={expected_name}
        inputs.append(dict(test=test,folder=folder.relative_to(ROOT).as_posix(),ucdb=ucdb.relative_to(ROOT).as_posix(),
                           sha256=sha(ucdb),testname=expected_name,bytes=ucdb.stat().st_size,
                           tb_sha256=sha(ROOT/'tb'/(test+'.v')),checks=summary['checks'],diagnostics=summary['simulation_diagnostics'],
                           independent=indep,independent_tool_sha256=sha(ROOT/'tools/t65_check.py'),
                           summary_sha256=sha(folder/'summary.json'),simulation_seconds=jobs['simulation']['seconds'],
                           start=a['start'],finish=a['finish']))
    all_tests={p.stem for p in (ROOT/'tb').glob('tb_t65_*.v')}
    assert set(selected)==all_tests,('unaccepted test',all_tests-set(selected))
    save(EVID/'ucdb_inputs.json',dict(t64=dict(ucdb=frozen['t64_collection']['merged_ucdb'],sha256=sha(base_ucdb)),t65=inputs))
    print('T65 native/independent/provenance accepted: '+str(len(inputs)),flush=True)
    merged=WORK/'merged.ucdb'
    merge_key=[sha(base_ucdb)]+[r['sha256'] for r in inputs]
    cache=WORK/'merged_origin.json'
    if not (merged.exists() and cache.exists() and load(cache).get('inputs')==merge_key and load(cache).get('sha256')==sha(merged)):
        vc('merge',['merge','-checkinputs','-ucdbchecks',merged,base_ucdb,*[ROOT/r['ucdb'] for r in inputs]],base_ucdb)
        save(cache,dict(inputs=merge_key,sha256=sha(merged)))
    old_names=names(vc('t64_testnames',['testnames',base_ucdb],base_ucdb))
    baseline=load(ROOT/'docs/evidence/t64_f1_coverage/comparison.json')
    expected_old={r['test']+'_'+Path(r['folder']).name for r in baseline}
    assert old_names==expected_old and len(old_names)==frozen['t64_collection']['input_count']
    actual_names=names(vc('merged_testnames',['testnames',merged],merged))
    assert actual_names==old_names|{r['testname'] for r in inputs}
    print('Merged identities exactly match baseline plus T65',flush=True)
    text=vc('all_units_summary',['report','-code','bcesft','-showenabledcodecov',merged],merged)
    actual_units=set(re.findall(r'=== Design Unit: work\.(\w+)',text))
    assert actual_units==set(t64['units']),(actual_units,set(t64['units']))
    modules={};denominators=[]
    for index,unit in enumerate(sorted(t64['units']),1):
        for suffix,extra in [('summary',[]),('uncovered',['-details','-zeros'])]:
            vc(unit+'_'+suffix,['report','-du=work.'+unit,'-code','bcesft',*extra,'-showenabledcodecov','-output',RAW/(unit+'_'+suffix+'.txt'),merged],merged)
        text=(RAW/(unit+'_summary.txt')).read_text()
        found=re.findall(r'^    (Branches|Conditions|Expressions|FSM States|FSM Transitions|Statements|Toggles)\s+(\d+)\s+(\d+)\s+(\d+)\s+([0-9.]+)%',text,re.M)
        mm={n:metric(int(h),int(t)) for n,t,h,m,p in found}
        assert set(mm)==set(METRICS)
        modules[unit]=mm
        for name in METRICS:
            old=t64['modules'][unit][name]
            denominators.append(dict(unit=unit,metric=name,t64=old['total'],t65=mm[name]['total'],same=old['total']==mm[name]['total']))
        if index%5==0:print('DU reports complete: '+str(index)+'/'+str(len(t64['units'])),flush=True)
    save(EVID/'denominators.json',dict(same=all(x['same'] for x in denominators),rows=denominators))
    total={n:metric(sum(mm[n]['covered'] for mm in modules.values()),sum(mm[n]['total'] for mm in modules.values())) for n in METRICS}
    delta={n:dict(covered=total[n]['covered']-t64['metrics'][n]['covered'],percentage_points=round(total[n]['percent']-t64['metrics'][n]['percent'],2)) for n in METRICS} if all(x['same'] for x in denominators) else None
    data=dict(t64_sha256=sha(base_ucdb),merged_ucdb=merged.relative_to(ROOT).as_posix(),merged_sha256=sha(merged),
              old_attempts=len(old_names),new_attempts=len(inputs),test_identity_exact=True,unit_count=len(actual_units),
              denominator_same=all(x['same'] for x in denominators),metrics=total,delta=delta,module_metrics=modules,finished=now())
    save(EVID/'coverage.json',data)
    items=native(merged,'merged')
    terms={u:missed_terms((RAW/(u+'_uncovered.txt')).read_text()) for u in t64['units']}
    targets=load(EVID/'targets.json');hits=[];excerpts=[]
    for target in targets:
        row=dict(target);unit=row['unit'];key=None
        if row['metric']=='Branches':key=row['item']
        elif row['metric']=='Statements':key='work.'+unit+'/#stmt#'+row['source_line']+'#'+row['item'].split()[-1]+'#'
        elif row['metric']=='FSM Transitions':
            fsm,trans=row['item'].split(': ',1);trans=trans.split(' [Trans_ID=')[0]
            key='work.'+unit+'::'+fsm+'/trans/'+trans
        if key:
            assert key in items,('native key absent',row['id'],key)
            native_row=items[key];row.update(hit=native_row['count']>0,count=native_row['count'],native_key=key)
            excerpts.append(row['id']+' '+key+'\n'+native_row['raw'])
        else:
            term=row['item'].split(' | ')[0]
            row.update(hit=(row['metric'],int(row['source_line']),term) not in terms[unit],count=None,native_key=None)
        row['reason']='UCDB 已命中' if row['hit'] else ('本卡登记选择 st1=6；st9=4 未注入复位' if row['id']=='T64-0906' else '保留未覆盖，详见同单元 uncovered 原文及报告说明')
        hits.append(row)
    (RAW/'target_native.txt').write_text('\n'.join(excerpts),encoding='utf-8')
    g3=[]
    for suffix,unit,register,transition,value in [('rx','afdx_rx_engine','op','FRAME -> INIT',2),('mac','afdx_mac_tx','state','PREAMBLE -> GAP',1),('app','afdx_app_tx','state','st1 -> st0',6)]:
        a=selected['tb_t65_reset_'+suffix];item_key='work.'+unit+'::'+register+'/trans/'+transition
        its=native(Path(a['folder'])/'coverage.ucdb','reset_'+suffix)
        assert its[item_key]['count']>0
        g3.append(dict(test=a['test'],native_key=item_key,count=its[item_key]['count'],state_value=value,ucdb_sha256=a['ucdb_sha256']))
        (RAW/('reset_'+suffix+'_transition.txt')).write_text(its[item_key]['raw'],encoding='utf-8')
    save(EVID/'target_hits.json',dict(rows=hits,g3=g3,method='vcover dump -canonical DU prefix; FEC term status from -details -zeros; source/denominators unchanged'))
    with (EVID/'target_hits.csv').open('w',newline='',encoding='utf-8') as f:
        keys=['id','analysis_group','unit','metric','source_line','item','hit','count','reason'];w=csv.DictWriter(f,fieldnames=keys,extrasaction='ignore');w.writeheader();w.writerows(hits)
    original_check()
    print(json.dumps(dict(metrics=total,delta=delta,units=len(actual_units),new_attempts=len(inputs),target_hits=sum(x['hit'] for x in hits),targets=len(hits),g3=g3),ensure_ascii=False,indent=2))

if __name__=='__main__':collect()
