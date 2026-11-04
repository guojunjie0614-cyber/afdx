"""Finite T78 RTL closeout run. No retries or continuation service."""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import psutil

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/t78'


def main():
    OUT.mkdir(parents=True, exist_ok=False)
    started = time.time()
    deadline = datetime.now(timezone(timedelta(hours=8))) + timedelta(hours=4)
    os.environ.setdefault('MODELSIM_HOME', 'E:/Verilog/ModelSim/setup_pack/win64')
    os.environ.setdefault('ELINX_HOME', 'E:/2026_Embedded_FPGA/setup_pack')
    os.environ.update(AFDX_PYTHON=sys.executable, AFDX_CE_DIV='2',
        AFDX_MEM_FLOOR_GB='3', AFDX_MODELSIM_DECL_ORDER='0',
        AFDX_SIM_TIMEOUT_SECONDS='14400')
    receipt = dict(pid=os.getpid(), created=psutil.Process().create_time(),
        source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        started=deadline.__class__.fromtimestamp(started,deadline.tzinfo).strftime('%Y-%m-%d %H:%M:%S'),
        deadline=deadline.strftime('%Y-%m-%d %H:%M:%S'), runs=[])
    def save():
        (OUT/'run.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    save()
    queue=[sys.executable,'-B','-X','utf8','tools/par_regress.py',
        '--output','out/t78_regression','--list','sim/tests.txt','--branch-tests',
        '--raw-sources','--max-sims','6','--max-owned-sims','6','--rtl-hours','4']
    commands=[queue]+[[sys.executable,'-B','-X','utf8','tools/t76_app.py',
        '--deadline',deadline.isoformat()]+extra for extra in ([],['--small'])]
    for index,command in enumerate(commands):
        with (OUT/f'run_{index}.log').open('xb') as log:
            process=subprocess.Popen(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,
                creationflags=subprocess.CREATE_NO_WINDOW)
            row=dict(command=command,pid=process.pid,created=psutil.Process(process.pid).create_time())
            receipt['runs'].append(row);save()
            try:
                row['exit']=process.wait(timeout=max(1,14400-(time.time()-started)))
            except subprocess.TimeoutExpired:
                tree=psutil.Process(process.pid).children(recursive=True)
                for child in reversed(tree):
                    try:child.kill()
                    except psutil.NoSuchProcess:pass
                process.kill();process.wait()
                row.update(exit=process.returncode,timed_out=True)
                save();break
            save()
    receipt.update(finished=datetime.now(deadline.tzinfo).strftime('%Y-%m-%d %H:%M:%S'),
        seconds=round(time.time()-started,3))
    save()
    return int(len(receipt['runs'])!=3 or any(r['exit']!=0 for r in receipt['runs']))


if __name__=='__main__':raise SystemExit(main())
