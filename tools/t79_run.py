"""One finite T79 queue: six CPU slots, seven runs, no retries or callbacks."""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import psutil

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'out/t79'
EVIDENCE = ROOT/'docs/evidence/t79_63vl'
TZ = timezone(timedelta(hours=8))
CASES = [('P1',1,0),('P17',17,0),('P256',256,0),('P1024',1024,0),
         ('P1471',1471,0),('B1',1471,1),('B2',1471,2)]

def now():
    return datetime.now(TZ).strftime('%Y-%m-%d %H:%M:%S')

def save(path, value):
    path.write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')

def stop_owned(active):
    for process, row, stream in active:
        try:
            parent=psutil.Process(process.pid)
            if parent.create_time()!=row['created']:continue
            children=parent.children(recursive=True)
            for child in reversed(children):
                try:child.kill()
                except psutil.NoSuchProcess:pass
            parent.kill();process.wait()
        except psutil.NoSuchProcess:pass
        row.update(status='STOPPED_BY_REPORT_CONDITION',finished=now())
        stream.close()

def collect(row):
    from t76_stats import analyse
    folder=Path(row['folder'])
    stats=analyse(folder)
    with (folder/'tcl_stats.log').open('wb') as log:
        subprocess.run(['E:/2026_Embedded_FPGA/setup_pack/bin/Passkey/bin/tclsh.exe',
            str(ROOT/'sim/t76_stats.tcl'),str(folder)],cwd=ROOT,stdout=log,
            stderr=subprocess.STDOUT,check=True,timeout=180)
    equal=(folder/'t76_python.tsv').read_bytes()==(folder/'t76_tcl.tsv').read_bytes()
    groups=stats['groups']
    worst=max(groups,key=lambda g:g['official_jitter_cycles'])
    invalid=[g for g in groups if not g['formula_precondition']]
    over=[g for g in groups if g['formula_precondition'] and not g['under_100us']]
    values=dict(line.split('\t') for line in (folder/'t76_python.tsv').read_text().splitlines())
    run=json.loads((folder/'summary.json').read_text())
    row.update(hdl_pass=run['passed'],integrity_pass=not stats['issues'],statistics_equal=equal,
        groups=len(groups),formula_invalid=len(invalid),jitter_failures=len(over),
        maximum_jitter_us=worst['official_jitter_us'],worst_vlid=worst['vlid'],
        worst_length=worst['length'],worst_source=worst['source'],
        maximum_latency_us=max(g['maximum'] for g in groups)*.008,
        latency_pass=all(g['short_latency_under_2ms'] for g in groups),
        page_upper_bounds=[int(values[f'{s}/total/page_upper_bound']) for s in (0,1)],
        bag_pairs=[int(values[f'{s}/total/bag_pairs']) for s in (0,1)],
        bag_pair_failures=[int(values[f'{s}/total/bag_pair_failures']) for s in (0,1)],
        receive_mbps=[int(values[f'{s}/total/receive_bytes'])*1000/stats['window_cycles'] for s in (0,1)],
        simulation_seconds=next(j['seconds'] for j in run['jobs'] if j['name']=='simulation'),
        issues=stats['issues'])
    target=EVIDENCE/row['case'];target.mkdir()
    for name in ('summary.json','tool_metrics.json','simulation.log','window.txt','t76_stats.json',
                 't76_python.tsv','t76_tcl.tsv','t76_budget_0.json','t76_budget_1.json'):
        (target/name).write_bytes((folder/name).read_bytes())
    row['status']='PASS' if (row['hdl_pass'] and row['integrity_pass'] and equal and not invalid
        and not over and row['latency_pass']) else 'FAIL'
    return bool(invalid or over)

def main():
    OUT.mkdir(parents=True,exist_ok=False)
    EVIDENCE.mkdir(parents=True,exist_ok=True)
    os.environ.update(AFDX_PYTHON=sys.executable,MODELSIM_HOME='E:/Verilog/ModelSim/setup_pack/win64',
        ELINX_HOME='E:/2026_Embedded_FPGA/setup_pack',AFDX_CE_DIV='2',AFDX_MEM_FLOOR_GB='3',
        AFDX_MODELSIM_DECL_ORDER='0',AFDX_T76_SPEC_CONFIRMED='1')
    own=psutil.Process();cpus=own.cpu_affinity()[:6];own.cpu_affinity(cpus)
    receipt=dict(started=now(),pid=own.pid,created=own.create_time(),cpu_affinity=cpus,
        source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        per_case_limit_seconds=10800,runs=[],status='RUNNING')
    active=[];pending=list(CASES)
    def persist():
        save(OUT/'run.json',receipt);save(EVIDENCE/'run_receipt.json',receipt)
    persist()
    try:
        while pending or active:
            for item in list(active):
                process,row,stream=item
                if process.poll() is None:continue
                active.remove(item);stream.close()
                row.update(exit_code=process.returncode,finished=now(),seconds=round(time.time()-row['launch_epoch'],3))
                folders=set((ROOT/'out/t76_sim/tb_t76_load').glob('*/summary.json'))
                matches=[p for p in folders if json.loads(p.read_text()).get('parameters')==row['parameters']]
                if len(matches)!=1:raise RuntimeError('Expected one unique result for '+row['case'])
                row['folder']=str(matches[0].parent)
                if process.returncode:
                    row['status']='TOOL_OR_HDL_FAIL';raise RuntimeError('Run failed: '+row['case'])
                if collect(row):
                    receipt['report_condition']='Formula invalid or jitter >=100 us: '+row['case']
                    raise RuntimeError(receipt['report_condition'])
                persist()
            if pending and len(active)<6:
                others=[p for p in psutil.process_iter(['name']) if (p.info['name'] or '').lower()
                    in ('vsimk.exe','elinx_synthesis.exe','implementation.exe')]
                # Never launch beyond six total active kernels; all owned children inherit affinity.
                if len(others)<6 and psutil.virtual_memory().available>=3*1024**3:
                    import eda
                    if eda.free_disk_bytes('E:/')<8*1024**3:raise RuntimeError('E: free space below 8 GiB')
                    name,length,burst=pending.pop(0)
                    deadline=datetime.now(TZ)+timedelta(hours=3)
                    params=dict(VL_COUNT=63,GROUP_LENGTH=length,MIXED=0,DUPLEX=1,
                        DURATION=12500000,SMOKE=0,SWAP=0,BAG_BURST=burst)
                    command=[sys.executable,'-B','-X','utf8','tools/t76_sim.py','--deadline',deadline.isoformat()]
                    for key,value in params.items():command+=['--param',f'{key}={value}']
                    env=os.environ.copy();env['AFDX_LATEST_PREFIX']='t79_'+name+'_'
                    stream=(OUT/(name+'.log')).open('xb')
                    process=subprocess.Popen(command,cwd=ROOT,env=env,stdout=stream,stderr=subprocess.STDOUT,
                        creationflags=subprocess.CREATE_NO_WINDOW)
                    row=dict(case=name,parameters=params,pid=process.pid,created=psutil.Process(process.pid).create_time(),
                        started=now(),launch_epoch=time.time(),deadline=deadline.strftime('%Y-%m-%d %H:%M:%S'),
                        command=command,status='RUNNING')
                    receipt['runs'].append(row);active.append((process,row,stream));persist()
            if active or pending:time.sleep(1)
        receipt['status']='PASS' if all(r['status']=='PASS' for r in receipt['runs']) else 'FAIL'
    except Exception as exc:
        receipt.update(status='STOPPED',error=str(exc),not_started=[c[0] for c in pending])
        stop_owned(active)
    finally:
        receipt['finished']=now();persist()
    return int(receipt['status']!='PASS')

if __name__=='__main__':raise SystemExit(main())
