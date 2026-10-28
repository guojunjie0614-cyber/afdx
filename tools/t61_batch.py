"""T61 coordinator: immutable inputs, resource admission, six terminal records."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import psutil

from t61_freeze import ROOT, SOURCE, SOURCE_ROOT, INSTALL, closure, freeze, git, identities, sha
from t61_constraints import self_check

OUT=ROOT/'out/t61'
BASE='18d1606cc86930e76332120131c55fa982e0e018'
GIB=1024**3
GUI_ERRORS=[
    'computer-use request timed out: launch_app',
    'window id 7737180 no longer belongs to E:/2026_Embedded_FPGA/setup_pack/eLinx3.0.exe; current owner is the same reported path',
    'FrameArrived timed out: timed out waiting on channel',
    'window capture timed out: timed out waiting on channel',
    'element 2247 is not available in cached app state for T61_eLinx.exe',
    'element 4953 is not available in cached app state for T61_eLinx.exe',
]

def save(path,data):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_suffix(path.suffix+'.tmp')
    temporary.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    for attempt in range(8):
        try:os.replace(temporary,path);return
        except PermissionError:
            if attempt==7:raise
            time.sleep(.1*(attempt+1))

def now():return datetime.now().astimezone().isoformat()

def blocked(number,reason,identity):
    return dict(experiment_id=number,terminal_status='blocked',reason=reason,
                run_completed=False,control_reproduced=None,constraints_applied=None,
                timing_closed=None,valid_for_comparison=False,input_identities=identity,
                raw_metrics=None,elapsed_seconds=0,attempts=[],
                null_reason='No implementation or timing measurement was run',
                evidence={'preflight':str(OUT/'preflight.json')})

def prepare():
    if (OUT/'manifest.json').exists():raise RuntimeError('Manifest exists; do not overwrite frozen inputs')
    if git(ROOT,'status','--porcelain','--untracked-files=no'):raise RuntimeError('Commit preparation scripts first')
    tests=self_check(ROOT)
    identities_all={};configs={};initial_results={}
    initial_disk={drive:shutil.disk_usage(drive+':/').free for drive in ('D','E')}
    for n in range(1,7):
        eid='E'+str(n)
        root=Path('E:/2026_Embedded_FPGA/worktrees/active/c3_t61_e1') if n==1 else Path(f'D:/2026_Embedded_FPGA_t61/c3_t61_e{n}')
        ident=identities(root)
        if n>=2:ident=freeze(root)
        identities_all[eid]=ident
        if n==1:
            free=shutil.disk_usage(root).free
            if free>=11*GIB:raise RuntimeError('E1 is now admissible; extend frozen schedule instead of retaining old disk block')
            initial_results[eid]=blocked(eid,f'E: free={free} bytes; admission requires 8 GiB floor + 3 GiB reservation. No existing files removed.',ident)
        elif n>=3:
            initial_results[eid]=blocked(eid,'Required I/O Planning pin statement export unavailable: native UI capture and cached-control errors; no pin syntax or native legality assumed.',ident)
        else:
            frozen={rel:row['sha256'] for rel,row in ident['source_closure'].items()}
            frozen.update(ident['setting_hashes']);frozen.update(ident['scripts'])
            synth=Path(ident['synthesis'])/'project/AFDX_EndSystem.runs/synth_1'
            for name,digest in ident['synth1_files'].items():frozen[(synth/name).relative_to(root).as_posix()]=digest
            frozen['out/latest_AFDX_top.json']=sha(root/'out/latest_AFDX_top.json')
            config={'experiment_id':eid,'root':str(root),'attempt_id':'attempt_01',
                    'input_identities':ident,'frozen_files':frozen,'disk_paths':['D:/','E:/'],
                    'reference_full_summary':str(SOURCE_ROOT/'out/timing/AFDX_top_full_timing/20261027_091407_901817/summary.json'),
                    'reference_constraint_path':str(SOURCE_ROOT/'elinx/constraints.edc'),
                    'control_expected':{'resources':{'lut':39895,'ff':20885,'clb':5136,'memory':404,'pins':172,'dsp':0,'pll':0},
                        'clock':{'period':8000,'setup_worst_slack':-184,'hold_worst_slack':229,
                                 'setup_fail_ends':10,'setup_total_ends':53882,'hold_fail_ends':0,'hold_total_ends':53882},
                        'setup_uncertainty_ns':.30},
                    'checks':{'constraints_applied':None,'reason':'E2 has automatic pins and no added region'},
                    'tool_home':str(INSTALL)}
            path=root/'out/t61/config_attempt_01.json';save(path,config);configs[eid]=str(path)
    preflight={'timestamp':now(),'status':'ready_for_admissible_jobs',
               'initial_disk_free_bytes':initial_disk,'available_memory_bytes':psutil.virtual_memory().available,
               'audit_guard_tests':tests,'pin_native_export':{'completed':False,'errors':GUI_ERRORS,
                 'actual_export_path':None,'attempt_artifacts':'D:/2026_Embedded_FPGA_t61/preparation',
                 'owned_gui_processes_stopped':True,'installation_data_unchanged':True},
               'P0_P1_static':str(OUT/'preparation/pins_summary.json'),
               'R_static':str(OUT/'preparation/region_manifest.json'),
               'R_native_legal':None,'R_native_reason':'Physical cohort blocked before native validation',
               'admitted':['E2'],'blocked':{key:row['reason'] for key,row in initial_results.items()}}
    save(OUT/'preflight.json',preflight)
    tools={str(p):sha(p) for p in (INSTALL/'bin/shell/bin/Implementation.exe',INSTALL/'bin/shell/bin/run_route.tcl',
                                 INSTALL/'bin/shell/bin/run_synthesized_timing.tcl',INSTALL/'data/version.ini',INSTALL/'data/common.ini')}
    manifest={'frozen_at':now(),'coordinator_head':git(ROOT,'rev-parse','HEAD'),'design_base':BASE,
              'canonical_synthesis':str(SOURCE),'canonical_summary_sha256':sha(SOURCE/'summary.json'),
              'tool_identity':tools,'tool_version':'eLinx 3.0.7','python_executable':sys.executable,
              'python_version':sys.version,'psutil_version':psutil.__version__,
              'experiments':identities_all,'configs':configs,
              'parameters':{'period_ns':8,'setup_uncertainty_ns':.30,'PRES_FAC_MULT':1.55,'INIT_SA':0,'INNERNUM':1},
              'budgets':{'route_seconds':7200,'report_seconds':1800,'memory_floor_gib':3,'disk_floor_gib':8,
                         'new_job_disk_reservation_gib':3,'max_concurrency':6,'total_deadline':None},
              'preparation_files':{p.name:sha(p) for p in (OUT/'preparation').glob('*') if p.is_file()},
              'protected_paths_diff':git(ROOT,'diff',BASE,'HEAD','--','rtl','tb','sim','docs')}
    if manifest['protected_paths_diff']:raise RuntimeError('Protected paths changed')
    save(OUT/'manifest.json',manifest)
    for eid,row in initial_results.items():save(OUT/eid/'result.json',row)
    save(OUT/'status.json',{'phase':'prepared','timestamp':now(),'configs':configs,'terminal':list(initial_results)})
    print('PREPARED '+json.dumps({'configs':configs,'terminal':list(initial_results)}))

def run():
    manifest=json.loads((OUT/'manifest.json').read_text(encoding='utf-8'))
    for path,digest in manifest['tool_identity'].items():
        if sha(path)!=digest:raise RuntimeError('Frozen native tool changed: '+path)
    existing=OUT/'owner.json'
    if existing.exists():
        old=json.loads(existing.read_text())
        try:
            p=psutil.Process(old['pid'])
            if p.create_time()==old['created']:raise RuntimeError('Coordinator already running')
        except psutil.NoSuchProcess:pass
    owner={'pid':os.getpid(),'created':psutil.Process().create_time(),'cwd':str(ROOT),'started':now()}
    save(existing,owner)
    # This immutable manifest currently admits one independent control. The
    # scheduler accepts all resource-admissible configured items concurrently.
    jobs=[];results={}
    for eid in [f'E{i}' for i in range(1,7)]:
        result=OUT/eid/'result.json'
        if result.exists():results[eid]=json.loads(result.read_text(encoding='utf-8'))
    disk_reservations={};memory_reserved=0
    for eid,config_path in manifest['configs'].items():
        if eid in results:continue
        config=json.loads(Path(config_path).read_text(encoding='utf-8'));root=Path(config['root']);drive=root.drive
        available=psutil.virtual_memory().available
        disk=shutil.disk_usage(root).free
        if available-memory_reserved<4*GIB or disk-disk_reservations.get(drive,0)<11*GIB:
            results[eid]=blocked(eid,'Resource admission failed before tool launch',config['input_identities']);save(OUT/eid/'result.json',results[eid]);continue
        disk_reservations[drive]=disk_reservations.get(drive,0)+3*GIB;memory_reserved+=GIB
        jobs.append((eid,root,Path(config_path)))
    running={};start=time.monotonic();peak_concurrency=0
    def worker(item):
        eid,root,config_path=item;log=root/'out/t61/worker_attempt_01.log';log.parent.mkdir(exist_ok=True,parents=True)
        env=os.environ.copy();env.update(ELINX_HOME=str(INSTALL),PYTHONDONTWRITEBYTECODE='1')
        with log.open('wb') as stream:
            p=psutil.Popen([sys.executable,'-B',str(root/'tools/t61_runtime.py'),'worker','--config',str(config_path)],cwd=root,env=env,stdout=stream,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
            running[eid]={'pid':p.pid,'created':p.create_time(),'cwd':str(root),'started':now(),'log':str(log)}
            code=p.wait()
        result_path=root/'out/t61/runtime/attempt_01/result.json'
        if not result_path.is_file():
            row=blocked(eid,'Worker terminated without result: exit='+str(code),manifest['experiments'][eid]);row['terminal_status']='failed';row['attempts']=[{**running[eid],'exit_code':code}]
        else:row=json.loads(result_path.read_text(encoding='utf-8'))
        row['worker_exit_code']=code;return eid,row
    with ThreadPoolExecutor(max_workers=6) as pool:
        futures=[pool.submit(worker,item) for item in jobs]
        while any(not f.done() for f in futures):
            active={eid:row for eid,row in running.items() if psutil.pid_exists(row['pid'])}
            peak_concurrency=max(peak_concurrency,len(active))
            save(OUT/'status.json',{'phase':'running','timestamp':now(),'owner':owner,'jobs':active,'terminal':list(results),
                                  'elapsed_seconds':time.monotonic()-start,'disk_free_bytes':{d:shutil.disk_usage(d+':/').free for d in ('D','E')}})
            time.sleep(3)
        for f in futures:
            eid,row=f.result();results[eid]=row;save(OUT/eid/'result.json',row)
    save(OUT/'results.json',{'experiments':results,'peak_concurrent_workers':peak_concurrency,'elapsed_seconds':time.monotonic()-start})
    save(OUT/'status.json',{'phase':'all_terminal','timestamp':now(),'owner':owner,'jobs':{},'terminal':{k:v['terminal_status'] for k,v in results.items()},'awaiting':'D3 review'})
    print('ALL_TERMINAL '+json.dumps({k:v['terminal_status'] for k,v in results.items()}))

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('action',choices=['prepare','run']);a=ap.parse_args()
    prepare() if a.action=='prepare' else run()
