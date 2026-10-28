"""T62 stage budgets and one process admission registry for all candidates.

No installation/global configuration is changed. Only a verified owned process
tree may be stopped. The registry lives in the coordinator's ignored output.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime
import json
import msvcrt
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import time
import uuid

import psutil
import eda

ROOT = Path(__file__).resolve().parents[1]
COORD = ROOT.parent / 'c3_t62' / 'out/t62'
GIB = 1024 ** 3
BUDGETS = dict(analysis=3600, export=300, pack=1200, timing=1200,
               route=7200, report=1800, c4_probe=1200)
NATIVE = {'implementation.exe', 'quartus_map.exe', 'quartus_cdb.exe', 'elinx_synthesis.exe'}
MODELSIM = {'vsim.exe', 'vlog.exe', 'vlib.exe', 'vopt.exe'}


def now():
    return datetime.now().astimezone().isoformat()


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    for retry in range(10):
        try:
            os.replace(temporary, path)
            return
        except PermissionError:
            if retry == 9:
                raise
            time.sleep(.05 * (retry + 1))


def capture(process):
    return dict(pid=process.pid, created=process.create_time(),
                command=process.cmdline(), cwd=process.cwd())


def alive(identity):
    try:
        current = capture(psutil.Process(identity['pid']))
        return current == identity
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return False


def observed(group):
    wanted = NATIVE if group == 'elinx' else MODELSIM
    identities = []
    for process in psutil.process_iter(['name']):
        if (process.info['name'] or '').lower() in wanted:
            try:
                identities.append(capture(process))
            except psutil.NoSuchProcess:
                continue
            except psutil.AccessDenied:
                # Count an inaccessible matching process; never act on it.
                identities.append(dict(pid=process.pid, inaccessible=True))
    return identities


@contextmanager
def locked_registry():
    COORD.mkdir(parents=True, exist_ok=True)
    with (COORD / 'admission.lock').open('a+b') as stream:
        if stream.tell() == 0:
            stream.write(b'0')
            stream.flush()
        while True:
            stream.seek(0)
            try:
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                break
            except OSError:
                time.sleep(.1)
        try:
            path = COORD / 'admission.json'
            value = json.loads(path.read_text()) if path.exists() else dict(leases=[], events=[])
            value['leases'] = [row for row in value['leases'] if alive(row['owner'])]
            yield value
            save(path, value)
        finally:
            stream.seek(0)
            msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)


class ResourceBlocked(RuntimeError):
    pass


@contextmanager
def admission(command, folder, units=1):
    executable = Path(command[0]).name.lower()
    group = 'elinx' if executable in NATIVE else 'modelsim' if executable in MODELSIM else 'helper'
    token = uuid.uuid4().hex
    queued = time.monotonic()
    while True:
        with locked_registry() as registry:
            running = observed(group) if group != 'helper' else []
            # Leases cover the small interval before a native process appears.
            leases = [row for row in registry['leases'] if row['group'] == group]
            counted = len(running) + sum(max(0,row.get('units',1)
                -sum(_descendant(item['pid'],row['owner']['pid']) for item in running)) for row in leases)
            memory = psutil.virtual_memory().available
            disk = shutil.disk_usage(ROOT).free
            resource_ok = memory >= 3 * GIB and disk >= 8 * GIB
            capacity = group == 'helper' or counted+units <= (6 if group == 'elinx' else 10)
            if resource_ok and capacity:
                item = dict(token=token, owner=capture(psutil.Process()), group=group,units=units,
                            folder=str(folder), command=command, admitted=now(),
                            queue_seconds=time.monotonic()-queued,
                            observed_tools=running, memory_free_bytes=memory, disk_free_bytes=disk)
                registry['leases'].append(item)
                registry['events'].append(dict(event='admitted', **item))
                break
            if not resource_ok and not registry['leases'] and not observed('elinx') and not observed('modelsim'):
                raise ResourceBlocked('resource_budget: all tools idle and RAM <3 GiB or E free <8 GiB')
        save(Path(folder) / 'waiting_resource.json', dict(status='waiting_resource', group=group,
            command=command, queued_seconds=time.monotonic()-queued, memory_free_bytes=memory,
            disk_free_bytes=disk, observed_tools=running))
        time.sleep(2)
    try:
        yield item
    finally:
        with locked_registry() as registry:
            registry['leases'] = [row for row in registry['leases'] if row['token'] != token]
            registry['events'].append(dict(event='released', token=token, time=now()))


def _descendant(pid, owner):
    try:
        return any(process.pid == owner for process in psutil.Process(pid).parents())
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return False


class Flow(eda.Flow):
    def __init__(self, kind, name, deadline):
        # Windows wall-clock resolution can give concurrent parameterizations
        # the same microsecond timestamp. A UUID keeps both attempts immutable.
        stamp=datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'_'+uuid.uuid4().hex[:12]
        self.folder=ROOT/'out'/kind/name/stamp
        self.folder.mkdir(parents=True,exist_ok=False)
        self.jobs=[]
        self.deadline = datetime.fromisoformat(deadline).timestamp() if deadline else None
        self.result=dict(name=name,started=now(),folder=str(self.folder),
            scope='T62 bounded diagnostics; no delivery acceptance',memory_limit_gib=None,
            memory_floor_gib=3, disk_floor_gib=8, overall_deadline=self.deadline,
            native_tool_budgets_seconds=BUDGETS)

    def job(self, name, command, budget=900, cwd=None):
        command = list(map(str, command))
        budget = BUDGETS.get(name, budget)
        # run_app.do owns one outer ModelSim plus one compiler/simulator child.
        with admission(command, self.folder,units=2 if name=='app_small' else 1) as lease:
            # Resource waiting is excluded from the stage budget. An explicit
            # caller deadline remains an intentional additional upper bound.
            if self.deadline is not None:
                budget = min(budget, self.deadline-time.time())
                if budget <= 0:
                    raise RuntimeError('Explicit caller deadline reached')
            begin = time.monotonic()
            owned = {}
            peak = 0
            minimum_memory = psutil.virtual_memory().available
            minimum_disk = shutil.disk_usage(ROOT).free
            reason = None
            actions = []
            path = self.folder / (name + '.log')
            with path.open('xb') as stream:
                process = psutil.Popen(command, cwd=str(cwd or self.folder), stdout=stream,
                    stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
                identity = capture(process)
                owned[process.pid] = identity
                active = dict(name=name, started=now(), **identity, log=str(path),
                    budget_seconds=budget, status='running', admission=lease)
                save(self.folder / 'active_job.json', active)
                last_save = begin
                while process.poll() is None:
                    rss = 0
                    try:
                        members = [process] + process.children(recursive=True)
                    except psutil.NoSuchProcess:
                        members = []
                    for child in members:
                        try:
                            owned[child.pid] = capture(child)
                            rss += child.memory_info().rss
                            if name=='app_small' and child.pid!=process.pid:
                                executable=Path(owned[child.pid]['command'][0]).name.lower()
                                child_budget={'vlog.exe':120,'vsim.exe':900}.get(executable)
                                if child_budget and time.time()-child.create_time()>child_budget:
                                    reason='timeout_'+executable
                        except (psutil.NoSuchProcess, psutil.AccessDenied):
                            continue
                    peak = max(peak, rss)
                    minimum_memory = min(minimum_memory, psutil.virtual_memory().available)
                    minimum_disk = min(minimum_disk, shutil.disk_usage(ROOT).free)
                    if time.monotonic() - begin > budget:
                        reason = 'timeout'
                    elif minimum_disk < 8 * GIB:
                        reason = 'disk_floor_8gib'
                    if reason:
                        for item in reversed(list(owned.values())):
                            matches = alive(item)
                            if matches:
                                try:
                                    psutil.Process(item['pid']).kill()
                                except psutil.NoSuchProcess:
                                    matches = False
                            actions.append(dict(identity=item, killed=matches))
                        process.wait(timeout=15)
                        break
                    if time.monotonic() - last_save >= 5:
                        save(self.folder / 'active_job.json', dict(active, owned_processes=list(owned.values()),
                            elapsed_seconds=time.monotonic()-begin, peak_tree_bytes=peak))
                        last_save = time.monotonic()
                    time.sleep(.5)
            info = dict(active, status='finished', finished=now(), exit_code=process.returncode,
                stop_reason=reason, seconds=time.monotonic()-begin, peak_tree_bytes=peak,
                minimum_available_memory_bytes=minimum_memory, minimum_disk_free_bytes=minimum_disk,
                owned_processes=list(owned.values()), termination_actions=actions)
            self.jobs.append(info)
            save(self.folder / 'tool_metrics.json', self.jobs)
            save(self.folder / 'active_job.json', info)
            if process.returncode or reason:
                raise RuntimeError(f'{name}: exit={process.returncode} reason={reason}; {path}')
            return path.read_text(encoding='utf-8-sig', errors='replace')


def install():
    eda.Flow = Flow


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('entry', choices=['synth', 'impl', 'report', 'sim'])
    args, rest = parser.parse_known_args()
    install()
    script = dict(synth='official_synth.py', impl='official_impl.py',
                  report='report_routed_timing.py', sim='eda.py')[args.entry]
    if args.entry == 'sim':
        import eda as simulation
        # Run the imported module's main, preserving its reference to Flow.
        sys.argv = [str(ROOT/'tools/eda.py'), 'sim', *rest]
        return simulation.main()
    sys.argv = [str(ROOT/'tools'/script), *rest]
    runpy.run_path(str(ROOT/'tools'/script), run_name='__main__')


if __name__ == '__main__':
    raise SystemExit(main())
