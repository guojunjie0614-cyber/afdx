"""Unique resumable T62 round-2 queue. Never retries or changes live inputs.

The model prepares candidate commits and requests; this process alone admits
six native workers and eight regression workers across the entire batch.
Every tool remains independently bounded by t62_runtime.Flow.
"""
import argparse
import json
import msvcrt
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

import psutil
import eda
import t62_runtime as rt
from t62_regress import cases

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/t62'
R2=OUT/'round_02'
PRES=['1.30','1.40','1.45','1.50','1.55','1.60','1.70']
ITEMS=['C0','C1','C2','C3a','C3b','C3c','C4','C4p','C5','C6']
RTL_ITEMS=['C1','C2','C3a','C3b','C3c','C6']
TERMINAL={'completed','failed','blocked','not_applicable'}
SYNTH_BYTES=763359240
ROUTE_BYTES=1751043075
RESERVE={key:SYNTH_BYTES+7*ROUTE_BYTES for key in ['C0',*RTL_ITEMS]}
RESERVE.update(C4p=7*ROUTE_BYTES,C5=ROUTE_BYTES,C4=0)
CANONICAL=ROOT.parent/'c3_t60_r5a_p155/out/synth/AFDX_top/20261027_085802_489925'


def load(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def sha(path):return eda.sha(Path(path))


def tree_size(path):
    """Do not follow synthesis junctions into shared frozen sources."""
    total=0
    if not Path(path).exists():return total
    for base,dirs,files in os.walk(path,followlinks=False):
        dirs[:]=[name for name in dirs if not (Path(base)/name).is_junction() and not (Path(base)/name).is_symlink()]
        for name in files:
            try:total+=(Path(base)/name).stat().st_size
            except FileNotFoundError:pass
    return total


def worktree(candidate):return ROOT.parent/('c3_t62_'+candidate.lower())


def freeze(root,extra=()):
    paths=subprocess.check_output(['git','-C',str(root),'ls-files','rtl','tb','tools','elinx','sim'],text=True).splitlines()
    keep={'.v','.vh','.py','.do','.tcl','.json','.edc','.sdc','.epr','.qdf','.txt','.csv','.hex','.count','.ini'}
    paths=[name for name in paths if Path(name).suffix.lower() in keep]
    paths+=list(extra)
    return {str(name):eda.sha(root/name) for name in sorted(set(paths))}


def empty_item(candidate):
    return dict(candidate=candidate,status='pending',phase='awaiting_C0',run_completed=False,
        control_reproduced=None,constraints_applied=None,functional_passed=None,timing_closed=None,
        valid_for_comparison=None,eligible_for_combination=None,slots={},jobs=[],reservation=None)


class Queue:
    def __init__(self):
        path=R2/'queue.json'
        self.value=load(path) if path.exists() else dict(round_id='round_02',created=rt.now(),
            items={key:empty_item(key) for key in ITEMS},jobs={},validation={},events=[])
        self.owner=rt.capture(psutil.Process())
        self.handles={}
        self.value['owner']=self.owner
        self.value['items']['C4'].update(status='blocked',phase='terminal',reason_code='constraint_illegal',
            reason='Three total legality probes exhausted in round 1; no fourth probe authorized',
            evidence=str(worktree('C4')/'out/t62/C4/result.json'))
        self.last_native=None
        self.last_sim=None

    def event(self,event,**data):
        self.value['events'].append(dict(event=event,time=rt.now(),**data))

    def save(self):
        self.value['updated']=rt.now()
        rt.save(R2/'queue.json',self.value)
        active=[{k:job.get(k) for k in ['id','candidate','mode','status','owner','config','log','group']}
            for job in self.value['jobs'].values() if job['status']=='running']
        items={key:{k:v for k,v in item.items() if k not in ['frozen_files','slots']}
            for key,item in self.value['items'].items()}
        rt.save(OUT/'status.json',dict(round_id='round_02',updated=rt.now(),owner=self.owner,
            phase='C0_gate' if not self.value.get('gate_passed') else 'batch1_candidates',
            items=items,active_jobs=active,queue=str(R2/'queue.json'),validation=self.value['validation']))

    def adopt_gate(self):
        identity='r2_C0_gate'
        if identity in self.value['jobs']:return
        config=OUT/'C0/P1.55/attempt_03/config.json'
        status=load(config.parent/'worker_status.json')
        if not rt.alive(status['owner']) and not (config.parent/'result.json').exists():
            raise RuntimeError('C0 worker identity absent without a terminal result; do not duplicate')
        self.value['jobs'][identity]=dict(id=identity,candidate='C0',mode='c0_gate',group='elinx',
            status='running',owner=status['owner'],config=str(config),log=str(config.parent/'worker.log'),pres='1.55')
        item=self.value['items']['C0'];item['jobs'].append(identity)
        item.update(status='running',phase='C0_gate',frozen_files=load(config)['frozen_files'])
        # C0 was admitted before this adopter; conservatively reserve the full
        # remaining candidate budget rather than crediting unmeasured growth.
        item['reservation']=dict(bytes=RESERVE['C0'],baseline_bytes=tree_size(worktree('C0')/'out'),admitted=rt.now())
        self.event('adopted',job=identity,owner=status['owner'])

    def add(self,candidate,key,mode,**options):
        item=self.value['items'][candidate]
        revision='_'+item['verification_revision'] if item.get('verification_revision') else ''
        identity='r2_'+candidate+revision+'_'+key
        if identity in self.value['jobs']:return identity
        base=OUT/candidate/('P'+str(options['pres']) if 'pres' in options else 'round_02_'+key)
        number=1
        while (base/f'attempt_{number:02d}').exists():number+=1
        attempt=base/f'attempt_{number:02d}';attempt.mkdir(parents=True,exist_ok=False)
        root=worktree(candidate)
        config=dict(job_id=identity,candidate=candidate,mode=mode,round_id='round_02',root=str(root),
            attempt=str(attempt),head=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),
            frozen_files=item['frozen_files'],**options)
        rt.save(attempt/'config.json',config)
        job=dict(id=identity,candidate=candidate,mode=mode,group='elinx' if mode in ['synth','route'] else 'modelsim',
            status='pending',config=str(attempt/'config.json'),log=str(attempt/'worker.log'),pres=options.get('pres'))
        self.value['jobs'][identity]=job;item['jobs'].append(identity)
        return identity

    def result(self,identity):
        job=self.value['jobs'][identity]
        return load(Path(job['config']).parent/'result.json') if job['status'] in TERMINAL else None

    def poll(self):
        for identity,job in list(self.value['jobs'].items()):
            if job['status']!='running':continue
            handle=self.handles.get(identity)
            live=handle.poll() is None if handle else rt.alive(job['owner'])
            if live:continue
            path=Path(job['config']).parent/'result.json'
            result=load(path) if path.exists() else dict(status='failed',reason_code='tool_error',
                error='Frozen worker exited without result; no automatic retry',run_completed=False,
                config_sha256=sha(job['config']),reported_by='coordinator, no measurement',metrics=None)
            if not path.exists():rt.save(path,result)
            if path.exists() and result.get('config_sha256')!=sha(job['config']):
                raise RuntimeError('Result/config identity mismatch: '+identity)
            job.update(status=result['status'],finished=rt.now(),result=str(path),reason_code=result.get('reason_code'))
            self.event('job_terminal',job=identity,status=job['status'],reason=job.get('reason_code'))
            if result.get('timing_closed'):
                # Register the immutable input/result identity immediately. The
                # dedicated validation planner submits its jobs to this same queue.
                source=load(job['config']).get('source') or result.get('source_synthesis')
                netlist=load(Path(source)/'summary.json')['netlist']
                import hashlib
                full_inputs=freeze(worktree(job['candidate']))
                tool_hashes=load(OUT/'manifest.json')['tool_hashes']
                validation_identity=dict(vqm=sha(netlist),inputs=full_inputs,tools=tool_hashes,CE_DIV=2,
                    cases=cases(worktree(job['candidate'])),default_and_small_app=True,judge_cases=8)
                key=hashlib.sha256(json.dumps(validation_identity,sort_keys=True).encode()).hexdigest().upper()
                if key not in self.value['validation']:
                    record=dict(status='pending',phase='freeze_and_submit',candidate=job['candidate'],
                        first_closed_job=job['id'],source=source,netlist=netlist,vqm_sha256=sha(netlist),identity=validation_identity,
                        frozen_files=load(job['config'])['frozen_files'],created=rt.now(),
                        dedup_requires=['RTL','VQM','test code','parameters','tool/library versions'])
                    self.value['validation'][key]=record
                    rt.save(OUT/'validation'/key[:16]/'request.json',record)

    def group_done(self,ids):return bool(ids) and all(self.value['jobs'][key]['status'] in TERMINAL for key in ids)
    def group_passed(self,ids):return self.group_done(ids) and all(self.value['jobs'][key]['status']=='completed' for key in ids)

    def terminate_item(self,candidate,status,reason_code=None,**extra):
        item=self.value['items'][candidate]
        item.update(status=status,phase='terminal',reason_code=reason_code,finished=rt.now(),**extra)
        for identity in item['jobs']:
            job=self.value['jobs'][identity]
            if job['status']=='pending':job.update(status='blocked',reason_code=reason_code,not_launched=True)
        rt.save(OUT/candidate/'result.json',item)

    def reuse_directed(self,identity,spec,root):
        job=self.value['jobs'][identity]
        if job['status']!='completed':return None
        config=load(job['config']);result=self.result(identity)
        if config['mode']!='directed' or config['directed']!=spec:return None
        inputs=result.get('directed',{}).get('inputs',[])
        if not inputs or not all(sha(row['path'])==row['sha256'] for row in inputs):return None
        # The original job conservatively froze every TB. An unrelated TB may
        # change; all actually compiled inputs plus the shared helpers, RTL and
        # constraints must remain byte-identical for a valid reuse.
        unchanged={name:digest for name,digest in config['frozen_files'].items()
            if name.startswith(('tools/','rtl/','elinx/'))}
        if not all(sha(root/name)==digest for name,digest in unchanged.items()):return None
        if not all(sha(name)==digest for name,digest in load(OUT/'manifest.json')['tool_hashes'].items()):return None
        return dict(job=identity,result=job['result'],result_sha256=sha(job['result']),
            actual_input_hashes=inputs,common_and_design_hashes=unchanged,
            note='Only another, uncompiled TB changed; all actual test inputs, design and helpers remain identical')

    def advance(self):
        gatejob=self.value['jobs']['r2_C0_gate']
        c0=self.value['items']['C0']
        if c0['phase']=='C0_gate' and gatejob['status'] in TERMINAL:
            gate=self.result('r2_C0_gate')
            if gatejob['status']=='completed' and gate.get('control_reproduced'):
                self.value['gate_passed']=True
                c0.update(source=gate['source_synthesis'],phase='routes',control_reproduced=True,
                    constraints_applied=True,slots={'1.55':gatejob['result']})
                for pres in PRES:
                    if pres!='1.55':self.add('C0','P'+pres,'route',pres=pres,source=c0['source'])
                self.event('C0_gate_passed',gate=gatejob['result'])
                rt.save(R2/'gate_release.json',dict(passed=True,time=rt.now(),gate=gatejob['result']))
            else:
                self.value['gate_passed']=False
                self.terminate_item('C0',gatejob['status'] if gatejob['status']!='completed' else 'blocked',
                    gate.get('reason_code','control_mismatch'),control_reproduced=gate.get('control_reproduced'),gate=gatejob.get('result'))
                for candidate in ITEMS:
                    if candidate not in ['C0','C4']:
                        self.terminate_item(candidate,'blocked','upstream_blocked',reason='C0 P1.55 gate did not reproduce')
        if not self.value.get('gate_passed'):return
        reference=self.value['items']['C4p']
        if reference['phase']=='awaiting_C0':
            root=worktree('C4p');rt.environment_guard()
            reference.update(frozen_files=freeze(root),source=str(CANONICAL),phase='routes',status='pending')
            for pres in PRES:self.add('C4p','P'+pres,'route',pres=pres,source=str(CANONICAL))
        requests=R2/'requests';requests.mkdir(exist_ok=True)
        for path in sorted(requests.glob('*.json')):
            request=load(path);candidate=request['candidate'];item=self.value['items'][candidate]
            revision=eda.sha(path)
            if item.get('request_sha256')==revision:continue
            previous_directed=[]
            if item['phase']=='terminal' and item['status']=='failed' and request.get('restart_after_test_fix'):
                if request.get('supersedes_request_sha256')!=item.get('request_sha256'):
                    raise RuntimeError('Test repair does not identify the exact previous request')
                if any(self.value['jobs'][key]['status']=='running' for key in item['jobs']):
                    raise RuntimeError('Test repair attempted while a candidate worker is active')
                if any(self.value['jobs'][key]['mode'] in ['synth','route'] for key in item['jobs']):
                    raise RuntimeError('This repair path never repeats native synthesis or implementation')
                root=worktree(candidate)
                changed=subprocess.check_output(['git','-C',str(root),'diff','--name-only',item['head'],request['head']],text=True).splitlines()
                if not changed or not all(name.startswith('tb/') for name in changed):
                    raise RuntimeError('Verification repair may change only the candidate testbench')
                previous_directed=list(item.get('directed_jobs',[]))
                item.setdefault('verification_history',[]).append({key:item.get(key) for key in
                    ['head','request','request_sha256','status','reason_code','directed_jobs','finished']})
                item.update(phase='awaiting_preparation',status='pending',reason_code=None,
                    verification_revision=request['verification_revision'],run_completed=False,functional_passed=None)
                self.event('verification_only_repair',candidate=candidate,changed=changed,
                    previous_directed=previous_directed,native_retry=False)
            if item['phase'] not in ['awaiting_C0','awaiting_preparation']:continue
            if candidate=='C5' and not self.value['items']['C1'].get('source'):continue
            if candidate=='C6' and not all(self.value['items'][key]['status'] in TERMINAL for key in RTL_ITEMS if key!='C6'):continue
            if request.get('status') in TERMINAL:
                self.terminate_item(candidate,request['status'],request.get('reason_code'),request=request)
                continue
            root=worktree(candidate)
            head=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
            if head!=request['head']:raise RuntimeError('Prepared candidate HEAD changed: '+candidate)
            dirty=subprocess.check_output(['git','-C',str(root),'status','--porcelain'],text=True).strip()
            if dirty:raise RuntimeError('Prepared candidate is not committed: '+candidate)
            extras=[source for spec in request.get('directed',[]) for source in spec.get('extra_sources',[])]
            item.update(request=str(path),request_sha256=revision,head=head,functional_boundary=request.get('functional_boundary'),
                frozen_files=freeze(root,extras),phase='directed',status='pending',directed_jobs=[])
            if candidate=='C5' and request.get('kind')=='reuse':
                item.update(source=request['source'],functional_passed=request.get('functional_passed'),phase='routes')
                self.add(candidate,'P1.55','route',pres='1.55',source=item['source'])
                continue
            for index,spec in enumerate(request.get('directed',[])):
                reused=next((proof for identity in previous_directed
                    if (proof:=self.reuse_directed(identity,spec,root)) is not None),None)
                if reused:
                    item.setdefault('directed_reuse',[]).append(reused)
                    item['directed_jobs'].append(reused['job'])
                else:item['directed_jobs'].append(self.add(candidate,'directed'+str(index),'directed',directed=spec))
            if not item['directed_jobs']:raise RuntimeError('RTL candidate has no directed cycle comparison: '+candidate)
        for candidate in ITEMS:
            item=self.value['items'][candidate]
            if item['status'] in TERMINAL:continue
            if item['phase']=='awaiting_C0':item['phase']='awaiting_preparation'
            if item['phase']=='directed' and self.group_done(item['directed_jobs']):
                if not self.group_passed(item['directed_jobs']):
                    self.terminate_item(candidate,'failed','regression_failed',functional_passed=False);continue
                item.update(phase='regression',regression_jobs=[])
                for index,row in enumerate(cases(worktree(candidate))):
                    item['regression_jobs'].append(self.add(candidate,'reg'+str(index),'sim',**row))
                for key in ['wrapper','app']:item['regression_jobs'].append(self.add(candidate,key,key))
            if item['phase']=='regression' and self.group_done(item['regression_jobs']):
                if not self.group_passed(item['regression_jobs']):
                    self.terminate_item(candidate,'failed','regression_failed',functional_passed=False);continue
                item.update(functional_passed=True,phase='synthesis')
                item['synthesis_job']=self.add(candidate,'synth','synth')
            if item['phase']=='synthesis' and self.group_done([item['synthesis_job']]):
                result=self.result(item['synthesis_job'])
                if result['status']!='completed':
                    self.terminate_item(candidate,result['status'],result.get('reason_code'));continue
                item.update(source=result['synthesis']['folder'],phase='routes')
                for pres in PRES:self.add(candidate,'P'+pres,'route',pres=pres,source=item['source'])
            if item['phase']=='routes':
                routeids=[key for key in item['jobs'] if self.value['jobs'][key]['mode']=='route']
                for key in routeids:
                    job=self.value['jobs'][key]
                    if job['status'] in TERMINAL:item['slots'][job['pres']]=job.get('result')
                if self.group_done(routeids):
                    measured=[self.result(key) for key in routeids if self.value['jobs'][key]['status']=='completed']
                    self.terminate_item(candidate,'completed' if self.group_passed(routeids) else 'failed',
                        None if self.group_passed(routeids) else 'tool_error',run_completed=self.group_passed(routeids),
                        constraints_applied=all(row.get('constraints_applied') for row in measured) if measured else None,
                        timing_closed=any(row.get('timing_closed') for row in measured) if measured else None,
                        valid_for_comparison=self.group_passed(routeids))

    def reserve(self,candidate):
        item=self.value['items'][candidate]
        if item.get('reservation'):return True
        free=shutil.disk_usage(ROOT).free
        remaining=0
        for other,row in self.value['items'].items():
            if row.get('reservation') and row['status'] not in TERMINAL:
                # Credit a stage only after it is terminal. Its actual evidence
                # already reduces disk free. Regression files never consume a
                # future native-stage reservation invisibly.
                released=0
                for identity in row['jobs']:
                    job=self.value['jobs'][identity]
                    if job['status'] not in TERMINAL:continue
                    if job['mode']=='c0_gate':released+=SYNTH_BYTES+ROUTE_BYTES
                    elif job['mode']=='synth':released+=SYNTH_BYTES
                    elif job['mode']=='route':released+=ROUTE_BYTES
                remaining+=max(0,row['reservation']['bytes']-released)
        requested=RESERVE[candidate]
        required=8*rt.GIB+4*rt.GIB+remaining+requested
        if free>=required:
            item['reservation']=dict(bytes=requested,baseline_bytes=tree_size(worktree(candidate)/'out'),
                admitted=rt.now(),free_bytes=free,other_remaining_bytes=remaining,floor_and_aux_bytes=12*rt.GIB)
            self.event('candidate_reserved',candidate=candidate,**item['reservation']);return True
        item.update(status='waiting_resource',resource_wait=dict(free_bytes=free,required_bytes=required,remaining_bytes=remaining))
        return False

    def dispatch(self):
        rt.environment_guard()
        jobs=self.value['jobs']
        for group,cap in [('elinx',6),('modelsim',8)]:
            active=sum(row['status']=='running' and row['group']==group for row in jobs.values())
            last=self.last_native if group=='elinx' else self.last_sim
            candidates=ITEMS[ITEMS.index(last)+1:]+ITEMS[:ITEMS.index(last)+1] if last in ITEMS else ITEMS
            while active<cap:
                pending=[row for candidate in candidates for row in jobs.values()
                    if row['candidate']==candidate and row['group']==group and row['status']=='pending'
                    and (row.get('validation_id') or self.value['items'][candidate]['status'] not in TERMINAL)
                    and all(jobs[dependency]['status']=='completed' for dependency in row.get('depends_on',[]))]
                selected=None
                for job in pending:
                    if psutil.virtual_memory().available<3*rt.GIB:break
                    if job.get('validation_id') or self.reserve(job['candidate']):selected=job;break
                if selected is None:break
                config=load(selected['config']);root=Path(config['root'])
                for name,digest in config['frozen_files'].items():
                    if eda.sha(root/name)!=digest:raise RuntimeError('Frozen queued input changed: '+str(root/name))
                rt.environment_guard()
                env=os.environ.copy();env.update(AFDX_T62_COORD=str(OUT),AFDX_CE_DIV='2',ELINX_HOME='E:/2026_Embedded_FPGA/setup_pack')
                command=[sys.executable,'-B',str(root/'tools/t62_worker.py'),'--config',selected['config']]
                with Path(selected['log']).open('xb') as stream:
                    process=psutil.Popen(command,cwd=root,env=env,stdout=stream,stderr=subprocess.STDOUT,
                        creationflags=subprocess.CREATE_NO_WINDOW)
                selected.update(status='running',owner=rt.capture(process),started=rt.now())
                self.handles[selected['id']]=process
                if not selected.get('validation_id'):self.value['items'][selected['candidate']]['status']='running'
                active+=1;last=selected['candidate']
                candidates=ITEMS[ITEMS.index(last)+1:]+ITEMS[:ITEMS.index(last)+1]
                self.event('dispatched',job=selected['id'],owner=selected['owner'])
            if group=='elinx':self.last_native=last
            else:self.last_sim=last
        running=any(row['status']=='running' for row in jobs.values())
        if not running:
            for candidate,item in self.value['items'].items():
                if item['status']=='waiting_resource' and not self.reserve(candidate):
                    self.terminate_item(candidate,'blocked','resource_budget',reason='Whole-candidate budget does not fit after active tools exited')

    def validations(self):
        submissions=R2/'validation_submissions';submissions.mkdir(exist_ok=True)
        for path in sorted(submissions.glob('*.json')):
            request=load(path);key=request['validation_id']
            record=self.value['validation'][key]
            if record.get('submission'):continue
            ids=[]
            for config_path in request['configs']:
                config_path=Path(config_path);config=load(config_path);identity=config['job_id']
                if config['mode'] not in ['sim','directed','app','app_default','wrapper','judge']:
                    raise RuntimeError('Unexpected D11 mode')
                if identity in self.value['jobs']:raise RuntimeError('Duplicate D11 job identity')
                self.value['jobs'][identity]=dict(id=identity,candidate=record['candidate'],mode=config['mode'],
                    group='modelsim',status='pending',config=str(config_path),log=str(config_path.parent/'worker.log'),
                    validation_id=key,depends_on=config.get('depends_on',[]))
                ids.append(identity)
            record.update(submission=str(path),phase='validation_jobs',status='running',jobs=ids)
            self.event('D11_submitted',validation_id=key,jobs=len(ids))
        for key,record in self.value['validation'].items():
            ids=record.get('jobs',[])
            for identity in ids:
                job=self.value['jobs'][identity]
                if job['status']=='pending' and any(self.value['jobs'][dep]['status'] in TERMINAL-{'completed'} for dep in job.get('depends_on',[])):
                    job.update(status='blocked',reason_code='upstream_blocked',not_launched=True)
            if ids and self.group_done(ids):
                record.update(status='completed' if self.group_passed(ids) else 'failed',phase='terminal',finished=rt.now())
                rt.save(OUT/'validation'/key[:16]/'result.json',record)

    def run(self):
        self.adopt_gate();self.save()
        while True:
            self.poll();self.advance();self.validations();self.dispatch();self.save()
            if all(row['status'] in TERMINAL for row in self.value['items'].values()) and not any(
                row['status']=='running' for row in self.value['jobs'].values()) and all(
                row['status'] in TERMINAL for row in self.value['validation'].values()):
                self.value['coordinator_terminal']=True;self.value['finished']=rt.now();self.save();return
            time.sleep(5)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-only',action='store_true')
    args=parser.parse_args()
    if args.check_only:
        assert len(cases(ROOT))==40 and len(ITEMS)==10 and len(PRES)==7
        rt.environment_guard()
        print(json.dumps(dict(case_count=40,pres=PRES,reservations=RESERVE,gui_forbidden=True)));return 0
    R2.mkdir(parents=True,exist_ok=True)
    with (R2/'coordinator.lock').open('a+b') as lock:
        if lock.tell()==0:lock.write(b'0');lock.flush()
        lock.seek(0)
        msvcrt.locking(lock.fileno(),msvcrt.LK_NBLCK,1)
        with rt.locked_registry() as registry:
            previous=registry.get('regression_owner')
            if previous and rt.alive(previous):raise RuntimeError('Another regression coordinator is active')
            registry['regression_owner']=rt.capture(psutil.Process())
        try:Queue().run()
        except Exception as error:
            rt.save(R2/'coordinator_failure.json',dict(time=rt.now(),error=str(error),owner=rt.capture(psutil.Process())))
            raise
        finally:
            with rt.locked_registry() as registry:
                if (registry.get('regression_owner') or {}).get('pid')==os.getpid():registry['regression_owner']=None


if __name__=='__main__':raise SystemExit(main())
