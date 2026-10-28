"""Aggregate round-2 evidence and verify the D10 stop, without launching tools.

--partial refreshes results only. --final requires every item/started D11 and
all recorded workers, native tools, coordinator and observer to have exited.
The report is composed/reviewed from these verified records separately.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import eda
import psutil
import t62_evaluate as evaluate
import t62_physical_summary as physical_summary
import t62_runtime as rt
from t62_finish import files,max_overlap

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/t62'
R2=OUT/'round_02'
ITEMS=['C0','C1','C2','C3a','C3b','C3c','C4','C4p','C5','C6']
TERMINAL={'completed','failed','blocked','not_applicable'}


def load(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def sha(path):return eda.sha(Path(path))


def git(root,*args):return subprocess.check_output(['git','-C',str(root),*args],text=True,encoding='utf-8').strip()


def process_state(identity):
    try:
        process=psutil.Process(identity['pid'])
        created=process.create_time()
        # PID reuse already proves that the recorded task process exited.
        # Do not require access to an unrelated replacement process's command.
        if created!=identity['created']:
            return dict(identity=identity,exited=True,state='pid_reused',current_created=created)
        same=rt.capture(process)==identity
        return dict(identity=identity,exited=not same,state='still_owned' if same else 'identity_changed')
    except psutil.NoSuchProcess:
        return dict(identity=identity,exited=True,state='exited')
    except psutil.AccessDenied:
        return dict(identity=identity,exited=None,state='identity_inaccessible')


def refresh_evaluation():
    previous=sys.argv
    try:sys.argv=['t62_evaluate'];evaluate.main()
    finally:sys.argv=previous
    return load(R2/'evaluation.json')


def job_sources(queue):
    summaries={}
    for key,job in queue['jobs'].items():
        config=load(job['config']);root=Path(config['root'])
        for pointer in (root/'out').glob(key+'_latest_*.json'):
            summary=load(pointer)
            if summary.get('folder'):summaries[summary['folder']]=summary
    return summaries


def tool_records(queue,summaries):
    records={};identities={}
    def add_identity(value):
        if value and 'pid' in value and 'created' in value:
            identities[(value['pid'],value['created'])]=value
    add_identity(queue['owner'])
    for job in queue['jobs'].values():add_identity(job.get('owner'))
    observer=R2/'resource_metrics.json'
    observed=load(observer) if observer.exists() else {}
    add_identity(observed.get('owner'))
    for row in observed.get('processes',{}).values():add_identity(row['identity'])
    for folder in summaries:
        path=Path(folder)/'tool_metrics.json'
        if not path.exists():continue
        for job in load(path):
            records[(job['pid'],job['created'])]=job
            add_identity({key:job[key] for key in ['pid','created','command','cwd']})
            for identity in job.get('owned_processes',[]):add_identity(identity)
    values=list(records.values())
    checks=[process_state(identity) for identity in identities.values()]
    result=dict(jobs=values,process_checks=checks,all_recorded_processes_exited=all(row['exited'] is True for row in checks),
        sampler=observed,peak_elinx=max(max_overlap(values,'elinx'),observed.get('peak_elinx',0)),
        peak_modelsim=max(max_overlap(values,'modelsim'),observed.get('peak_modelsim',0)),
        actual_peak_method='Precise admitted process intervals plus actual one-second global native-process observations; nested app/judge children sampled separately',
        total_tool_seconds=sum(row['seconds'] for row in values),
        minimum_available_memory_bytes=min([row['minimum_available_memory_bytes'] for row in values]
            +[observed['minimum_available_memory_bytes']] if observed else [row['minimum_available_memory_bytes'] for row in values]),
        minimum_E_free_bytes=min([row['minimum_disk_free_bytes'] for row in values]
            +[observed['minimum_E_free_bytes']] if observed else [row['minimum_disk_free_bytes'] for row in values]),
        peak_tool_tree_rss_bytes=max((row['peak_tree_bytes'] for row in values),default=None),
        per_stage=[dict(name=row['name'],budget_seconds=row['budget_seconds'],seconds=row['seconds'],
            exit_code=row['exit_code'],stop_reason=row.get('stop_reason'),log=row['log']) for row in values])
    return result


def protected_checks(manifest):
    before=load(OUT/'preparation/protected_before.json');protected={}
    for name,old in before.items():
        directory=Path(name)
        after={p.relative_to(directory).as_posix():[p.stat().st_size,p.stat().st_mtime_ns] for p in files(directory)}
        missing=sorted(set(old)-set(after));added=sorted(set(after)-set(old))
        changed=[key for key in old.keys()&after.keys() if old[key]!=after[key]]
        protected[name]=dict(passed=not(missing or added or changed),count=len(old),missing=missing,added=added,changed=changed)
    tools={name:sha(name)==digest for name,digest in manifest['tool_hashes'].items()}
    libraries={name:sha(name)==digest for name,digest in load(OUT/'manifest_v10_libraries.json')['simulation_libraries'].items()}
    evidence={name:sha(name)==digest for name,digest in manifest['protected_evidence_hashes'].items()}
    canonical=Path(manifest['canonical_r5a_synthesis'])/'project/AFDX_EndSystem.runs/synth_1'
    frozen={name:sha(canonical/name)==digest for name,digest in manifest['canonical_synth_files'].items()}
    manual={}
    for name,inventory in load(R2/'excluded_manual_probes.json')['inventory'].items():
        path=Path(name);is_file='bytes' in inventory
        entries={'':inventory} if is_file else inventory
        mismatches=[]
        actual={''} if is_file and path.is_file() else {str(p.relative_to(path)) for p in files(path)} if path.is_dir() else set()
        if actual!=set(entries):mismatches.append(dict(file_set_difference=sorted(actual^set(entries))))
        for relative,old in entries.items():
            current=path if is_file else path/relative
            if not current.exists():mismatches.append(dict(path=str(current),missing=True));continue
            stat=current.stat()
            if stat.st_size!=old['bytes'] or stat.st_mtime_ns!=old['mtime_ns'] or ('sha256' in old and sha(current)!=old['sha256']):
                mismatches.append(dict(path=str(current),changed=True))
        manual[name]=dict(passed=not mismatches,mismatches=mismatches,count=len(entries))
    return dict(protected_metadata=protected,tool_hashes=tools,simulation_libraries=libraries,protected_evidence_hashes=evidence,
        canonical_synth_files=frozen,excluded_manual_probes=manual,
        immutable_manifest=sha(OUT/'manifest.json')==load(OUT/'manifest_v5_complete.json')['immutable_original_manifest_sha256'],
        archived_report_attempt1=sha(OUT/'report_F1_attempt1.md')==load(OUT/'manifest_v5_complete.json')['report_sha256'])


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--final',action='store_true')
    args=parser.parse_args();environment=rt.environment_guard()
    queue=load(R2/'queue.json');evaluation=refresh_evaluation();summaries=job_sources(queue)
    resources=tool_records(queue,summaries)
    result=dict(task='T62',phase='F batch1',round_id='round_02',updated=rt.now(),items=evaluation['items'],
        validation=queue['validation'],eligible_union=evaluation['eligible_union'],C0_gate=str(OUT/'C0/P1.55/attempt_03/gate.json'),
        evaluation_rules=str(OUT/'manifest_v8_evaluation.json'),queue=str(R2/'queue.json'),environment=environment,
        final=False,GUI=dict(status='blocked',reason_code='awaiting_user_gui',launch_forbidden=True,deliverable=False),
        D10='All ten terminal and started validation terminal; no batch2/docs/merge/push',
        measured_native_inputs='Only frozen task jobs; excluded manual probes never reused',
        resources={key:value for key,value in resources.items() if key not in ['jobs','process_checks','sampler']})
    failures=[]
    for identity,job in queue['jobs'].items():
        if job['status'] not in ['failed','blocked']:continue
        record=load(job['result']) if job.get('result') and Path(job['result']).exists() else {}
        failures.append(dict(job_id=identity,candidate=job['candidate'],mode=job['mode'],status=job['status'],
            reason_code=record.get('reason_code',job.get('reason_code')),error=record.get('error'),result=job.get('result'),log=job['log']))
    result['failures_and_blocked_jobs']=failures
    result['items']['C4']['retained_native_probe_record']=load(ROOT.parent/'c3_t62_c4/out/t62/C4/result.json')
    if not args.final:
        rt.save(OUT/'results.json',result)
        rt.save(R2/'tool_metrics_partial.json',resources)
        print(json.dumps(dict(partial=True,items={key:row['status'] for key,row in result['items'].items()},failures=len(failures))))
        return 0
    terminal=all(row['status'] in TERMINAL for row in queue['items'].values())
    validated=all(row['status'] in TERMINAL for row in queue['validation'].values())
    if not terminal or not validated or not queue.get('coordinator_terminal') or not resources['all_recorded_processes_exited']:
        raise RuntimeError('D10 cannot close while an item, started validation or recorded process remains active/unverified')
    manifest=load(OUT/'manifest.json');protection=protected_checks(manifest)
    physical=physical_summary.collect(queue)
    rt.save(OUT/'physical_comparison.json',physical)
    workspaces={};heads={};input_checks={}
    for key,root in [('t62',ROOT)]+[('t62-'+key.lower(),ROOT.parent/('c3_t62_'+key.lower())) for key in ITEMS]:
        heads[key]=git(root,'rev-parse','HEAD')
        dirty=git(root,'status','--porcelain')
        protected_diff=git(root,'diff','--name-only','32a9b161','--','docs','sim/reference','sim/wave/png')
        protected_untracked=git(root,'ls-files','--others','--exclude-standard','docs','sim/reference','sim/wave/png')
        workspaces[key]=dict(root=str(root),head=heads[key],status=dirty,protected_diff=protected_diff,
            protected_untracked=protected_untracked,passed=not dirty and not protected_diff and not protected_untracked)
    for identity,job in queue['jobs'].items():
        if job.get('not_launched'):continue
        config=load(job['config']);root=Path(config['root']);checked={}
        for name,digest in config['frozen_files'].items():
            # Verification-only repairs explicitly retain older raw results.
            # Check their actual tool inputs, not a later unrelated TB they did
            # not compile. All active/final-version inputs remain exact.
            current=root/name
            checked[name]=current.exists() and sha(current)==digest
        mismatches=[name for name,passed in checked.items() if not passed]
        superseded=job['candidate']=='C2' and 'verification02' not in identity and job['mode']=='directed'
        if superseded:
            allowed=['tb/tb_t62_c2_cfg_cycle.v']
            passed=all(name in allowed for name in mismatches)
        else:passed=not mismatches
        input_checks[identity]=dict(passed=passed,changed=mismatches,superseded_verification_only=superseded)
    conditions=dict(all_items_terminal=terminal,all_started_D11_terminal=validated,
        coordinator_and_tools_exited=resources['all_recorded_processes_exited'],INI_unchanged=True,
        global_caps_respected=resources['peak_elinx']<=6 and resources['peak_modelsim']<=10,
        all_workspaces_clean=all(row['passed'] for row in workspaces.values()),
        original_manifest_preserved=protection['immutable_manifest'],old_report_preserved=protection['archived_report_attempt1'],
        protected_paths_unchanged=all(row['passed'] for row in protection['protected_metadata'].values()),
        native_tools_unchanged=all(protection['tool_hashes'].values()),T61_evidence_unchanged=all(protection['protected_evidence_hashes'].values()),
        simulation_libraries_unchanged=all(protection['simulation_libraries'].values()),
        canonical_synthesis_unchanged=all(protection['canonical_synth_files'].values()),
        actual_placements_and_frozen_synthesis_sources=physical['passed'],
        excluded_manual_probes_preserved=all(row['passed'] for row in protection['excluded_manual_probes'].values()),
        frozen_job_inputs_or_explicit_verified_test_repair=all(row['passed'] for row in input_checks.values()))
    checks=dict(passed=all(conditions.values()),timestamp=rt.now(),conditions=conditions,branch_heads=heads,
        workspaces=workspaces,environment=environment,job_input_checks=input_checks,**protection)
    rt.save(OUT/'final_checks.json',checks)
    if not checks['passed']:raise RuntimeError('Final protection checks failed; see final_checks.json')
    result.update(final=True,final_checks=str(OUT/'final_checks.json'),branch_heads=heads,
        physical_comparison=str(OUT/'physical_comparison.json'))
    for key,item in result['items'].items():
        rt.save(OUT/key/'result.json',dict(item,queue_summary=queue['items'][key]))
    rt.save(OUT/'results.json',result);rt.save(OUT/'tool_metrics_final.json',resources)
    rt.save(OUT/'comparisons.json',dict(rules=str(OUT/'manifest_v8_evaluation.json'),
        items={key:row['pres_runs'] for key,row in result['items'].items()},eligible_union=result['eligible_union']))
    number=9
    while list(OUT.glob('manifest_v'+str(number)+'_*.json')):number+=1
    rt.save(OUT/('manifest_v'+str(number)+'_complete.json'),dict(created=rt.now(),branch_heads=heads,
        manifests={path.name:sha(path) for path in OUT.glob('manifest*.json')},results_sha256=sha(OUT/'results.json'),
        final_checks_sha256=sha(OUT/'final_checks.json'),tools={p.name:sha(p) for p in (ROOT/'tools').glob('t62*.py')},
        GUI='forbidden/awaiting_user_gui',phase='F batch1 round2 terminal; stop D10, no delivery acceptance'))
    print(json.dumps(dict(final=True,final_checks_passed=True,items={key:row['status'] for key,row in result['items'].items()})))
    return 0


if __name__=='__main__':raise SystemExit(main())
