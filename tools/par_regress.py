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
from eda import free_disk_bytes, modelsim_slot_pids

ROOT = Path(__file__).resolve().parents[1]
TZ = timezone(timedelta(hours=8))
GIB = 1024**3
EDA_NAMES = ('elinx_synthesis.exe', 'implementation.exe', 'quartus_map.exe', 'elinx.exe')
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
    eda = set()
    for p in psutil.process_iter(['pid', 'name', 'create_time', 'memory_info']):
        try:
            name = (p.info['name'] or '').lower()
            if name in EDA_NAMES:
                eda.add(p.pid)
        except psutil.NoSuchProcess:
            pass
    return modelsim_slot_pids(), eda


def reserved_sim_slots(active, global_slots):
    """Include foreign kernels and own workers still in compile/check phases."""
    workers=[v for v in active if v['row']['kind']!='SYNTH']
    owned=set().union(*(v.get('sim_pids',set()) for v in workers))
    return len(workers)+len(global_slots-owned)


def reserved_synth_slots(active, global_slots):
    """Reserve mapping workers in addition to external eLinx/GUI processes."""
    workers=[v for v in active if v['row']['kind']=='SYNTH']
    owned=set().union(*(v.get('eda_pids',set()) for v in workers))
    return len(workers)+len(global_slots-owned)


def reserved_netlist_bytes(active, observed_peak):
    """Reserve not-yet-resident memory for queued reference/compile phases.

    An A runner in its small RTL-reference phase still reserves a complete VQM
    slot. Otherwise several small wrappers can pass the free-RAM gate before
    their netlists all grow at once.
    """
    budget=max(observed_peak*1.10,GIB)
    reserve=sum(max(0,budget-v.get('rss',0)) for v in active
                if v['row']['kind'] in ('A','B','VQM76'))
    return budget,reserve


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--list', type=Path)
    parser.add_argument('--jobs', type=Path, help='Explicit finite JSON job list')
    parser.add_argument('--rtl-root', type=Path, default=ROOT)
    parser.add_argument('--case', action='append', default=[])
    parser.add_argument('--branch-tests', action='store_true')
    parser.add_argument('--gui', action='append', default=[])
    parser.add_argument('--netlist', type=Path)
    parser.add_argument('--synth', action='append', default=[])
    parser.add_argument('--class-b', action='store_true')
    parser.add_argument('--max-sims', type=int, default=10)
    parser.add_argument('--max-owned-sims', type=int, default=10)
    parser.add_argument('--max-netlists', type=int, default=3)
    parser.add_argument('--max-synth', type=int, default=6)
    parser.add_argument('--raw-sources', action='store_true', help='Compile original RTL without portability copies')
    parser.add_argument('--post-command',type=Path,help='Finite JSON argv to execute once after this queue ends')
    parser.add_argument('--compute-cores',type=int,default=0,help='Computing simulations plus one owned build reservation')
    parser.add_argument('--paused-manifest',type=Path,help='Identity-pinned T76 kernels held for priority work')
    parser.add_argument('--manage-pauses',action='store_true')
    parser.add_argument('--peer-queue',type=Path,action='append',default=[])
    parser.add_argument('--critical-net-queue',type=Path)
    parser.add_argument('--own-netlist-limit',action='store_true',help='Apply the netlist limit to this queue; still enforce whole-host CPU/RAM/ModelSim limits')
    parser.add_argument('--rtl-hours', type=float, default=8)
    parser.add_argument('--plan-only', action='store_true')
    parser.add_argument('--resume', action='store_true', help='Adopt original PID/creation-time pairs; do not restart jobs')
    parser.add_argument('--pending-root', type=Path, help='Frozen source root for jobs not yet started on resume')
    args = parser.parse_args()
    if not (1 <= args.max_sims <= 10 and 1 <= args.max_owned_sims <= 10
            and 1 <= args.max_netlists <= 3 and 1 <= args.max_synth <= 6):
        parser.error('Invalid global/owned/netlist/synthesis resource limits')
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
    if args.jobs:
        enqueue(json.loads(args.jobs.read_text(encoding='utf-8')))
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
         max_owned_sims=args.max_owned_sims,max_netlists=args.max_netlists,max_synth=args.max_synth,
         raw_sources=args.raw_sources,memory_launch_floor_gib=4,disk_launch_floor_gib=20,automatic_retries=False))
    report()
    if args.plan_only:
        return 0

    def synth_status(top):
        found = [r for r in runs if r['Kind'] == 'SYNTH' and r['Test'] == top]
        return found[-1] if found else None

    def ready(row):
        if row.get('wait_until_any_exit'):
            alive=[]
            for identity in row['wait_until_any_exit']:
                try:alive.append(psutil.Process(identity['pid']).create_time()==identity['created'])
                except psutil.NoSuchProcess:alive.append(False)
            if all(alive):return False
        if any(index not in {r['Index'] for r in runs} for index in row.get('after',[])):
            return False
        if row['kind']=='VQM76' and 'reference_index' in row:
            return any(r['Index']==row['reference_index'] and r['Status']=='PASS' for r in runs)
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
                item['sim_pids']={q.pid for q in children if q.name().lower() in ('vsim.exe','vsimk.exe')}
                item['eda_pids']={q.pid for q in children if q.name().lower() in EDA_NAMES}
                rss = sum(q.memory_info().rss for q in children)
                item['rss'] = rss
                item['peak'] = max(item['peak'], rss)
                if item['row']['kind'] in ('A','VQM76') and any(q.name().lower() == 'vsimk.exe' for q in children):
                    peaks['observed_class_a_tree_bytes'] = max(peaks.get('observed_class_a_tree_bytes', 0), rss)
                    kernels=[q for q in children if q.name().lower()=='vsimk.exe']
                    optimizing=any(q.name().lower().startswith('vopt') for q in children)
                    if not optimizing and any(re.search(r'/gui_netlist/[^/]+_gui/|/t76_sim/tb_t76_load/',q.cwd().replace('\\','/')) and q.cpu_times().user>=5 for q in kernels):
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
        sim_slots, eda_slots = processes()
        available = psutil.virtual_memory().available
        disk = free_disk_bytes(ROOT.anchor)
        sim_reserved = max(reserved_sim_slots(active.values(),sim_slots),len(sim_slots))
        # The official .do host waits for one child simulator. Both kernels
        # occupy process slots, but the bounded job computes on one core.
        duplicate_hosts=sum(max(0,len(v.get('sim_pids',set()) & sim_slots)-1)
            for v in active.values() if v['row']['kind']!='SYNTH')
        own_workers={v['identity']['pid'] for v in active.values()}
        for path in args.peer_queue:
            peer=json.loads(path.read_text(encoding='utf-8'))
            for row in peer.get('Active',[]):
                identity=row['Process']
                if row['kind']=='SYNTH' or identity['pid'] in own_workers:continue
                try:
                    process=psutil.Process(identity['pid'])
                    if process.create_time()!=identity['created']:continue
                    kernels={q.pid for q in process.children(recursive=True) if q.pid in sim_slots}
                    if not kernels:sim_reserved+=1
                    else:duplicate_hosts+=max(0,len(kernels)-1)
                except psutil.NoSuchProcess:pass
        compute_reserved=sim_reserved-duplicate_hosts
        synth_reserved = reserved_synth_slots(active.values(),eda_slots)
        reserve_rx=0
        if args.critical_net_queue:
            peer=json.loads(args.critical_net_queue.read_text(encoding='utf-8'))
            if not any(r.get('id',r.get('Index'))==5 for r in peer.get('Active',[])+peer.get('Runs',[])):
                rx=next((r for r in peer.get('Pending',[]) if r.get('id')==5),None)
                if rx:
                    for identity in rx.get('wait_until_any_exit',[]):
                        try:released=psutil.Process(identity['pid']).create_time()!=identity['created']
                        except psutil.NoSuchProcess:released=True
                        if released:reserve_rx=1;break
        paused_count=0;build_reservation=bool(eda_slots)
        if args.paused_manifest:
            hold=json.loads(args.paused_manifest.read_text(encoding='utf-8'))
            owner=hold.get('hold_owner',{})
            try:build_reservation|=psutil.Process(owner['pid']).create_time()==owner['created']
            except (KeyError,psutil.NoSuchProcess):pass
            for entry in hold['kernels']:
                if not entry.get('paused'):continue
                try:
                    q=psutil.Process(entry['pid'])
                    if q.create_time()==entry['created'] and q.pid in sim_slots:paused_count+=1
                except psutil.NoSuchProcess:pass
            # Resume original kernels without re-launching or changing any
            # deadline. All identities and the owning worktree are rechecked.
            if args.manage_pauses and not build_reservation and args.compute_cores:
                for entry in sorted(hold['kernels'],key=lambda r:-r.get('resume_priority',0)):
                    if not entry.get('paused') or compute_reserved-paused_count+reserve_rx>=args.compute_cores:continue
                    try:
                        q=psutil.Process(entry['pid'])
                        if q.create_time()!=entry['created']:continue
                        if str(ROOT).lower() not in q.cwd().lower():raise RuntimeError('Paused kernel left task worktree')
                        q.resume();entry.update(paused=False,resumed=now());paused_count-=1
                        save(args.paused_manifest,hold)
                        print('PAR RESUME ORIGINAL KERNEL '+str(q.pid),flush=True)
                    except psutil.NoSuchProcess:
                        entry.update(paused=False,note='Original kernel already exited; no replacement resumed')
                        save(args.paused_manifest,hold)
        observed = peaks.get('observed_class_a_tree_bytes', 0)
        # Reserve the complete measured footprint even for A runners which are
        # still preparing a tiny RTL reference. Admit only one before measuring
        # a real official-netlist kernel past optimization.
        net_active = sum(v['row']['kind'] in ('A', 'B','VQM76') for v in active.values())
        own_sim_workers=sum(v['row']['kind']!='SYNTH' for v in active.values())
        owned_sim_pids=set().union(*(v.get('sim_pids',set()) for v in active.values()))
        # Conservatively reserve every foreign kernel as a netlist seat. This
        # keeps the three running T75 VQM jobs within the whole-host limit.
        foreign_sim_workers=len(sim_slots-owned_sim_pids)
        net_budget,net_reserve=reserved_netlist_bytes(active.values(),observed)
        usable=available-net_reserve
        net_limit = min(args.max_sims, max(1, net_active + int(max(0,usable-4*GIB)/net_budget))) if peaks.get('class_a_runtime_measured') else 1
        peaks['netlist_concurrency_limit'] = net_limit
        candidates = sorted(jobs, key=lambda r: (0 if r['kind'] in ('A','B','VQM76') else 1 if r['kind']=='SYNTH' else 2,
                            -r.get('priority',WEIGHTS.get(r['test'], 100)), r['id']))
        for row in candidates:
            if not ready(row):
                continue
            if available < 4*GIB or usable < 4*GIB or disk < 20*GIB:
                break
            if row['kind'] == 'SYNTH':
                if synth_reserved >= args.max_synth:
                    continue
            else:
                if sim_reserved >= args.max_sims or own_sim_workers >= args.max_owned_sims:
                    continue
                if args.compute_cores and compute_reserved-paused_count+int(build_reservation)+reserve_rx>=args.compute_cores:
                    continue
                if row['kind'] in ('A', 'B','VQM76') and (net_active >= args.max_netlists or net_active >= net_limit or
                        (not args.own_netlist_limit and net_active+foreign_sim_workers >= args.max_netlists)):
                    continue
            if row['kind'] == 'B' and any(synth_status(t)['Status'] != 'PASS' for t in row['tops']):
                runs.append(dict(Test=row['test'],Param=row['params'],Status='BLOCKED',Exit=None,Folder=None,
                     Checks=None,CheckItems=None,Kind='B',Index=row['id'],Error='Required yosys mapping failed'))
                jobs.remove(row)
                report()
                break
            root = Path(row['root'])
            deadline = (datetime.now(TZ)+timedelta(hours=24 if row['kind'] in ('A','B','VQM76','RTL76') else args.rtl_hours)).isoformat()
            env = os.environ.copy()
            env.setdefault('MODELSIM_HOME', 'E:/Verilog/ModelSim/setup_pack/win64')
            env.setdefault('ELINX_HOME', 'E:/2026_Embedded_FPGA/setup_pack')
            env.update(AFDX_PYTHON=sys.executable, AFDX_CE_DIV='2',
                       AFDX_MEM_FLOOR_GB='3', AFDX_LATEST_PREFIX=row['prefix'], AFDX_PAR_RESOURCE_GATES='1',
                       AFDX_MODELSIM_DECL_ORDER='0' if args.raw_sources else '1')
            if row['kind']=='MIX_SEARCH76':
                command=[sys.executable,'-B','-X','utf8',str(root/'tools/t76_search.py'),'--deadline',deadline]
                env['AFDX_T76_SPEC_CONFIRMED']='1'
            elif row['kind'] in ('RTL76','VQM76'):
                command=[sys.executable,'-B','-X','utf8',str(root/'tools/t76_sim.py'),'--deadline',deadline]
                env['AFDX_T76_SPEC_CONFIRMED']='1'
                if row['kind']=='VQM76':
                    command+=['--netlist',row['netlist']]
                    reference=next(r for r in runs if r['Index']==row['reference_index'])
                    command+=['--reference',reference['Folder']]
                for param in row['params'].split(','):
                    if param:command+=['--param',param]
            elif row['kind'] == 'A':
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
    if args.post_command:
        command=json.loads(args.post_command.read_text(encoding='utf-8'))
        if not isinstance(command,list) or not all(isinstance(x,str) for x in command):
            raise ValueError('Post command must be a JSON array of argv strings')
        outcome=subprocess.run(command,cwd=ROOT,timeout=1800,creationflags=subprocess.CREATE_NO_WINDOW)
        save(output/'postprocess.json',dict(command=command,exit=outcome.returncode,finished=now()))
        if outcome.returncode:return outcome.returncode
    return 0 if all(r['Status']=='PASS' for r in runs) else 1


if __name__ == '__main__':
    raise SystemExit(main())
