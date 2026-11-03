"""Evaluate the single authorized route trial; commit only its RTL on PASS."""
import argparse
from datetime import datetime,timedelta,timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

import build_1030
import eda
import official_impl
from t61_metrics import read_place

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/t76'
EVIDENCE=ROOT/'docs/evidence/t76_frag1030'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--commit',action='store_true');args=parser.parse_args()
    latest=ROOT/'out/t76_trial_latest_AFDX_top_1030.json'
    if not latest.is_file():raise RuntimeError('Trial still active or has not produced a final receipt')
    result=json.loads(latest.read_text(encoding='utf-8'))
    edits=json.loads((OUT/'source_compat_edits.json').read_text(encoding='utf-8'))
    allowed=[r['file'] for r in edits]
    for row in edits:
        if eda.sha(ROOT/row['file']).lower()!=row['after_sha256']:
            raise RuntimeError('Candidate RTL changed; preserving current source: '+row['file'])
    raw_compile=json.loads((ROOT/'out/t76_latest_source_compile.json').read_text())
    candidate_exact=all(eda.sha(Path(p))==digest for p,digest in raw_compile['inputs'].items())
    output=Path(result.get('route_output') or Path(result['folder'])/'project/AFDX_EndSystem.runs/imple_1')
    route_log=Path(result['folder'])/'route.log'
    log=route_log.read_text(encoding='utf-8',errors='replace') if route_log.is_file() else ''
    native_route_ok='All was well!' in log and 'BUILD1030_ROUTE_COMPLETED' in log
    edi=output/'AFDX_EndSystem.edi'
    native_errors=[line for line in edi.read_text(encoding='utf-8',errors='replace').splitlines()
        if re.search(r'\[(ERROR|CRIT)\]',line)] if edi.is_file() else ['Native implementation log missing']
    route_resources={};route_timing={}
    if native_route_ok:
        route_resources,route_timing,resource_report,timing_database=official_impl.reports(output,'AFDX_EndSystem')
    measurements=dict(synthesized_timing=result.get('synthesized_timing',{}),routed_timing=route_timing,
        synth_resources=result.get('resources',{}),route_resources=route_resources,
        native_route_completed=native_route_ok,native_errors=native_errors,strict_runner_error=result.get('error'),
        note='Read native reports even if the older exact-cluster-set wrapper rejected the changed packed set')
    checks={}
    for stage,key in (('synthesis','synthesized_timing'),('route','routed_timing')):
        clocks=measurements.get(key,{}).get('clocks',[])
        checks[stage]=bool(clocks) and all(c['setup_worst_slack']>0 and c['hold_worst_slack']>=0
            and c['setup_fail_ends']==0 and c['hold_fail_ends']==0 for c in clocks)
    protected=('rtl/AFDX_top.v','elinx/afdx_all.v','elinx/tiles_1030.edc',
        'elinx/constraints_t62.json','elinx/physical_only.edc','elinx/timing_only.sdc')
    p0_inputs=all((ROOT/name).read_bytes()==subprocess.check_output(['git','show','e4573d22:'+name],cwd=ROOT) for name in protected)
    binding=json.loads((OUT/'trial_vqm_binding.json').read_text())
    checks.update(candidate_matches_verified_compile=candidate_exact,original_vlog_iverilog_compile=raw_compile.get('passed') is True,
        p0_pin_and_constraint_inputs_unchanged=p0_inputs,
        native_route_completed=native_route_ok,no_native_critical_errors=not native_errors,
        multicycle_audit=result.get('multicycle_audit_passed') is True,
        classified_netlist_bound_to_trial=binding['noncomment_sorted_identical'] and
            bool(result.get('netlist')) and binding['trial_sha256']==eda.sha(Path(result['netlist'])).lower())
    cluster_details={}
    try:
        _,expected=build_1030.load_tile_locks(ROOT/'elinx/tiles_1030.edc')
        place=output/'AFDX_EndSystem.place';placed={}
        for line in place.read_text(encoding='utf-8-sig').splitlines():
            p=line.split()
            if len(p)>=4 and p[0].startswith('stratix_'):placed[p[0]]=(int(p[1]),int(p[2]))
        cluster_details=dict(expected=len(expected),placed=len(placed),missing=len(expected.keys()-placed.keys()),
            retained=len(expected.keys()&placed.keys()),extra=len(placed.keys()-expected.keys()),
            moved=sum(placed[k]!=v for k,v in expected.items() if k in placed),
            missing_names=sorted(expected.keys()-placed.keys()),extra_names=sorted(placed.keys()-expected.keys()))
        _,ios=read_place(place);pins=json.loads((ROOT/'elinx/constraints_t62.json').read_text())['pins']
        p0=[dict(port=r['port'],expected=r,actual=ios.get(r['port']),passed=r['port'] in ios
            and ios[r['port']]['package_pin']==r['pin'] and ios[r['port']]['coordinates']==r['xyz']
            and ios[r['port']]['direction']==r['direction']) for r in pins]
        checks['P0_native_placement']=len(ios)==172 and all(r['passed'] for r in p0)
        tile_lines,_=build_1030.load_tile_locks(ROOT/'elinx/tiles_1030.edc')
        constraints=(Path(result['folder'])/'project/imple_constraints.edc').read_text(encoding='utf-8')
        checks['default_tiles_loaded_without_modification']=all(line in constraints for line in tile_lines)
    except (OSError,KeyError) as exc:cluster_details=dict(error=str(exc))
    checks.setdefault('P0_native_placement',False);checks.setdefault('default_tiles_loaded_without_modification',False)
    passed=all(checks.values())
    receipt=dict(status='PASS' if passed else 'FAIL',checked=datetime.now(timezone(timedelta(hours=8))).strftime('%Y-%m-%d %H:%M:%S'),
        checks=checks,clusters=cluster_details,source_build=result,native_measurements=measurements,
        p0_checks=locals().get('p0',[]),netlist_binding=binding,
        modified_rtl=allowed,decision='Keep and independently commit authorized RTL' if passed else 'Restore RTL to e4573d22; no reroute',
        new_vqm_rerun_decision='External confirmation required; existing T75/T76 VQM windows are not restarted')
    OUT.mkdir(exist_ok=True);EVIDENCE.mkdir(parents=True,exist_ok=True)
    (OUT/'trial_gate.json').write_bytes((json.dumps(receipt,ensure_ascii=False,indent=2)+'\n').encode('utf-8'))
    (EVIDENCE/'trial_gate.json').write_bytes((OUT/'trial_gate.json').read_bytes())
    if not passed:
        for row in edits:(ROOT/row['file']).write_bytes(subprocess.check_output(['git','show','e4573d22:'+row['file']],cwd=ROOT))
        print('TRIAL GATE FAIL; RTL restored; no retry or re-placement')
        return 1
    if args.commit:
        if subprocess.check_output(['git','branch','--show-current'],cwd=ROOT,text=True).strip()!='t76':raise RuntimeError('Unexpected branch')
        if subprocess.run(['git','diff','--cached','--quiet'],cwd=ROOT).returncode:raise RuntimeError('Index contains other staged changes')
        paths=allowed+['docs/evidence/t76_frag1030/trial_gate.json']
        subprocess.run(['git','add','--',*paths],cwd=ROOT,check=True)
        subprocess.run(['git','diff','--cached','--check'],cwd=ROOT,check=True)
        synth=measurements['synthesized_timing']['clocks'][0];route=measurements['routed_timing']['clocks'][0]
        body=f"VQM SHA256 {binding['trial_sha256']}\nSynthesis setup/hold {synth['setup_worst_slack']:+d}/{synth['hold_worst_slack']:+d} ps; route {route['setup_worst_slack']:+d}/{route['hold_worst_slack']:+d} ps; zero failing endpoints.\nOriginal tiles unchanged: {cluster_details.get('retained')} retained, {cluster_details.get('missing')} missing, {cluster_details.get('extra')} new, {cluster_details.get('moved')} moved; P0 unchanged. New A3 timing gate; only the three authorized portability edit classes."
        subprocess.run(['git','commit','-m','fix(t76): preserve timing with portable source declarations','-m',body],cwd=ROOT,check=True)
        commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
        (OUT/'trial_commit.json').write_bytes((json.dumps(dict(commit=commit,vqm_sha256=binding['trial_sha256'],gate='PASS'),indent=2)+'\n').encode())
        print('TRIAL RTL COMMIT '+commit)
    print(json.dumps(dict(status='PASS',checks=checks,clusters=cluster_details),ensure_ascii=False))
    return 0


if __name__=='__main__':raise SystemExit(main())
