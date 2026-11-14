"""Run the real application .do entry from a frozen task-owned source tree."""
import argparse
from datetime import datetime, timedelta
import json
from pathlib import Path
import re
import shutil
import subprocess

import eda

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deadline')
    parser.add_argument('--baseline',action='store_true')
    parser.add_argument('--small',action='store_true')
    args=parser.parse_args()
    name=('baseline' if args.baseline else 'isolated')+('_small' if args.small else '_default')
    flow=eda.Flow('app_sim',name,args.deadline)
    flow.result.update(passed=False,baseline=args.baseline)
    try:
        source=flow.folder/'source'
        for name in ('rtl','tb','tools','sim'):
            shutil.copytree(ROOT/name,source/name,ignore=shutil.ignore_patterns('__pycache__','*.pyc','wave'))
        if args.baseline:
            original=subprocess.check_output(['git','show','e4573d22:tb/tb_app_entry.v'],cwd=ROOT)
            (source/'tb/tb_app_entry.v').write_bytes(original)
        stimulus=source/'sim/vectors/app/stimulus.txt'
        if args.small:
            stimulus=source/'sim/vectors/app/small_check.txt'
            stimulus.write_text('0 0100 0102030405060708090a0b0c0d0e0f1011\n1100 0204 '+('5a'*1471)+'\n',encoding='ascii')
        config=source/'sim/vectors/app/vl_config.txt'
        entry=source/'sim/run_app.do'
        do=flow.folder/'entry.do'
        do.write_text('cd {'+source.as_posix()+'}\ndo {'+entry.as_posix()+'} {'+
            stimulus.as_posix()+'} {'+config.as_posix()+'} app_entry\n',encoding='utf-8')
        ms=eda.modelsim_dir()
        log=flow.job('entry',[ms/'vsim.exe','-batch','-l',flow.folder/'transcript.log',
            '-wlf',flow.folder/'entry.wlf','-do','do entry.do'],86400)
        folder=source/'out/app/app_entry'
        if 'APP ENTRY PASS' not in log or 'APP ENTRY FAIL' in log:
            raise RuntimeError('Application .do entry did not pass; see entry.log')
        flow.result.update(passed=True,app_folder=str(folder),records={
            str(p.relative_to(folder)):eda.sha(p) for p in folder.rglob('*.txt')
            if 'vectors' not in p.parts})
        print('APPLICATION ENTRY PASS '+str(folder),flush=True)
        return 0
    except Exception as exc:
        flow.result['error']=str(exc);print('APPLICATION FAIL '+str(exc),flush=True);return 1
    finally:flow.finish()


if __name__=='__main__':raise SystemExit(main())
