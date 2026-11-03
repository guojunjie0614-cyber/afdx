"""Recheck copied captures with current public-point definitions; no simulation."""
import argparse
from datetime import datetime,timedelta
import json
from pathlib import Path
import shutil
import sys

import eda

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--label',choices=('baseline','actual'),required=True)
    args=parser.parse_args()
    flow=eda.Flow('t76_perf_check',args.label,(datetime.now(eda.REPORT_TZ)+timedelta(minutes=20)).isoformat())
    flow.result.update(passed=False,simulation_launched=False,source=str(args.source.resolve()),
        checker_sha256=eda.sha(ROOT/'tools/perf_ref.py'),source_receipt=eda.sha(args.source/'summary.json') if (args.source/'summary.json').exists() else None)
    try:
        captures=flow.folder/'captures';captures.mkdir()
        inputs={}
        for path in args.source.rglob('*.txt'):
            relative=path.relative_to(args.source)
            if any(part in ('sources','modelsim_rtl','work') for part in relative.parts):continue
            target=captures/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,target)
            inputs[str(path)]=eda.sha(path)
        flow.job('check',[sys.executable,'-B','-X','utf8',ROOT/'tools/sys_run_checks.py',
            '--test','tb_sys_perf','--dir',captures],900)
        checked=json.loads((captures/'check_summary.json').read_text(encoding='utf-8'))
        flow.result.update(passed=checked['errors']==0,items=checked['items'],errors=checked['errors'],
                           captures=str(captures),inputs=inputs)
        print('T76 CURRENT PUBLIC-POINT CHECK '+args.label+' '+str(checked['items'])+' errors='+str(checked['errors']))
        return 0 if flow.result['passed'] else 1
    except Exception as exc:
        flow.result['error']=str(exc);print('T76 CURRENT CHECK FAIL '+str(exc));return 1
    finally:flow.finish()


if __name__=='__main__':raise SystemExit(main())
