"""Single T62 eight-worker CE2 regression entry; no candidate gate is bypassed.

--plan-only freezes case names and parameters without starting ModelSim.
--smoke runs the first eight cases to check the entry, never a full regression.
Candidates still need their own directed cycle comparison before synthesis.
"""
import argparse
import concurrent.futures
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import psutil
import eda
import t62_runtime as runtime

ROOT=Path(__file__).resolve().parents[1]


def cases(root):
    rows=[]
    for line in (root/'sim/tests.txt').read_text(encoding='utf-8-sig').splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields=line.strip().split('|')
        params=fields[1].split(',') if len(fields)>1 and fields[1] else []
        if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*',fields[0]):
            raise ValueError('Invalid test name')
        if any(not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*=\d+',p) for p in params):
            raise ValueError('Invalid test parameter')
        rows.append(dict(test=fields[0],parameters=params))
    return rows


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=ROOT)
    parser.add_argument('--plan-only',action='store_true')
    parser.add_argument('--smoke',action='store_true')
    args=parser.parse_args()
    root=args.root.resolve()
    if root.parent!=ROOT.parent or not root.name.startswith('c3_t62'):
        raise ValueError('Only T62 worktrees are allowed')
    rows=cases(root)
    folder=ROOT/'out/t62/preparation/regression'/datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    folder.mkdir(parents=True)
    plan=dict(root=str(root),workers=8,ce_div=2,case_count=len(rows),cases=rows,
        tests_sha256=eda.sha(root/'sim/tests.txt'),plan_only=args.plan_only,smoke=args.smoke,
        mandatory_after_cases=['check_wrapper','run_app.do small stimulus','candidate directed cycle comparison'],
        budgets_seconds=dict(compile=120,rtl=900,tb_sys_perf=5400,tb_sys_perf_var=14400,
            module_netlist=1800,top_netlist=5400,tb_net_services_top_netlist=28800),
        acceptance='All full cases plus wrapper, app small and directed comparison; 0 Error/FAIL/RAMCOLL')
    runtime.save(folder/'plan.json',plan)
    if args.plan_only:
        print(json.dumps(plan,ensure_ascii=False))
        return 0
    owner=runtime.capture(psutil.Process())
    with runtime.locked_registry() as registry:
        previous=registry.get('regression_owner')
        if previous and runtime.alive(previous):
            raise RuntimeError('The unique eight-worker regression coordinator is already running')
        registry['regression_owner']=owner
    selected=rows[:8] if args.smoke else rows
    results=[]
    try:
        def run(index,row):
            prefix='t62_reg_'+folder.name+'_'+str(index)+'_'
            env=os.environ.copy()
            env.update(AFDX_CE_DIV='2',AFDX_LATEST_PREFIX=prefix)
            command=[sys.executable,'-B',str(root/'tools/t62_runtime.py'),'sim','--test',row['test']]
            for parameter in row['parameters']:
                command+=['--param',parameter]
            with (folder/(str(index)+'_'+row['test']+'.log')).open('xb') as log:
                process=subprocess.Popen(command,cwd=root,env=env,stdout=log,
                    stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
                identity=runtime.capture(psutil.Process(process.pid))
                code=process.wait()
            path=root/'out'/(prefix+'latest_'+row['test']+'.json')
            summary=json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
            return dict(index=index,**row,worker=identity,exit_code=code,summary=str(path),
                passed=code==0 and summary.get('passed') is True,
                folder=summary.get('folder'),diagnostics=summary.get('simulation_diagnostics'))
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            futures=[pool.submit(run,index,row) for index,row in enumerate(selected)]
            for future in concurrent.futures.as_completed(futures):
                results.append(future.result())
                runtime.save(folder/'status.json',dict(owner=owner,results=sorted(results,key=lambda r:r['index'])))
        passed=len(results)==len(selected) and all(row['passed'] for row in results)
        runtime.save(folder/'result.json',dict(**plan,results=sorted(results,key=lambda r:r['index']),
            entry_smoke_passed=passed if args.smoke else None,full_case_set_passed=passed if not args.smoke else None,
            candidate_regression_passed=None,remaining_acceptance=plan['mandatory_after_cases']))
        print(str(folder/'result.json'))
        return 0 if passed else 1
    finally:
        with runtime.locked_registry() as registry:
            if registry.get('regression_owner')==owner:
                registry['regression_owner']=None


if __name__=='__main__':
    raise SystemExit(main())
