"""Read or compare the approved T75 fragment prefix; never start a simulator."""
import argparse
from datetime import datetime,timedelta,timezone
import hashlib
import json
from pathlib import Path

import psutil

ROOT=Path(__file__).resolve().parents[1]
FLOW=ROOT/'out/t75/candidate1_source/out/gui_netlist/tb_frag1030_net_gui/20261103_000741_186882'
REFERENCE=ROOT/'out/t75/candidate1_source/out/gui_netlist/tb_frag1030_net_rtl/20261103_000656_614198'
OUTPUT=ROOT/'out/t75/fragment_prefix'
FILES=('tx_a.txt','tx_b.txt','rx.txt','tx_messages.txt','events.txt')
CUTOFF=199578
TZ=timezone(timedelta(hours=8))


def digest(raw):return hashlib.sha256(raw).hexdigest().upper()
def read_json(path):return json.loads(path.read_text(encoding='utf-8-sig'))
def save(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')


def lines(raw):
    """Only LF-terminated records; retain every original byte, including CR."""
    parts=raw.split(b'\n')
    return [part+b'\n' for part in parts[:-1]],parts[-1]


def read_files(folder):return {name:(folder/name).read_bytes() for name in FILES}


def load_plan():
    plan=read_json(ROOT/'out/t75/prefix_plan.json')
    assert (ROOT/plan['flow']).resolve()==FLOW and (ROOT/plan['reference']).resolve()==REFERENCE
    assert plan['cutoff_cycle']==CUTOFF and plan['result_label']=='PASS-PREFIX'
    assert plan['kernel']==dict(pid=33644,created=1793693286.312673)
    assert plan['launcher']==dict(pid=28808,created=1793693286.2756767)
    assert plan['minimum_complete_lines']=={'tx_a.txt':6,'tx_b.txt':6,'rx.txt':4}
    for name,value in plan.get('source_sha256',{}).items():
        assert name in ('t75_prefix.py','t75_prefix_stop.py') and digest((ROOT/'tools'/name).read_bytes())==value,'Prefix controller source changed'
    reference=read_files(REFERENCE)
    assert all(digest(reference[name])==plan['reference_sha256'][name] for name in FILES),'Paired RTL reference changed'
    assert read_json(REFERENCE/'summary.json')['passed'] is True
    assert digest((FLOW/'original.vqm').read_bytes())==plan['vqm_sha256']
    return plan,reference


def prefix_records(raw):
    result={name:b''.join(lines(raw[name])[0][:count]) for name,count in
            (('tx_a.txt',6),('tx_b.txt',6),('rx.txt',4))}
    result['tx_messages.txt']=raw['tx_messages.txt']
    event_rows,tail=lines(raw['events.txt']);events=[];previous=-1
    for row in event_rows:
        fields=row.split()
        if fields and fields[0]==b'FINAL':continue
        if not fields or not fields[0].isdigit():raise ValueError('Malformed event record')
        cycle=int(fields[0])
        if cycle<previous:raise ValueError('Event records are not monotonic')
        previous=cycle
        if cycle<=CUTOFF:events.append(row)
    if tail and (not tail.split()[0].isdigit() or int(tail.split()[0])<=CUTOFF):
        raise ValueError('Incomplete event record inside approved prefix')
    result['events.txt']=b''.join(events)
    return result


def status(raw):
    counts={name:len(lines(raw[name])[0]) for name in FILES}
    ready=all(counts[name]>=count for name,count in (('tx_a.txt',6),('tx_b.txt',6),('rx.txt',4)))
    return dict(ready_to_stop=ready,complete_lines=counts,cutoff_cycle=CUTOFF)


def compare_bytes(actual,reference):
    expected=prefix_records(reference);observed=prefix_records(actual)
    rx=lines(expected['rx.txt'])[0][3].split()
    assert int(rx[1])==CUTOFF and int(rx[2],16)==0x0102 and len(bytes.fromhex(rx[3].decode('ascii')))==1472
    assert len(lines(expected['tx_messages.txt'])[0])==8 and not lines(expected['tx_messages.txt'])[1]
    assert all(int(lines(expected[name])[0][5].split()[0])==197940 for name in ('tx_a.txt','tx_b.txt'))
    comparisons=[]
    for name in FILES:
        a,b=observed[name],expected[name]
        equal=a==b
        first=next((i for i,(x,y) in enumerate(zip(a,b)) if x!=y),min(len(a),len(b))) if not equal else None
        comparisons.append(dict(file=name,equal=equal,actual_sha256=digest(a),reference_sha256=digest(b),
            actual_bytes=len(a),reference_bytes=len(b),records=len(lines(b)[0]),first_difference_byte=first))
    errors=sum(not row['equal'] for row in comparisons)
    return dict(passed=errors==0,items=len(comparisons),errors=errors,comparisons=comparisons,
        compared_records=sum(row['records'] for row in comparisons),
        coverage=dict(cutoff_cycle=CUTOFF,vlid='0x0102',reassembled_payload_bytes=1472,
            rx_record=4,second_fragment_tx_record=6,second_fragment_tx_start=197940,
            networks=['A','B'],full_tx_message_lines=8,events_through_cutoff=len(lines(expected['events.txt'])[0])))


def check():
    plan,reference=load_plan();actual=read_files(FLOW)
    stop=read_json(OUTPUT/'stop_record.json')
    assert stop['kernel']==plan['kernel'] and stop['signal_sent'] is True and stop['ready_before']['ready_to_stop'] is True
    identity=plan['kernel']
    assert not (psutil.pid_exists(identity['pid']) and psutil.Process(identity['pid']).create_time()==identity['created']),'Original fragment kernel is still alive'
    assert status(actual)['ready_to_stop'],'Approved stop boundary was not reached'
    for kind,records in (('actual_raw',actual),('reference_raw',reference)):
        directory=OUTPUT/kind;directory.mkdir(parents=True,exist_ok=True)
        for name,raw in records.items():(directory/name).write_bytes(raw)
    try:result=compare_bytes(actual,reference)
    except Exception as error:result=dict(passed=False,items=5,errors=1,error=str(error))
    result.update(Status='PASS-PREFIX' if result['passed'] else 'FAIL-PREFIX',
        checked=datetime.now(TZ).isoformat(),flow=str(FLOW.relative_to(ROOT)),reference=str(REFERENCE.relative_to(ROOT)),
        cutoff_cycle=CUTOFF,complete_simulation=False,hdl_result_reached=False,
        vqm_sha256=plan['vqm_sha256'],kernel=identity,stop_record=str((OUTPUT/'stop_record.json').relative_to(ROOT)),
        source_sha256=digest(Path(__file__).read_bytes()),raw_sha256={name:digest(value) for name,value in actual.items()},
        deferred_vqm_coverage=['8192-byte complete message','fault recovery'])
    if result['passed']:
        for kind,records in (('actual_prefix',prefix_records(actual)),('reference_prefix',prefix_records(reference))):
            directory=OUTPUT/kind;directory.mkdir(parents=True,exist_ok=True)
            for name,raw in records.items():(directory/name).write_bytes(raw)
    save(OUTPUT/'check_summary.json',result)
    print(json.dumps(result,ensure_ascii=False))
    return 0 if result['passed'] else 1


def selftest():
    _,reference=load_plan();cases=[]
    def verify(name,data,expected):
        try:passed=compare_bytes(data,reference)['passed']
        except (ValueError,AssertionError,IndexError):passed=False
        assert passed==expected,name
        cases.append(dict(case=name,expected_match=expected,passed=True))
    verify('RTL fixture complete data has matching approved prefix',dict(reference),True)
    truncated=prefix_records(reference)
    verify('RTL fixture truncated exactly at approved records',truncated,True)
    for name in ('tx_a.txt','tx_b.txt','rx.txt'):
        data=dict(truncated);data[name]=data[name].replace(b'0',b'1',1)
        verify('reject byte difference in '+name,data,False)
    data=dict(truncated);data['rx.txt']=b''.join(lines(data['rx.txt'])[0][:3]);verify('reject missing fourth RX record',data,False)
    data=dict(truncated);data['tx_a.txt']=b''.join(lines(data['tx_a.txt'])[0][:5]);verify('reject missing sixth A frame',data,False)
    data=dict(truncated);data['tx_messages.txt']+=b'200000 200001 999 1\r\n';verify('reject extra TX message record',data,False)
    data=dict(truncated);data['events.txt']+=b'199578 01 00 00 00 0\r\n';verify('reject extra event inside prefix',data,False)
    data=dict(truncated);data['events.txt']+=b'250000 01 00 00 00 0\r\n';verify('ignore complete events after cutoff',data,True)
    data=dict(truncated);data['events.txt']+=b'199578 01';verify('reject partial event inside prefix',data,False)
    data=dict(truncated);data['tx_b.txt']=data['tx_b.txt'].replace(b'\r\n',b'\n',1);verify('retain exact line-ending byte comparison',data,False)
    save(ROOT/'out/t75/prefix_checker_selftest.json',dict(passed=True,cases=cases,
        source_sha256=digest(Path(__file__).read_bytes()),note='RTL fixtures validate the file comparator only; no VQM acceptance or simulation is performed.'))
    print('[RESULT] prefix_comparator_selftest PASS checks='+str(len(cases))+' errors=0')


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('command',choices=('status','check','selftest'))
    command=parser.parse_args().command
    if command=='selftest':selftest();return 0
    if command=='check':return check()
    load_plan();print(json.dumps(status(read_files(FLOW))));return 0


if __name__=='__main__':raise SystemExit(main())
