"""Freeze and submit D11 validation to the existing unique T62 queue.

No EDA or simulator is launched here. Candidate regression is reused only when
its complete frozen source/test/helper identity matches the immutable snapshot.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

import eda
import t62_runtime as rt
from t62_regress import cases

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/t62'
R2=OUT/'round_02'


def load(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def sha(path):return eda.sha(Path(path))


def submit(key,queue):
    record=queue['validation'][key]
    destination=R2/'validation_submissions'/(key+'.json')
    if destination.exists():return dict(validation_id=key,already_submitted=True)
    rt.environment_guard()
    candidate=record['candidate'];item=queue['items'][candidate]
    source=ROOT.parent/('c3_t62_'+candidate.lower())
    origin=record['identity']['inputs']
    if any(sha(source/name)!=digest for name,digest in origin.items()):
        raise RuntimeError('D11 source/test/helper changed before freeze: '+candidate)
    base=OUT/'validation'/key[:16]
    snapshot=base/('snapshot_'+datetime.now().strftime('%Y%m%d_%H%M%S')+'_'+uuid.uuid4().hex[:8])
    snapshot.mkdir(parents=True,exist_ok=False)
    for name in origin:
        target=snapshot/name;target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(source/name,target)
        if sha(target)!=origin[name]:raise RuntimeError('Snapshot copy differs: '+name)
    directed=[]
    if item.get('request'):
        directed=load(item['request']).get('directed',[])
        for spec in directed:
            for name in spec.get('extra_sources',[]):
                relative=Path(name)
                if relative.is_absolute():raise RuntimeError('D11 baseline source must be inside candidate output')
                relative.resolve()
                target=snapshot/relative;target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copyfile(source/relative,target)
    # The independent snapshot uses the round-2 validation harness, including
    # the batch-only judge guard. The design/test sources are unchanged.
    common=load(R2/'common_files.json')
    for name in common:
        target=snapshot/name;target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(ROOT/name,target)
    netlist=snapshot/'netlist/AFDX_EndSystem.vqm';netlist.parent.mkdir()
    shutil.copyfile(record['netlist'],netlist)
    if sha(netlist)!=record['vqm_sha256']:raise RuntimeError('Snapshot VQM copy differs')
    files={p.relative_to(snapshot).as_posix():sha(p) for p in snapshot.rglob('*') if p.is_file()}
    tool_hashes=load(OUT/'manifest.json')['tool_hashes']
    tool_checks={name:sha(name)==digest for name,digest in tool_hashes.items()}
    if not all(tool_checks.values()):raise RuntimeError('D11 native tool or library changed')
    # Absolute hashes protect shared installed tools/libraries without copying
    # or changing the installation. Environment is checked again per job.
    frozen=dict(files,**tool_hashes)
    reuse=item.get('functional_passed') is True and all(
        name in files and files[name]==digest for name,digest in item.get('frozen_files',{}).items())
    reuse_ids=item.get('directed_jobs',[])+item.get('regression_jobs',[]) if reuse else []
    reuse=reuse and bool(reuse_ids) and all(queue['jobs'][identity]['status']=='completed' for identity in reuse_ids)
    configs=[]
    def add(label,mode,**options):
        identity='r2_D11_'+key[:16]+'_'+label
        attempt=base/'jobs'/label;attempt.mkdir(parents=True,exist_ok=False)
        config=dict(job_id=identity,candidate=candidate,mode=mode,root=str(snapshot),attempt=str(attempt),
            round_id='round_02',validation_id=key,frozen_files=frozen,origin_head=item.get('head'),**options)
        path=attempt/'config.json';rt.save(path,config);configs.append(str(path));return identity
    if not reuse:
        for index,row in enumerate(cases(snapshot)):add('ce'+str(index),'sim',**row)
        add('wrapper','wrapper');add('app_small','app')
        for index,spec in enumerate(directed):add('directed'+str(index),'directed',directed=spec)
    add('app_default','app_default')
    rtl_services=add('services_rtl','sim',test='tb_net_services',parameters=[])
    add('services_netlist','sim',test='tb_net_services',parameters=[],netlist=str(netlist),depends_on=[rtl_services])
    for case in ['services','capacity','snmp','burst77','burst81','rtc','performance','perf_var']:
        add('judge_'+case,'judge',judge_case=case)
    manifest=dict(validation_id=key,candidate=candidate,created=rt.now(),snapshot=str(snapshot),
        source=str(source),source_synthesis=record['source'],source_identity=record['identity'],
        snapshot_hashes=files,tool_hashes=tool_hashes,tool_checks=tool_checks,environment=rt.environment_guard(),
        vqm_sha256=record['vqm_sha256'],candidate_regression_reused=reuse,
        reused_jobs=[dict(job_id=identity,result=queue['jobs'][identity]['result'],
            config=queue['jobs'][identity]['config'],result_sha256=sha(queue['jobs'][identity]['result'])) for identity in reuse_ids] if reuse else [],
        reused_acceptance='CE2 all 40, wrapper, app small, all candidate directed tests' if reuse else None,
        configs=configs,CE_DIV=2,judge_case_count=8,immutable=True,
        boundary='D11 functional evidence only; GUI forbidden/awaiting_user_gui and no delivery acceptance')
    rt.save(base/'frozen_snapshot.json',manifest)
    rt.save(destination,dict(validation_id=key,configs=configs,manifest=str(base/'frozen_snapshot.json')))
    return dict(validation_id=key,snapshot=str(snapshot),submitted_jobs=len(configs),candidate_regression_reused=reuse)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--check-only',action='store_true')
    args=parser.parse_args();rt.environment_guard()
    if args.check_only:
        assert len(cases(ROOT))==40
        assert (ROOT/'sim/vectors/app/stimulus.txt').is_file()
        assert 'AFDX_JUDGE_CASE' in (ROOT/'sim/run_judge.do').read_text()
        print('D11 plan checks PASS: CE2 40, default input, eight-case batch judge entry');return 0
    queue=load(R2/'queue.json')
    results=[submit(key,queue) for key,record in queue['validation'].items() if record['status']=='pending']
    print(json.dumps(results,ensure_ascii=False));return 0


if __name__=='__main__':raise SystemExit(main())
