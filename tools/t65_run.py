"""T65 owned serial runner. Existing sources and T64 evidence are read-only."""
import argparse
import csv
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

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'out/t65'
EVID = ROOT / 'docs/evidence/t65_gap_tests'
MS = Path('E:/Verilog/ModelSim/setup_pack/win64')
TZ = timezone(timedelta(hours=8))
FROZEN = 'e5cd815020448820c2de7c587f288554defb74bc'

def now():
    return datetime.now(TZ).isoformat()

def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest().upper()

def load(p):
    return json.loads(Path(p).read_text(encoding='utf-8-sig'))

def save(p, value):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT).decode('utf-8').strip()

def original_check():
    f = load(BASE/'freeze.json')
    baseline=load(ROOT/'docs/evidence/t64_f1_coverage/freeze.json')['original_files']
    rtl=[n for n in f['original_files'] if n.startswith('rtl/')]
    assert len(rtl)==29
    assert all(f['original_files'][n]==baseline[n] and sha(ROOT/n)==baseline[n] for n in rtl), 'Initial/final RTL bytes differ from T64 frozen bytes'
    changed = [n for n,h in f['original_files'].items() if sha(ROOT/n) != h]
    assert not changed, changed
    assert sorted(p.name for p in (ROOT/'tb/lib').iterdir() if p.is_file()) == f['tb_lib_files']
    assert not git('diff', FROZEN, '--', 'rtl')
    assert not git('diff', 'HEAD', '--')
    return dict(original_files_unchanged=True, rtl_equal_frozen=True, rtl_byte_hashes_equal_t64_before_and_after=True, tb_lib_unchanged=True)

def resources():
    rows=[]
    for p in psutil.process_iter(['name','cmdline','create_time']):
        if re.match(r'^(vsim|vsimk|vlog|vcover|vopt|elinx|implementation|quartus)', p.info['name'] or '', re.I):
            rows.append(dict(pid=p.pid, **p.info))
    ram=psutil.virtual_memory().available
    disk=shutil.disk_usage(ROOT).free
    assert ram >= 5*1024**3 and disk >= 8*1024**3, (ram,disk)
    assert not rows, ('serial policy: native EDA process already running', rows)
    return dict(available_memory=ram, disk_free=disk, native_processes=rows)

def init():
    assert not (BASE/'freeze.json').exists(), 'Use existing T65 state; do not restart clock'
    assert git('branch','--show-current')=='t63'
    assert git('rev-parse','HEAD')=='d64758551f8d27c873c1f360c9ac4d4bd8263459'
    assert not git('diff',FROZEN,'HEAD','--','rtl','tb','sim')
    assert git('diff','--name-only',FROZEN,'HEAD','--','tools')=='tools/t64_coverage.py'
    assert not git('diff','HEAD','--')
    names=git('ls-files','-z').split('\0')
    coll=load(ROOT/'docs/evidence/t64_f1_coverage/collection.json')
    assert sha(ROOT/coll['merged_ucdb'])==coll['merged_sha256']
    # Include task reading/setup time: first preflight was 2026-10-30 08:49:56.
    start=datetime.fromisoformat('2026-10-30T08:49:56+08:00')
    data=dict(head=git('rev-parse','HEAD'), branch='t63', start=start.isoformat(),
              initialized_at=now(), simulation_deadline=(start+timedelta(hours=10)).isoformat(),
              hard_deadline=(start+timedelta(hours=12)).isoformat(),
              g3_start_deadline=(start+timedelta(hours=8)).isoformat(),
              original_files={n:sha(ROOT/n) for n in names if n},
              tb_lib_files=sorted(p.name for p in (ROOT/'tb/lib').iterdir() if p.is_file()),
              resources=resources(), t64_collection=coll,
              versions={n:subprocess.check_output([str(MS/n),'-version']).decode().strip() for n in ['vsim.exe','vlog.exe','vcover.exe']})
    save(BASE/'freeze.json',data)
    gaps=list(csv.DictReader((ROOT/'docs/evidence/t64_f1_coverage/uncovered_index.csv').open(encoding='utf-8-sig')))
    selected=[r for r in gaps if r['analysis_group'] in ('A01','A02') or r['id'] in ('T64-1619','T64-1225','T64-0898','T64-0906')]
    save(EVID/'targets.json',selected)
    print(json.dumps({k:v for k,v in data.items() if k not in ('original_files','tb_lib_files')},ensure_ascii=False,indent=2))

def terminate_tree(p, created):
    try:
        if p.create_time()!=created:
            return
        owned=[(q,q.create_time()) for q in p.children(recursive=True)]+[(p,created)]
        for q,c in owned:
            try:
                if q.create_time()==c: q.kill()
            except psutil.NoSuchProcess: pass
    except psutil.NoSuchProcess: pass

def run(tests, mutant):
    original_check()
    frozen=load(BASE/'freeze.json')
    deadline=frozen['simulation_deadline']
    print('Deadline local: '+datetime.fromisoformat(deadline).astimezone().isoformat(),flush=True)
    # One OS-held lock. Stale files are not proof that a worker is running.
    import msvcrt
    with (BASE/'execution.lock').open('a+b') as lock:
        lock.seek(0);lock.write(b'0');lock.flush();lock.seek(0)
        msvcrt.locking(lock.fileno(),msvcrt.LK_NBLCK,1)
        for test in tests:
            assert test.startswith('tb_t65_')
            assert datetime.now(TZ)<datetime.fromisoformat(deadline)
            if test.startswith('tb_t65_reset_'):
                assert datetime.now(TZ)<datetime.fromisoformat(frozen['g3_start_deadline'])
            res=resources()
            original_check()
            env=os.environ.copy()
            env.update(AFDX_PYTHON='E:/anaconda3/python.exe',MODELSIM_HOME=str(MS),AFDX_CE_DIV='2',PYTHONDONTWRITEBYTECODE='1')
            env['AFDX_LATEST_PREFIX']='t65_mut_' if mutant else ''
            # Leave the runner's existing memory guard unchanged.
            assert float(env.get('AFDX_MEM_FLOOR_GB','5'))>=5
            args=['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(ROOT/'sim/run.ps1'),'-Test',test,'-Deadline',deadline]
            if mutant: args+=['-Param',f'T65_MUTANT={mutant}']
            else: args+=['-Coverage']
            tag=datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'_'+test+f'_m{mutant}'
            log=BASE/(tag+'.txt')
            begin=time.monotonic()
            with log.open('wb') as output:
                p=subprocess.Popen(args,cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
                proc=psutil.Process(p.pid);created=proc.create_time()
                owner=dict(pid=p.pid,created=created,command=args,log=str(log),test=test,mutant=mutant,start=now())
                save(BASE/'current.json',dict(status='running',**owner))
                try: p.wait(timeout=max(1,(datetime.fromisoformat(deadline)-datetime.now(TZ)).total_seconds()))
                except subprocess.TimeoutExpired:
                    terminate_tree(proc,created);p.wait()
            pointer=ROOT/'out'/((env['AFDX_LATEST_PREFIX'])+'latest_'+test+'.json')
            summary=load(pointer) if pointer.exists() else {}
            assert summary.get('name')==test and Path(summary['folder']).stat().st_mtime>=time.time()-(time.monotonic()-begin)-30, 'Latest pointer is stale'
            folder=Path(summary['folder'])
            sys.path.insert(0,str(ROOT/'tools'))
            from t65_check import check
            independent=check(folder,test,mutant)
            save(folder/'t65_independent.json',independent)
            record=dict(**owner,finish=now(),seconds=round(time.monotonic()-begin,3),exit_code=p.returncode,folder=str(folder),
                        summary_sha256=sha(folder/'summary.json'),passed=bool(summary.get('passed')) and independent['passed'] and p.returncode==0,
                        native_passed=summary.get('passed'),independent=independent,resources=res,
                        ucdb_sha256=sha(folder/'coverage.ucdb') if (folder/'coverage.ucdb').exists() else None,
                        independent_tool_sha256=sha(ROOT/'tools/t65_check.py'),runner_sha256=sha(__file__))
            manifest=load(BASE/'attempts.json') if (BASE/'attempts.json').exists() else []
            manifest.append(record);save(BASE/'attempts.json',manifest)
            save(BASE/'current.json',dict(status='finished',**record))
            print(json.dumps({k:record[k] for k in ['test','mutant','exit_code','native_passed','passed','folder','seconds','independent']},ensure_ascii=False),flush=True)
            original_check()

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=['init','run','verify','mutants'])
    parser.add_argument('tests',nargs='*')
    parser.add_argument('--mutant',type=int,default=0)
    a=parser.parse_args()
    if a.action=='init': init()
    elif a.action=='run': run(a.tests,a.mutant)
    elif a.action=='mutants':
        tests=a.tests or [p.stem for p in sorted((ROOT/'tb').glob('tb_t65_*.v'))]
        for mutation in (1,2):run(tests,mutation)
    else: print(original_check())
