"""T62 F1 evidence aggregation and bounded-stop audit; never launch EDA tools."""
import argparse
from collections import Counter
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess

import psutil
import eda
import t62_constraints as constraints
import t62_runtime as runtime

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/t62'
ITEMS=['C0','C1','C2','C3a','C3b','C3c','C4','C4p','C5','C6']
GIB=1024**3
MEASURES=['setup_worst_slack_ps','hold_worst_slack_ps','setup_failed_endpoints',
    'hold_failed_endpoints','setup_endpoint_count','hold_endpoint_count','below_0p5ns',
    'below_0p8ns','endpoint_module_groups','target_cone_worst_slack_ps','worst_three_paths',
    'lut','ff','memory','pins','endpoint_min_setup_negative_slack_sum_ps']


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def git(root,*args):
    return subprocess.check_output(['git','-c','safe.directory=*','-C',str(root),*args],
                                    text=True,encoding='utf-8').strip()


def files(directory):
    for base,dirs,names in os.walk(directory):
        dirs[:]=[name for name in dirs if name!='.git' and not (Path(base)/name).is_junction()]
        for name in names:
            if name!='.git':
                yield Path(base)/name


def process_state(identity):
    try:
        process=psutil.Process(identity['pid'])
        same=runtime.capture(process)==identity
        return dict(identity=identity,exited=not same,state='still_owned' if same else 'pid_reused')
    except psutil.NoSuchProcess:
        return dict(identity=identity,exited=True,state='exited')
    except psutil.AccessDenied:
        return dict(identity=identity,exited=None,state='identity_inaccessible')


def max_overlap(jobs,group):
    events=[]
    for job in jobs:
        executable=Path(job['command'][0]).name.lower()
        actual='elinx' if executable in runtime.NATIVE else 'modelsim' if executable in runtime.MODELSIM else 'helper'
        if actual!=group:
            continue
        events.extend([(job['created'],1),(datetime.fromisoformat(job['finished']).timestamp(),-1)])
    current=peak=0
    for _,delta in sorted(events):
        current+=delta;peak=max(peak,current)
    return peak


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--final',action='store_true')
    args=parser.parse_args()
    manifest=load(OUT/'manifest.json')
    original=OUT/'C0/result_native.json'
    if not original.exists():
        shutil.copy2(OUT/'C0/result.json',original)
    c0=load(original)
    if c0['status']!='blocked' or c0['reason_code']!='license':
        raise RuntimeError('This finalizer only closes the observed C0-license-blocked batch')
    c4_source=ROOT.parent/'c3_t62_c4/out/t62/C4/result.json'
    c4=load(c4_source)
    if c4['status']!='blocked' or c4['actual_native_attempts']!=3:
        raise RuntimeError('C4 has no final three-attempt result')
    results={}
    for item in ITEMS:
        reason='license' if item=='C0' else 'constraint_illegal' if item=='C4' else 'upstream_blocked'
        detail={'C0':c0['reason'],'C4':c4['reason'],'C4p':'C0 source reconstruction gate failed; no frozen-checkpoint paired implementation released',
                'C5':'No C1 rebuilt/packed checkpoint; exact cluster/slot/carry/RAM mapping cannot be evaluated',
                'C6':'C0 gate failed; local combination eligibility was never measured, so this is upstream_blocked rather than a proven zero-eligible combination'}
        data=dict(candidate=item,status='blocked',reason_code=reason,
            reason=detail.get(item,'C0 P1.55 source gate blocked by license; no RTL candidate or implementation released'),
            run_completed=False,control_reproduced=None,constraints_applied=None,functional_passed=None,
            timing_closed=None,valid_for_comparison=None,eligible_for_combination=None,
            rtl_modified=False,source_added_registers=0,source_added_cycles=0,synthesized_ff_delta=None,
            directed_cycle_comparison=None,seven_slot_median_ns=None,closed_slot_count=None,
            complete_candidate_adopted=None,combination_assessed=False,metrics={key:None for key in MEASURES})
        if item=='C0':
            data.update(native_attempt_record=str(original),synthesis=c0['synthesis'],native_synthesis_attempts=1,license_retries=0,
                preflight_only_attempt=str(OUT/'C0/P1.55/attempt_01/result.json'),attempt=str(c0['attempt']))
        if item=='C4':
            data.update(probe_evidence=str(c4_source),probe_evidence_sha256=eda.sha(c4_source),
                attempts=c4['attempts'],actual_native_attempts=3,full_R_verified=None,R_allowlist_opened=False,
                actual_conflicting_area_identities=None,valid_for_comparison=False)
        pres=['1.55'] if item=='C5' else list(constraints.PRES)
        slots=[]
        for value in pres:
            attempts=[]
            if item=='C0' and value=='1.55':
                attempts=[str(OUT/'C0/P1.55/attempt_01/result.json'),str(Path(c0['attempt'])/'result.json')]
            slot=dict(pres=value,status='blocked',reason_code=reason,reason=data['reason'],
                attempt_results=attempts,implementation_started=False,run_completed=False,
                timing_closed=None,metrics={key:None for key in MEASURES},delta_vs_control={key:None for key in MEASURES})
            runtime.save(OUT/item/('P'+value)/'result.json',slot)
            slots.append(slot)
        data['pres_runs']=slots
        runtime.save(OUT/item/'result.json',data)
        results[item]=data
    first=load(OUT/'preparation/regression/20261028_023154_793113/result.json')
    second=load(OUT/'preparation/regression/20261028_023906_629354/result.json')
    smoke={row['index']:row for row in first['results']}
    for row in second['results']:
        smoke[row['index']]=row
    smoke_pass=len(smoke)==8 and all(row['passed'] for row in smoke.values())
    smoke_inputs={str(index):all(eda.sha(Path(row['path']))==row['sha256']
        for row in load(smoke[index]['summary'])['inputs']) for index in sorted(smoke)}
    app=load(OUT/'preparation/app_small_result.json')
    wrapper_command=[str(Path(os.sys.executable)),'-B',str(ROOT/'tools/check_wrapper.py')]
    wrapper=subprocess.run(wrapper_command,cwd=ROOT,capture_output=True,encoding='utf-8',check=False)
    wrapper_result=dict(command=wrapper_command,exit_code=wrapper.returncode,stdout=wrapper.stdout,
                        passed=wrapper.returncode==0 and 'RESULT check_wrapper PASS' in wrapper.stdout)
    runtime.save(OUT/'preparation/wrapper_result.json',wrapper_result)
    regression=dict(planned_full_cases=40,workers=8,smoke_cases=8,smoke_passed=smoke_pass,
        valid_smoke_runs=[smoke[index] for index in sorted(smoke)],input_hashes_unchanged=smoke_inputs,
        first_entry_failure='Timestamp output-folder collision before default tb_tx_basic started',
        first_failure_preserved=str(OUT/'preparation/regression/20261028_023154_793113/result.json'),
        correction_and_selected_retry=str(OUT/'preparation/regression/20261028_023906_629354/result.json'),
        wrapper=wrapper_result,app_small_passed=app.get('passed'),app_small=str(OUT/'preparation/app_small_result.json'),
        candidate_full_regression_passed=None,directed_candidate_tests_passed=None,
        note='Entry preparation only; seven valid smoke cases retained and only prelaunch collision case rerun. No full candidate regression or D11 acceptance implied.')
    runtime.save(OUT/'preparation/regression_summary.json',regression)
    entry=constraints.self_check()
    runtime.save(OUT/'preparation/constraint_checks_final.json',entry)
    near=load(OUT/'nearcritical_baseline.json')
    full_synth=sum(path.stat().st_size for path in files(Path(manifest['canonical_r5a_synthesis'])))
    budget=dict(manifest['resource_budget'])
    budget.update(measured_full_synthesis_record_bytes=full_synth,
        per_new_synthesis_reservation_bytes=int(full_synth*1.15))
    budget['raw_full_batch_bytes']=64*budget['per_run_reservation_bytes']+7*budget['per_new_synthesis_reservation_bytes']
    budget['full_plan_with_floor_and_auxiliary_bytes']=budget['raw_full_batch_bytes']+budget['keep_free_bytes']+budget['regression_reservation_bytes']+budget['probe_reservation_bytes']
    budget['initial_plan_shortfall_bytes']=max(0,budget['full_plan_with_floor_and_auxiliary_bytes']-budget['available_disk_bytes'])
    remaining=budget['available_disk_bytes']-budget['keep_free_bytes']-budget['regression_reservation_bytes']-budget['probe_reservation_bytes']
    reservations=[]
    for item in ITEMS:
        cost=(1 if item=='C5' else 7)*budget['per_run_reservation_bytes']
        if item in ['C0','C1','C2','C3a','C3b','C3c','C6']:
            cost+=budget['per_new_synthesis_reservation_bytes']
        fits=cost<=remaining
        if fits:remaining-=cost
        reservations.append(dict(candidate=item,reservation_bytes=cost,fits_initial_full_plan=fits,
            conditional_reason=None if fits else 'resource_budget',actual_release=False,
            actual_release_reason=results[item]['reason_code']))
    budget.update(initial_full_plan_reservations=reservations,unreserved_bytes=remaining,
        full_plan_admitted=False,gate_pending=False,actual_dependents_released=False,
        actual_candidates_resource_blocked=[],
        note='The full hypothetical matrix exceeds storage. Later initial-plan reservations are refused; no dependent implementation became ready after the license gate failed. Actual candidate terminal reasons therefore remain license/constraint_illegal/upstream_blocked, not an invented disk failure.')
    runtime.save(OUT/'preparation/resource_budget_v2.json',budget)
    jobs={}
    identities={}
    for root in [ROOT,ROOT.parent/'c3_t62_c0',ROOT.parent/'c3_t62_c4']:
        for path in files(root/'out'):
            if path.name!='tool_metrics.json':
                continue
            value=load(path)
            if not isinstance(value,list):
                continue
            for job in value:
                key=(job['pid'],job['created'])
                jobs[key]=job
                for identity in job.get('owned_processes',[]):
                    identities[(identity['pid'],identity['created'])]=identity
    for identity in [load(Path(c0['attempt'])/'config.json')['worker']]+[row['worker'] for row in first['results']+second['results']]:
        identities[(identity['pid'],identity['created'])]=identity
    process_checks=[process_state(identity) for identity in identities.values()]
    exited=all(row['exited'] is True for row in process_checks)
    values=list(jobs.values())
    peak_elinx=max_overlap(values,'elinx');peak_ms=max_overlap(values,'modelsim')
    resources=dict(counting='Independent admitted tool process trees; internal compiler children belong to their owning tool tree. App outer script reserves two slots.',
        actual_peak_elinx_jobs=peak_elinx,actual_peak_modelsim_jobs=peak_ms,regression_worker_limit=8,
        tool_jobs=len(values),tool_tree_rss_peak_bytes=max(job['peak_tree_bytes'] for job in values),
        minimum_sampled_available_memory_bytes=min(job['minimum_available_memory_bytes'] for job in values),
        minimum_sampled_disk_free_bytes=min(job['minimum_disk_free_bytes'] for job in values),
        disk_free_now_bytes=shutil.disk_usage(ROOT).free,available_memory_now_bytes=psutil.virtual_memory().available,
        total_tool_seconds=sum(job['seconds'] for job in values),
        elinx_seconds=sum(job['seconds'] for job in values if Path(job['command'][0]).name.lower() in runtime.NATIVE),
        native_route_jobs=0,full_routed_report_jobs=0,license_retries=0,c4_native_attempts=3,c4_infrastructure_retries=1,
        regression_prelaunch_retries=1,timing_or_simulation_failure_retries=0)
    runtime.save(OUT/'tool_metrics_final.json',dict(resources=resources,jobs=values,process_checks=process_checks))
    before=load(OUT/'preparation/protected_before.json')
    protected={}
    for name,old in before.items():
        directory=Path(name)
        after={path.relative_to(directory).as_posix():[path.stat().st_size,path.stat().st_mtime_ns] for path in files(directory)}
        missing=sorted(set(old)-set(after));added=sorted(set(after)-set(old))
        changed=[key for key in old.keys()&after.keys() if old[key]!=after[key]]
        protected[name]=dict(passed=not(missing or added or changed),file_count=len(old),
                              missing=missing,added=added,changed=changed)
    tools={name:eda.sha(Path(name))==digest for name,digest in manifest['tool_hashes'].items()}
    evidence={name:eda.sha(Path(name))==digest for name,digest in manifest['protected_evidence_hashes'].items()}
    synth=Path(manifest['canonical_r5a_synthesis'])/'project/AFDX_EndSystem.runs/synth_1'
    frozen={name:eda.sha(synth/name)==digest for name,digest in manifest['canonical_synth_files'].items()}
    heads={};workspaces={}
    for item in ['coordinator']+ITEMS:
        directory=ROOT if item=='coordinator' else ROOT.parent/('c3_t62_'+item.lower())
        branch=git(directory,'branch','--show-current');heads[branch]=git(directory,'rev-parse','HEAD')
        closure=all(eda.sha(directory/name)==row['sha256'] for name,row in manifest['source_closure'].items())
        forbidden=git(directory,'diff',manifest['base_head'],'--','rtl','tb','sim','docs','submission')
        workspaces[item]=dict(root=str(directory),branch=branch,head=heads[branch],
            status=git(directory,'status','--porcelain'),source_closure_unchanged=closure,protected_tracked_diff=forbidden)
    old_heads=load(ROOT.parent/'c3_t61/out/t61/final_checks.json')['branch_heads']
    old_refs={branch:git(ROOT,'rev-parse',branch)==head for branch,head in old_heads.items()}
    conditions=dict(all_ten_terminal=all(row['status']=='blocked' for row in results.values()),
        no_active_owned_job=exited,global_native_limits=peak_elinx<=6 and peak_ms<=10,
        disk_floor=resources['minimum_sampled_disk_free_bytes']>=8*GIB,
        protected_metadata=all(row['passed'] for row in protected.values()),
        tool_hashes=all(tools.values()),protected_evidence_hashes=all(evidence.values()),canonical_synth_hashes=all(frozen.values()),
        old_branch_heads=all(old_refs.values()),source_closures=all(row['source_closure_unchanged'] for row in workspaces.values()),
        protected_tracked_paths=all(not row['protected_tracked_diff'] for row in workspaces.values()),
        entry_checks=entry['passed'],nearcritical_count=near['selected_endpoints']==550,
        smoke_passed=smoke_pass,smoke_input_hashes=all(smoke_inputs.values()),
        wrapper_passed=wrapper_result['passed'],app_small_passed=app.get('passed') is True,
        gui_dual_cli=load(OUT/'preparation/gui_cli_check.json')['passed'])
    preflight=load(OUT/'preflight.json')
    preflight.update(finalized=runtime.now(),license=dict(status='blocked',reason_code='license',native_attempts=1,
        native_log=c0['synthesis']['jobs'][0]['log']),entry_checks_final=str(OUT/'preparation/constraint_checks_final.json'),
        candidate_release={item:dict(status=data['status'],reason_code=data['reason_code']) for item,data in results.items()},
        gui=load(OUT/'preparation/gui_result.json'),regression_entry=regression,resource_budget=budget)
    runtime.save(OUT/'preflight.json',preflight)
    validation=dict(status='not_applicable',reason='D11 not triggered: no rebuilt candidate achieved a measured closed timing snapshot',
        registered_snapshots=[],started_jobs=[],full_ce2=None,judge_8_of_8=None,default_app=None,netlist_simulations=None)
    runtime.save(OUT/'validation/result.json',validation)
    # v1 freezes the forward C4/C4p pair. Make its inverse explicit without
    # changing that immutable manifest or inventing C0 as C4's control.
    pairing={**manifest['pairing'],'C4p':'C4 same frozen r5A VQM/ECP and PRES; inverse R/no-R pair'}
    comparison={item:dict(control=pairing[item],valid=False,reason=results[item]['reason_code'],
        same_pres_deltas=[dict(pres=slot['pres'],delta=slot['delta_vs_control']) for slot in results[item]['pres_runs']],
        seven_slot_median_delta_ns=None) for item in ITEMS}
    runtime.save(OUT/'comparisons.json',comparison)
    complete=dict(task='T62 F1',updated=runtime.now(),phase='D10_review_pending' if args.final else 'final_audit_pending',
        results=results,branches=heads,preparation=dict(entry='prepared; P0 syntax/static semantics checked; native C0 implementation blocked',
            license='blocked',gui='blocked + awaiting_user_gui',C0_gate='blocked',regression_entry='eight smoke cases/wrapper/app small passed; full candidate regression not run',
            nearcritical='550 exact endpoint minima; classification is inference',resource_budget='whole plan does not fit; no dependent release'),
        current_batch_timing_measurements=None,comparisons=comparison,resources=resources,validation=validation,
        adopted_candidate=None,combination_eligible_count=None,next_action='Stop for D10 review; no batch2')
    runtime.save(OUT/'results.json',complete)
    finalization=load(OUT/'finalization.json') if (OUT/'finalization.json').exists() else {}
    if args.final:
        conditions.update(clean_workspaces=all(not row['status'] for row in workspaces.values()),
            automation_deleted=finalization.get('automation_deleted') is True,
            report_exists=(OUT/'report_F1.md').is_file())
    checks=dict(passed=all(conditions.values()),timestamp=runtime.now(),conditions=conditions,branch_heads=heads,
        workspaces=workspaces,protected_metadata=protected,tool_hashes=tools,protected_evidence_hashes=evidence,
        canonical_synth_files=frozen,old_branch_heads=old_refs,resources=resources,all_owned_processes_exited=exited,
        owned_process_checks=process_checks,automation=finalization,manifest_sha256=eda.sha(OUT/'manifest.json'),
        report_sha256=eda.sha(OUT/'report_F1.md') if (OUT/'report_F1.md').exists() else None,
        exclusions='No batch2, D11 acceptance, official document update, merge or push performed',
        current_finalizer=runtime.capture(psutil.Process()))
    runtime.save(OUT/'final_checks.json',checks)
    state=load(OUT/'status.json')
    state.update(updated=runtime.now(),phase=complete['phase'],items={item:dict(status=data['status'],reason_code=data['reason_code'],result=str(OUT/item/'result.json')) for item,data in results.items()},
        active_jobs=[],final_checks=str(OUT/'final_checks.json'),automation_deleted=finalization.get('automation_deleted',False))
    runtime.save(OUT/'status.json',state)
    print(json.dumps(dict(passed=checks['passed'],conditions=conditions,branches=heads,resources=resources,
                         resource_budget=budget,regression_smoke_passed=smoke_pass),ensure_ascii=False,indent=2))
    return 0 if checks['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
