"""TX stimulus and black-box event/capture checker (stdlib only).

The checker opens only events.txt, dump_a.txt, dump_b.txt. Stimulus generation
is deliberately separate from reconstruction of accepted messages and frames.
"""
import bisect
import collections
import json
import random
from pathlib import Path


class Stimulus:
    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.commands, self.payload = [], bytearray()
        self.messages = 0

    def emit(self, text):
        self.commands.append(text)

    def stage(self, name):
        self.emit('P ' + name)
        self.emit('Z 00000000')

    def cfg(self, vl, *, bag=672, nets=3, en=1, qmax=63, maximum=1471,
            vlid=None, src=None, dst=None, sport=None, dport=None):
        words = [(maximum << 9) | (qmax << 3) | (nets << 1) | en, bag,
                 vlid if vlid is not None else vl+100,
                 src if src is not None else 0x0a000001+vl,
                 dst if dst is not None else 0xe0000001+vl,
                 ((sport if sport is not None else 1000+vl) << 16) |
                 (dport if dport is not None else 2000+vl)]
        for w, value in enumerate(words):
            self.emit(f'C {vl*8+w:x} {value:08x}')

    def msg(self, vl, n=1, *, pen=0, sport=3123, dport=4567, pause=0, mutate=0, cut=0):
        offset = len(self.payload)
        self.payload.extend(self.rng.randbytes(n))
        self.emit(f'M {vl} {n} {pen} {sport:04x} {dport:04x} {pause} {mutate} {cut} {offset}')
        if not cut:
            self.messages += 1

    def drain(self):
        self.emit('D')

    def write(self, out):
        (out/'tx_core.txt').write_text('\n'.join(self.commands)+'\n', encoding='ascii')
        (out/'tx_payload.hex').write_text(''.join(f'{b:02x}\n' for b in self.payload), encoding='ascii')
        (out/'tx_payload.count').write_text(str(len(self.payload))+'\n', encoding='ascii')


def basic(s):
    s.stage('len');s.cfg(0)
    for n in [1,16,17,18,255,256,257,511,512,513,1025,1470,1471]+[s.rng.randrange(1,1472) for _ in range(32)]:
        s.msg(0,n);s.drain()
    s.stage('nets')
    for vl,nets,vlid in ((0,1,0),(1,2,65535),(2,3,s.rng.randrange(1,65535))):
        s.cfg(vl,nets=nets,vlid=vlid)
    for _ in range(3):
        for vl in range(3):s.msg(vl,33+vl);s.drain()
    s.stage('ports');s.cfg(0);s.cfg(1,nets=1)
    for k in range(12):
        s.msg(k%2,31+k,pen=k%2,sport=s.rng.randrange(65536),dport=s.rng.randrange(65536),mutate=1);s.drain()
    s.stage('pause');s.cfg(0);s.cfg(1,nets=1)
    for k in range(20):s.msg(k%2,s.rng.randrange(1,301),pause=7,mutate=1)
    s.drain()
    s.stage('wrap');s.cfg(0,bag=672)
    for _ in range(310):s.msg(0);s.emit('W 650')
    s.drain()
    s.stage('userid');s.cfg(0)
    for value in (0x0000,0xabcd):
        s.emit(f'U {value:04x}')
        for _ in range(3):s.msg(0,32);s.drain()


def bag(s):
    for name,value,count in (('exact',100000,50),('odd',100003,10)):
        s.stage(name);s.cfg(0,bag=value)
        for _ in range(count):s.msg(0)
        s.drain()
    s.stage('short')
    for value in (800,672,400):
        s.emit('Z 00000000');s.cfg(0,bag=value)
        for _ in range(22):s.msg(0)
        s.drain()
    s.stage('late')
    for delta in (5000,-2000,-300,-150,-60,-10):
        s.emit('Z 00000000');s.cfg(0,bag=100000);s.msg(0);s.drain()
        s.emit(f'T {100000+delta}');s.msg(0);s.drain()
    s.stage('queue');s.cfg(0,bag=20000)
    for _ in range(8):s.msg(0)
    s.drain()
    s.stage('nowwrap');s.emit('Z fffff000');s.cfg(0,bag=20000)
    for _ in range(10):s.msg(0)
    s.drain()
    s.stage('jump');s.cfg(0,bag=20000);s.msg(0);s.drain();s.emit('W 21000');s.emit('J 80001000');s.msg(0);s.drain()
    s.stage('flood');s.cfg(0,bag=20000);s.cfg(1,en=0)
    for _ in range(5):s.msg(0)
    for _ in range(2200):s.msg(1)
    s.drain()
    s.stage('reset');s.cfg(0,bag=20000);s.msg(0,1471);s.emit('S')
    for _ in range(5):s.msg(0)
    s.emit('W 200');s.emit('B 6 0');s.emit('Z 00000000');s.cfg(0,bag=20000)
    for _ in range(3):s.msg(0)
    s.drain()


def multi(s):
    s.stage('burst128')
    for vl in range(128):s.cfg(vl,bag=1000)
    s.msg(127,1471);s.emit('S')
    for vl in range(128):s.msg(vl,s.rng.randrange(1,33))
    s.drain()
    s.stage('rr3');s.cfg(127,bag=1000)
    for vl in range(3):s.cfg(vl,bag=400)
    s.msg(127,1471);s.emit('S')
    for _ in range(20):
        for vl in range(3):s.msg(vl)
    s.drain()
    for stage,length,arrival in (('late_x',1471,99000),('early_x',1,99940)):
        s.stage(stage);s.cfg(0,bag=100000);s.cfg(1,bag=1000)
        s.msg(0);s.drain();s.msg(0);s.msg(0)
        # 连续写入最长消息：首字节到末字节相差 1470 + 六次取页各六拍。
        s.emit(f'T {arrival-(1506 if length==1471 else 0)}');s.msg(1,length);s.drain()
    s.stage('mix')
    for vl in range(128):s.cfg(vl,bag=4000+3000*vl)
    for _ in range(1500):
        s.msg(s.rng.randrange(128),s.rng.randrange(1,514),pen=s.rng.randrange(2),sport=s.rng.randrange(65536),dport=s.rng.randrange(65536))
        s.emit(f'W {s.rng.randrange(500,6001)}')
    s.drain()


def saturation(s):
    s.msg(0);s.drain()  # 开启长 BAG，等首页释放后开始同一批填充。
    for _ in range(42):s.msg(0,1471)
    s.msg(0,1471)  # 剩四页：第五页申请失败，已占四页必须全部归还。
    s.msg(0,1024)  # 余数四页，合计 256 页。
    s.msg(0)       # 首页也无页可取。
    s.drain()


def drop(s):
    s.stage('dis');s.cfg(0,en=0);s.cfg(1,nets=0);s.cfg(2,bag=400)
    for vl in (0,1,0,1):s.msg(vl,32);s.msg(2);s.drain()
    s.stage('long');s.cfg(0,maximum=16);s.cfg(1,bag=400)
    for n in (17,1472,3000):s.msg(0,n);s.msg(1);s.drain()
    s.stage('full')
    for maximum in (0,1,2,63):
        s.emit('Z 00000000');s.cfg(0,qmax=maximum,bag=30000);s.cfg(1,bag=400)
        if maximum:s.msg(0);s.drain()
        for _ in range(maximum):s.msg(0)
        for _ in range(3):s.msg(0);s.msg(1);s.emit('W 700')
        s.drain()
    s.stage('nopage');s.cfg(0,bag=100000);saturation(s)
    s.emit('P refill');saturation(s)  # 刻意不复位，检验页是否泄漏。
    s.emit('P reset_refill');s.emit('W 101000');s.msg(0,1471);s.emit('S')
    for _ in range(5):s.msg(0)
    s.msg(0,1471,cut=700);s.emit('B 6 1');s.emit('Z 00000000');s.cfg(0,bag=100000);saturation(s)


def net(s):
    s.stage('lengths');s.cfg(0);s.cfg(1,nets=1)
    for k,n in enumerate((1,17,18,300,1471)):s.msg(k%2,n);s.drain()
    s.stage('queue');s.cfg(0,bag=20000,qmax=4);s.cfg(1,nets=1,en=0)
    s.msg(0);s.drain()
    for _ in range(5):s.msg(0)
    s.msg(1);s.msg(0,1472);s.drain()


def generate(test, seed, out):
    s = Stimulus(seed)
    {'tb_tx_basic': basic,'tb_tx_bag':bag,'tb_tx_multi':multi,'tb_tx_drop':drop,'tb_tx_net':net}[test](s)
    s.write(out)
    return dict(messages=s.messages,payload_bytes=len(s.payload),commands=len(s.commands))


def check(test, folder):
    from afdx_ref import build_frame, line_bytes, PREAMBLE, fcs
    items = errors = either = 0
    diagnostics = []
    def expect(ok, label):
        nonlocal items, errors
        items += 1
        if not ok:
            errors += 1
            if len(diagnostics)<40:diagnostics.append(label)
    events=[]
    for number,line in enumerate((folder/'events.txt').read_text(encoding='ascii').splitlines(),1):
        p=line.split()
        if len(p)<2:raise ValueError(f'events line {number}')
        events.append((int(p[1]),number,p))
    events.sort()
    params={};cfg={};uid=0;epoch=0;stage='initial';messages=[];stages={};pending=[];tx_events={'A':[],'B':[]};resets=[];now_points=[]
    public_inputs=collections.deque()
    for cycle,_,p in events:
        code=p[0]
        if code=='G':params[p[2]]=int(p[3])
        elif code=='P':stage=p[2];stages.setdefault(stage,[])
        elif code=='U':uid=int(p[2],16)
        elif code=='N':now_points.append((cycle,int(p[2],16)))
        elif code=='Z':
            resets.append(cycle);epoch+=1;cfg={};pending=[];public_inputs.clear()
        elif code=='C':
            expect(p[2]=='tx','C table is tx');cfg[int(p[3],16)]=int(p[4],16)
        elif code=='A':
            expect(len(p)==8 and len(p[4])==int(p[3])*2,'A public input format')
            public_inputs.append(p)
        elif code=='M':
            vl,n,pen=map(int,p[2:5]);sp,dp=int(p[5],16),int(p[6],16);body=bytes.fromhex(p[7])
            expect(len(body)==n and p[7]==p[7].lower(),'M payload format')
            words=[cfg.get(vl*8+w,0) for w in range(6)]
            if len(p)>11:
                expect(bool(public_inputs),'A public input exists for core M')
                if public_inputs:
                    a=public_inputs.popleft()
                    expect(int(a[2],16)==(words[2]&65535) and int(a[3])==n and a[4]==p[7],
                           'A public VLID/payload matches core M')
                    expect(int(a[1])==int(p[10]) and int(a[5])==int(p[8]),'A public input timing matches M')
                    expect(int(a[6])==int(p[11]) and int(a[7])==int(p[9]),'A public backpressure matches M')
            m=dict(cycle=cycle,vl=vl,n=n,pen=pen,sp=sp,dp=dp,payload=body,words=words,uid=uid,
                   epoch=epoch,stage=stage,index=len(messages),result=None,frame=None)
            messages.append(m);stages.setdefault(stage,[]).append(m);pending.append(m)
        elif code=='E':
            name=p[2]
            if name in ('tx_a','tx_b'):tx_events[name[-1].upper()].append(cycle)
            else:
                expect(len(pending)>=1,f'G2 queued M available at E {cycle}')
                if pending:
                    m=pending.pop(0);m['result']=name;m['event']=cycle
                    expect(0<cycle-m['cycle']<=96,f'G2 outcome deadline message {m["index"]}')
        elif code!='R':expect(False,'unexpected event '+code)
    expect(not public_inputs,'A no unaccounted public input')
    expect(not pending,'G2 no missing outcome')
    expect(set(params)=={'TX_PAGE_AW','TX_OFF_AW','LOOKAHEAD'},'G parameter set')
    captures=[]
    for net in ('A','B'):
        for line in (folder/f'dump_{net.lower()}.txt').read_text(encoding='ascii').splitlines():
            p=line.split();wire=bytes.fromhex(p[3]);start=int(p[1]);count=int(p[2])
            expect(p[0]==net and len(wire)==count and p[3]==p[3].lower(),'G1 capture format')
            expect(wire[:8]==PREAMBLE and 64<=len(wire)-8<=1518 and fcs(wire[8:-4])==wire[-4:],f'G1 wire {net} {start}')
            captures.append(dict(net=net,start=start,end=start+count,wire=wire,epoch=bisect.bisect_right(resets,start)))
    captures.sort(key=lambda f:(f['start'],f['net']))
    groups=[]
    for f in captures:
        if groups and groups[-1]['start']==f['start']:
            expect(f['net'] not in groups[-1]['nets'],f'G3 duplicate {f["net"]} capture at {f["start"]}')
            groups[-1]['nets'][f['net']]=f
        else:groups.append(dict(start=f['start'],end=f['end'],epoch=f['epoch'],nets={f['net']:f}))
    available=collections.defaultdict(collections.deque)
    for m in messages:
        if m['result']=='accept':available[(m['epoch'],m['words'][2]&65535)].append(m)
    last_vl={};sn={};ident=collections.defaultdict(int);previous=None
    for group in groups:
        f=next(iter(group['nets'].values()));body=f['wire'][8:-4];ep=group['epoch']
        key=(ep,int.from_bytes(body[4:6],'big'));q=available[key]
        expect(bool(q),f'G3 unexpected frame at {group["start"]}')
        if not q:continue
        m=q.popleft();group['message']=m;m['frame']=group;vlkey=(ep,m['vl']);words=m['words'];control=words[0]
        expect(m['cycle']<group['start'],f'G3 frame precedes complete message {m["index"]}')
        enabled={net for net,bit in (('A',1),('B',2)) if control&(1<<bit)}
        expect(set(group['nets'])==enabled,f'G5 network set message {m["index"]}')
        n_sn=sn.get(vlkey,0);n_ident=ident[ep]
        for net,frame in group['nets'].items():
            expected=line_bytes(build_frame(m['payload'],net=net,vlid=words[2]&65535,user_id=m['uid'],sn=n_sn,ident=n_ident,
                src_ip=words[3],dst_ip=words[4],sport=m['sp'] if m['pen'] else words[5]>>16,
                dport=m['dp'] if m['pen'] else words[5]&65535))
            expect(frame['wire']==expected,f'G1/G4 frame fields message {m["index"]} net={net}')
        sn[vlkey]=1 if n_sn==255 else n_sn+1;ident[ep]=(n_ident+1)&65535
        previous_vl=last_vl.get(vlkey)
        due=m['cycle'] if previous_vl is None else previous_vl['start']+words[1]
        m['due']=due
        if previous_vl:expect(group['start']-previous_vl['start']>=words[1],f'G6 BAG message {m["index"]}')
        group['previous']=previous if previous and previous['epoch']==ep else None
        last_vl[vlkey]=group;previous=group
    for m in messages:
        if m['result']=='accept' and not m['frame']:
            expect(any(r>m['cycle'] for r in resets),f'G3 accepted message absent {m["index"]}')
        elif m['result']!='accept':expect(m['frame'] is None,f'G3 dropped message emitted {m["index"]}')
    previous_message={}
    for m in messages:
        if m['result']!='accept':continue
        key=(m['epoch'],m['vl']);prior=previous_message.get(key)
        if 'due' not in m:
            m['due']=m['cycle'] if prior is None else (prior['frame']['start']+m['words'][1] if prior['frame'] else 1<<60)
        previous_message[key]=m
    # Reconstruct dequeue/page availability intervals independently of implementation.
    pages=1<<params.get('TX_PAGE_AW',8);size=1<<params.get('TX_OFF_AW',8)
    for m in messages:
        if m['result'] is None:continue  # interrupted by reset
        ep=m['epoch'];cycle=m['cycle'];control=m['words'][0];needed=(min(m['n'],1471)+size-1)//size
        # M 只记末字节；首次取页可以早于它。接收期间可能有旧帧归还页面。
        previous=messages[m['index']-1] if m['index'] else None
        first_possible=previous['cycle']+1 if previous and previous['epoch']==ep else resets[ep-1]
        prior=[x for x in messages[:m['index']] if x['epoch']==ep and x['result']=='accept']
        used_min=used_max=0;queued_min=queued_max=0
        for x in prior:
            frame=x['frame'];count=(x['n']+size-1)//size
            if frame is None or frame['start']>cycle:used_min+=count
            if frame is None or frame['end']+16>first_possible:used_max+=count
            if x['vl']==m['vl']:
                if frame is None or frame['start']>cycle:queued_max+=1
                prev=frame.get('previous') if frame else None
                earliest=prev['start'] if prev else x['cycle']
                # 入队检查发生在 M 与结果 E 之间，不能假定恰好在末字节那拍。
                if frame is None or earliest>m['event']:queued_min+=1
        free_min,free_max=pages-used_max,pages-used_min
        options=set()
        if free_min<needed:options.add('drop_nopage')
        if free_max>=needed:
            if m['n']>1471:options.add('drop_long')
            elif control&1==0 or control&6==0:options.add('drop_dis')
            elif m['n']>((control>>9)&2047):options.add('drop_long')
            else:
                maximum=(control>>3)&63
                if queued_max>=maximum:options.add('drop_full')
                if queued_min<maximum:options.add('accept')
        expect(m['result'] in options,f'G2 message {m["index"]}: {m["result"]}, allowed={sorted(options)} free={free_min}..{free_max} queue={queued_min}..{queued_max}')
        if len(options)>1:either+=1
    for group in groups:
        m=group.get('message')
        if not m:continue
        S=group['start'];A=m['cycle'];T=m['due'];prev=group['previous'];L=max(T,prev['end']+12 if prev else T)
        expect(S>=L,f'G7 early message {m["index"]}: S={S} L={L}')
        competing=[]
        for other in messages:
            if other['epoch']!=m['epoch'] or other['vl']==m['vl'] or other['result']!='accept':continue
            of=other['frame'];os=of['start'] if of else 1<<60
            if other['cycle']<S and os>S-2000 and other.get('due',other['cycle'])<S+512:competing.append(other)
        if not competing:expect(S<=max(L,A+100),f'G7 late message {m["index"]}: S={S} L={L} A={A}')
        if prev is None or S-prev['end']>1024:
            old=S-1024
            heads={}
            for other in messages:
                if other['epoch']!=m['epoch'] or other['result']!='accept' or other['cycle']>=old:continue
                of=other['frame'];os=of['start'] if of else 1<<60
                if os>=old:heads.setdefault(other['vl'],other)
            for other in heads.values():
                of=other['frame'];os=of['start'] if of else 1<<60
                if os>=S and other['cycle']<old-100:expect(other['due']>old,f'G8 idle starvation message {other["index"]}')
    for net in ('A','B'):
        frames=[f for f in captures if f['net']==net]
        expect(len(frames)==len(tx_events[net]),f'G9 {net} count')
        for f,e in zip(frames,tx_events[net]):expect(f['end']<=e<=f['end']+16,f'G9 {net} pulse {e}')
    stage_checks(test,stages,groups,resets,now_points,events,expect)
    result=dict(test=test,items=items,errors=errors,either=either,messages=len(messages),frames_a=sum(f['net']=='A' for f in captures),
                frames_b=sum(f['net']=='B' for f in captures),sends=len(groups),stages={k:len(v) for k,v in stages.items()},diagnostics=diagnostics)
    for row in diagnostics:print('[CHECK_FAIL] '+row)
    print(f'[CHECK] {test} {"PASS" if errors==0 else "FAIL"} items={items} errors={errors} either={either}')
    return result


def stage_checks(test,stages,groups,resets,now_points,events,expect):
    def ms(stage):return stages.get(stage,[])
    def fs(stage):return [g for g in groups if g.get('message',{}).get('stage')==stage]
    def all_accept(stage):expect(all(m['result']=='accept' for m in ms(stage)),f'{stage}: all messages accepted')
    def spacing(stage,step,minimum):
        frames=fs(stage);expect(len(frames)>=minimum,f'{stage}: frame count >= {minimum}')
        for a,b in zip(frames,frames[1:]):
            if a['epoch']==b['epoch']:expect(b['start']-a['start']==step,f'{stage}: spacing {b["start"]-a["start"]}, expected {step}')
    def now_at(cycle):
        pos=bisect.bisect_right([p[0] for p in now_points],cycle)-1
        c,n=now_points[pos];return (n+cycle-c)&0xffffffff
    if test=='tb_tx_basic':
        expect(set(stages)=={'len','nets','ports','pause','wrap','userid'},'basic stages')
        lengths=[m['n'] for m in ms('len')]
        expect(set((1,16,17,18,255,256,257,511,512,513,1025,1470,1471))<=set(lengths) and len(lengths)>=42,'len matrix')
        for a,b in zip(ms('len'),ms('len')[1:]):expect(a['frame'] is not None and a['frame']['end']<b['cycle'],'len: drain individually')
        nets=ms('nets');expect({(m['words'][0]>>1)&3 for m in nets}=={1,2,3},'nets A/B/AB')
        expect({0,65535}<={m['words'][2] for m in nets} and len({m['words'][2] for m in nets})==3,'nets VLID matrix')
        for idx in (3,4,5):expect(len({m['words'][idx] for m in nets})==3,f'nets distinct config word {idx}')
        expect(collections.Counter(m['pen'] for m in ms('ports'))[0]>=3 and collections.Counter(m['pen'] for m in ms('ports'))[1]>=3,'ports override matrix')
        expect(len(ms('pause'))>=2,'pause messages')
        expect(len(fs('wrap'))>=300 and len({m['vl'] for m in ms('wrap')})==1 and all(m['words'][1]<=1000 for m in ms('wrap')),'SN wrap matrix')
        expect(len({m['uid'] for m in ms('userid')})>=2,'user ID changes')
        for name in stages:all_accept(name)
    elif test=='tb_tx_bag':
        expect(set(stages)=={'exact','odd','short','late','queue','nowwrap','jump','flood','reset'},'bag stages')
        spacing('exact',100000,50);spacing('odd',100003,10);spacing('queue',20000,8);spacing('nowwrap',20000,10);spacing('flood',20000,5)
        for stage in ('exact','odd'):
            frames=fs(stage)
            for a,b in zip(frames,frames[1:]):expect(b['message']['cycle']<=a['start']+b['message']['words'][1]-2000,f'{stage}: early arrival')
        short=collections.defaultdict(list)
        for f in fs('short'):short[f['message']['words'][1]].append(f)
        expect(set(short)=={800,672,400},'short BAG values')
        for value,frames in short.items():
            expect(len(frames)>=20 and all(m['message']['n']<=17 for m in frames),'short count/length')
            for a,b in zip(frames,frames[1:]):expect(b['start']-a['start']==max(value,84),'short exact spacing')
        late=collections.defaultdict(list)
        for f in fs('late'):late[f['epoch']].append(f)
        offsets=[]
        for frames in late.values():
            expect(len(frames)==2,'late pair')
            if len(frames)==2:offsets.append(frames[1]['message']['cycle']-frames[0]['start']-100000)
        expect(sorted(offsets)==sorted([5000,-2000,-300,-150,-60,-10]),f'late arrival offsets {offsets}')
        wrap=fs('nowwrap');expect(bool(wrap) and now_at(wrap[0]['start'])>now_at(wrap[-1]['start']),'now wraps during frames')
        jump=fs('jump');expect(len(jump)==2 and jump[-1]['start']-jump[-1]['message']['cycle']<=100,'jump immediate start')
        expect(any(((b[1]-a[1]-(b[0]-a[0]))&0xffffffff)==0x80001000 for a,b in zip(now_points,now_points[1:])),'jump magnitude')
        disabled=[m for m in ms('flood') if m['result']=='drop_dis']
        expect(len(disabled)>=2000 and all(m['n']==1 for m in disabled),'flood disabled traffic')
        expect(disabled and fs('flood') and disabled[-1]['cycle']>=fs('flood')[-1]['end'],'flood lasts through fifth frame')
        reset=fs('reset');expect(len(reset)==3,'reset leaves only three new frames')
        for name in ('exact','odd','short','late','queue','nowwrap','jump','reset'):all_accept(name)
    elif test=='tb_tx_multi':
        expect(set(stages)=={'burst128','rr3','late_x','early_x','mix'},'multi stages')
        burst=fs('burst128');expect(len(burst)==129 and burst[0]['message']['n']==1471,'burst count/blocker')
        expect(len({f['message']['vl'] for f in burst[1:]})==128 and all(f['message']['n']<=32 for f in burst[1:]),'burst all VLs')
        for a,b in zip(burst,burst[1:]):expect(b['start']-a['end']==12,'burst exact IFG')
        rr=fs('rr3');expect(len(rr)==61 and rr[0]['message']['n']==1471,'rr3 count/blocker')
        for a,b in zip(rr[1:],rr[2:]):expect(b['start']-a['start']>=84,'rr3 native minimum slot')
        for vl in range(3):
            vv=[f for f in rr[1:] if f['message']['vl']==vl]
            for a,b in zip(vv,vv[1:]):expect(b['start']-a['start']>=400,'rr3 preserves each VL BAG')
        for i in range(3,len(rr[1:])-8):expect(len({f['message']['vl'] for f in rr[1:][i:i+3]})==3,'rr3 round robin')
        for stage in ('late_x','early_x'):
            msgs=ms(stage);frames=fs(stage);x=msgs[0]['vl'] if msgs else -1
            xf=[f for f in frames if f['message']['vl']==x];yf=[f for f in frames if f['message']['vl']!=x]
            expect(len(xf)==3 and len(yf)==1,stage+' shape')
            if len(xf)==3 and len(yf)==1:
                y=yf[0];expect(y['message']['cycle']==xf[0]['start']+100000-(1000 if stage=='late_x' else 60),stage+' arrival')
                if stage=='late_x':
                    expect(y['start']-y['message']['cycle']<=100 and xf[1]['start']==y['end']+12,stage+' Y then X')
                else:expect(xf[1]['start']==xf[0]['start']+100000 and y['start']==xf[1]['end']+12,stage+' X then Y')
                expect(xf[2]['start']==xf[1]['start']+100000,stage+' subsequent BAG from actual start')
        mix=ms('mix');expect(len(mix)>=1500 and len({m['vl'] for m in mix})==128,'mix coverage')
        values={m['vl']:m['words'][1] for m in mix}
        expect(len(set(values.values()))==128 and all(4000<=b<=400000 for b in values.values()),'mix BAG configuration')
        for name in stages:all_accept(name)
    elif test=='tb_tx_drop':
        expect(set(stages)=={'dis','long','full','nopage','refill','reset_refill'},'drop stages')
        for stage,reason in (('dis','drop_dis'),('long','drop_long'),('full','drop_full')):
            msgs=ms(stage);dropped=[m for m in msgs if m['result']==reason]
            expect(bool(dropped),stage+' drop present')
            for m in dropped:
                i=msgs.index(m);expect(i+1<len(msgs) and msgs[i+1]['vl']!=m['vl'] and msgs[i+1]['result']=='accept' and msgs[i+1]['frame'] is not None,stage+' good message after drop')
        expect({(m['words'][0]>>3)&63 for m in ms('full') if m['vl']==0}=={0,1,2,63},'full qmax matrix')
        expect({17,1472,3000}<={m['n'] for m in ms('long') if m['result']=='drop_long'},'long lengths')
        counts=[]
        for stage in ('nopage','refill','reset_refill'):
            msgs=ms(stage);last_epoch=max((m['epoch'] for m in msgs),default=-1);msgs=[m for m in msgs if m['epoch']==last_epoch]
            counts.append(sum(m['result']=='accept' for m in msgs))
            expect({1,1471}<={m['n'] for m in msgs if m['result']=='drop_nopage'},stage+' first/middle allocation failure')
            expect(sum(m['result']=='drop_nopage' for m in msgs)==2,stage+' exactly two no-page messages')
        expect(counts==[44,44,44],f'page refill accepted counts {counts}')
        expect(ms('nopage') and ms('refill') and ms('nopage')[0]['epoch']==ms('refill')[0]['epoch'],'refill without reset')
    elif test=='tb_tx_net':
        expect(max((c for c,_,_ in events),default=0)<=200000,'netlist cycle budget')
        expect({1,17,18,300,1471}<={m['n'] for m in ms('lengths')},'netlist lengths')
        expect({1,3}=={(m['words'][0]>>1)&3 for m in ms('lengths')},'netlist networks')
        spacing('queue',20000,5)
        counts=collections.Counter(m['result'] for stage in stages for m in ms(stage))
        expect(all(counts[x]==1 for x in ('drop_full','drop_dis','drop_long')),'netlist drops')
