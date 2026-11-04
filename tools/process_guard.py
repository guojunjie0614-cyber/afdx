"""Bound only the process tree launched by a verification command."""
import json
import os
from pathlib import Path
import subprocess
import time
import psutil


def run(args, *, cwd, stdout, stderr, timeout, env=None, metrics=None):
    floor=int(float(os.environ.get('AFDX_MEM_FLOOR_GB','5'))*1024**3)
    limit=int(float(os.environ.get('AFDX_MEM_LIMIT_GB','10'))*1024**3)
    if floor and psutil.virtual_memory().available<floor:
        raise RuntimeError('Available memory below verification launch floor')
    start=time.monotonic();peak=0;reason=None;owned={}
    p=psutil.Popen(list(map(str,args)),cwd=cwd,env=env,stdout=stdout,stderr=stderr,
                   creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        while p.poll() is None:
            try:children=[p]+p.children(recursive=True)
            except psutil.NoSuchProcess:children=[]
            for q in children:
                try:owned[q.pid]=q.create_time()
                except psutil.NoSuchProcess:pass
            rss=0
            for pid,created in list(owned.items()):
                try:
                    q=psutil.Process(pid)
                    if q.create_time()==created:rss+=q.memory_info().rss
                except psutil.NoSuchProcess:pass
            peak=max(peak,rss)
            if time.monotonic()-start>timeout:reason='timeout'
            elif limit and rss>limit:reason='process_tree_memory_limit'
            elif floor and psutil.virtual_memory().available<floor:reason='available_memory_floor'
            if reason:break
            time.sleep(.2)
    finally:
        if p.poll() is None:
            for pid,created in reversed(list(owned.items())):
                try:
                    q=psutil.Process(pid)
                    if q.create_time()==created:q.kill()
                except psutil.NoSuchProcess:pass
            p.wait()
        if metrics:
            Path(metrics).write_text(json.dumps(dict(pid=p.pid,peak_tree_bytes=peak,
                seconds=round(time.monotonic()-start,3),returncode=p.returncode,
                stop_reason=reason),indent=2),encoding='utf-8')
    if reason:raise RuntimeError('Verification process stopped: '+reason)
    return subprocess.CompletedProcess(args,p.returncode)
