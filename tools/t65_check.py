"""Independent checks on captures, events and resource snapshots, after simulation."""
from pathlib import Path
import json
import zlib

def pattern(tag,n):return bytes((tag+j)&255 for j in range(n))

def read(folder):
    rows=[]
    p=Path(folder)/'t65_trace.txt'
    if p.exists():
        rows=[s.split() for s in p.read_text().splitlines() if s.strip()]
    return rows

def check(folder,test,mutant=0):
    rows=read(folder); failures=[];checks=0
    capture_floor={}
    def expect(ok,label):
        nonlocal checks
        checks+=1
        if not ok:failures.append(label)
    def messages(channel):
        out=[]
        for r in rows:
            if r[0]=='M' and r[1]==channel:
                if int(r[2])<=capture_floor.get(channel,-1):continue
                b=bytes.fromhex(r[4]);expect(len(b)==int(r[3]),'capture length '+channel);out.append(b)
        return out
    events={r[1]:int(r[2]) for r in rows if r[0]=='E'}
    if test=='tb_t65_queue_a':
        expect(messages('rx')==[pattern(0x31,1471),pattern(0x51,1),pattern(0x52,1),pattern(0x90,64)],'G1 exact accepted messages including recovery')
        expect(events==dict(good=12,overflow=8,parse_overflow=0,b_events=0,deliver=4),'G1 event conservation, no B/ring event')
        q=[r for r in rows if r[0]=='Q'];expect(len(q)==2,'G1 both drain snapshots')
        for r in q:
            v=list(map(int,r[2:]));expect(v[0]==v[1]==v[2] and v[3]==v[4]==v[5] and v[6:]==[0,0,0],'G1 ring and descriptors idle')
    elif test.startswith('tb_t65_tx_'):
        inputs=[list(map(int,r[1:])) for r in rows if r[0]=='I']
        expect(bool(inputs),'TX first-byte admission capture')
        recovery=-1
        if 'short_' in test:
            rec=[r for r in rows if r[:2]==['S','recovery']]
            expect(len(rec)==1,'TX undocumented one-byte observation isolated from recovery checks')
            if rec:recovery=int(rec[0][2]);capture_floor.update(core=recovery,wire=recovery)
        expected=[];drops=0;misses=0;optional=[]
        for cycle,n,vl,tag,init,desc,used,ready,policy,serial in inputs:
            reject=not init or desc==32 or policy==1
            if n>=2 and reject:drops+=1
            if n>=3 and not reject:
                if test.endswith('_unmapped') and serial==1:misses+=1
                elif policy==2:optional.append(pattern(tag,n-2))
                elif cycle>recovery:expected.append(pattern(tag,n-2))
            elif n==2 and not reject:misses+=1
        core=messages('core');wire=messages('wire')
        expect(core==expected or (optional and core==expected+optional),'TX exact whole admitted messages, ready-low extra observational')
        expect(len(wire)==len(core),'TX every application message becomes one wire frame')
        for b,payload in zip(wire,core):
            expect(b[:8]==b'\x55'*7+b'\xd5','TX wire preamble')
            expect(len(b)>=72 and zlib.crc32(b[8:-4])==int.from_bytes(b[-4:],'little'),'TX independent CRC32')
            expect(b[8:14]==bytes.fromhex('030000004000'),'TX VLID')
            n=int.from_bytes(b[46:48],'big')-8
            expect(n==len(payload) and b[50:50+n]==payload,'TX wire UDP payload and length')
        if 'short_' not in test and not test.endswith('_hint'):
            expect(events.get('overflow')==drops,'TX one overflow event per resource reject')
            expect(events.get('miss')==misses,'TX lookup/empty drop ledger')
        if test.endswith('_space'):
            expect(events.get('max_used')==8192 and events.get('max_count')==8194,'TX maximum-message rollback and oversized count saturation')
        if test.endswith(('_desc','_short_full')):
            expect(any(x[5]==32 for x in inputs),'TX input actually starts with 32 descriptors')
        if test.endswith('_ready'):
            withdrawal=[r for r in rows if r[:2]==['S','withdrawal']]
            expect(bool(withdrawal),'TX legal burst observed ready withdrawal')
            expect(all(x[7]==1 for x in inputs),'TX legal inputs obey ready')
        if test.endswith('_hint'):
            expect(any(x[7]==0 and x[5]<32 and x[6]<32768 and x[8]==2 for x in inputs),'TX hint-only input starts ready-low with resources')
        if 'short_' in test:
            short=[x for x in inputs if x[1]<3]
            expect({x[1] for x in short}=={1,2},'TX 1-byte and VLID-only inputs captured')
            if test.endswith('_short_init'):expect(all(x[4]==0 for x in short),'TX short inputs uninitialized')
            if test.endswith('_short_full'):expect(all(x[5]==32 for x in short),'TX short inputs with actual full descriptor queue')
            if test.endswith('_short_normal'):expect(all(x[4] and x[5]<32 for x in short),'TX short inputs with resources')
            two=[r for r in rows if r[:2]==['S','two_result']]
            expect(len(two)==1 and list(map(int,two[0][2:]))==([0,1] if test.endswith('_short_normal') else [1,0]),'TX documented two-byte result independently separated from one-byte observation')
        q=[r for r in rows if r[:2]==['Q','tx']];expect(bool(q),'TX drain resource snapshot')
        for r in q:
            wp,rp,d=map(int,r[2:]);expect(wp==rp and d==0,'TX pointers and descriptors reclaimed')
    elif test.startswith('tb_t65_rx_'):
        inputs=[list(map(int,r[1:])) for r in rows if r[0]=='J']
        expected=[];rejected=0;desc_reject=0;data_reject=0
        for cycle,n,tag,serial,reject,prev_used,prev_desc,used in inputs:
            bad=prev_used>24575 or prev_desc>=30
            expect(bad==bool(reject),'RX independently evaluate registered admission at '+str(cycle))
            if bad:
                rejected+=1;desc_reject+=prev_desc>=30;data_reject+=prev_used>24575
            else:expected.append(b'\x40\0'+pattern(tag,n))
        expect(messages('rx')==expected,'RX accepted messages exact, rejected messages wholly absent, recovery included')
        expect(expected and expected[-1]==b'\x40\0'+pattern(0x90,64),'RX recovery input accepted')
        expect(events.get('overflow')==rejected,'RX independent drop ledger')
        expect(events.get('data_reject')==data_reject and events.get('desc_reject')==desc_reject,'RX rejection reasons')
        if test.endswith('_data'):expect(data_reject>0 and desc_reject==0,'RX data-only threshold')
        else:expect(desc_reject>0 and data_reject==0,'RX descriptor-only threshold')
        q=[r for r in rows if r[:2]==['Q','rx']];expect(len(q)==2,'RX both drain snapshots')
        for r in q:
            wp,rp,d=map(int,r[2:]);expect(wp==rp and d==0,'RX resources fully recovered')
    elif test.startswith('tb_t65_reset_'):
        pressure=[b'\x41\x00'+pattern(0x10,320),b'\x41\x02'+pattern(0x30,512),b'\x41\x03'+pattern(0x40,17)]
        expect(messages('peer')==pressure*2+[b'\x40\0'+pattern(0x90,64)],'G3 unreset peer exact messages, no partial/old/duplicate')
        expect(messages('target')==[b'\x40\0'+pattern(0xa0,64)],'G3 target fresh receive exact, old RX abandoned')
        r=[x for x in rows if x[0]=='R'];expect(len(r)==1,'G3 one state-aligned reset')
        if r:
            label,state={'rx':('FRAME','2'),'mac':('PREAMBLE','1'),'app':('st1','6')}[test.rsplit('_',1)[1]]
            expect(r[0][3:5]==[label,state],'G3 exact registered target state name and value')
        vectors={phase:[list(map(int,x[3:])) for x in rows if x[:2]==['P',str(phase)]] for phase in (0,1)}
        expect(vectors[0]==vectors[1]==[[1,0,1,1],[0,1,0,0],[1,0,1,1],[1,0,1,1]],'G3 fixed 320/513/512/17 pressure outcome vector before/after')
        q=[r for r in rows if r[:2]==['Q','peer']];expect(len(q)==10,'G3 peer idle snapshots at both probes and recovery')
        for r in q:
            v=list(map(int,r[2:]));expect(v[0]==v[1]==v[2] and v[3]==v[4]==v[5] and v[6:]==[0,0,0],'G3 peer ring/descriptors reclaimed')
        mac=test.endswith('_mac')
        expect(events==dict(good=7,overflow=2,length=int(mac),fcs=0,header=0,deliver=7,other=0,b_events=0),'G3 peer error and delivery ledger')
        actual=messages('wire_target')
        if mac:
            expect(len(actual)==2 and actual[0]==b'\x55'*4,'G3 peer really sees a four-byte truncated preamble')
        else:expect(len(actual)==1,'G3 no old target wire prefix in lookup/RX reset')
        for b in actual[int(mac):]:
            expect(b[:8]==b'\x55'*7+b'\xd5' and zlib.crc32(b[8:-4])==int.from_bytes(b[-4:],'little'),'G3 recovery wire frame CRC')
            expect(b[50:114]==pattern(0x90,64),'G3 recovery wire payload')
        incoming=messages('peer_input')
        expect(len(incoming)==9+int(mac),'G3 all peer input frames captured through direct connection')
        if mac:expect(incoming[4]==b'\x55'*4,'G3 receiver-side prefix capture matches TX')
        from_target_peer=messages('wire_peer')
        expect(len(from_target_peer)==(2 if test.endswith('_rx') else 1),'G3 reverse wire frame count')
        if test.endswith('_rx'):
            expect(from_target_peer[0][50:250]==pattern(0x33,200),'G3 RX FRAME reached after complete old frame')
    else:
        expect(False,'independent checker not implemented for '+test)
    expect(checks>1 and bool(rows),'nonempty independent evidence')
    return dict(passed=not failures,checks=checks,errors=len(failures),failures=failures,mutant=mutant)

if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser();p.add_argument('folder');p.add_argument('test');a=p.parse_args()
    result=check(a.folder,a.test);print(json.dumps(result,ensure_ascii=False,indent=2));raise SystemExit(not result['passed'])
