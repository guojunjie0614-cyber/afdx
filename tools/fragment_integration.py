"""Build independent integration input and check public-pin capture files."""
import argparse
from collections import defaultdict, deque
from pathlib import Path
import struct
import zlib
import fragment_ref as ref


def pattern(tag, n): return bytes((i*19+tag*37+(tag >> (i%3))) & 255 for i in range(n))

def write_bytes(path, data): path.write_text(''.join('%02x\n'%x for x in data),encoding='ascii')
def config(path, rows):
    path.write_text(str(len(rows))+'\n'+''.join('%d %d %d %d %d\n'%r for r in rows),encoding='ascii')

def prepare(out):
    v=out/'vectors';v.mkdir(parents=True,exist_ok=True)
    if (v/'window.txt').exists(): (v/'window.txt').unlink()
    rows=[(x,1000,1471,1000,2000) for x in (0x100,0x101,0x102,0x103,0x104,0x300,0x301,0x302,0x303,0x304,0x305)]
    rows.append((0x105,1000,16,1000,2000))
    config(v/'config.txt',rows)
    # Overlap independent VLs while retaining a real 1 ms per-fragment BAG.
    lengths=(1464,1471,1472,8192,17,8193,17); ids=(0x100,0x101,0x102,0x103,0x104,0x104,0x105)
    times=(0,2000,4000,6000,15000,20000,30000)
    data=b''; schedule=[]
    for tag,(n,vl,due) in enumerate(zip(lengths,ids,times),1):
        schedule.append((due,vl,n,len(data)));data+=pattern(tag,n)
    write_bytes(v/'payload.hex',data)
    (v/'schedule.txt').write_text('%d %d %d\n'%(len(schedule),len(data),len(schedule)-2)+''.join('%d %d %d %d\n'%r for r in schedule),encoding='ascii')
    wire=bytearray(); commands=[]
    def emit(net,frame):
        frame=bytearray(frame)
        if net==2:
            was_valid=zlib.crc32(frame[:-4])==int.from_bytes(frame[-4:],'little')
            frame[11]=0x40;frame[-4:]=struct.pack('<I',zlib.crc32(frame[:-4]) ^ (0 if was_valid else 1))
        # Let a completed 8 KiB application delivery drain before the next independent scenario.
        gap=10000 if (int.from_bytes(frame[20:22],'big') & 0x1fff)==0 else 512
        raw=ref.PREAMBLE+bytes(frame);commands.append((net,len(wire),len(raw),gap));wire.extend(raw)
    # Complementary loss: each successive frame has forward SN on its chosen network.
    fs=ref.build(pattern(30,8192),vlid=0x300,ident=0x301,sn=1)
    for i,f in enumerate(fs):
        emit(1 if i%2==0 else 2,f)
        if i==0: emit(2,f)  # redundant copy, after the first copy
    # FCS failure on A, good B copy with identical SN, then completion on A.
    fs=ref.build(pattern(31,1472),vlid=0x301,ident=0x302,sn=1)
    bad=bytearray(fs[0]);bad[-1]^=1;emit(1,bad);emit(2,fs[0]);emit(1,fs[1])
    # Overlap destroys a context; a later valid datagram proves recovery.
    fs=ref.build(pattern(32,1472),vlid=0x302,ident=0x303,sn=1)
    overlap=bytearray(fs[1]);overlap[20:22]=struct.pack('!H',1);overlap[24:26]=b'\0\0';overlap[24:26]=struct.pack('!H',ref.checksum(overlap[14:34]));overlap[-4:]=struct.pack('<I',zlib.crc32(overlap[:-4]));emit(1,fs[0]);emit(1,overlap)
    for f in ref.build(pattern(33,1472),vlid=0x302,ident=0x304,sn=3): emit(1,f)
    # Bad nonzero UDP checksum, followed by recovery on the same VL.
    fs=ref.build(pattern(34,1472),vlid=0x303,ident=0x305,sn=1)
    bad=bytearray(fs[1]);bad[34]^=1;bad[-4:]=struct.pack('<I',zlib.crc32(bad[:-4]))
    emit(1,fs[0]);emit(1,bad)
    for f in ref.build(pattern(35,1472),vlid=0x303,ident=0x306,sn=3): emit(1,f)
    # Incomplete datagram and valid new ID: no partial application output.
    fs=ref.build(pattern(36,1472),vlid=0x304,ident=0x307,sn=1);emit(1,fs[0])
    for f in ref.build(pattern(37,1472),vlid=0x304,ident=0x308,sn=2):emit(1,f)
    # MF fragment with non-eight-byte IP data; valid datagram follows.
    fs=ref.build(pattern(38,1472),vlid=0x305,ident=0x309,sn=1)
    bad=bytearray(fs[0]);bad[16:18]=struct.pack('!H',1491);bad[24:26]=b'\0\0';bad[24:26]=struct.pack('!H',ref.checksum(bad[14:34]));bad[-4:]=struct.pack('<I',zlib.crc32(bad[:-4]));emit(1,bad)
    # SN 2 is the next or permitted second SN depending on where the malformed frame was rejected.
    for f in ref.build(pattern(39,1472),vlid=0x305,ident=0x30a,sn=2):emit(1,f)
    write_bytes(v/'injection.hex',wire)
    (v/'injection.txt').write_text('%d %d\n'%(len(commands),len(wire))+''.join('%d %d %d %d\n'%c for c in commands),encoding='ascii')
    print('Generated %d injection frames and %d TX messages'%(len(commands),len(schedule)))

def records(path):
    with path.open(encoding='ascii') as f:
        for line in f:
            if line.strip(): yield line.split()

def read_schedule(out):
    v=out/'vectors'; lines=list(records(v/'schedule.txt')); _,count,target=map(int,lines[0]); data=bytes(int(x[0],16) for x in records(v/'payload.hex'))
    if len(data)!=count: raise ValueError('payload file length')
    return [(int(t),int(vl),data[int(o):int(o)+int(n)]) for t,vl,n,o in lines[1:]],target

def check(out, app=False):
    schedule,target=read_schedule(out)
    cfgrows=list(records(out/'vectors/config.txt'))[1:]
    configs={int(r[0]):int(r[1]) for r in cfgrows}
    config_lmax={int(r[0]):int(r[2]) for r in cfgrows}
    def accepted(vl,payload): return len(payload)<=8192 and not (len(payload)<=1471 and len(payload)>config_lmax[vl])
    expected=defaultdict(deque)
    for _,vl,payload in schedule:
        if accepted(vl,payload): expected[vl].append(payload)
    if not app:
        for vl,tag,n in [(0x300,30,8192),(0x301,31,1472),(0x302,33,1472),(0x303,35,1472),(0x304,37,1472),(0x305,39,1472)]: expected[vl].append(pattern(tag,n))
    inputs=[]; epoch=None
    for row in records(out/'tx_messages.txt'):
        if row[0]=='E':epoch=int(row[1]);continue
        start,end,vl,n=map(int,row);inputs.append((start,end,vl,n))
    if len(inputs)!=len(schedule) or epoch is None: raise ValueError('TX message records missing')
    starts=defaultdict(deque)
    for (due,vl,payload),(start,end,gotvl,n) in zip(schedule,inputs):
        if (vl,len(payload))!=(gotvl,n) or end-start+1!=len(payload)+2: raise ValueError('TX stream record mismatch')
        if accepted(vl,payload): starts[vl].append((start,end,len(payload),due))
    metrics=[]
    for first,last,ident,raw in records(out/'rx.txt'):
        first,last=int(first),int(last);data=bytes.fromhex(ident+raw)
        if len(data)<3 or last-first+1!=len(data): raise ValueError('RX framing')
        vl=int.from_bytes(data[:2],'big')
        if not expected[vl] or expected[vl].popleft()!=data[2:]: raise ValueError('unexpected/incorrect/duplicate delivery VL %04x'%vl)
        if starts[vl]:
            start,end,n,due=starts[vl].popleft();metrics.append((vl,n,last-start,first-start,start-epoch-due,start,end))
    if any(expected.values()): raise ValueError('missing application delivery')
    if any(starts.values()):raise ValueError('missing TX application output')
    decoded={}; pernet={}
    for net in ('a','b'):
        frames=[]; reasm=ref.Reassembler(); msgs=defaultdict(deque)
        for _,vl,p in schedule:
            if accepted(vl,p):msgs[vl].append(p)
        prev_time={};prev_sn={}; datagrams=defaultdict(list)
        for row in records(out/('tx_'+net+'.txt')):
            t=int(row[0]);wire=bytes.fromhex(row[1]);f=ref.decode(wire);vl=f['vlid']
            if vl not in configs: raise ValueError('unknown TX VL')
            if vl in prev_time and t-prev_time[vl] < configs[vl]*125: raise ValueError('BAG VL %04x'%vl)
            if vl in prev_sn and f['sn'] != (1 if prev_sn[vl]==255 else prev_sn[vl]+1): raise ValueError('SN VL %04x'%vl)
            prev_time[vl]=t;prev_sn[vl]=f['sn'];datagrams[vl].append((f['offset'],f['mf'],f['ident']))
            completed=reasm.feed(wire,t)
            if completed is not None:
                if not msgs[vl] or completed!=msgs[vl].popleft(): raise ValueError('TX payload VL %04x'%vl)
                group=datagrams.pop(vl)
                if group[0][0]!=0 or any(x[2]!=group[0][2] for x in group):raise ValueError('fragment ID/offset')
                cap=min(1479,int(config_lmax[vl])+8); remaining=len(completed)+8; pos=0; offsets=[]
                while remaining:
                    part=remaining if remaining<=cap else (cap//8)*8
                    if part==0:raise ValueError('invalid fragment budget')
                    offsets.append((pos,remaining>part));pos+=part;remaining-=part
                if [(x[0],x[1]) for x in group]!=offsets:raise ValueError('fragment offset/MF sequence')
            frames.append((t,wire,f))
        if any(msgs.values()) or reasm.contexts:raise ValueError('missing/incomplete TX wire datagram')
        pernet[net]=frames
    a,b=pernet['a'],pernet['b']
    if len(a)!=len(b): raise ValueError('A/B frame count mismatch')
    for (_,wa,fa),(_,wb,fb) in zip(a,b):
        if any(fa[k]!=fb[k] for k in ('vlid','src','dst','ident','offset','mf','data','sn')):raise ValueError('A/B payload or SN mismatch')
    if not app:
        ev=list(records(out/'events.txt')); final=[r for r in ev if r[0]=='FINAL']
        if len(final)!=1 or int(final[0][2])+int(final[0][3])<2:raise ValueError('oversize and tiny-Lmax drops were not both reported')
        if not any(int(r[2],16)&2 or int(r[3],16)&2 for r in ev if r[0]!='FINAL'):raise ValueError('bad FCS was not reported')
        if not any(int(r[5],16) for r in ev if r[0]!='FINAL'):raise ValueError('duplicate was not rejected by RM')
    jitter=defaultdict(list)
    window_path=out/'vectors/window.txt'
    begin,end=(map(int,next(records(window_path))) if window_path.exists() else (0,0))
    selected=[m for m in metrics if end<=begin or epoch+begin<=m[6]<epoch+end]
    for vl,n,lat,first,lag,start,stop in selected:jitter[(vl,n)].append(lat)
    j=max((max(v)-min(v) for v in jitter.values()),default=0)
    short=max((lat for vl,n,lat,first,lag,start,stop in metrics if n<=1471),default=0)
    long=max((lat for vl,n,lat,first,lag,start,stop in metrics if n>1471),default=0)
    if app and short>250000:raise ValueError('unfragmented raw completion exceeds 2000 us')
    first=max((m[3] for m in metrics),default=0)
    # Input payload byte intervals exclude the two VLID bytes; clipping matches the raw 8 ns clock window.
    inject=sum(max(0,min(stop+1,epoch+end)-max(start+2,epoch+begin)) for vl,n,lat,first_lat,lag,start,stop in metrics) if end>begin else 0
    mbps=inject*1000.0/(end-begin) if end>begin else 0.0
    summary='APP METRIC inject_mbps=%.3f raw_short_completion_us=%.3f raw_fragmented_completion_us=%.3f max_e2e_first_us=%.3f jitter_r119_us=%.3f delivered=%d frames=%d\nAPP REQUIREMENT REPORT fragmented_completion=informational jitter_r139=ambiguous\n'%(mbps,short*.008,long*.008,first*.008,j*.008,len(metrics),len(a))
    (out/'summary.txt').write_text(summary,encoding='ascii');print(summary.strip());print('[RESULT] fragment_integration PASS')

def app_prepare(out,config_path,schedule_path,payload_path,window_path):
    v=out/'vectors';v.mkdir(parents=True,exist_ok=True)
    rows=[]
    for row in records(config_path):
        if row[0].startswith('#'): continue
        rows.append((int(row[0],16),*map(int,row[1:5])))
    config(v/'config.txt',rows)
    lines=list(records(schedule_path)); count=int(lines[0][0]); schedule=[tuple(map(int,r)) for r in lines[1:]]
    data=[int(r[0],16) for r in records(payload_path)]
    (v/'schedule.txt').write_text('%d %d %d\n'%(count,len(data),count)+''.join('%d %d %d %d\n'%r for r in schedule),encoding='ascii')
    write_bytes(v/'payload.hex',data);(v/'injection.txt').write_text('0 0\n',encoding='ascii')
    (v/'window.txt').write_text(window_path.read_text(encoding='ascii'),encoding='ascii')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('command',choices=['prepare','check','app-prepare','app-check']);p.add_argument('out',type=Path);p.add_argument('paths',nargs='*');a=p.parse_args()
    if a.command=='prepare':prepare(a.out)
    elif a.command=='check':check(a.out)
    elif a.command=='app-check':check(a.out,True)
    else:
        if len(a.paths)!=4:p.error('app-prepare needs config, schedule, payload, window')
        app_prepare(a.out,*map(Path,a.paths))
