"""Independent GMII X1--X4 reconstruction, using public records only.

All frame ends are the first low cycle.  M1 admission is derived exclusively
from the GMII bytes, reset/enable records and the documented byte-release rule;
observed slow captures or gdrop pulses never decide admission.
"""
import bisect
from pathlib import Path


def capture(folder, net, stride, expect):
    result=[]
    for line in (folder/f'dump_{net.lower()}.txt').read_text(encoding='ascii').splitlines():
        p=line.split();wire=bytes.fromhex(p[3]);start=int(p[1]);count=int(p[2])
        expect(p[0]==net and count==len(wire) and p[3]==p[3].lower(), 'X capture format')
        result.append(dict(net=net,start=start,end=start+stride*count,wire=wire))
    return result


def tx_capture_survives(start,length,resets,delay):
    return not any(start<z<=start+delay+length for z in resets)


def model_channel(incoming, ep, net, capacity, delay, expect):
    schedules=[];expected=[];drops=[];starts=[];prefix=[]
    allocated=0;epoch=None;previous_end=-1;peak=0;max_wait=0;clean_peak=0;clean_wait=0
    def released(t):
        k=bisect.bisect_right(starts,t)-1
        if k<0:return 0
        f=schedules[k]
        return prefix[k]+min(len(f['wire']),(t-f['start'])//8+1)
    for f in sorted(incoming,key=lambda f:f['start']):
        s,e,n=f['start'],f['end'],len(f['wire'])
        zindex=bisect.bisect_right(ep['resets'],s)
        if zindex!=epoch:
            epoch=zindex;schedules=[];starts=[];prefix=[];allocated=0;previous_end=-1
        last_reset=ep['resets'][zindex-1] if zindex else -1
        next_reset=ep['resets'][zindex] if zindex<len(ep['resets']) else 1<<62
        ready=any(last_reset<i<=s for i in ep['inits'])
        if not ready:
            continue
        interrupted=e>=next_reset
        visible=min(n,max(0,next_reset-s)) if interrupted else n
        if not visible:continue
        # During a continuous GMII frame at most one byte can be released per
        # cycle, so occupancy after each input byte is monotonic nondecreasing.
        def occupancy(j):return allocated+j-released(s+j-1)
        final=occupancy(visible)
        if final>capacity:
            lo,hi=1,visible
            while lo<hi:
                mid=(lo+hi)//2
                if occupancy(mid)>capacity:hi=mid
                else:lo=mid+1
            rejected=s+lo-1
            if rejected+1<next_reset:
                drops.append(dict(cycle=rejected+1,frame=f,byte=lo-1))
            peak=max(peak,capacity)
            # Trial allocation rolls back; previously committed bytes remain.
            continue
        peak=max(peak,final)
        if interrupted:continue
        replay_start=max(e+delay,previous_end+16) if previous_end>=0 else e+delay
        wait=replay_start-(e+delay);max_wait=max(max_wait,wait)
        replay=dict(f,gmii_start=s,gmii_end=e,start=replay_start,end=replay_start+8*n,queue_wait=wait)
        clean=f.get('original') and f.get('mode')=='pass'
        if clean:
            clean_peak=max(clean_peak,final);clean_wait=max(clean_wait,wait)
        prefix.append(allocated);starts.append(replay_start);schedules.append(replay)
        allocated+=n;previous_end=replay['end']
        if replay['end']<next_reset:
            expected.append(replay)
    return expected,drops,dict(max_occupancy=peak,max_queue_wait=max_wait,
        clean_max_occupancy=clean_peak,clean_max_queue_wait=clean_wait,accepted=len(expected),dropped=len(drops))


def prepare(test, folder, endpoints, sysrows):
    folder=Path(folder);items=errors=0;diagnostics=[]
    def expect(ok,label):
        nonlocal items,errors
        items+=1
        if not ok:
            errors+=1
            if len(diagnostics)<40:diagnostics.append(label)
    params={p[2]:int(p[3]) for _,_,p in sysrows if p[0]=='G'}
    for key,value in (('CLOCK_NS',8),('GMII_TX_DELAY',10688),('GMII_RX_REPLAY_R',16)):
        expect(params.get(key)==value,'X declared '+key)
    tx_delay=params.get('GMII_TX_DELAY',10688);rx_delay=params.get('GMII_RX_REPLAY_R',16)
    capacity=1<<params.get('GMII_RX_AW',12)
    for es,ep in endpoints.items():
        ep['gmii_tx']=[];ep['gmii_rx']=[]
        for net in ('A','B'):
            sent=capture(folder/f'es{es}_gmii_tx',net,1,expect)
            received=capture(folder/f'es{es}_gmii_rx',net,1,expect)
            ep['gmii_tx'].extend(sent);ep['gmii_rx'].extend(received)
            slow=[f for f in ep['tx'] if f['net']==net]
            wanted=[]
            for f in slow:
                start=f['start']+tx_delay;end=start+len(f['wire'])
                if not tx_capture_survives(f['start'],len(f['wire']),ep['resets'],tx_delay):continue
                wanted.append(f)
            expect(len(sent)==len(wanted),f'X1 ES{es} {net} TX frame count')
            for fast,core in zip(sent,wanted):
                expect(fast['start']==core['start']+tx_delay and fast['wire']==core['wire'],
                       f'X1 ES{es} {net} exact D and bytes S={core["start"]}')
                fast['message']=core.get('message');fast['slow_source']=core
                core['gmii']=fast
            for a,b in zip(sent,sent[1:]):
                if any(a['start']<z<=b['start'] for z in ep['resets']):continue
                expect(b['start']-a['end']>=12,f'X2 ES{es} {net} IFG >=12')
    link_rows={i:[] for i in range(4)};actions=set();stage='initial'
    for c,_,p in sysrows:
        if p[0]=='P':stage=p[2]
        elif p[0] in ('L','A','R','J'):
            link=int(p[2]);expect(link in link_rows,'X3 link id')
            if link in link_rows:link_rows[link].append((c,p))
            if p[0] in ('R','J') or p[0]=='A' and p[4]!='pass':actions.add(stage)
    channels={};expected={1:[],2:[]};statistics={}
    for link in range(4):
        source=endpoints[1 if link<2 else 2];destination=endpoints[2 if link<2 else 1]
        es=destination['number'];net='AB'[link%2]
        tx=sorted((f for f in source['gmii_tx'] if f['net']==net),key=lambda f:f['start'])
        delays=[(c,int(p[3])) for c,p in link_rows[link] if p[0]=='L']
        plans={int(p[3]):(c,p[4],int(p[5]),int(p[6],16)) for c,p in link_rows[link] if p[0]=='A'}
        incoming=[]
        for number,f in enumerate(tx,1):
            options=[d for c,d in delays if c<=f['start']]
            expect(bool(options),f'X3 link {link} delay before frame')
            delay=options[-1] if options else 0
            c,mode,byte,mask=plans.get(number,(0,'pass',0,0))
            expect(c<=f['start'] and mode in ('pass','drop','xor','hold'),'X3 timely valid action')
            if mode in ('drop','hold'):continue
            wire=bytearray(f['wire'])
            if mode=='xor':
                expect(0<=byte<len(wire),'X3 XOR byte index')
                if 0<=byte<len(wire):wire[byte]^=mask
            incoming.append(dict(net=net,start=f['start']+delay,end=f['end']+delay,
                wire=bytes(wire),source=f,message=f.get('message'),mode=mode,original=True,
                number=number,link=link,link_delay=delay))
        for c,p in link_rows[link]:
            if p[0]=='R':
                number,start=int(p[3]),int(p[4]);expect(1<=number<=len(tx),'X3 replay source')
                if not 1<=number<=len(tx):continue
                f=tx[number-1]
                expect(start>=c>=f['end'],'X3 replay after retained complete frame')
                incoming.append(dict(net=net,start=start,end=start+len(f['wire']),wire=f['wire'],
                    source=f,message=f.get('message'),mode='replay',original=False,number=number,link=link,link_delay=None))
            elif p[0]=='J':
                start,n=int(p[3]),int(p[4]);wire=bytes.fromhex(p[5])
                expect(start>=c and len(wire)==n and p[5]==p[5].lower(),'X3 insertion format')
                incoming.append(dict(net=net,start=start,end=start+n,wire=wire,source=None,
                    message=None,mode='insert',original=False,link=link,link_delay=None))
        incoming.sort(key=lambda f:f['start'])
        for a,b in zip(incoming,incoming[1:]):expect(b['start']-a['end']>=12,'X3 GMII link gap >=12')
        intervals=list(zip(destination['resets'],destination['releases']))
        retained=[]
        for f in incoming:
            f['reset_crossing']=any(f['start']<r and f['end']>=z for z,r in intervals)
            if not f['reset_crossing']:retained.append(f)
        actual=sorted((f for f in destination['gmii_rx'] if f['net']==net),key=lambda f:f['start'])
        expect(len(actual)==len(retained),f'X3 link {link} count expected={len(retained)} got={len(actual)}')
        for a,b in zip(actual,retained):expect(a['start']==b['start'] and a['wire']==b['wire'],f'X3 link {link} bytes/start {b["start"]}')
        replay,dropped,stats=model_channel(incoming,destination,net,capacity,rx_delay,expect)
        self_spaced=all(f.get('original') for f in incoming) and all(
            b['start']-a['start']>=8*len(a['wire'])+96 for a,b in zip(incoming,incoming[1:]))
        stats['self_spaced_input']=self_spaced
        if self_spaced and capacity>=4096:
            expect(not dropped and stats['max_queue_wait']<=1374 and stats['max_occupancy']<=3054,
                   f'X4 ES{es} {net} self-source backlog and capacity bounds')
        observed=sorted((f for f in destination['rx'] if f['net']==net),key=lambda f:f['start'])
        expect(len(observed)==len(replay),f'X4 ES{es} {net} replay frame count expected={len(replay)} got={len(observed)}')
        for a,b in zip(observed,replay):
            expect(a['start']==b['start'] and a['wire']==b['wire'],f'X4 ES{es} {net} M1 replay S={b["start"]}')
        pulses=[c for c,_,p in sysrows if p[0]=='E' and int(p[2])==es and p[3]==net.lower()+'_gdrop']
        expect(pulses==[d['cycle'] for d in dropped],f'X4 ES{es} {net} exact gdrop cycles expected={[d["cycle"] for d in dropped]} got={pulses}')
        expected[es].extend(replay);statistics[f'es{es}_{net.lower()}']=stats
        channels[link]=dict(incoming=incoming,replay=replay,dropped=dropped)
    summary=dict(test=test+'_gmii',items=items,errors=errors,either=0,tx_delay=tx_delay,
                 replay_delay=rx_delay,capacity=capacity,channels=statistics,diagnostics=diagnostics)
    return dict(report=summary,expected=expected,actions=actions,channels=channels)


def emit(report):
    for label in report['diagnostics']:print('[CHECK_FAIL] '+label)
    print(f'[CHECK] {report["test"]} {"PASS" if not report["errors"] else "FAIL"} items={report["items"]} errors={report["errors"]} either=0')
