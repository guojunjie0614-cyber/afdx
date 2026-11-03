"""One finite queue-completion callback; no timer, new job, or continuation."""
import argparse
from datetime import datetime,timedelta,timezone
import json
import os
from pathlib import Path
import subprocess
import sys

import psutil

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/t76'


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--guard',type=Path,required=True)
    args=parser.parse_args()
    OUT.mkdir(exist_ok=True)
    lock=OUT/'closeout.lock'
    try:
        descriptor=os.open(lock,os.O_WRONLY|os.O_CREAT|os.O_EXCL)
    except FileExistsError:
        identity=read(lock)
        try:live=psutil.Process(identity['pid']).create_time()==identity['created']
        except psutil.NoSuchProcess:live=False
        if not live:raise RuntimeError('Stale closeout lock; preserve it for inspection')
        print('T76 other finite completion callback owns closeout')
        return 0
    identity=dict(pid=os.getpid(),created=psutil.Process().create_time())
    with os.fdopen(descriptor,'w',encoding='utf-8') as stream:json.dump(identity,stream)
    try:
        queues={name:read(ROOT/'out'/name/'summary.json') for name in
                ('t76_fallback_parallel','t76_vqm_parallel')}
        terminal=all(q.get('Finished') and not q.get('Active') and not q.get('Pending') for q in queues.values())
        if not terminal:
            print('T76 this finite queue ended; the other queue still owns its original jobs')
            return 0
        receipt=OUT/'closeout_commit.json'
        if receipt.is_file():
            head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
            if head!=read(receipt)['commit']:raise RuntimeError('HEAD changed after recorded closeout')
            print('T76 closeout already recorded '+head)
            return 0
        command=[sys.executable,'-B','-X','utf8',str(ROOT/'tools/t76_report.py'),
                 '--require-terminal','--commit-guard',str(args.guard.resolve())]
        log=OUT/'closeout.log'
        with log.open('ab') as stream:
            outcome=subprocess.run(command,cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT,
                timeout=1800,creationflags=subprocess.CREATE_NO_WINDOW)
        status=dict(timestamp=datetime.now(timezone(timedelta(hours=8))).strftime('%Y-%m-%d %H:%M:%S'),
                    command=command,exit=outcome.returncode,log=str(log),
                    result='COLLECTED_AND_COMMITTED' if outcome.returncode==0 else 'FAILED_PRESERVED')
        (OUT/'closeout.json').write_text(json.dumps(status,indent=2)+'\n',encoding='utf-8')
        print(json.dumps(status))
        return outcome.returncode
    finally:
        if read(lock)==identity:lock.unlink()


if __name__=='__main__':raise SystemExit(main())
