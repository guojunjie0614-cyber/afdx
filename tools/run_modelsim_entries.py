"""Execute original ModelSim Tcl entries against isolated compatible sources."""
import argparse
from datetime import datetime, timedelta
import os
from pathlib import Path
import re
import shutil
import sys

sys.path.insert(0,str(Path(__file__).resolve().parent))
import eda
from modelsim_compat import adapt_text


def prepare_tree(target):
    originals=[];changes=[]
    paths=[]
    for sub in ('rtl','tb'):
        paths.extend(p for p in (eda.ROOT/sub).rglob('*') if p.suffix in ('.v','.vh'))
    paths.extend((eda.ROOT/'sim').glob('*.do'))
    paths.extend((eda.ROOT/'sim').glob('*.tcl'))
    paths.extend(p for p in (eda.ROOT/'sim/wave').rglob('*') if p.is_file())
    paths.extend(p for p in (eda.ROOT/'sim/vectors').rglob('*') if p.is_file())
    paths.extend((eda.ROOT/'tools').glob('*.py'))
    for path in paths:
        rel=path.relative_to(eda.ROOT)
        dest=target/rel;dest.parent.mkdir(parents=True,exist_ok=True)
        originals.append(dict(path=str(path),sha256=eda.sha(path)))
        raw=path.read_bytes()
        if path.suffix in ('.v','.vh'):
            text,records=adapt_text(rel.as_posix(),raw.decode('utf-8-sig'))
            text,count=re.subn(r'\$finish_and_return\(1\)','$fatal(1)',text)
            if count:records.append(dict(path=rel.as_posix(),action='portable_failure_exit',count=count))
            optional={'rtl/afdx_app_tx.v':('.read_data(memory_q));','.read_data(memory_q),.raw_write_data());'),
                      'rtl/afdx_app_rx.v':('.data(q_data));','.data(q_data),.next_limit());')}
            if rel.as_posix() in optional:
                old,new=optional[rel.as_posix()]
                if text.count(old)==1:
                    text=text.replace(old,new);records.append(dict(path=rel.as_posix(),action='explicit_open_optional_input'))
                elif text.count(new)!=1:
                    raise ValueError('Optional port input changed: '+str(rel))
            raw=text.encode('utf-8');changes.extend(records)
        dest.write_bytes(raw)
    eda.save(target/'original_inputs.json',originals)
    eda.save(target/'modelsim_adaptations.json',changes)
    return originals


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('entry',choices=('judge','app_default','app_long'))
    parser.add_argument('--prepare-only',action='store_true')
    args=parser.parse_args()
    os.environ['AFDX_VERIFICATION_PROFILE']='fragmentation1030'
    os.environ['AFDX_PYTHON']=sys.executable
    os.environ['AFDX_CE_DIV']='2'
    os.environ.pop('AFDX_JUDGE_CASE',None)
    deadline=(datetime.now().astimezone()+timedelta(hours=8)).isoformat()
    flow=eda.Flow('report_entry',args.entry,deadline)
    try:
        root=flow.folder/'project';originals=prepare_tree(root)
        flow.result.update(entry=args.entry,verification_profile='fragmentation1030',
            root=str(root),inputs=originals)
        if args.prepare_only:
            flow.result.update(prepared=True,passed=False,execution='not launched')
            print('PREPARED',root,flush=True)
            return 0
        command='do sim/run_judge.do'
        expected='JUDGE ENTRY PASS cases=8 warnings=0'
        if args.entry=='app_default':
            command='do sim/run_app.do'
            expected='APP ENTRY PASS'
        elif args.entry=='app_long':
            flow.job('long_vectors',[sys.executable,eda.ROOT/'tools/gen_app_vectors.py','--long','--out',root/'sim/vectors/app_long'],60)
            command='do sim/run_app.do sim/vectors/app_long/stimulus.txt sim/vectors/app_long/vl_config.txt current_long'
            expected='APP ENTRY PASS'
        log=flow.job('entry',[eda.modelsim_dir()/'vsim.exe','-batch','-do',command],7*3600,cwd=root)
        if expected not in log or re.search(r'(?m)^.*(?:ENTRY FAIL|\*\* (?:Error|Fatal|Warning))',log):
            raise RuntimeError('Native Tcl entry did not pass; see entry.log')
        # Snapshot original sources at launch. Unrelated live edits cannot alter
        # the isolated run, but are still disclosed rather than erased.
        changed=[row['path'] for row in originals if eda.sha(Path(row['path']))!=row['sha256']]
        flow.result.update(passed=True,changed_originals=changed)
        print('ENTRY PASS',args.entry,'OUTPUT',flow.folder,flush=True)
        return 0
    except Exception as error:
        flow.result.update(passed=False,error=str(error));print('ENTRY FAIL',args.entry,error,flush=True)
        return 1
    finally:flow.finish()


if __name__=='__main__':raise SystemExit(main())
