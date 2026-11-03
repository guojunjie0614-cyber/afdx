"""Resource-gated parallel RTL / official VQM / mapped-netlist regression.

No retries, heartbeat, or continuation service. Each process owns one unique
latest prefix and output library. Additional explicitly prepared jobs may be
submitted as JSON lists in OUTPUT/inbox/*.json while this coordinator is alive.
"""
import argparse
import ctypes
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import psutil
from eda import free_disk_bytes

ROOT = Path(__file__).resolve().parents[1]
TZ = timezone(timedelta(hours=8))
GIB = 1024**3
DEFAULT_BRANCH = ('tb_cfg_local_ready', 'tb_context_pipeline', 'tb_reassembly_engine',
                  'tb_reassembly_limits', 'tb_reassembly_transactions', 'tb_service_pipeline',
                  'tb_rtc_banked', 'tb_fragmentation', 'tb_app_payload_pipeline',
                  'tb_tx_ingress_elastic', 'tb_tx_buffer_bounds')
WEIGHTS = {'tb_sys_perf_var': 10000, 'tb_sys_perf': 5000, 'tb_sys_load': 3000,
           'tb_sys_rtc': 2000, 'tb_elinx': 1500, 'tb_gbe_burst': 1200,
           'tb_sys_net': 1000, 'tb_sys_615a': 900, 'tb_judge_capacity': 800}


class AdoptedProcess:
    """Hold a Windows process handle so exit status survives process exit."""
    def __init__(self, identity):
        self.pid=identity['pid']
        process=psutil.Process(self.pid)
        if process.create_time()!=identity['created']:
            raise RuntimeError('PID creation-time mismatch; refusing adoption')
        kernel=ctypes.windll.kernel32
        kernel.OpenProcess.restype=ctypes.c_void_p
        self.handle=kernel.OpenProcess(0x100000|0x1000,False,self.pid)
        if not self.handle:
            raise ctypes.WinError()
        self.returncode=None

    def poll(self):
        if self.returncode is None:
            status=ctypes.c_ulong()
            if not ctypes.windll.kernel32.GetExitCodeProcess(ctypes.c_void_p(self.handle),ctypes.byref(status)):
                raise ctypes.WinError()
            if status.value!=259:
                self.returncode=ctypes.c_long(status.value).value
                ctypes.windll.kernel32.CloseHandle(ctypes.c_void_p(self.handle))
        return self.returncode


def now():
    return datetime.now(TZ).isoformat()


def save(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temp.replace(path)


def read_list(path, kind='RTL', source_root=None):
    jobs = []
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        parts = line.strip().split('|')
        job = dict(test=parts[0], kind=kind, params=parts[1] if len(parts) > 1 else '')
        if source_root:
            job['root'] = str(source_root)
        if kind == 'B':
            job['tops'] = job.pop('params').split(',')
            job['params'] = parts[2] if len(parts) > 2 else ''
        jobs.append(job)
    return jobs


def processes():
    sims, eda = [], []
    for p in psutil.process_iter(['pid', 'name', 'create_time', 'memory_info']):
        try:
            name = (p.info['name'] or '').lower()
            if name in ('vsimk.exe', 'vsim.exe'):
                sims.append(p)
            if name in ('elinx_synthesis.exe', 'implementation.exe', 'quartus_map.exe', 'elinx.exe'):
                eda.append(p)
        except psutil.NoSuchProcess:
            pass
    # vsim.exe is a launcher; count kernels, and launchers not yet owning one.
    kernels = {p.pid for p in sims if p.info['name'].lower() == 'vsimk.exe'}
    pending = 0
    for p in sims:
        if p.pid in kernels:
            continue
        try:
            if not any(q.pid in kernels for q in p.children(recursive=True)):
                pending += 1
        except psutil.NoSuchProcess:
            pass
    return len(kernels) + pending, len(eda)


def reserved_netlist_bytes(active, observed_peak):
    """Reserve not-yet-resident memory for queued reference/compile phases.

    An A runner in its small RTL-reference phase still reserves a complete VQM
    slot. Otherwise several small wrappers can pass the free-RAM gate before
    their netlists all grow at once.
    """
    budget=max(observed_peak*1.10,GIB)
    reserve=sum(max(0,budget-v.get('rss',0)) for v in active
                if v['row']['kind'] in ('A','B'))
    return budget,reserve


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--list', type=Path)
    parser.add_argument('--rtl-root', type=Path, default=ROOT)
    parser.add_argument('--case', action='append', default=[])
    parser.add_argument('--branch-tests', action='store_true')
    parser.add_argument('--gui', action='append', default=[])
    parser.add_argument('--netlist', type=Path)
    parser.add_argument('--synth', action='append', default=[])
    parser.add_argument('--class-b', action='store_true')
    parser.add_argument('--max-sims', type=int, default=10)
    parser.add_argument('--rtl-hours', type=float, default=8)
    parser.add_argument('--plan-only', action='store_true')
    parser.add_argument('--resume', action='store_true', help='Adopt original PID/creation-time pairs; do not restart jobs')
    parser.add_argument('--pending-root', type=Path, help='Frozen source root for jobs not yet started on resume')
    args = parser.parse_args()
    if not 1 <= args.max_sims <= 10:
        parser.error('--max-sims must be between 1 and 10')
    output = args.output.resolve()
    output.relative_to(ROOT / 'out')
    if args.resume:
        previous=json.loads((output/'summary.json').read_text(encoding='utf-8'))
        owner=previous['Owner']
        if psutil.pid_exists(owner['pid']) and psutil.Process(owner['pid']).create_time()==owner['created']:
            raise RuntimeError('Original coordinator is still alive; refusing duplicate ownership')
    else:
        output.mkdir(parents=True, exist_ok=False)
        (output / 'inbox').mkdir()
    started = now()
    prefix = 'par_' + output.name + '_'
    jobs, runs, active, peaks = [], [], {}, {}
    serial = 0

    def enqueue(items):
        nonlocal serial
        for item in items:
            row = dict(item)
            row.setdefault('params', '')
            row.setdefault('root', str(ROOT))
            if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', row['test']):
                raise ValueError('Invalid test name')
            row['id'] = serial
            row['prefix'] = prefix + str(serial) + '_'
            serial += 1
            jobs.append(row)

    if args.resume:
        started=previous['Started'];jobs=previous['Pending'];runs=previous['Runs'];peaks=previous['PeakMemory']
        serial=max([r['Index'] for r in runs]+[r['id'] for r in jobs]+[r['id'] for r in previous['Active']])+1
        if args.pending_root:
            for row in jobs:row['root']=str(args.pending_root.resolve())
        for row in previous['Active']:
            identity=row.pop('Process');process=AdoptedProcess(identity)
            root=Path(row['root']);name=row['test']+'_gui' if row['kind']=='A' else row['test']
            latest=root/'out'/(row['prefix']+'latest_'+name+'.json')
            begin=identity['created'];launched=datetime.fromtimestamp(begin,TZ).isoformat()
            active[row['id']]=dict(row=row,process=process,log=(output/(str(row['id'])+'_'+row['test']+'.log')).open('ab'),
                identity=identity,started=launched,begin=time.monotonic()-(time.time()-begin),peak=peaks.get('observed_class_a_tree_bytes',0) if row['kind']=='A' else 0)
        save(output/('adoption_'+datetime.now(TZ).strftime('%Y%m%d_%H%M%S')+'.json'),
             dict(previous_owner=owner,new_owner=dict(pid=os.getpid(),created=psutil.Process().create_time()),
                  adopted=[v['identity'] for v in active.values()],note='PID, creation time and original deadlines preserved; no simulation restarted'))
    if args.list:
        enqueue(read_list(args.list, source_root=args.rtl_root.resolve()))
    enqueue([dict(test=t, kind='RTL') for t in args.case + (list(DEFAULT_BRANCH) if args.branch_tests else [])])
    enqueue([dict(test=t, kind='A', netlist=str(args.netlist.resolve())) for t in args.gui])
    enqueue([dict(test=t, kind='SYNTH') for t in args.synth])
    if args.class_b:
        enqueue(read_list(ROOT / 'sim/tests_netlist.txt', 'B'))

    def report():
        save(output / 'summary.json', dict(Started=started, Netlist=False, Runs=sorted(runs, key=lambda r: r['Index']),
             Pending=jobs, Active=[v['row'] | dict(Process=v['identity']) for v in active.values()],
             Owner=dict(pid=os.getpid(), created=psutil.Process().create_time()),
             PeakMemory=peaks, Finished=now() if not jobs and not active else None))

    save(output / ('resume_plan.json' if args.resume else 'plan.json'), dict(Started=started, Jobs=jobs, max_sims=args.max_sims,
         memory_launch_floor_gib=4, disk_launch_floor_gib=20, automatic_retries=False))
    report()
    if args.plan_only:
        return 0

    def synth_status(top):
        found = [r for r in runs if r['Kind'] == 'SYNTH' and r['Test'] == top]
        return found[-1] if found else None

    def ready(row):
        if row['kind'] != 'B':
            return True
        return all(synth_status(t) for t in row['tops']) and any(
            r['Test'] == row['test'] and r['Kind'] == 'RTL' and r['Status'] == 'PASS' for r in runs)

    print('PAR START ' + str(output), flush=True)
    while jobs or active:
        for inbox in sorted((output / 'inbox').glob('*.json')):
            enqueue(json.loads(inbox.read_text(encoding='utf-8')))
            inbox.rename(inbox.with_suffix('.accepted'))
            report()
        changed = False
        for key, item in list(active.items()):
            p = item['process']
            try:
                children = psutil.Process(p.pid).children(recursive=True)
                rss = sum(q.memory_info().rss for q in children)
                item['rss'] = rss
                item['peak'] = max(item['peak'], rss)
                if item['row']['kind'] == 'A' and any(q.name().lower() == 'vsimk.exe' for q in children):
                    peaks['observed_class_a_tree_bytes'] = max(peaks.get('observed_class_a_tree_bytes', 0), rss)
                    kernels=[q for q in children if q.name().lower()=='vsimk.exe']
                    optimizing=any(q.name().lower().startswith('vopt') for q in children)
                    if not optimizing and any(re.search(r'/gui_netlist/[^/]+_gui/',q.cwd().replace('\\','/')) and q.cpu_times().user>=5 for q in kernels):
                        peaks['class_a_runtime_measured']=True
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
            if p.poll() is None:
                continue
            item['log'].close()
            row = item['row']
            root = Path(row['root'])
            name = row['test'] + '_gui' if row['kind'] == 'A' else row['test']
            latest = root / 'out' / (row['prefix'] + 'latest_' + name + '.json')
            result = json.loads(latest.read_text(encoding='utf-8')) if latest.exists() else {}
            passed = p.returncode == 0 and result.get('completed' if row['kind'] == 'SYNTH' else 'passed') is True
            checks = result.get('checks')
            if checks is None and result.get('results'):
                checks = int(result['results'][-1][2])
            run = dict(Test=row['test'], Param=row['params'], Status='PASS' if passed else 'FAIL',
                       Exit=p.returncode, Folder=result.get('folder'), Checks=checks,
                       CheckItems=result.get('check', {}).get('items'), Kind=row['kind'], Index=key,
                       Started=item['started'], Finished=now(), Seconds=round(time.monotonic()-item['begin'], 3),
                       Process=item['identity'], PeakTreeBytes=item['peak'], Summary=str(latest),
                       Log=str(output / (str(key) + '_' + row['test'] + '.log')), Error=result.get('error'))
            runs.append(run)
            del active[key]
            print(f"PAR {run['Status']} {row['kind']} {row['test']} {row['params']} checks={checks} seconds={run['Seconds']}", flush=True)
            changed = True
        if changed:
            report()
        sims, edas = processes()
        available = psutil.virtual_memory().available
        disk = free_disk_bytes(ROOT.anchor)
        sim_active = sum(v['row']['kind'] != 'SYNTH' for v in active.values())
        synth_active = len(active) - sim_active
        observed = peaks.get('observed_class_a_tree_bytes', 0)
        # Reserve the complete measured footprint even for A runners which are
        # still preparing a tiny RTL reference. Admit only one before measuring
        # a real official-netlist kernel past optimization.
        net_active = sum(v['row']['kind'] in ('A', 'B') for v in active.values())
        net_budget,net_reserve=reserved_netlist_bytes(active.values(),observed)
        usable=available-net_reserve
        net_limit = min(args.max_sims, max(1, net_active + int(max(0,usable-4*GIB)/net_budget))) if peaks.get('class_a_runtime_measured') else 1
        peaks['netlist_concurrency_limit'] = net_limit
        candidates = sorted(jobs, key=lambda r: (0 if r['kind'] in ('A','B') else 1 if r['kind']=='SYNTH' else 2,
                            -WEIGHTS.get(r['test'], 100), r['id']))
        for row in candidates:
            if not ready(row):
                continue
            if available < 4*GIB or usable < 4*GIB or disk < 20*GIB:
                break
            if row['kind'] == 'SYNTH':
                if max(edas, synth_active) >= 6:
                    continue
            else:
                if max(sims, sim_active) >= args.max_sims:
                    continue
                if row['kind'] in ('A', 'B') and net_active >= net_limit:
                    continue
            if row['kind'] == 'B' and any(synth_status(t)['Status'] != 'PASS' for t in row['tops']):
                runs.append(dict(Test=row['test'],Param=row['params'],Status='BLOCKED',Exit=None,Folder=None,
                     Checks=None,CheckItems=None,Kind='B',Index=row['id'],Error='Required yosys mapping failed'))
                jobs.remove(row)
                report()
                break
            root = Path(row['root'])
            deadline = (datetime.now(TZ)+timedelta(hours=24 if row['kind'] in ('A','B') else args.rtl_hours)).isoformat()
            env = os.environ.copy()
            env.update(AFDX_PYTHON=sys.executable, MODELSIM_HOME='E:/Verilog/ModelSim/setup_pack/win64',
                       ELINX_HOME='E:/2026_Embedded_FPGA/setup_pack', AFDX_CE_DIV='2',
                       AFDX_MEM_FLOOR_GB='3', AFDX_LATEST_PREFIX=row['prefix'], AFDX_PAR_RESOURCE_GATES='1',
                       AFDX_MODELSIM_DECL_ORDER='1')
            if row['kind'] == 'A':
                command = [sys.executable,'-B','-X','utf8',str(root/'tools/gui_netlist.py'),'--test',row['test'],
                           '--netlist',row['netlist'],'--deadline',deadline]
                env['AFDX_GUI_SIM_TIMEOUT_SECONDS'] = '86400'
            else:
                command = [sys.executable,'-B','-X','utf8',str(root/'tools/eda.py')]
                if row['kind'] == 'SYNTH':
                    command += ['synth','--top',row['test'],'--deadline',deadline]
                    env['AFDX_SYNTH_TIMEOUT_SECONDS'] = '7200'
                else:
                    command += ['sim','--test',row['test'],'--seed','20261007','--deadline',deadline]
                    for param in row['params'].split(','):
                        if param:
                            command += ['--param',param]
                    if row['kind'] == 'B':
                        command += ['--netlist'] + [str(Path(synth_status(t)['Folder'])/'netlist.v') for t in row['tops']]
                        env['AFDX_NETLIST_SIM_TIMEOUT_SECONDS'] = '86400' if row['test']=='tb_sys_net' else '14400'
                env['AFDX_COMPILE_TIMEOUT_SECONDS'] = '600'
            log = (output / (str(row['id']) + '_' + row['test'] + '.log')).open('xb')
            proc = subprocess.Popen(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT,
                                    creationflags=subprocess.CREATE_NO_WINDOW)
            identity = dict(pid=proc.pid, created=psutil.Process(proc.pid).create_time(),deadline=deadline)
            active[row['id']] = dict(row=row,process=proc,log=log,identity=identity,started=now(),begin=time.monotonic(),peak=0)
            jobs.remove(row)
            print(f"PAR LAUNCH {row['kind']} {row['test']} pid={proc.pid} free_gib={available/GIB:.2f} disk_gib={disk/GIB:.2f}", flush=True)
            report()
            # Refresh global process and memory state for every launch.
            break
        else:
            if not active and jobs and not any(ready(r) for r in jobs):
                for row in jobs[:]:
                    runs.append(dict(Test=row['test'],Param=row['params'],Status='BLOCKED',Exit=None,Folder=None,
                         Checks=None,CheckItems=None,Kind=row['kind'],Index=row['id'],Error='No passed RTL prerequisite'))
                    jobs.remove(row)
                report()
        time.sleep(1)
    report()
    print('PAR FINISHED ' + str(output / 'summary.json'), flush=True)
    return 0 if all(r['Status']=='PASS' for r in runs) else 1


if __name__ == '__main__':
    raise SystemExit(main())
