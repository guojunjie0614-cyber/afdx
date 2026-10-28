"""Read-only native timing evaluation and fixed D9 candidate comparisons.

Endpoint selection describes functional sink roles, including their replacement
registers. Every reported setup path into those sinks is considered; no source
filter hides a replacement critical path. Missing measurements remain null.
"""
import argparse
import copy
from collections import Counter
import json
from pathlib import Path
import re
import sqlite3
import statistics

import eda
import t62_runtime as rt
from t61_metrics import module_name

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/t62'
PRES=['1.30','1.40','1.45','1.50','1.55','1.60','1.70']
TARGETS={
    'C1':[r'rx_core\|map_bank\[(?:18|19)\]\.(?:write_request|write_local|write_permitted)',
          r'rx_core\|engine\|deliver_allowed',r'rx_core\|engine\|state_wd\['],
    'C2':[r'cfg_regs\|cfg_rdata\['],
    'C3a':[r'snmp\|mib_rd(?:~|\[|\|)'],
    'C3b':[r'loader\|sender\|(?:bytes(?:_|\[)|register_queue\.byte[0-7]|read_pos\[|write_pos\[|tx_data\[)'],
    'C3c':[r'^application_tx\|(?:write_ptr\[|used\[|start_used\[|read_reserved\[)',
           r'^application_tx\|reader\|(?:pointer\[|reserved\[)']}
MEASURES=['setup_worst_slack_ps','hold_worst_slack_ps','setup_failed_endpoints','hold_failed_endpoints',
    'setup_endpoint_count','hold_endpoint_count','below_0p5ns','below_0p8ns','endpoint_min_setup_negative_slack_sum_ps']


def load(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def clean(name):return '|'.join(part.split(':')[-1] for part in name.lstrip('\\').split('|'))


def selected_cones(database):
    database=Path(database).resolve();connection=sqlite3.connect(database.as_uri()+'?mode=ro',uri=True)
    connection.row_factory=sqlite3.Row
    connection.execute('PRAGMA query_only=ON');connection.execute('PRAGMA temp_store=MEMORY')
    patterns={key:[re.compile(pattern) for pattern in values] for key,values in TARGETS.items()}
    ends={key:{} for key in patterns};sources={key:set() for key in patterns};path_counts=Counter();failed={}
    try:
        for native in connection.execute('SELECT * FROM elinx_intra_clock_longest_sync_path_report'):
            row=dict(native);endpoint=row['to_cell_name'];normal=clean(endpoint)
            if row['slack']<0:
                old=failed.get(endpoint)
                if old is None or row['slack']<old['slack']:failed[endpoint]=row
            for key,regexes in patterns.items():
                if not any(regex.search(normal) for regex in regexes):continue
                path_counts[key]+=1;sources[key].add(row['from_cell_name'])
                old=ends[key].get(endpoint)
                if old is None or (row['slack'],row['path_id'])<(old['slack'],old['path_id']):ends[key][endpoint]=row
        result={}
        for key,rows in ends.items():
            values=list(rows.values())
            result[key]=dict(endpoint_count=len(values),all_related_path_count=path_counts[key],
                distinct_related_source_count=len(sources[key]),worst_slack_ps=min((row['slack'] for row in values),default=None),
                failed_endpoints=sum(row['slack']<0 for row in values) if values else None,
                endpoint_min_negative_slack_sum_ps=sum(min(row['slack'],0) for row in values) if values else None,
                worst_three_paths=sorted(values,key=lambda row:(row['slack'],row['path_id']))[:3],
                selected_endpoints=sorted(rows))
        return dict(cones=result,failed_named_endpoints=failed,
            input_database=str(database),setup_paths_considered='all rows; source names are never filtered')
    finally:connection.close()


def evaluation(path):
    path=Path(path)
    if not path.exists():return None
    result=load(path)
    if result.get('status')!='completed' or not result.get('metrics'):return None
    cache=path.parent/'evaluation_v1.json'
    database=result['report']['timing_database']
    result_hash=eda.sha(path)
    if cache.exists():
        stored=load(cache)
        if stored['attempt_result_sha256']!=result_hash:raise RuntimeError('Completed attempt changed: '+str(path))
        return stored
    detail=selected_cones(database)
    stored=dict(attempt_result=str(path),attempt_result_sha256=result_hash,
        metrics=result['metrics'],resources=result.get('resources'),constraints_applied=result.get('constraints_applied'),
        timing_closed=result.get('timing_closed'),**detail)
    rt.save(cache,stored);return stored


def compare(candidate,control,target):
    deltas={key:None if candidate is None or control is None else candidate['metrics'][key]-control['metrics'][key]
        for key in MEASURES}
    result=dict(measurement_available=candidate is not None,control_available=control is not None,delta= deltas,
        target_cone=None,target_delta=None,new_failed_named_endpoints=None,new_failed_modules=None)
    if candidate is None or control is None:return result
    new={name:row for name,row in candidate['failed_named_endpoints'].items() if name not in control['failed_named_endpoints']}
    result.update(new_failed_named_endpoints=list(new.values()),new_failed_modules=dict(Counter(module_name(name) for name in new)),
        new_failure_note='Named endpoints; renamed storage may change identities. This is reported without a setup veto.')
    if target in TARGETS:
        current=candidate['cones'][target];baseline=control['cones'][target]
        result['target_cone']=dict(candidate=current,control=baseline)
        result['target_delta']={key:None if current[key] is None or baseline[key] is None else current[key]-baseline[key]
            for key in ['worst_slack_ps','failed_endpoints','endpoint_min_negative_slack_sum_ps']}
    return result


def apply_single_candidate_reuse(queue,results):
    """Expose existing measurements with their provenance; never create a run."""
    item=queue['items']['C6'];request=item.get('request')
    if not isinstance(request,dict) or not request.get('reuse_of'):return
    reference=request['reuse_of']
    if item['status']!='completed' or reference not in TARGETS or item['jobs']:
        raise RuntimeError('Invalid single-candidate C6 reuse state')
    original=queue['items'][reference];measured=results[reference]
    if (original['status']!='completed' or not measured['complete_seven_slots']
        or measured['eligible_for_combination'] is not True
        or request['source_candidate_head']!=original['head']
        or request['source']!=original['source'] or request['reuse_slots']!=original['slots']):
        raise RuntimeError('C6 reuse does not identify the complete eligible source')
    decision=load(request['decision'])
    if (sha256:=eda.sha(Path(request['decision'])))!=request['decision_sha256']:
        raise RuntimeError('C6 decision identity changed')
    frozen=OUT/'round_02/D9_evaluation_frozen.json'
    if (decision['eligible_union']!=[reference] or decision['combination_count']!=1
        or decision['rules_sha256']!=eda.sha(OUT/'manifest_v8_evaluation.json')
        or eda.sha(frozen)!=decision['evaluation_sha256']):
        raise RuntimeError('C6 reuse differs from the frozen D9 decision')
    reused=copy.deepcopy(measured)
    reused.update(candidate='C6',status=item['status'],reason_code=item.get('reason_code'),
        source_result=str(OUT/'C6/result.json'),reuse_of=reference,
        source_candidate_head=original['head'],source_synthesis=original['source'],
        reused_source_result=str(OUT/reference/'result.json'),
        reuse_decision=request['decision'],reuse_decision_sha256=sha256,
        measurement_provenance='All seven measurements and functional results reused from '+reference,
        new_native_runs=0,new_validation_jobs=0)
    for row in reused['pres_runs']:row['measurement_provenance']='reused from '+reference
    results['C6']=reused


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--freeze-spec',action='store_true')
    args=parser.parse_args()
    if args.freeze_spec:
        path=OUT/'manifest_v8_evaluation.json'
        spec=dict(created=rt.now(),parent='manifest_v7_queue.json',parent_sha256=eda.sha(OUT/'manifest_v7_queue.json'),
            target_endpoint_patterns=TARGETS,matching='Remove leading escape and optional module type qualifiers; match complete endpoint role. Consider every related setup source/path.',
            baseline='C0 same PRES for C1/C2/C3a/b/c/C6; C4p same canonical for C4; C1 same checkpoint/P1.55 for C5',
            local_eligibility='At least one valid matched PRES improves target-cone worst slack or failing-endpoint count; functional/D4/D5/P0 pass and no added hold failures in measured matched slots. Missing slots stay null and are reported; they do not supply an improvement or a complete-candidate rank.',
            full_adoption='Both seven-slot tables complete; more closed slots, or equal closed counts and median WNS gain >=50ps',
            setup_degradation='All global deltas/new failed named endpoints/modules reported; no added numeric veto',
            zero_match='Null, never treated as a repaired path',single_combination='Union of locally eligible C1/C2/C3a/C3b/C3c once; 0 not_applicable, 1 reuse, multiple semantic merge and complete validation',
            coordinator_frozen_sha256=eda.sha(ROOT/'tools/t62_round2.py'),evaluator_sha256=eda.sha(Path(__file__)))
        if path.exists():raise RuntimeError('Evaluation spec already frozen; never overwrite')
        rt.save(path,spec);print(str(path));return 0
    spec=load(OUT/'manifest_v8_evaluation.json')
    if spec['target_endpoint_patterns']!=TARGETS:raise RuntimeError('Frozen target-cone rules differ')
    queue=load(OUT/'round_02/queue.json');evaluated={}
    for key,item in queue['items'].items():
        slots={}
        for pres,path in item['slots'].items():slots[pres]=evaluation(path) if path else None
        evaluated[key]=slots
    results={}
    for key,item in queue['items'].items():
        control_key='C4p' if key=='C4' else 'C1' if key=='C5' else 'C0'
        wanted=['1.55'] if key=='C5' else PRES
        slots=[];improved=[];no_added_hold=True
        for pres in wanted:
            current=evaluated[key].get(pres);baseline=evaluated[control_key].get(pres)
            comparison=compare(current,baseline,key)
            matched=current is not None and baseline is not None
            if matched and current['metrics']['hold_failed_endpoints']>baseline['metrics']['hold_failed_endpoints']:no_added_hold=False
            target=comparison.get('target_delta')
            if matched and target and ((target['worst_slack_ps'] is not None and target['worst_slack_ps']>0)
                or (target['failed_endpoints'] is not None and target['failed_endpoints']<0)):improved.append(pres)
            slots.append(dict(pres=pres,evaluation=str(Path(item['slots'][pres]).parent/'evaluation_v1.json') if item['slots'].get(pres) and current else None,
                raw_metrics={name:current['metrics'][name] if current else None for name in MEASURES},resources=current['resources'] if current else None,
                timing_closed=current['timing_closed'] if current else None,comparison=comparison))
        full=len(wanted)==7 and all(evaluated[key].get(pres) is not None for pres in PRES)
        basefull=all(evaluated[control_key].get(pres) is not None for pres in PRES)
        measured=list(evaluated[key].values());measured=[row for row in measured if row]
        closed=sum(row['timing_closed'] is True for row in measured)
        median=statistics.median(row['metrics']['setup_worst_slack_ps'] for row in measured) if full else None
        adopted=None
        if full and basefull and key not in ['C0','C4p','C5']:
            controls=[evaluated[control_key][pres] for pres in PRES]
            baseclosed=sum(row['timing_closed'] is True for row in controls)
            basemedian=statistics.median(row['metrics']['setup_worst_slack_ps'] for row in controls)
            adopted=closed>baseclosed or (closed==baseclosed and median-basemedian>=50)
        eligible=None
        if key in TARGETS:
            if item.get('functional_passed') is False:eligible=False
            elif item.get('functional_passed') is True and measured:
                eligible=bool(improved) and no_added_hold and all(row['constraints_applied'] is True for row in measured)
        results[key]=dict(candidate=key,status=item['status'],reason_code=item.get('reason_code'),control=control_key,
            run_completed=item.get('run_completed'),control_reproduced=item.get('control_reproduced'),
            functional_passed=item.get('functional_passed'),constraints_applied=item.get('constraints_applied'),
            timing_closed=item.get('timing_closed'),valid_for_comparison=item.get('valid_for_comparison'),
            eligible_for_combination=eligible,improved_target_pres=improved,no_added_hold_failures_in_measured_pairs=no_added_hold,
            measured_pres=sorted(evaluated[key]),complete_seven_slots=full,seven_slot_median_ps=median,
            measured_closed_slot_count=closed if measured else None,complete_candidate_adopted=adopted,pres_runs=slots,
            source_result=str(OUT/key/'result.json'),functional_boundary=item.get('functional_boundary'))
    apply_single_candidate_reuse(queue,results)
    destination=OUT/'round_02/evaluation.json';rt.save(destination,dict(updated=rt.now(),rules=str(OUT/'manifest_v8_evaluation.json'),items=results,
        eligible_union=[key for key in TARGETS if results[key]['eligible_for_combination'] is True]))
    print(json.dumps(dict(evaluation=str(destination),eligible_union=[key for key in TARGETS if results[key]['eligible_for_combination'] is True],
        complete_seven=[key for key in results if results[key]['complete_seven_slots']])));return 0


if __name__=='__main__':raise SystemExit(main())
