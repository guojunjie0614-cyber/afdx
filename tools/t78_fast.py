"""Finish the authorized quick subset, preserving all original long jobs."""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import psutil

ROOT=Path(__file__).resolve().parents[1]
LONG={'tb_sys_perf_var','tb_sys_perf','tb_sys_load','tb_sys_rtc'}

def main():
    original=json.loads((ROOT/'out/t78/run.json').read_text())
    deadline=datetime.strptime(original['started'],'%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone(timedelta(hours=8)))+timedelta(hours=1)
    receipt=dict(source_commit=original['source_commit'],pid=os.getpid(),created=psutil.Process().create_time(),
        started=original['started'],deadline=deadline.strftime('%Y-%m-%d %H:%M:%S'),runs=[],excluded=sorted(LONG))
    def save():
        (ROOT/'out/t78/fast_run.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    save()
    while True:
        q=json.loads((ROOT/'out/t78_regression/summary.json').read_text())
        if not any(r['test'] not in LONG for r in q['Active']+q['Pending']):break
        if datetime.now(deadline.tzinfo)>=deadline:raise TimeoutError('Quick subset deadline; original jobs retained')
        time.sleep(1)
    os.environ.update(AFDX_PYTHON=sys.executable,AFDX_CE_DIV='2',AFDX_MEM_FLOOR_GB='3',AFDX_MODELSIM_DECL_ORDER='0')
    for extra in ([],['--small']):
        command=[sys.executable,'-B','-X','utf8','tools/t76_app.py','--deadline',deadline.isoformat()]+extra
        with (ROOT/'out/t78'/('app_small.log' if extra else 'app_default.log')).open('xb') as log:
            p=subprocess.Popen(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
            row=dict(command=command,pid=p.pid,created=psutil.Process(p.pid).create_time());receipt['runs'].append(row);save()
            row['exit']=p.wait();save()
    receipt.update(finished=datetime.now(deadline.tzinfo).strftime('%Y-%m-%d %H:%M:%S'),
        seconds=(datetime.now(deadline.tzinfo)-datetime.strptime(original['started'],'%Y-%m-%d %H:%M:%S').replace(tzinfo=deadline.tzinfo)).total_seconds())
    save()
    return int(any(r['exit'] for r in receipt['runs']))

if __name__=='__main__':raise SystemExit(main())
