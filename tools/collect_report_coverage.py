"""Collect only accepted current native UCDBs; retain actual denominators."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import sys

sys.path.insert(0,str(Path(__file__).resolve().parent))
import eda
from report_input_identity import accept_positive

METRICS=('Branches','Conditions','Expressions','FSM States','FSM Transitions','Statements','Toggles')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--batch',type=Path,required=True)
    parser.add_argument('--extra',type=Path,action='append',default=[])
    parser.add_argument('--replacement-batch',type=Path,action='append',default=[])
    parser.add_argument('--review-unused-output',action='store_true',
                        help='Review only the exact app_cfg_ready unused-output TB fix')
    args=parser.parse_args()
    batch=json.loads((args.batch/'summary.json').read_text())
    manifest=json.loads((args.batch/'manifest.json').read_text())
    expected=set(manifest['cases'])
    rows=batch['results']
    if (len(expected)!=len(manifest['cases']) or len(rows)!=len(expected) or
        {r['case'] for r in rows}!=expected):
        raise SystemExit('Native positive set incomplete; do not publish a merged PASS')
    if not manifest['coverage'] or manifest['profile']!='fragmentation1030' or manifest['seed']!=20261007:
        raise SystemExit('Native batch configuration does not match the current report execution')
    originals={r['case']:r for r in rows};selected=dict(originals);replacements={}
    for replacement in args.replacement_batch:
        retry=json.loads((replacement/'summary.json').read_text())
        config=json.loads((replacement/'manifest.json').read_text())
        cases=config['cases'];items=retry['results']
        if (not retry.get('passed') or len(set(cases))!=len(cases) or len(items)!=len(cases) or
            {r['case'] for r in items}!=set(cases) or not set(cases)<=expected or
            any(config[k]!=manifest[k] for k in ('profile','seed','coverage','simulator')) or
            not all(r['passed'] and r['exit_code']==0 for r in items)):
            raise SystemExit('Replacement batch is incomplete, failed or configured differently')
        for row in items:
            case=row['case']
            if case in replacements:raise SystemExit('Multiple replacements for '+case)
            replacements[case]=dict(original=originals[case],replacement=row,batch=str(replacement))
            selected[case]=row
    rows=[selected[case] for case in manifest['cases']]
    flow=eda.Flow('report','native_coverage_collection',None)
    try:
        inputs=[]
        flow.result.update(original_batch=str(args.batch),original_batch_passed=batch.get('passed'),
                           original_failed_cases=[r for r in batch['results'] if not r['passed'] or r['exit_code']!=0],
                           replacements=replacements)
        candidates=[(r['case'],Path(r['folder']),r) for r in rows]+[(p.parent.name,p,None) for p in args.extra]
        for case,folder,row in candidates:
            summary=json.loads((folder/'summary.json').read_text())
            acceptance=accept_positive(summary,folder,args.review_unused_output)
            if row is not None and (row['passed']!=summary['passed'] or row['exit_code']!=(0 if summary['passed'] else 1)):
                raise RuntimeError('Batch row differs from original native outcome: '+case)
            if summary.get('parameters') and any(p.startswith('T65_MUTANT=') for p in summary['parameters']):
                raise RuntimeError('Negative-control UCDB excluded')
            test,_,parameter_text=case.partition('|')
            parameters=parameter_text.split(',') if parameter_text else []
            if (summary['name']!=test or summary['parameters']!=parameters or
                summary['verification_profile']!=manifest['profile'] or summary['ce_div']!=2 or
                summary.get('replaced_modules')):
                raise RuntimeError('Case, parameters, profile, CE or RTL scope mismatch: '+case)
            jobs={j['name']:j for j in summary['jobs']}
            if any(j['exit_code']!=0 or j.get('stop_reason') for j in summary['jobs']):
                raise RuntimeError('Unsuccessful native job in coverage input: '+case)
            for name in ('compile_rtl','compile'):
                if '+define+AFDX_CE_DIV=2' not in jobs[name]['command']:
                    raise RuntimeError('Actual compile CE differs from summary: '+case)
            simulation=jobs['simulation']['command']
            if Path(simulation[0]).resolve()!=Path(manifest['simulator'],'vsim.exe').resolve():
                raise RuntimeError('Native simulator differs from batch: '+case)
            if test not in simulation or [a[2:] for a in simulation if a.startswith('-g')]!=parameters:
                raise RuntimeError('Actual native top or parameters differ: '+case)
            vector_seed=None
            if 'vectors' in jobs and '--seed' in jobs['vectors']['command']:
                vector_command=jobs['vectors']['command']
                vector_seed=int(vector_command[vector_command.index('--seed')+1])
                if vector_seed!=manifest['seed']:
                    raise RuntimeError('Actual vector seed differs from batch: '+case)
            if '+cover=sbceft' not in jobs['compile_rtl']['command'] or '-coverage' not in simulation:
                raise RuntimeError('RTL coverage instrumentation missing')
            if any('+cover=' in arg for arg in jobs['compile']['command']):
                raise RuntimeError('Testbench coverage mixed into RTL denominator')
            ucdb=folder/'coverage.ucdb'
            if not ucdb.is_file() or not ucdb.stat().st_size:raise RuntimeError('UCDB missing')
            inputs.append(dict(case=case,folder=str(folder),ucdb=str(ucdb),sha256=eda.sha(ucdb),
                               testname=summary['name']+'_'+folder.name,parameters=summary['parameters'],
                               verification_profile=summary['verification_profile'],ce_div=summary['ce_div'],
                               vector_seed=vector_seed,**acceptance,
                               seed_scope='Verified generator --seed when present; otherwise this case has no seeded vector command'))
        if len({i['ucdb'] for i in inputs})!=len(inputs) or len({i['testname'] for i in inputs})!=len(inputs):
            raise RuntimeError('Duplicate UCDB or native test identity')
        eda.save(flow.folder/'inputs.json',inputs)
        ms=eda.modelsim_dir();merged=flow.folder/'merged.ucdb'
        flow.job('merge',[ms/'vcover.exe','merge','-checkinputs','-ucdbchecks',merged,*[i['ucdb'] for i in inputs]],600)
        names=flow.job('testnames',[ms/'vcover.exe','testnames',merged],120)
        actual={line.strip() for line in names.splitlines() if re.fullmatch(r'tb_\w+_\d{8}_\d{6}_\d+',line.strip())}
        wanted={i['testname'] for i in inputs}
        if actual!=wanted:raise RuntimeError('Merged test identities differ from accepted inputs')
        text=flow.job('design_units',[ms/'vcover.exe','report','-code','bcesft','-showenabledcodecov',merged],300)
        if re.search(r'\*\* (Error|Fatal|Warning):',text):raise RuntimeError('Coverage report diagnostics')
        # The default report repeats Design Unit headers for every instance.
        # Request native DU aggregates explicitly; an instance row must never
        # overwrite another instance and masquerade as a module denominator.
        units=sorted(set(re.findall(r'^=== Design Unit: work\.(\w+)',text,re.M)))
        if not units:raise RuntimeError('No native design-unit identities parsed')
        modules={}
        for unit in units:
            body=flow.job('du_'+unit,[ms/'vcover.exe','report','-du=work.'+unit,
                '-code','bcesft','-showenabledcodecov',merged],120)
            if re.search(r'\*\* (Error|Fatal|Warning):',body):raise RuntimeError('DU coverage diagnostics: '+unit)
            found=re.findall(r'^\s+(Branches|Conditions|Expressions|FSM States|FSM Transitions|Statements|Toggles)\s+(\d+)\s+(\d+)\s+(\d+)\s+([0-9.]+)%',body,re.M)
            if len(found)!=len(METRICS) or {r[0] for r in found}!=set(METRICS):
                raise RuntimeError('Missing or duplicated native DU metrics: '+unit)
            metrics={metric:dict(total=int(total),covered=int(hit),missed=int(miss),percent=float(percent))
                     for metric,total,hit,miss,percent in found}
            if any(m['covered']+m['missed']!=m['total'] for m in metrics.values()):
                raise RuntimeError('Inconsistent native DU bins: '+unit)
            modules[unit]=metrics
        totals={}
        for metric in METRICS:
            total=sum(m.get(metric,{}).get('total',0) for m in modules.values())
            hit=sum(m.get(metric,{}).get('covered',0) for m in modules.values())
            totals[metric]=dict(total=total,covered=hit,missed=total-hit,percent=100*hit/total if total else None)
        eda.save(flow.folder/'coverage.json',dict(input_count=len(inputs),testnames=sorted(actual),
            design_unit_count=len(modules),modules=modules,totals=totals,
            policy='Observed current RTL denominators; no inherited percentage threshold or claim of full coverage'))
        # A zeros report is useful evidence even when every test passes.
        flow.job('uncovered',[ms/'vcover.exe','report','-code','bcesft','-details','-zeros',merged],600)
        flow.result.update(passed=True,ucdb=str(merged),ucdb_sha256=eda.sha(merged),
            inputs=inputs,design_units=sorted(modules),totals=totals)
        print('COVERAGE COLLECTION PASS inputs=',len(inputs),'design_units=',len(modules),'OUTPUT',flow.folder,flush=True)
        return 0
    except Exception as error:
        flow.result.update(passed=False,error=str(error));print('COVERAGE COLLECTION FAIL',error,flush=True)
        return 1
    finally:flow.finish()


if __name__=='__main__':raise SystemExit(main())
