"""T65b serial official-entry runner; no scheduler or continuation."""
import argparse
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
import msvcrt
import psutil

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT/'out/t65b'
EVID = ROOT/'docs/evidence/t65b_regress'
MS = Path(os.environ.get('MODELSIM_HOME') or Path(shutil.which('vsim.exe') or 'vsim.exe').parent)
PYTHON = Path(os.environ.get('AFDX_PYTHON') or sys.executable)
TZ = timezone(timedelta(hours=8))

def now(): return datetime.now(TZ).isoformat()
def load(p): return json.loads(Path(p).read_text(encoding='utf-8-sig'))
def save(p, x):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(x, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
def git(*args): return subprocess.check_output(['git', *args], cwd=ROOT)
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest().upper()
def resources():
    rows=[dict(pid=p.pid, **p.info) for p in psutil.process_iter(['name','create_time','cmdline'])
          if re.match(r'^(vsim|vsimk|vlog|vopt|vcover|elinx|implementation|quartus)',p.info['name'] or '',re.I)]
    memory=psutil.virtual_memory().available; disk=shutil.disk_usage(ROOT).free
    assert not rows, rows
    assert memory>=5*1024**3 and disk>=8*1024**3, (memory,disk)
    return dict(memory_bytes=memory,disk_bytes=disk,native_processes=rows)
def binding():
    names=git('ls-tree','-r','--name-only','e5cd8150','--','rtl','elinx').decode().splitlines()
    result=[]
    current=git('ls-files','--','rtl','elinx').decode().splitlines()
    assert current==names
    for name in names:
        frozen=git('show','e5cd8150:'+name)
        assert (ROOT/name).read_bytes()==frozen, name
        result.append(dict(path=name,sha256=sha(ROOT/name)))
    return result
def init():
    assert not (BASE/'state.json').exists(), 'Do not restart an existing batch clock'
    assert git('branch','--show-current').decode().strip()=='t63'
    assert git('rev-parse','HEAD').decode().strip()=='591d99a65933464faa5f2eda3e0e7e2253ed84bb'
    start=datetime.now(TZ)
    s=dict(start=start.isoformat(),hard_deadline=(start+timedelta(hours=6)).isoformat(),resources=resources(),binding_before=binding())
    original=git('show','HEAD:sim/tests.txt')
    assert (ROOT/'sim/tests.txt').read_bytes()==original
    inputs=load(ROOT/'docs/evidence/t65_gap_tests/ucdb_inputs.json')['t65']
    lines=[]
    for row in inputs:
        params=load(ROOT/row['folder']/'summary.json')['parameters']
        lines.append(row['test']+('|' + ','.join(params) if params else ''))
    assert len(lines)==16
    newline=b'\r\n' if original.endswith(b'\r\n') else b'\n'
    (ROOT/'sim/tests.txt').write_bytes(original+(b'' if original.endswith(b'\n') else newline)+newline.join(x.encode() for x in lines)+newline)
    assert (ROOT/'sim/tests.txt').read_bytes().startswith(original)
    save(BASE/'state.json',s);save(EVID/'preflight.txt',s)

def negative():
    # This process-only wrapper changes a generated capture after real simulation.
    # Neither TB, checker nor eda.py default behavior is altered.
    sys.path.insert(0,str(ROOT/'tools'))
    import eda
    original=eda.Flow.job
    def job(self,name,*args,**kwargs):
        result=original(self,name,*args,**kwargs)
        if name=='simulation':
            p=self.folder/'t65_trace.txt'
            shutil.copyfile(p,BASE/'negative_original_trace.txt')
            p.write_text('',encoding='ascii')
        return result
    eda.Flow.job=job
    return eda.sim(argparse.Namespace(test='tb_t65_queue_a',deadline=sys.argv[2],seed=20261007,param=[],netlist=[],coverage=False))

def run():
    s=load(BASE/'state.json')
    assert datetime.now(TZ)<datetime.fromisoformat(s['hard_deadline'])
    env=os.environ.copy();env.update(AFDX_PYTHON=str(PYTHON),MODELSIM_HOME=str(MS),AFDX_CE_DIV='2',PYTHONDONTWRITEBYTECODE='1')
    assert float(env.get('AFDX_MEM_FLOOR_GB','5'))>=5
    assert not env.get('AFDX_LATEST_PREFIX')
    for key in ('AFDX_MEM_LIMIT_GB','AFDX_MEM_FLOOR_GB'): assert key not in env, 'Use default memory guards'
    with (BASE/'execution.lock').open('a+b') as lock:
        lock.seek(0);lock.write(b'0');lock.flush();lock.seek(0);msvcrt.locking(lock.fileno(),msvcrt.LK_NBLCK,1)
        stages=['positive','negative','regression']
        for stage in stages:
            resources()
            deadline=min(datetime.now(TZ)+timedelta(hours=5),datetime.fromisoformat(s['hard_deadline'])).isoformat()
            if stage=='negative':
                args=[sys.executable,'-B','-X','utf8',__file__,'negative',deadline]
            else:
                args=['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(ROOT/('sim/regress.ps1' if stage=='regression' else 'sim/run.ps1')),'-Deadline',deadline]
                if stage=='positive':args+=['-Test','tb_t65_queue_a']
            before=set((ROOT/'out/regress').glob('rtl_*'))
            begin=now()
            with (EVID/(stage+'_entry.txt')).open('wb') as stream:
                p=subprocess.Popen(args,cwd=ROOT,env=env,stdout=stream,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
                created=psutil.Process(p.pid).create_time()
                active=dict(stage=stage,pid=p.pid,created=created,command=args,started=begin,deadline=deadline)
                save(BASE/'current.json',dict(status='running',**active))
                try:p.wait(timeout=max(1,(datetime.fromisoformat(deadline)-datetime.now(TZ)).total_seconds()))
                except subprocess.TimeoutExpired:
                    proc=psutil.Process(p.pid)
                    if proc.create_time()==created:
                        for q in reversed(proc.children(recursive=True)):
                            try:q.kill()
                            except psutil.NoSuchProcess:pass
                        proc.kill()
                    p.wait()
            result=dict(**active,finished=now(),exit_code=p.returncode)
            if stage=='regression':
                batch=set((ROOT/'out/regress').glob('rtl_*'))-before
                assert len(batch)==1, batch
                result['batch']=str(next(iter(batch)))
                save(EVID/'regression_summary.txt',load(next(iter(batch))/'summary.json'))
            else:
                summary=load(ROOT/'out/latest_tb_t65_queue_a.json')
                result['summary']=summary
                assert any(Path(x['path']).name=='t65_check.py' for x in summary['inputs'])
                assert summary['result']=='PASS' and summary['errors']==0
                assert bool(summary['passed'])==(stage=='positive')
                assert (summary['check']['errors']==0)==(stage=='positive')
                assert p.returncode==(0 if stage=='positive' else 1)
                for name in ('simulation.log','check.log','compile.log'):
                    shutil.copyfile(Path(summary['folder'])/name,EVID/(stage+'_'+name.replace('.log','.txt')))
            save(EVID/(stage+'_result.txt'),result)
            save(BASE/'current.json',dict(status='finished',**result))
            print(stage+' finished exit='+str(p.returncode),flush=True)
            if stage=='regression':assert p.returncode==0
        save(EVID/'binding_after.txt',binding())
        s['finished']=now();save(BASE/'state.json',s)

if __name__=='__main__':
    action=sys.argv[1]
    if action=='init':init()
    elif action=='negative':raise SystemExit(negative())
    elif action=='run':run()
    else:raise ValueError(action)
