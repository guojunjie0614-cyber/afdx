"""Native T65 HDL controls and real checker-failure entry propagation.

A rejected compilation or tool startup never counts as a detected HDL control.
Runs one simulation at a time; caller allocates one of the shared three slots.
"""
import argparse
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import re
import shutil
import sys
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eda


def diagnostics(text):
    return {**{k: len(re.findall(r'\*\* '+k+':', text)) for k in ('Error', 'Fatal', 'Warning')},
            'RAMCOLL': text.count('RAMCOLL')}


def validate_native_control(folder, test, code, propagation=False):
    summary=json.loads((folder/'summary.json').read_text(encoding='utf-8'))
    jobs={j['name']:j for j in summary['jobs']}
    for name in ('vlib','compile','simulation'):
        if name not in jobs or jobs[name]['exit_code'] or jobs[name]['stop_reason']:
            raise RuntimeError('Control did not execute normally: '+name)
    compile_log=(folder/'compile.log').read_text(encoding='utf-8-sig',errors='replace')
    if not re.search(r'Errors: 0, Warnings: 0',compile_log):
        raise RuntimeError('Control compilation diagnostics')
    log=(folder/'simulation.log').read_text(encoding='utf-8-sig',errors='replace')
    diag=diagnostics(log)
    if any(diag.values()):raise RuntimeError('Control engine diagnostics: '+str(diag))
    rows=re.findall(r'\[RESULT\]\s+(\w+)\s+(PASS|FAIL)\s+checks=(\d+)\s+errors=(\d+)',log)
    if not rows or rows[-1][0]!=test or int(rows[-1][2])<=0:
        raise RuntimeError('Actual HDL result absent')
    _,status,checks,errors=rows[-1]
    if code!=1 or summary.get('passed') is not False:
        raise RuntimeError('Official entry did not propagate the rejection')
    if propagation:
        check=json.loads((folder/'check_summary.json').read_text(encoding='utf-8'))
        if status!='PASS' or int(errors)!=0 or check.get('errors',0)<=0:
            raise RuntimeError('Expected HDL PASS followed by independent checker FAIL')
        if 'check' not in jobs or jobs['check']['exit_code'] or jobs['check']['stop_reason']:
            raise RuntimeError('Independent checker failed to execute normally')
    elif status!='FAIL' or int(errors)<=0:
        raise RuntimeError('HDL mutant was not detected by actual HDL checks')
    for row in summary['inputs']:
        if eda.sha(Path(row['path']))!=row['sha256']:
            raise RuntimeError('Control source drift: '+row['path'])
    if (folder/'coverage.ucdb').exists():raise RuntimeError('Negative control must not produce coverage')
    return dict(passed=True,folder=str(folder),test=test,entry_exit=code,
                hdl_status=status,hdl_checks=int(checks),hdl_errors=int(errors),diagnostics=diag)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode',choices=('mutants','propagation','all'),default='all')
    parser.add_argument('--test',action='append',default=[],help='Rerun only the named affected fixtures')
    args=parser.parse_args()
    os.environ['AFDX_VERIFICATION_PROFILE']='fragmentation1030'
    os.environ['AFDX_LATEST_PREFIX']='report_controls_'
    batch=eda.ROOT/'out/report_controls'/datetime.now().strftime('native_%Y%m%d_%H%M%S_%f')
    batch.mkdir(parents=True)
    tests=[s.strip().partition('|')[0] for s in (eda.ROOT/'sim/tests.txt').read_text().splitlines()
           if s.strip().startswith('tb_t65_')]
    if len(tests)!=16 or len(set(tests))!=16:raise RuntimeError('Expected sixteen distinct T65 fixtures')
    if set(args.test)-set(tests):raise RuntimeError('Unknown requested T65 fixture')
    selected=[test for test in tests if not args.test or test in args.test]
    cases=[(test,mutant,False) for test in selected for mutant in (1,2)] if args.mode!='propagation' else []
    if args.mode!='mutants':cases.append(('tb_t65_queue_a',0,True))
    deadline=(datetime.now().astimezone()+timedelta(hours=8)).isoformat()
    eda.save(batch/'manifest.json',dict(mode=args.mode,cases=cases,workers=1,coverage=False,
        seed=20261007,ce_div=os.environ.get('AFDX_CE_DIV','2'),deadline=deadline))
    original_flow=eda.Flow;original_job=eda.Flow.job;state={};rows=[]
    class RecordingFlow(original_flow):
        def __init__(self,*a,**kw):
            super().__init__(*a,**kw);state['flow']=self
        def job(self,name,*a,**kw):
            result=original_job(self,name,*a,**kw)
            if name=='simulation' and state.get('propagation'):
                trace=self.folder/'t65_trace.txt'
                shutil.copyfile(trace,self.folder/'negative_original_trace.txt')
                trace.write_text('',encoding='ascii')
                eda.save(self.folder/'injected_checker_control.json',dict(
                    action='Clear generated trace after successful real HDL execution',
                    original_sha256=eda.sha(self.folder/'negative_original_trace.txt')))
            return result
    eda.Flow=RecordingFlow
    print('OUTPUT',batch,flush=True)
    try:
        for test,mutant,propagation in cases:
            state['propagation']=propagation
            options=SimpleNamespace(test=test,deadline=deadline,netlist=[],seed=20261007,
                coverage=False,param=[] if propagation else ['T65_MUTANT='+str(mutant)])
            code=eda.sim(options);folder=state['flow'].folder
            try:
                row=validate_native_control(folder,test,code,propagation)
            except Exception as error:
                row=dict(passed=False,test=test,folder=str(folder),entry_exit=code,error=str(error))
            row.update(mutant=mutant,propagation=propagation);rows.append(row)
            eda.save(batch/'status.json',rows)
            print(json.dumps(row),flush=True)
        passed=all(r['passed'] for r in rows)
        eda.save(batch/'summary.json',dict(passed=passed,cases=len(rows),
            passed_cases=sum(r['passed'] for r in rows),results=rows))
        return int(not passed)
    finally:
        eda.Flow=original_flow


if __name__=='__main__':raise SystemExit(main())
