"""Narrow evidence review for the unused app_cfg_ready TB output connection."""
import hashlib
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
TARGET=ROOT/'tb/lib/top_stream_endpoint.v'
# No arbitrary hash allowlist: the entire old source must transform into the
# entire current source using exactly these two reviewed, logic-free edits.
EDITS=(
    ('    generate if(DIRECT_CORE)begin:direct\n        afdx_es',
     '    generate if(DIRECT_CORE)begin:direct\n        wire [1:0] app_cfg_ready_unused;\n        afdx_es'),
    ('            .ev_tx(ev_tx),.ev_a(ev_a),.ev_b(ev_b),.ev_rm_drop(ev_rm_drop),.ev_deliver(ev_deliver));',
     '            .ev_tx(ev_tx),.ev_a(ev_a),.ev_b(ev_b),.ev_rm_drop(ev_rm_drop),.ev_deliver(ev_deliver),.app_cfg_ready(app_cfg_ready_unused));'),
)

def digest(data):
    return hashlib.sha256(data).hexdigest().upper()

def text(data):
    return data.decode('utf-8-sig').replace('\r\n','\n')

def review_inputs(summary,folder,allow_unused_output=False):
    changes=[]
    for index,source in enumerate(summary['inputs']):
        path=Path(source['path'])
        current=path.read_bytes()
        if digest(current)==source['sha256'].upper():
            continue
        if not allow_unused_output or path.resolve()!=TARGET.resolve():
            raise RuntimeError('Changed input dependency: '+str(path))
        saved=Path(folder)/'sources'/(str(index)+'_'+path.name)
        before=saved.read_bytes()
        if digest(before)!=source['sha256'].upper():
            raise RuntimeError('Original TB snapshot identity differs: '+str(saved))
        expected=text(before)
        for old,new in EDITS:
            if expected.count(old)!=1:
                raise RuntimeError('Unreviewed original port-connection source')
            expected=expected.replace(old,new,1)
        if text(current)!=expected or expected.count('app_cfg_ready_unused')!=2:
            raise RuntimeError('TB differs beyond the unused output sink connection')
        # Direction/width come from the same frozen DUT input, never inferred
        # from a port name. Every other input is checked normally above/below.
        declarations=[(i,r) for i,r in enumerate(summary['inputs'])
                      if Path(r['path']).resolve()==(ROOT/'rtl/afdx_es.v').resolve()]
        if len(declarations)!=1:
            raise RuntimeError('Missing unique afdx_es declaration identity')
        i,record=declarations[0]
        original=(Path(folder)/'sources'/(str(i)+'_afdx_es.v')).read_bytes()
        if digest(original)!=record['sha256'].upper() or not re.search(
                r'output\s+wire\s+\[1:0\]\s+app_cfg_ready\s*\)',text(original)):
            raise RuntimeError('Recorded app_cfg_ready is not the reviewed two-bit output')
        changes.append(dict(path=str(path),original_sha256=source['sha256'],
            current_sha256=digest(current),snapshot=str(saved),
            review='Exact two edits only: connect existing two-bit output to a new otherwise-unused wire in DIRECT_CORE; no DUT, stimulus, checker or behavior change'))
    return changes

def accept_positive(summary,folder,allow_unused_output=False):
    if summary.get('error') or any(summary.get('simulation_diagnostics',{}).values()):
        raise RuntimeError('Diagnosed or interrupted native input: '+str(folder))
    if summary.get('result')!='PASS' or summary.get('errors')!=0:
        raise RuntimeError('HDL did not pass: '+str(folder))
    if any(job['exit_code']!=0 or job.get('stop_reason') for job in summary['jobs']):
        raise RuntimeError('Unsuccessful tool job: '+str(folder))
    if 'check' in summary and summary['check'].get('errors')!=0:
        raise RuntimeError('Independent checker did not pass: '+str(folder))
    changes=review_inputs(summary,folder,allow_unused_output)
    if not summary.get('passed'):
        # eda.sim's only remaining false predicate after these checks is its
        # original byte-identity test. Preserve its false result and re-evaluate
        # this exact nonfunctional source difference in a separate acceptance.
        if len(changes)!=1 or not summary.get('check'):
            raise RuntimeError('Raw failed input is not solely reviewed source drift')
        log=(Path(folder)/'simulation.log').read_text(encoding='utf-8-sig',errors='replace')
        rows=re.findall(r'\[RESULT\]\s+(\w+)\s+(PASS|FAIL)\s+checks=(\d+)\s+errors=(\d+)',log)
        if (not rows or rows[-1][0]!=summary['name'] or
                any(status!='PASS' or int(errors)!=0 for _,status,_,errors in rows)):
            raise RuntimeError('Original HDL transcript does not independently pass')
    return dict(raw_summary_passed=summary['passed'],reviewed_nonfunctional_changes=changes,
                acceptance='raw_positive' if summary['passed'] else 'same_capture_source_identity_recheck')
