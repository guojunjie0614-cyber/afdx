"""Finite mixed-VL binary search and one 100ms margin confirmation; no retries."""
import argparse
from datetime import datetime,timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import sys

import eda

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deadline')
    args=parser.parse_args()
    flow=eda.Flow('load_search','tb_t76_mixed_search',args.deadline)
    flow.result.update(passed=False,probes=[],final_run=None,
        scope='Confirmed 22:40 mixed-profile search; 81-VL maximum short profile unchanged',
        baseline_rtl={p.name:eda.sha(p) for p in sorted((ROOT/'rtl').glob('*.v'))})
    prefix=os.environ.get('AFDX_LATEST_PREFIX','')
    seen=set()

    def run(vls,duration,final=False):
        key=vls,duration
        if key in seen:raise RuntimeError('Refusing an implicit search retry')
        seen.add(key)
        command=[sys.executable,'-B','-X','utf8',str(ROOT/'tools/run_load_sim.py'),
            *(['--deadline',args.deadline] if args.deadline else []),
            '--param','VL_COUNT='+str(vls),'--param','GROUP_LENGTH=1471',
            '--param','MIXED=1','--param','DURATION='+str(duration)]
        tool='confirm_'+str(vls) if final else 'probe_'+str(vls)
        try:flow.job(tool,command,86400)
        except RuntimeError:pass
        path=ROOT/'out'/(prefix+'latest_tb_t76_load.json')
        if not path.is_file():raise RuntimeError('Search child produced no final receipt')
        receipt=json.loads(path.read_text(encoding='utf-8'))
        params=receipt.get('parameters',{})
        if params.get('VL_COUNT')!=vls or params.get('DURATION')!=duration:
            raise RuntimeError('Search receipt does not bind this probe')
        folder=Path(receipt['folder'])
        log=(folder/'simulation.log').read_text(encoding='utf-8',errors='replace') if (folder/'simulation.log').exists() else ''
        infrastructure=any(j.get('stop_reason') for j in receipt.get('jobs',[]))
        functional=bool(re.search(r'\*\* Fatal: (T76|\[XZ_FAIL\])',log))
        if receipt.get('passed') is True:status='PASS'
        elif functional and not infrastructure:status='FAIL_DESIGN'
        else:status='STOP_INFRASTRUCTURE'
        row=dict(vls=vls,duration_cycles=duration,planned_ms=duration*.000008,
            status=status,folder=str(folder),summary_sha256=eda.sha(path),
            first_failure=next((line for line in log.splitlines() if '** Fatal:' in line),None),
            process=flow.jobs[-1] if flow.jobs else None)
        if final:flow.result['final_run']=row
        else:flow.result['probes'].append(row)
        eda.save(flow.folder/'progress.json',flow.result)
        print('MIXED SEARCH '+status+' vls='+str(vls)+' ms='+str(row['planned_ms']),flush=True)
        if status=='STOP_INFRASTRUCTURE':raise RuntimeError('Infrastructure stop is not a failing VL boundary')
        return status=='PASS'

    try:
        # 81 is already a confirmed functional overflow of this unchanged RTL.
        flow.result['known_upper_failure']=dict(vls=81,first_event_cycle=450556,
            ev_a='80',ev_b='01',note='Confirmed mixed-profile overflow baseline; not rerun')
        high=81;low=None;candidate=64
        while low is None or high-low>1:
            passed=run(candidate,2500000)
            if passed:low=candidate
            else:high=candidate
            if low is None:
                if candidate==3:raise RuntimeError('Even the three-long-VL minimum has no passing mixed profile')
                candidate=max(3,candidate//2)
            elif high-low>1:candidate=(low+high)//2
        margin=(low*9)//10
        if margin<3 or margin>=low:
            raise RuntimeError('No profile can retain three long VLs and at least ten percent margin')
        flow.result.update(maximum_observed_passing_vls=low,adjacent_failing_vls=high,
            boundary_scope='Adjacent binary-search boundary for the fixed deterministic stimulus; monotonicity assumed, not an exhaustive VL sweep',
            declared_candidate_vls=margin,margin_fraction=1-margin/low)
        passed=run(margin,12500000,True)
        flow.result.update(passed=passed,declared_mixed_vls=margin if passed else None,
            completed=True,scope='81-VL short profile unchanged; mixed declaration only if 100ms confirmation passed')
        return 0 if passed else 1
    except Exception as exc:
        flow.result['error']=str(exc);print('MIXED SEARCH STOP '+str(exc),flush=True);return 1
    finally:flow.finish()


if __name__=='__main__':raise SystemExit(main())
