"""Current-report native RTL/UCDB execution with bounded parallelism."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import sys
import threading
from types import SimpleNamespace

sys.path.insert(0,str(Path(__file__).resolve().parent))
import eda


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases',nargs='*')
    parser.add_argument('--workers',type=int,choices=(1,2),default=2)
    parser.add_argument('--profile',choices=('legacy','fragmentation1030'),default='fragmentation1030')
    parser.add_argument('--no-coverage',action='store_true')
    parser.add_argument('--extra',action='append',default=[])
    args=parser.parse_args()
    os.environ['AFDX_VERIFICATION_PROFILE']=args.profile
    os.environ['AFDX_LATEST_PREFIX']='report_native_'
    entries=args.cases or [line.strip() for line in (eda.ROOT/'sim/tests.txt').read_text().splitlines() if line.strip()]
    entries=list(dict.fromkeys(entries+args.extra))
    # Keep complete performance windows and start the slowest jobs first.
    order={'tb_sys_perf_var':0,'tb_sys_perf':1,'tb_t65_rx_data':2,'tb_tx_drop':3}
    entries.sort(key=lambda s:order.get(s.partition('|')[0],10))
    folder=eda.ROOT/'out/report_native'/datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    folder.mkdir(parents=True)
    context=threading.local();original=eda.Flow;lock=threading.Lock();results=[]
    class RecordingFlow(original):
        def __init__(self,*a,**kw):
            super().__init__(*a,**kw)
            context.flow=self
    eda.Flow=RecordingFlow
    deadline=(datetime.now().astimezone()+timedelta(hours=8)).isoformat()
    eda.save(folder/'manifest.json',dict(cases=entries,workers=args.workers,seed=20261007,
        profile=args.profile,coverage=not args.no_coverage,deadline=deadline,
        simulator=str(eda.modelsim_dir()),source_identity='per-case immutable inputs in summary.json'))
    print('OUTPUT '+str(folder),flush=True)
    def execute(entry):
        test,_,params=entry.partition('|')
        options=SimpleNamespace(test=test,deadline=deadline,netlist=[],seed=20261007,
            param=params.split(',') if params else [],coverage=not args.no_coverage)
        code=eda.sim(options)
        row=dict(case=entry,exit_code=code,folder=str(context.flow.folder),
                 passed=context.flow.result.get('passed',False))
        with lock:
            results.append(row);eda.save(folder/'status.json',results)
        print(json.dumps(row),flush=True)
        return row
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures=[pool.submit(execute,entry) for entry in entries]
        for future in as_completed(futures):future.result()
    passed=all(row['passed'] for row in results)
    eda.save(folder/'summary.json',dict(passed=passed,cases=len(results),
        passed_cases=sum(r['passed'] for r in results),results=results))
    print('NATIVE '+('PASS ' if passed else 'FAIL ')+str(folder),flush=True)
    return int(not passed)


if __name__=='__main__':raise SystemExit(main())
