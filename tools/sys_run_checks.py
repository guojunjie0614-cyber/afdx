"""逐一运行四份原有核对，再运行系统记录核对。"""
import sys
sys.dont_write_bytecode=True
import argparse
import json
from pathlib import Path
import tx_ref
import rx_ref
import sys_ref
import gmii_ref

def run(test,folder):
    from verification_profile import selected
    profile=selected()
    reports={}
    for sub,checker in (("es1_tx",tx_ref),("es2_tx",tx_ref),("es1_rx",rx_ref),("es2_rx",rx_ref)):
        result=checker.check(test+"_"+sub,folder/sub)
        (folder/sub/'check_summary.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
        reports[sub]=result
    reports['system']=sys_ref.check(test,folder)
    reports['gmii']=reports['system'].pop('gmii')
    gmii_ref.emit(reports['gmii'])
    result=dict(test=test,verification_profile=profile,items=sum(r['items'] for r in reports.values()),errors=sum(r['errors'] for r in reports.values()),reports=reports)
    if test in ('tb_sys_perf','tb_sys_perf_var'):
        from perf_ref import measure_r97, check_r97_var
        result['r97_fields']=len(measure_r97(folder))
        if test=='tb_sys_perf_var':
            measured=dict(line.split('\t') for line in (folder/'r97_python.tsv').read_text().splitlines())
            def number(value):
                if value=='NA':return value
                try:return int(value)
                except ValueError:return float(value)
            measured={k:number(v) for k,v in measured.items()}
            requirements=check_r97_var(folder,measured)
            result['r97_requirement_failures']=sum(row['status']=='FAIL' for row in requirements)
            result['errors']+=result['r97_requirement_failures']
    (folder/'check_summary.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    return result

def run_netlist(test,folder,reference):
    """L5 external-only gate; no invented results for inaccessible slow nets."""
    items=errors=0;diagnostics=[]
    def expect(ok,label):
        nonlocal items,errors
        items+=1
        if not ok:
            errors+=1
            if len(diagnostics)<30:diagnostics.append(label)
    baseline=json.loads((reference/'check_summary.json').read_text())
    expect(baseline['errors']==0 and len(baseline.get('reports',{}))==6,'netlist reference is a passed six-check RTL run')
    captures={}
    for es in (1,2):
        for kind in ('tx','rx'):
            sub=f'es{es}_gmii_{kind}'
            captures[es,kind]={}
            for net in ('A','B'):
                file=sub+'/dump_'+net.lower()+'.txt'
                expect((folder/file).read_bytes()==(reference/file).read_bytes(),'netlist exact GMII capture '+file)
                caps=gmii_ref.capture(folder/sub,net,1,expect);captures[es,kind][net]=caps
                for a,b in zip(caps,caps[1:]):expect(b['start']-a['end']>=12,'netlist GMII IFG >=12')
        def deliveries(base):
            return [line for line in (base/f'es{es}_rx/events.txt').read_text(encoding='ascii').splitlines() if line.startswith('D ')]
        expect(deliveries(folder)==deliveries(reference),f'netlist exact ES{es} D rows')
    expect((folder/'sys_events.txt').read_bytes()==(reference/'sys_events.txt').read_bytes(),'netlist exact sys_events')
    events=sys_ref.rows(folder/'sys_events.txt')
    for link in range(4):
        source=1 if link<2 else 2;destination=3-source;net='AB'[link%2]
        source_frames=captures[source,'tx'][net];wanted=[]
        local=[(c,p) for c,_,p in events if p[0] in ('L','A','R','J') and int(p[2])==link]
        delays=[(c,int(p[3])) for c,p in local if p[0]=='L']
        actions={int(p[3]):p for c,p in local if p[0]=='A'}
        for number,f in enumerate(source_frames,1):
            opts=[d for c,d in delays if c<=f['start']];expect(bool(opts),'netlist X3 delay specified')
            delay=opts[-1] if opts else 0;action=actions.get(number);wire=bytearray(f['wire'])
            if action and action[4] in ('drop','hold'):continue
            if action and action[4]=='xor':wire[int(action[5])]^=int(action[6],16)
            wanted.append((f['start']+delay,bytes(wire)))
        for _,p in local:
            if p[0]=='R':wanted.append((int(p[4]),source_frames[int(p[3])-1]['wire']))
            elif p[0]=='J':wanted.append((int(p[3]),bytes.fromhex(p[5])))
        got=[(f['start'],f['wire']) for f in captures[destination,'rx'][net]]
        expect(got==sorted(wanted),f'netlist X3 link {link} exact transformation')
    for label in diagnostics:print('[CHECK_FAIL] '+label)
    print(f'[CHECK] {test}_external {"PASS" if errors==0 else "FAIL"} items={items} errors={errors} either=0')
    report=dict(test=test+'_external',items=items,errors=errors,either=0,diagnostics=diagnostics,
                rtl_reference=str(reference),omitted='four slow-core checks and internal X1/X4; L5 external parity instead')
    result=dict(test=test,items=items,errors=errors,reports={'external':report})
    (folder/'check_summary.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--test',required=True);p.add_argument('--dir',type=Path,required=True)
    p.add_argument('--netlist',action='store_true');p.add_argument('--rtl-reference',type=Path)
    a=p.parse_args()
    if a.netlist and a.rtl_reference is None:p.error('--netlist requires --rtl-reference')
    result=run_netlist(a.test,a.dir,a.rtl_reference) if a.netlist else run(a.test,a.dir)
    raise SystemExit(int(result['errors']!=0))
