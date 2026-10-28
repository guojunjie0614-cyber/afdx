"""Read-only process/resource sampling for the active T62 batch.

No job is started or stopped by this observer. The unique native coordinator
continues to own dispatch, timeouts, and status.json.
"""
import json
import msvcrt
from pathlib import Path
import shutil
import time

import psutil
import t62_runtime as rt

ROOT=Path(__file__).resolve().parents[1]
R2=ROOT/'out/t62/round_02'


def main():
    with (R2/'resource_sampler.lock').open('a+b') as lock:
        if lock.tell()==0:lock.write(b'0');lock.flush()
        lock.seek(0);msvcrt.locking(lock.fileno(),msvcrt.LK_NBLCK,1)
        owner=rt.capture(psutil.Process())
        old=R2/'resource_metrics.json'
        metrics=json.loads(old.read_text()) if old.exists() else dict(started=rt.now(),samples=0,
            peak_elinx=0,peak_modelsim=0,minimum_available_memory_bytes=None,minimum_E_free_bytes=None,
            processes={},changes=[],violations=[])
        metrics.update(owner=owner,status='running',interval_seconds=1,
            count_scope='All visible native eLinx/ModelSim processes; owned and external identities retained')
        previous=None;last_save=0
        while True:
            current={};counts=dict(elinx=0,modelsim=0)
            for process in psutil.process_iter(['name']):
                name=(process.info['name'] or '').lower()
                group='elinx' if name in rt.NATIVE else 'modelsim' if name in rt.MODELSIM else None
                if group is None:continue
                counts[group]+=1
                try:
                    identity=rt.capture(process);key=str(identity['pid'])+'_'+str(identity['created'])
                    current[key]=identity
                    row=metrics['processes'].setdefault(key,dict(identity=identity,group=group,first_seen=rt.now(),first_seen_epoch=time.time()))
                    row.update(last_seen=rt.now(),last_seen_epoch=time.time())
                except (psutil.NoSuchProcess,psutil.AccessDenied):continue
            stamp=rt.now();memory=psutil.virtual_memory().available;disk=shutil.disk_usage(ROOT).free
            metrics['samples']+=1;metrics.update(updated=stamp,active=current,current_counts=counts)
            metrics['peak_elinx']=max(metrics['peak_elinx'],counts['elinx'])
            metrics['peak_modelsim']=max(metrics['peak_modelsim'],counts['modelsim'])
            for key,value in [('minimum_available_memory_bytes',memory),('minimum_E_free_bytes',disk)]:
                metrics[key]=value if metrics[key] is None else min(value,metrics[key])
            signature=tuple(sorted(current))
            if signature!=previous:
                metrics['changes'].append(dict(time=stamp,counts=counts,identities=list(current.values()),
                    available_memory_bytes=memory,E_free_bytes=disk));previous=signature
            if counts['elinx']>6 or counts['modelsim']>10:
                metrics['violations'].append(dict(time=stamp,counts=counts))
            queue=json.loads((R2/'queue.json').read_text())
            if queue.get('coordinator_terminal') and not rt.alive(queue['owner']) and not any(
                row.get('owner') and rt.alive(row['owner']) for row in queue['jobs'].values()):
                metrics.update(status='completed',finished=stamp);rt.save(old,metrics);return 0
            if time.monotonic()-last_save>=10:
                rt.save(old,metrics);last_save=time.monotonic()
            time.sleep(1)


if __name__=='__main__':raise SystemExit(main())
