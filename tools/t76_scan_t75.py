"""Read-only scan of T75 captures; never stop or write a T75 process/file."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re

import psutil

from gui_netlist import RECORDS, FRAGMENT_RECORDS


def scan(manifest):
    answer=[]
    for item in json.loads(Path(manifest).read_text(encoding='utf-8')):
        folder=Path(item['folder']);summary=folder/'summary.json'
        result=json.loads(summary.read_text(encoding='utf-8')) if summary.is_file() else None
        if item['test']=='tb_elinx':
            answer.append(dict(test=item['test'],status='NO_CAPTURE',
                t75_passed=result.get('passed') if result else None,
                note='Covered by new monitored VQM windows; no T75 rerun requested'))
            continue
        active=False
        try:active=psutil.Process(item['pid']).create_time()==item['created']
        except psutil.NoSuchProcess:pass
        files=[];hits=[]
        names=RECORDS if item['test']=='tb_net_services' else FRAGMENT_RECORDS
        for name in names:
            path=folder/name
            if not path.is_file():
                files.append(dict(name=name,present=False));continue
            data=path.read_bytes();complete=data.rsplit(b'\n',1)[0] if active and not data.endswith(b'\n') else data
            for line_number,line in enumerate(complete.decode('ascii').splitlines(),1):
                for field,token in enumerate(line.split(),1):
                    # These captures use bare %x fields, not 0x literals. A
                    # token such as "0x" is itself an unknown nibble, not a
                    # prefix to strip before checking.
                    value=token
                    if re.fullmatch('[0-9a-fA-FxXzZ]+',value) and re.search('[xXzZ]',value):
                        hits.append(dict(file=name,line=line_number,field=field,value=token[:128]))
            files.append(dict(name=name,present=True,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
        prefix_path=Path('E:/2026_Embedded_FPGA/worktrees/active/c3_frag1030/out/t75/fragment_prefix/check_summary.json')
        prefix=None;prefix_valid=False
        if item['test']=='tb_frag1030_net' and prefix_path.is_file():
            prefix=json.loads(prefix_path.read_text(encoding='utf-8'))
            hashes={r['name']:r.get('sha256','').upper() for r in files}
            prefix_valid=(not active and prefix.get('passed') is True and prefix.get('Status')=='PASS-PREFIX'
                and prefix.get('cutoff_cycle')==199578
                and prefix.get('kernel')==dict(pid=item['pid'],created=item['created'])
                and prefix.get('vqm_sha256','').lower()=='3cd8f5f8456c9881d083fe67dd7a60ed9c6779909ee1cb10dbf9367dc9729b6e'
                and all(hashes.get(name)==value for name,value in prefix.get('raw_sha256',{}).items())
                and len(prefix.get('raw_sha256',{}))==5)
        answer.append(dict(test=item['test'],folder=str(folder),process_active=active,
            status='FAIL_XZ' if hits else 'MISSING_CAPTURE' if any(not r['present'] for r in files) else
                'PASS_PREFIX_NO_XZ' if prefix_valid else
                'PREFIX_NO_XZ_PENDING_FINAL' if active or not result else
                'PASS_NO_XZ' if result.get('passed') is True else 'NO_XZ_BUT_T75_RESULT_NOT_PASSED',
            t75_passed=result.get('passed') if result else None,prefix_receipt=prefix,
            prefix_receipt_valid=prefix_valid,hits=hits,files=files))
    return dict(scanned_at=datetime.now(timezone(timedelta(hours=8))).strftime('%Y-%m-%d %H:%M:%S'),
        scope='All numeric/hex capture fields. Active files are prefixes only; no final T75 acceptance inferred.',runs=answer)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();result=scan(args.manifest)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps([(r['test'],r['status']) for r in result['runs']]))
