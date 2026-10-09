"""ARCH v0.4 RX: absolute-cycle stimulus and independent H1-H7 reconstruction.

rx_control.txt: P cycle stage; C cycle map|cfg address_hex data_hex;
Z cycle now_hex step (four reset cycles); K cycle step; B cycle 1 (reset precondition).
rx_core.meta: counts A/B, byte count, final cycle, then start/offset/length per network.
rx_wire.hex: concatenated wire bytes. check() opens only events.txt and dump_[ab].txt.
"""
import bisect
import collections
import copy
import itertools
import json
import random
import struct
from pathlib import Path
from afdx_ref import build_frame, fcs, ip_checksum, PREAMBLE


def checksum_udp(body):
    n=int.from_bytes(body[38:40],'big')
    return ip_checksum(body[26:34]+b'\x00\x11'+body[38:40]+body[34:34+n])


def repair(body, *, ip=True, udp=False):
    body=bytearray(body)
    if ip and len(body)>=34:
        body[24:26]=b'\0\0';body[24:26]=ip_checksum(body[14:34]).to_bytes(2,'big')
    if udp:
        body[40:42]=b'\0\0';value=checksum_udp(body);body[40:42]=(value or 65535).to_bytes(2,'big')
    return bytes(body)


class Scenario:
    def __init__(self,seed):
        self.rng=random.Random(seed);self.t=70000;self.events=[];self.frames={'A':[],'B':[]};self.ends={'A':0,'B':0}
        self.payload=bytearray();self.last_config=0;self.ident=0;self.reset_time=1;self.init_at=65541
    def event(self,cycle,command):self.events.append((cycle,len(self.events),command))
    def stage(self,name):
        self.t=max(self.t,max(self.ends.values())+2500);self.event(self.t,'P '+name);self.t+=1
    def config(self,vlid,idx,*,en=1,nets=3,ic=0,rm=0,skew=100,maximum=1471):
        self.t=max(self.t,max(self.ends.values())+202)
        self.event(self.t,f'C map {vlid:x} {0x1000|idx:x}');self.t+=1
        value=en|(nets<<1)|(ic<<3)|(rm<<4)|(skew<<5)|(maximum<<17)
        self.event(self.t,f'C cfg {idx:x} {value:x}');self.last_config=self.t;self.t+=17
    def unmap(self,vlid):
        self.t=max(self.t,max(self.ends.values())+202);self.event(self.t,f'C map {vlid:x} 0');self.last_config=self.t;self.t+=17
    def body(self,n=1,*,vlid=1000,sn=0,net='A',sport=1000,dport=2000,payload=None):
        if payload is None:payload=self.rng.randbytes(n)
        body=build_frame(payload,net=net,vlid=vlid,sn=sn,ident=self.ident&65535,sport=sport,dport=dport)
        self.ident+=1;return body
    def send(self,body=None,*,net='A',when=None,prefix=8,gap=96,wire=None,advance=True):
        if wire is None:wire=b'\x55'*(prefix-1)+b'\xd5'+body+fcs(body)
        start=max(self.t,self.ends[net]+gap,self.last_config+17,self.init_at+64) if when is None else when
        assert start>=self.ends[net]+8,(net,start,self.ends[net])
        offset=len(self.payload);self.payload.extend(wire);self.frames[net].append((start,offset,len(wire)))
        self.ends[net]=start+8*len(wire)
        if advance:self.t=max(self.t,self.ends[net]+gap)
        return start,self.ends[net]-1
    def pair(self,*,n=1,vlid=1000,sn=0,delay=200,first='A',when=None):
        start=max(self.t,max(self.ends.values())+96,self.last_config+17,self.init_at+64) if when is None else when
        data=self.rng.randbytes(n);template=self.body(n,vlid=vlid,sn=sn,net=first,payload=data)
        for net in (first,'B' if first=='A' else 'A'):
            body=bytearray(template);body[11]=0x20 if net=='A' else 0x40
            self.send(bytes(body),net=net,when=start+(0 if net==first else delay),advance=False)
        self.t=max(self.ends.values())+96
    def reset(self,value=0,step=4096,when=None):
        t=self.t if when is None else when;self.event(t,f'Z {value:04x} {step}');self.reset_time=t;self.init_at=t+65540
        # 在途线路被测试驱动器截断；随后的计划从新的空闲状态开始。
        self.ends={n:min(e,t) for n,e in self.ends.items()};self.t=self.init_at+100
        return t
    def clock_step(self,step):self.event(self.t,f'K {step}');self.t+=1
    def write(self,out):
        commands=[]
        for cycle,_,command in sorted(self.events):
            kind,_,tail=command.partition(' ');commands.append(f'{kind} {cycle} {tail}'.rstrip())
        (out/'rx_control.txt').write_text('\n'.join(commands)+'\n',encoding='ascii')
        end=max(self.t,max(self.ends.values()))+5000
        meta=[f'{len(self.frames["A"])} {len(self.frames["B"])} {len(self.payload)} {end}']
        for net in ('A','B'):
            meta.extend(' '.join(map(str,row)) for row in sorted(self.frames[net]))
        (out/'rx_core.meta').write_text('\n'.join(meta)+'\n',encoding='ascii')
        (out/'rx_wire.hex').write_text(''.join(f'{x:02x}\n' for x in self.payload),encoding='ascii')
        return dict(segments_a=len(self.frames['A']),segments_b=len(self.frames['B']),bytes=len(self.payload),cycles=end)


def basic(s):
    s.stage('len');s.config(1000,42)
    bodies=[]
    for n in [1,16,17,18,255,256,257,1470,1471]+[s.rng.randrange(1,1472) for _ in range(32)]:
        b=s.body(n);bodies.append(b);s.send(b)
    for b in bodies[:5]:s.send(b,net='B')
    s.stage('nets')
    for i in range(3):s.config(1100+i,100+i,nets=(1,2,3)[i])
    for i in range(3):
        for _ in range(3):
            for net in ('A','B'):s.send(s.body(vlid=1100+i,net=net),net=net)
    s.stage('map');ids=[0,65535,0xa593];indices=[0,4095,2300]
    for vl,idx in zip(ids,indices):s.config(vl,idx,maximum=20)
    s.config(1200,202,en=0)
    for vl in ids:s.send(s.body(1,vlid=vl))
    s.send(s.body(1,vlid=0x7ffa));s.send(s.body(1,vlid=1200));s.send(s.body(20,vlid=ids[2]));s.send(s.body(21,vlid=ids[2]))
    s.unmap(ids[2]);s.send(s.body(1,vlid=ids[2]))
    s.stage('ports');s.config(1300,300)
    for a in (0,65535,s.rng.randrange(65536)):
        for b in (0,65535,s.rng.randrange(65536)):s.send(s.body(23,vlid=1300,sport=a,dport=b))
    s.stage('preamble');s.config(1301,301)
    for i,prefix in enumerate((1,2,7,8,9,16,1,8)):
        start=max(s.t,s.ends['A']+96,s.last_config+17);start+=(i-start)%8
        s.send(s.body(1,vlid=1301),when=start,prefix=prefix)
    s.stage('gap');s.config(1302,302);s.config(1303,303)
    for _ in range(20):s.send(s.body(1,vlid=1302))
    for i in range(20):
        start=max(s.ends['A']+8,s.last_config+17)
        s.send(s.body(1 if i%2==0 else 1471,vlid=1302),when=start,gap=8)
    for _ in range(5):
        start=max(s.ends.values())+96
        for net,vl in (('A',1302),('B',1303)):s.send(s.body(1,vlid=vl,net=net),net=net,when=start,advance=False)
        s.t=max(s.ends.values())+96
    s.stage('all4096');ids=[0,65535]+s.rng.sample(range(1,65535),4094);s.rng.shuffle(ids)
    for idx,vl in enumerate(ids):s.config(vl,idx,ic=1,rm=1)
    for sn in (0,1):
        for vl in ids:s.pair(vlid=vl,sn=sn)


def fault_wire(body,kind,value=None):
    b=bytearray(body)
    if kind=='fcs':
        wire=bytearray(PREAMBLE+b+fcs(b));wire[-1]^=1;return bytes(wire)
    if kind=='data':
        wire=bytearray(PREAMBLE+b+fcs(b));wire[8+42]^=1;return bytes(wire)
    if kind=='length':
        n=value
        raw=bytes(b[:max(0,n-4)])
        if n>len(b)+4:raw=bytes(b)+bytes(n-len(b)-4)
        wire=raw+fcs(raw) if n>=4 else bytes(n)
        return PREAMBLE+wire
    if kind=='badpre':return b'\x55\x56'+PREAMBLE+bytes(b)+fcs(b)
    if kind=='only55':return b'\x55'*value
    no_ip=False
    if kind=='byte':b[value]^=1
    elif kind=='ihl':b[14]=value
    elif kind=='protocol':b[23]=value
    elif kind=='fragment':b[20:22]=value.to_bytes(2,'big')
    elif kind=='ipcheck':b[24:26]=((int.from_bytes(b[24:26],'big')+1)&65535).to_bytes(2,'big');no_ip=True
    elif kind=='udplen':
        b[38:40]=value.to_bytes(2,'big');b[16:18]=(value+20).to_bytes(2,'big')
    elif kind=='iplen':b[16:18]=(int.from_bytes(b[16:18],'big')+value).to_bytes(2,'big')
    elif kind=='size':b=b[:-1]+b'\x00'+b[-1:] if value>0 else b[:-2]+b[-1:]
    elif kind=='udpcheck':
        b=bytearray(repair(b,udp=True));v=(int.from_bytes(b[40:42],'big')+1)&65535;b[40:42]=(v or 1).to_bytes(2,'big')
    elif kind=='unknown':b[4:6]=b'\xbe\xef'
    b=repair(b,ip=not no_ip)
    return PREAMBLE+b+fcs(b)


def fault(s):
    next_sn={0:0,1:0}
    def pair(kind,n=1,value=None,which=0,corrupt_fcs=False):
        net='A' if which==0 else 'B';sn=next_sn[which];vl=1000+which
        b=s.body(n,vlid=vl,sn=sn,net=net)
        wire=fault_wire(b,kind,value)
        if corrupt_fcs:wire=wire[:-1]+bytes([wire[-1]^1])
        s.send(net=net,wire=wire);s.send(b,net=net)
        next_sn[which]=1 if sn==255 else sn+1
        return b
    s.stage('fcs');s.config(1000,10,ic=1,rm=1);s.config(1001,11,ic=1,rm=1)
    for n in (1,300,1471):
        for kind in ('fcs','data'):pair(kind,n)
    pair('fcs',300,which=1);pair('data',1471,which=1)
    # 两处错误同时存在，分类仍须优先使用 MAC 的 FCS 结论。
    pair('byte',32,0,corrupt_fcs=True);pair('ipcheck',32,corrupt_fcs=True)
    pair('fragment',32,0x2000,1,corrupt_fcs=True)
    s.stage('len')
    for count in (0,1,4,20,60,63,1519,1600):pair('length',1471 if count>1518 else 1,count)
    pair('length',1,63,1);pair('length',1471,1519,1)
    pair('length',1,63,corrupt_fcs=True);pair('length',1471,1519,corrupt_fcs=True)
    pair('length',1,63,1,corrupt_fcs=True)
    s.stage('preamble');pair('badpre')
    for count in (1,7,20):pair('only55',1,count)
    pair('badpre',which=1);pair('only55',1,20,1)
    s.stage('hdr')
    for pos in (0,1,2,3,12,13):pair('byte',32,pos)
    for value in (0x46,0x44,0x65):pair('ihl',32,value)
    for value in (6,1):pair('protocol',32,value)
    for value in (0x2000,1,0x1fff):pair('fragment',32,value)
    pair('ipcheck',32)
    for value in (8,7):pair('udplen',1,value)
    for value in (1,-1):pair('iplen',32,value)
    for n in (1,17,18,300):
        for value in (1,-1):pair('size',n,value)
    pair('udpcheck',33);pair('ipcheck',32,which=1);pair('udpcheck',33,which=1)
    s.stage('ok')
    for which in (0,1):
        variants=range(8) if which==0 else (0,6)
        for variant in variants:
            sn=next_sn[which];net='A' if which==0 else 'B';b=bytearray(s.body(17 if variant!=7 else 18,vlid=1000+which,sn=sn,net=net))
            if variant==0:b[20]=0x40
            elif variant==1:b[15]=0xe3
            elif variant==2:b[18:20]=b'\xde\xad'
            elif variant==3:b[22]=0xf3
            elif variant==4:b[6:12]=s.rng.randbytes(6)
            b=repair(b,udp=variant in (6,7));s.send(b,net=net);next_sn[which]=1 if sn==255 else sn+1
    # 接收方不检查以太网填充值，UDP 校验和只覆盖有效载荷。
    for which,n,udp in ((0,1,True),(0,16,True),(1,1,False)):
        net='A' if which==0 else 'B';sn=next_sn[which]
        b=bytearray(s.body(n,vlid=1000+which,sn=sn,net=net))
        b[42+n:59]=bytes(range(1,18-n));b=repair(b,udp=udp)
        s.send(b,net=net);next_sn[which]=1 if sn==255 else sn+1
    s.stage('six');last=pair('fcs');s.send(last,net='B')
    start=next_sn[0]
    for delta in (0,2,1,3):s.send(s.body(1,sn=start+delta))
    next_sn[0]=start+4
    pair('length',1471,1519);pair('unknown');pair('ipcheck');pair('udpcheck',33)
    pair('fcs',which=1);pair('udpcheck',33,which=1)


def net(s):
    s.stage('net');s.config(1000,0,ic=1,rm=1);s.config(1001,1,nets=1)
    for sn,n in enumerate((1,17,18,300,1471)):s.pair(n=n,sn=sn)
    b=s.body(17,sn=5);s.send(wire=fault_wire(b,'fcs'));s.send(wire=fault_wire(b,'byte',0));s.send(s.body(17,sn=7))
    s.send(s.body(1,vlid=1001));s.send(s.body(18,vlid=1001));s.send(s.body(1,vlid=1001),net='B');s.send(s.body(1,vlid=0xbeef))


def generate(test,seed,out):
    from rx_cases import icrm,load,ring,dq
    s=Scenario(seed)
    {'tb_rx_basic':basic,'tb_rx_fault':fault,'tb_rx_net':net,'tb_rx_icrm':icrm,'tb_rx_load':load,'tb_rx_ovf_ring':ring,'tb_rx_ovf_dq':dq}[test](s)
    return s.write(out)


def decode(wire):
    p=0
    while p<len(wire) and wire[p]==0x55:p+=1
    if p==len(wire) or wire[p]!=0xd5:return {'category':'len'}
    body=wire[p+1:];info={'prefix':p+1,'length':len(body),'category':'len'}
    if not 64<=len(body)<=1518:return info
    info['category']='fcs'
    if fcs(body[:-4])!=body[-4:]:return info
    info['category']='hdr';b=body[:-4]
    length=int.from_bytes(b[38:40],'big');n=length-8
    if b[:4]!=b'\x03\0\0\0' or b[12:15]!=b'\x08\x00\x45' or b[23]!=17:return info
    if int.from_bytes(b[20:22],'big')&0x3fff or ip_checksum(b[14:34])!=0:return info
    if not 1<=n<=1471 or int.from_bytes(b[16:18],'big')!=n+28 or len(body)!=47+max(n,17):return info
    if b[40:42]!=b'\0\0' and checksum_udp(b)!=0:return info
    info.update(category='good',n=n,vlid=int.from_bytes(b[4:6],'big'),sn=b[42+max(n,17)],sport=int.from_bytes(b[34:36],'big'),dport=int.from_bytes(b[36:38],'big'),payload=b[42:42+n])
    return info


def check(test,folder):
    items=errors=either=0;diagnostics=[]
    def expect(ok,text):
        nonlocal items,errors
        items+=1
        if not ok:
            errors+=1
            if len(diagnostics)<35:diagnostics.append(text)
    rows=[]
    for i,line in enumerate((folder/'events.txt').read_text().splitlines()):
        p=line.split();rows.append((int(p[1]),i,p))
    rows.sort();resets=[c for c,_,p in rows if p[0]=='Z'];inits=[c for c,_,p in rows if p[0]=='I']
    params={p[2]:int(p[3]) for _,_,p in rows if p[0]=='G'}
    clocks=[(c,int(p[2],16),int(p[3])) for c,_,p in rows if p[0]=='K'];clock_cycles=[x[0] for x in clocks]
    def now(c):
        k=clocks[bisect.bisect_right(clock_cycles,c)-1]
        return (k[1]+(c-k[0])//k[2])&65535
    pulses=[dict(cycle=c,name=p[2],used=False) for c,_,p in rows if p[0]=='E']
    by_name=collections.defaultdict(list)
    for p in pulses:by_name[p['name']].append(p)
    pulse_times={name:[p['cycle'] for p in values] for name,values in by_name.items()}
    def window(name,first,last):
        values=by_name[name];times=pulse_times.get(name,[])
        return [p for p in values[bisect.bisect_left(times,first):bisect.bisect_right(times,last)] if not p['used']]
    def ticks_between(first,last):
        result=0;i=max(0,bisect.bisect_right(clock_cycles,first)-1)
        while i<len(clocks) and clocks[i][0]<=last:
            c,_,step=clocks[i];a=max(first,c);b=min(last,clocks[i+1][0] if i+1<len(clocks) else last)
            result+=(b-c)//step-(a-c)//step;i+=1
        return result
    deliveries=[]
    for c,_,p in rows:
        if p[0]=='D':
            body=bytes.fromhex(p[7]);n=int(p[6]);expect(len(body)==n,'D length')
            deliveries.append(dict(cycle=c,net=p[2],idx=int(p[3]),sport=int(p[4],16),dport=int(p[5],16),n=n,payload=body,used=False))
    frames=[]
    for netname in ('A','B'):
        for line in (folder/f'dump_{netname.lower()}.txt').read_text().splitlines():
            p=line.split();start=int(p[1]);length=int(p[2]);wire=bytes.fromhex(p[3]);expect(p[0]==netname and len(wire)==length and p[3]==p[3].lower(),'capture format')
            f=dict(start=start,end=start+8*length-1,wire=wire,net=netname,epoch=bisect.bisect_right(resets,start),used=False)
            f.update(decode(wire));frames.append(f)
    frames.sort(key=lambda f:(f['end'],f['net']))
    # H2 的近同时帧允许交换：从结果/D的先后识别实际选择，再按协议验证该顺序。
    # 同拍帧不进入这里，仍严格 A 先；复位只截断交付队列的尾部。
    result_hints={}
    for epoch in range(1,len(resets)+1):
        epulses=[p for p in pulses if p['name']=='deliver' and bisect.bisect_right(resets,p['cycle'])==epoch]
        drows=[d for d in deliveries if bisect.bisect_right(resets,d['cycle'])==epoch]
        for p,d in zip(epulses,drows):result_hints[p['cycle']]=d['net']
    result_set={n+'_'+kind for n in ('a','b') for kind in ('unk','cfg','ic','ovf')}|{'deliver','rm_drop'}
    for i in range(len(frames)-1):
        a,b=frames[i:i+2]
        if a['net']==b['net'] or not 1<=b['end']-a['end']<=15:continue
        if any(f['category']!='good' or not window(f['net'].lower()+'_good',f['end']+1,f['end']+32) for f in (a,b)):continue
        candidates=sorted((p for name in result_set for p in window(name,a['end']+1,b['end']+150)),key=lambda p:p['cycle'])
        if not candidates:continue
        def hint(p):
            return p['name'][0].upper() if p['name'].startswith(('a_','b_')) else result_hints.get(p['cycle'])
        first=hint(candidates[0])
        if first is None and len(candidates)>1:
            second=hint(candidates[1]);first={'A':'B','B':'A'}.get(second)
        if first==b['net']:frames[i],frames[i+1]=b,a
        either+=2
    # 配置按真实事件回放，类脉冲只从抓包字节与容量边界推导。
    cfg={};mapping={};stage='initial';ep=0;cursor=0;states={};history=[];recent=collections.deque();previous_w={};stage_stats=collections.defaultdict(collections.Counter)
    def occupancy(net,t,earliest):
        value=0
        for old in recent:
            if old['epoch']!=ep or old['net']!=net:continue
            E=old['result_cycle'];D=old.get('delivery')
            if (E if earliest else E-8)>t:continue
            read=0 if D is None else max(0,min(old['n'],t-(D['cycle']-(4 if earliest else 0))+1))
            value+=old['n']-read
        return value
    for f in frames:
        while cursor<len(rows) and rows[cursor][0]<=f['start']:
            c,_,p=rows[cursor];cursor+=1
            if p[0]=='Z':cfg={};mapping={};states={};ep+=1
            elif p[0]=='P':stage=p[2]
            elif p[0]=='C':
                if p[2]=='map':mapping[int(p[3],16)]=int(p[4],16)
                elif p[2]=='cfg':cfg[int(p[3],16)]=int(p[4],16)
        f['stage']=stage;stage_stats[stage]['segments']+=1;e=f['end'];netname=f['net'];prefix=netname.lower()+'_'
        while recent and (recent[0]['epoch']!=ep or (recent[0].get('delivery') and recent[0]['delivery']['cycle']+recent[0]['n']<e-12000)):recent.popleft()
        following_reset=next((r for r in resets if r>f['start']),None)
        current_init=next((i for i in inits if i>=resets[f['epoch']-1]),1<<60)
        ignored=f['start']<current_init or (following_reset is not None and following_reset<=e)
        f['ignored']=ignored
        if ignored:continue
        optional=following_reset is not None and following_reset-e<150
        f['optional_reset']=following_reset if optional else None
        category=f['category'];allowed={category}
        if category=='good':
            begin=f['start']+8*(f['prefix']+46)
            used_min=min(occupancy(netname,t,True) for t in range(begin+1,begin+17))
            used_max=max(occupancy(netname,t,False) for t in range(begin+1,begin+17))
            capacity=1<<params['RX_RING_AW'];allowed=set()
            if capacity-used_max>=f['n']:allowed.add('good')
            elif capacity-used_min>=f['n']:allowed.update(('good','ovf'))
            else:allowed.add('ovf')
        candidates=sorted((p for name in allowed for p in window(prefix+name,e+1,e+32)),key=lambda p:p['cycle'])
        if optional and not candidates:continue
        expect(bool(candidates),f'H1 {netname} e={e} expected {allowed}, pulses={len(candidates)}')
        if not candidates:continue
        pulse=candidates[0];pulse['used']=True;category=pulse['name'][2:];f['class_cycle']=pulse['cycle'];f['observed_category']=category;stage_stats[stage][category]+=1
        if len(allowed)>1:either+=1
        if category!='good':continue
        result_names={prefix+x for x in ('unk','cfg','ic','ovf')}|{'rm_drop','deliver'}
        candidates=[p for name in result_names for p in window(name,pulse['cycle']+1,e+150)]
        if optional and not candidates:continue
        expect(bool(candidates),f'H2 missing result {netname} e={e}')
        if not candidates:continue
        actual=min(candidates,key=lambda p:p['cycle']);actual['used']=True;f['result_cycle']=actual['cycle'];f['result']=actual['name']
        mapped=mapping.get(f['vlid'],0);idx=mapped&4095;control=cfg.get(idx,0);f['idx']=idx;f['control']=control
        # 状态候选只包含协议允许的到达时刻，不使用RTL内部状态或激励期望。
        old_states=states.get(idx,[(None,None,None,None,None)])
        choices=[]
        times={now(t) for t in range(e+1,e+17)}
        if not mapped&4096:choices=[(prefix+'unk',st) for st in old_states]
        elif not(control&1) or not(control&(2 if netname=='A' else 4)) or f['n']>((control>>17)&2047):choices=[(prefix+'cfg',st) for st in old_states]
        else:
            for st in old_states:
                for arrival in times:
                    psna,psnb,last,lasttime,lastcycle=st;psn=psna if netname=='A' else psnb;sn=f['sn'];next_sn=1 if psn in (None,255) else psn+1;second=1 if next_sn==255 else next_sn+1
                    icok=psn is None or sn==0 or sn in (next_sn,second)
                    if control&8:
                        if netname=='A':psna=sn
                        else:psnb=sn
                    else:icok=True
                    state=(psna,psnb,last,lasttime,lastcycle)
                    if not icok:choices.append((prefix+'ic',state));continue
                    aged=lastcycle is not None and ticks_between(lastcycle,e)>32768
                    accept=not(control&16) or last is None or aged or ((arrival-lasttime)&65535)>((control>>5)&4095)
                    if not accept:
                        accept=sn!=last and (sn==0 or last==0 or 1<=(sn-last)%255<=127)
                    if not accept:choices.append(('rm_drop',state));continue
                    lo=999;hi=0
                    for t in range(actual['cycle']-8,actual['cycle']+1):
                        low=high=0
                        for old in recent:
                            if old['epoch']!=ep:continue
                            E=old['result_cycle'];D=old.get('delivery');V=D['cycle'] if D else 1<<60
                            if E<=t<V-8:low+=1
                            if E-8<=t<V:high+=1
                        lo=min(lo,low);hi=max(hi,high)
                    if hi>=(1<<params['RX_DQ_AW']):choices.append((prefix+'ovf',state))
                    if lo<(1<<params['RX_DQ_AW']):
                        if control&16:state=(psna,psnb,sn,arrival,e)
                        choices.append(('deliver',state))
        matching=[st for name,st in choices if name==actual['name']]
        expect(bool(matching),f'H2 {netname} e={e} sn={f["sn"]} expected={set(n for n,_ in choices)} actual={actual["name"]}')
        if matching:states[idx]=list(dict.fromkeys(matching))
        if len(set(name for name,_ in choices))>1:either+=1
        stage_stats[stage][actual['name']]+=1
        if actual['name']=='deliver':
            D=next((d for d in deliveries if not d['used']),None)
            matches=D and D['net']==netname and D['idx']==idx and D['sport']==f['sport'] and D['dport']==f['dport'] and D['payload']==f['payload']
            if not matches and following_reset is not None and following_reset<=max(e+200,previous_w.get(ep,e)+16)+f['n']-1:
                f['delivery']=None;history.append(f);recent.append(f);continue
            expect(bool(matches),f'H4 delivery {netname} e={e} idx={idx}')
            if D:
                D['used']=True;f['delivery']=D;W=previous_w.get(ep,-1);expect(e<D['cycle']<=max(e+200,W+16),f'H5 latency {D["cycle"]-e} at e={e}')
                previous_w[ep]=D['cycle']+D['n']-1
            history.append(f);recent.append(f)
    expect(all(d['used'] for d in deliveries),'H4 extra delivery')
    for p in pulses:
        if p['used']:continue
        # 复位前150拍内已经结束的帧可以没有完整结果链；不能放过清表或被截断的段。
        optional=any(not f.get('ignored') and f.get('optional_reset') and f['end']<p['cycle']<f['optional_reset'] for f in frames)
        expect(optional,f'H7 extra pulse {p["name"]} {p["cycle"]}')
    counts=collections.Counter(p['name'] for p in pulses)
    latency=max((f['delivery']['cycle']-f['end'] for f in history if f.get('delivery')),default=0)
    from rx_checks import stage_checks
    stage_checks(test,frames,rows,params,now,ticks_between,either,expect)
    result=dict(test=test,items=items,errors=errors,either=either,segments=len(frames),segments_a=sum(f['net']=='A' for f in frames),segments_b=sum(f['net']=='B' for f in frames),
                pulses=dict(counts),deliveries=len(deliveries),max_delivery_latency=latency,stages={k:dict(v) for k,v in stage_stats.items()},diagnostics=diagnostics)
    for line in diagnostics:print('[CHECK_FAIL] '+line)
    print(f'[CHECK] {test} {"PASS" if errors==0 else "FAIL"} items={items} errors={errors} either={either}')
    return result
