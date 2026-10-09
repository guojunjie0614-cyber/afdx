"""双端系统激励；只产生总线、消息和链路操作，不读取实现。"""
import argparse
import random
from pathlib import Path
from afdx_ref import build_frame, line_bytes, PREAMBLE, fcs


class Cases:
    def __init__(self, seed):
        self.rng=random.Random(seed);self.commands=[];self.payload=bytearray()
        self.words={};self.rx={};self.frames=[0]*4;self.message=0
    def emit(self,s):self.commands.append(s)
    def stage(self,s):self.emit('P '+s)
    def write(self,es,addr,value):self.emit(f'C {es} {addr:x} {value:x} 0')
    def blob(self,data):
        off=len(self.payload);self.payload.extend(data);return off
    def data(self,n):
        self.message+=1
        return bytes((self.message*37+i*19+(self.message>>(i%3)))&255 for i in range(n))
    def config(self,es,vl=0,*,idx=None,vlid=None,nets=3,bag=800,maximum=1471,qmax=63,en=1,rm=1,ic=1,rxnets=3,rxmax=None,skew=20):
        idx=vl if idx is None else idx;vlid=(100 if es==1 else 2000)+vl if vlid is None else vlid
        words=[maximum<<9|qmax<<3|nets<<1|en,bag,vlid,0x0a000001+es*256+vl,0xe0e00000|vlid,(1000+vl)<<16|2000+vl]
        self.words[es,vl]=words
        for w,v in enumerate(words):self.write(es,0x1000+vl*8+w,v)
        rw=1|rxnets<<1|ic<<3|rm<<4|skew<<5|(maximum if rxmax is None else rxmax)<<17
        self.write(3-es,0x10000+vlid,0x1000|idx);self.write(3-es,0x20000+idx,rw)
        self.rx[3-es,idx]=rw
        return words
    def user(self):
        self.write(1,2,0x1234);self.write(2,2,0xabcd)
    def msg(self,es,vl=0,n=18,pen=0,drain=False):
        off=self.blob(self.data(n));self.emit(f'M {es} {vl} {n} {pen} {3123+vl:04x} {4567+vl:04x} {off}')
        w=self.words.get((es,vl),[0])[0]
        if w&1 and n<=w>>9:
            for net in range(2):
                if w&(2<<net):self.frames[(es-1)*2+net]+=1
        if drain:self.emit('D')
    def pair(self,vl=0,n=18):
        a=self.blob(self.data(n));b=self.blob(self.data(n));self.emit(f'B {vl} {n} {a} {b}')
        for es in (1,2):
            for net in range(2):
                if self.words[es,vl][0]&(2<<net):self.frames[(es-1)*2+net]+=1
    def action(self,link,mode,byte=30,mask=1,ahead=1):
        self.emit(f'A {link} {self.frames[link]+ahead} {mode} {byte} {mask}')
    def inject(self,link,wire):self.emit(f'J {link} {len(wire)} {self.blob(wire)}');self.emit('D')
    def counts(self):self.emit('T')
    def save(self,out):
        out.mkdir(parents=True,exist_ok=True)
        (out/'sys_commands.txt').write_text('\n'.join(self.commands)+'\n',encoding='ascii')
        (out/'sys_payload.hex').write_text(''.join(f'{x:02x}\n' for x in self.payload),encoding='ascii')
        (out/'sys_payload.count').write_text(str(len(self.payload))+'\n',encoding='ascii')


def basic(s):
    s.stage('basic');s.user()
    for es in (1,2):
        for vl,(maximum,nets,bag) in enumerate(((17,1,672),(18,2,1013),(511,3,4001),(1471,3,12227))):
            s.config(es,vl,maximum=maximum,nets=nets,bag=bag)
    for k in range(4):
        for es in (1,2):
            for vl,n in enumerate((1 if k%2==0 else 17,18,17+s.rng.randrange(495),1471 if k<2 else s.rng.randrange(1,1472))):s.msg(es,vl,n,k%2)
        s.emit('D')
    s.counts()


def fault(s):
    s.stage('fcs');s.user()
    for es in (1,2):s.config(es)
    for es in (1,2):
        l=(es-1)*2;s.msg(es,drain=True)
        s.action(l,2);s.msg(es,drain=True);s.msg(es,drain=True)
        s.action(l,2);s.action(l+1,2);s.msg(es,drain=True);s.msg(es,drain=True)
        s.action(l+1,2);s.msg(es,drain=True);s.msg(es,drain=True)
    s.counts();s.stage('duplicate')
    for es in (1,2):
        s.msg(es,drain=True)
        for l in ((es-1)*2,(es-1)*2+1):s.emit(f'R {l} {s.frames[l]}');s.emit('D')
    s.counts();s.stage('reorder')
    for es in (1,2):
        for l in ((es-1)*2,(es-1)*2+1):
            s.action(l,3);s.msg(es,drain=True);held=s.frames[l]
            s.msg(es,drain=True);s.emit(f'R {l} {held}');s.emit('D');s.msg(es,drain=True)
    s.counts()
    for name in ('len','unk','ip_hdr','udp_hdr'):
        s.stage(name)
        for l in range(4):
            vlid=33333 if name=='unk' else (100 if l<2 else 2000)
            b=bytearray(build_frame(bytes(range(18)),net='A' if l%2==0 else 'B',vlid=vlid,dst_ip=0xe0e00000|vlid,sn=100))
            if name=='len':b=bytearray(build_frame(bytes(1471),net='A' if l%2==0 else 'B',dst_ip=0xe0e00001))+b'\0'
            if name=='ip_hdr':b[24]^=1
            if name=='udp_hdr':b[40]=1
            s.inject(l,line_bytes(b))
        for es in (1,2):s.msg(es,drain=True)
        s.counts()
    s.stage('drop')
    for es in (1,2):
        for l in ((es-1)*2,(es-1)*2+1):s.action(l,1);s.msg(es,drain=True);s.msg(es,drain=True)
    s.counts();s.stage('cfg')
    for es in (1,2):
        s.config(es,1,rxnets=1);s.config(es,2,rxnets=2)
    for es in (1,2):s.msg(es,1,drain=True);s.msg(es,2,drain=True)
    s.counts()
    # 满速外部坏长度帧只影响适配/len统计，不污染正常VL的序号状态。
    for link,count in ((0,10),(1,13)):
        s.stage('gdrop_a' if link==0 else 'gdrop_b')
        s.pair();s.emit('D')
        wire=line_bytes(build_frame(bytes(1471),net='A' if link==0 else 'B',vlid=100,dst_ip=0xe0e00064)+b'\0')
        off=s.blob(wire)
        for _ in range(count):s.emit(f'J {link} {len(wire)} {off}')
        s.emit('D');s.counts();s.pair();s.emit('D');s.counts()


def delay(s):
    s.stage('equal');s.user()
    for es in (1,2):s.config(es,skew=2)
    for k in range(3):s.pair();s.emit('D')
    for stage,da,db in (('a_late',15003,13001),('b_late',13001,15003),('boundary_inside',13001,21193),('boundary_outside',13001,25289)):
        s.stage(stage)
        for l in range(4):s.emit(f'L {l} {da if l%2==0 else db}')
        for k in range(3):s.pair();s.emit('W 26000');s.emit('D')
        s.counts()


def load(s):
    s.stage('all128');s.user()
    for idx in range(4096):s.write(2,0x20000+idx,1|6|8|16|20<<5|1471<<17)
    indices=[0,4095]+s.rng.sample(list(range(1,4095)),254)
    for es in (2,):s.config(es,maximum=1471)
    for roundno in range(2):
        if roundno:s.stage('all128_round2')
        for vl in range(128):s.config(1,vl,idx=indices[roundno*128+vl],vlid=5000+roundno*128+vl,maximum=1471,bag=800)
        s.msg(1,127,1471)
        for vl in range(128):s.msg(1,vl,1)
        s.msg(2,0,1471);s.emit('D')
    s.stage('sixteen153')
    for vl in range(128):
        if vl<16:s.config(1,vl,maximum=153,bag=800)
        else:s.write(1,0x1000+vl*8,0)
    for k in range(24):
        for vl in range(16):s.msg(1,vl,153)
    s.emit('D');s.counts();s.stage('bidirectional')
    for es in (1,2):
        for vl in range(16):s.config(es,vl,maximum=153,bag=800)
    for k in range(12):
        for vl in range(16):s.pair(vl,153)
    s.emit('D');s.counts();s.stage('drops')
    s.config(1,125,en=0);s.msg(1,125,drain=True)
    s.config(1,126,maximum=1);s.msg(1,126,18,drain=True)
    s.config(1,127,qmax=0);s.msg(1,127,drain=True)
    s.emit('D');s.config(1,0,bag=100000,maximum=1471,qmax=63)
    s.msg(1,0,1,drain=True)
    for k in range(48):s.msg(1,0,1471)
    s.msg(1,0,1024);s.msg(1,0,1);s.emit('D');s.counts()


def cfg(s):
    s.stage('registers');s.user()
    for es in (1,2):s.config(es)
    for es in (1,2):
        for a in (0,1,2):s.emit(f'Q {es} {a:x} 8')
        s.emit(f'U {es} beef');s.emit(f'Q {es} 2 4')
        for a in (3,0x80,0x1400,0x21000,0x30000+(2000 if es==1 else 100)):
            s.write(es,a,0);s.emit(f'Q {es} {a:x} 4')
    for k in range(3):s.pair();s.emit('D')
    s.stage('pulse_reads')
    for es,a in ((1,0x40),(1,0x45),(2,0x48),(2,0x59)):
        off=s.blob(b''.join(s.data(18) for _ in range(12)));s.emit(f'V {es} {a:x} 33000 {off}');s.emit('D')
    s.stage('rewrite')
    off=s.blob(b''.join(s.data(18) for _ in range(600)))
    s.emit('X '+' '.join(f'{v:x}' for v in s.words[1,0])+f' {s.rx[2,0]:x} 18 {off} 600')
    s.emit('D');s.pair();s.emit('D');s.counts()
    s.stage('new_value')
    value=(s.words[1,0][0]&~(2047<<9))|(17<<9)
    off=s.blob(s.data(18))
    s.emit(f'Y 1 0 {value:x} 18 {off}')
    s.words[1,0][0]=value
    s.msg(1,0,1,drain=True);s.msg(2,0,18,drain=True);s.counts()


def reset(s):
    s.stage('reset');s.user()
    for es in (1,2):s.config(es)
    s.pair();s.emit('D')
    for victim in (2,1):
        peer=3-victim
        for k in range(8):s.msg(peer,0,1471)
        s.emit(f'Z {victim}');s.emit(f'Q {victim} 2 1');s.counts();s.emit('H')
        s.msg(peer,0,18,drain=True)
        s.config(peer);s.config(victim);s.write(victim,2,0x9876)
        for k in range(3):s.pair();s.emit('D')
        s.counts()


def ovf(s):
    s.stage('ovf');s.user()
    for es in (1,2):s.config(es)
    for n in (513,17,1000,18,1471,1):
        for es in (1,2):s.msg(es,0,n,drain=True)
    s.counts()


def net(s):
    s.stage('net');s.user()
    for es in (1,2):s.config(es,maximum=64)
    s.action(0,2,ahead=2)
    for k in range(4):s.pair(n=18+k)
    s.emit('D');s.counts()


def perf(s):
    s.stage('light_d0');s.user()
    for es in (1,2):s.config(es,maximum=1471,bag=125000)
    for delay in (0,257):
        if delay:s.stage('light_d257')
        for link in range(4):s.emit(f'L {link} {delay}')
        for n in (1,17,18,1471,511):
            offsets=[s.blob(b''.join(s.data(n) for _ in range(8))) for es in (1,2)]
            # 固定长度重复8次，150003模8为3；间隔明显大于BAG，覆盖八个慢字节相位。
            s.emit(f'K {n} 8 150003 {offsets[0]} {offsets[1]}')
            for link in range(4):s.frames[link]+=8
            s.emit('D');s.emit('W 150003')
        s.counts()
    phases=[(('throughput' if directions==1 else 'duplex')+f'_d{delay}',delay,directions,125000)
            for delay in (0,257) for directions in (1,2)]
    # 1526个线上字节加12字节帧间隔，慢线每字节8拍；十帧恰好一轮。
    phases.append(('limit_d0',0,2,10*(1526+12)*8))
    for name,delay,directions,bag in phases:
        s.stage(name)
        for link in range(4):s.emit(f'L {link} {delay}')
        for es in range(1,directions+1):
            for vl in range(10):s.config(es,vl,maximum=1471,bag=bag)
        offsets=[]
        for es in range(1,directions+1):
            offsets.append(s.blob(b''.join(s.data(1471) for _ in range(23*10))))
            for net in range(2):s.frames[(es-1)*2+net]+=23*10
        if directions==1:offsets.append(0)
        s.emit(f'F {directions} 23 {bag} {offsets[0]} {offsets[1]}')
        s.emit('D');s.counts()


def generate(test,seed,out):
    s=Cases(seed);globals()[test.removeprefix('tb_sys_')](s);s.save(out)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--test',required=True);p.add_argument('--seed',type=int,default=20261007);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();generate(a.test,a.seed,a.out)
