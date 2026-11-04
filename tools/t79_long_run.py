"""Bounded mode-3 boundary experiment, isolated from the seven base scenarios."""
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import psutil

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'out/t79_long_source'
OUT=ROOT/'out/t79_long'
E=ROOT/'docs/evidence/t79_63vl/long_concurrent'
TZ=timezone(timedelta(hours=8))

def now():return datetime.now(TZ).strftime('%Y-%m-%d %H:%M:%S')
def save(path,value):path.write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')

def collect(row):
    import eda
    from t76_stats import analyse
    candidates=[]
    for p in (SOURCE/'out/t76_sim/tb_t76_load').glob('*/summary.json'):
        data=json.loads(p.read_text())
        if data.get('parameters')==row['parameters'] and datetime.fromisoformat(data['started']).timestamp()>=row['launch_epoch']-1:
            candidates.append((p.parent,data))
    if len(candidates)!=1:raise RuntimeError('Unique run receipt missing')
    folder,run=candidates[0];row['folder']=str(folder)
    target=E/row['case'];target.mkdir()
    log=(folder/'simulation.log').read_text(encoding='utf-8-sig',errors='replace') if (folder/'simulation.log').exists() else ''
    known=json.loads((ROOT/'docs/evidence/t79_63vl/warning_policy_proof.json').read_text())['patterns']
    warnings=re.findall(r'(?m)^.*\*\* Warning:[^\r\n]*',log)
    unexpected=[w for w in warnings if not any(re.search(p,w) for p in known)]
    results=re.findall(r'\[RESULT\] tb_t76_load (PASS|FAIL) checks=(\d+) errors=(\d+)',log)
    hdl=len(results)==1 and results[0][0]=='PASS' and results[0][2]=='0' and not unexpected and not any(x in log for x in ('** Error:','** Fatal:','RAMCOLL','[RX_ASSERT]'))
    unchanged=all(eda.sha(Path(p))==h for p,h in run['inputs'].items())
    row.update(hdl_pass=hdl,inputs_unchanged=unchanged,wrapper_passed=run['passed'],
        known_warning_count=len(warnings)-len(unexpected),unexpected_warnings=unexpected,
        simulation_seconds=next((j['seconds'] for j in run['jobs'] if j['name']=='simulation'),None))
    failures=[]
    for source in (0,1):
        path=folder/f'ep{source}_events.txt'
        if not path.exists():continue
        for line in path.read_text().splitlines():
            v=line.split();cycle=int(v[0]);tx,a,b=map(lambda x:int(x,16),v[1:4]);app=int(v[6])
            if tx&0x1e or a&0xfe or b&0xfe or app:
                failures.append(dict(source=source,cycle=cycle,simulation_ns=cycle*8-4,
                    ev_tx=f'0x{tx:02X}',ev_a=f'0x{a:02X}',ev_b=f'0x{b:02X}',ev_app=f'0x{app:X}'));break
    row['first_failure']=min(failures,key=lambda f:(f['cycle'],f['source'])) if failures else None
    row['failure_log_lines']=[line for line in log.splitlines() if any(s in line for s in ('** Fatal:','** Error:','Time:','[RESULT]'))][-8:]
    stats=None
    if hdl and unchanged:
        stats=analyse(folder)
        with (folder/'tcl_stats.log').open('wb') as stream:
            subprocess.run(['E:/2026_Embedded_FPGA/setup_pack/bin/Passkey/bin/tclsh.exe',
                str(SOURCE/'sim/t76_stats.tcl'),str(folder)],cwd=SOURCE,stdout=stream,
                stderr=subprocess.STDOUT,check=True,timeout=180)
        equal=(folder/'t76_python.tsv').read_bytes()==(folder/'t76_tcl.tsv').read_bytes()
        short=[g for g in stats['groups'] if g['length']<=1471]
        long=[g for g in stats['groups'] if g['length']==8192]
        worst=max(short,key=lambda g:g['official_jitter_cycles'])
        row.update(integrity_pass=not stats['issues'],issues=stats['issues'],statistics_equal=equal,
            short_groups=len(short),long_groups=len(long),
            short_formula_invalid=sum(not g['formula_precondition'] for g in short),
            short_jitter_failures=sum(g['under_100us'] is not True for g in short),
            maximum_short_jitter_us=worst['official_jitter_us'],worst_short_vlid=worst['vlid'],
            maximum_short_latency_us=max(g['maximum'] for g in short)*.008,
            maximum_long_completion_us=max(g['maximum'] for g in long)*.008,
            short_latency_pass=all(g['short_latency_under_2ms'] for g in short),
            long_completed_messages=sum(g['samples'] for g in long))
        row['status']='PASS' if not stats['issues'] and equal and row['short_formula_invalid']==0 and row['short_jitter_failures']==0 and row['short_latency_pass'] else 'FAIL'
    else:
        stopped=any(j.get('stop_reason') for j in run.get('jobs',[]))
        row['status']='TOOL_STOP' if stopped or not log else 'HDL_FAIL'
        row['integrity_pass']=False
    row['raw_record_hashes']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.glob('*.txt')}
    for name in ('summary.json','tool_metrics.json','simulation.log','window.txt','t76_python.tsv','t76_tcl.tsv',
                 't76_stats.json','t76_budget_0.json','t76_budget_1.json','ep0_events.txt','ep1_events.txt'):
        if (folder/name).exists():shutil.copyfile(folder/name,target/name)
    save(target/'evaluation.json',row)

def main():
    OUT.mkdir(parents=True,exist_ok=False);E.mkdir(parents=True,exist_ok=False)
    sys.path.insert(0,str(SOURCE/'tools'))
    import eda
    os.environ.update(AFDX_PYTHON=sys.executable,MODELSIM_HOME='E:/Verilog/ModelSim/setup_pack/win64',
        ELINX_HOME='E:/2026_Embedded_FPGA/setup_pack',AFDX_CE_DIV='2',AFDX_MEM_FLOOR_GB='3',
        AFDX_MODELSIM_DECL_ORDER='0',AFDX_T76_SPEC_CONFIRMED='1')
    p=psutil.Process();p.cpu_affinity(p.cpu_affinity()[::2][:6])
    receipt=dict(status='RUNNING',started=now(),pid=p.pid,created=p.create_time(),runs=[],
        source_tree=str(SOURCE),source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        global_kernel_limit=6,own_parallel_limit=3,extra_round_limit=1)
    def persist():save(OUT/'run.json',receipt);save(E/'run_receipt.json',receipt)
    def run_round(counts,ms,hours):
        pending=list(counts);active=[]
        while pending or active:
            for item in list(active):
                process,row,stream=item
                if process.poll() is None:continue
                active.remove(item);stream.close()
                row.update(exit_code=process.returncode,finished=now(),seconds=round(time.time()-row['launch_epoch'],3))
                try:collect(row)
                except Exception as exc:row.update(status='COLLECTION_ERROR',error=str(exc))
                persist()
            if pending and len(active)<3 and len(eda.modelsim_slot_pids())<6 and psutil.virtual_memory().available>=3*1024**3:
                if eda.free_disk_bytes('E:/')<8*1024**3:raise RuntimeError('E: below 8 GiB; no new launch')
                count=pending.pop(0);deadline=datetime.now(TZ)+timedelta(hours=hours)
                params=dict(VL_COUNT=63,GROUP_LENGTH=1471,MIXED=3,DUPLEX=1,DURATION=ms*125000,
                    SMOKE=0,SWAP=0,BAG_BURST=0,LONG_COUNT=count)
                case=f'N{count}_{ms}ms'
                command=[sys.executable,'-B','-X','utf8',str(SOURCE/'tools/t76_sim.py'),'--deadline',deadline.isoformat()]
                for key,value in params.items():command+=['--param',f'{key}={value}']
                env=os.environ.copy();env['AFDX_LATEST_PREFIX']='t79_long_'+case+'_'
                stream=(OUT/(case+'.log')).open('xb')
                process=subprocess.Popen(command,cwd=SOURCE,env=env,stdout=stream,stderr=subprocess.STDOUT,
                    creationflags=subprocess.CREATE_NO_WINDOW)
                row=dict(case=case,long_count=count,window_ms=ms,parameters=params,pid=process.pid,
                    created=psutil.Process(process.pid).create_time(),started=now(),launch_epoch=time.time(),
                    deadline=deadline.strftime('%Y-%m-%d %H:%M:%S'),budget_seconds=hours*3600,command=command,status='RUNNING')
                receipt['runs'].append(row);active.append((process,row,stream));persist()
            if pending or active:time.sleep(1)
    persist()
    try:
        run_round([2,3,4],20,1)
        if any(r['long_count']==4 and r['status']=='PASS' for r in receipt['runs']):
            run_round([6,8],20,1)
        passed=[r['long_count'] for r in receipt['runs'] if r['window_ms']==20 and r['status']=='PASS']
        if passed:
            selected=max(passed);receipt['selected_for_100ms']=selected;persist()
            run_round([selected],100,2)
            confirmed=[r['long_count'] for r in receipt['runs'] if r['window_ms']==100 and r['status']=='PASS']
            receipt['confirmed_limit']=max(confirmed) if confirmed else None
        else:receipt['confirmed_limit']=None
        receipt['status']='COMPLETE'
    except Exception as exc:receipt.update(status='STOPPED',error=str(exc))
    finally:receipt['finished']=now();persist()
    return int(receipt.get('confirmed_limit') is None)

if __name__=='__main__':raise SystemExit(main())
