"""Receive IC/RM, simultaneous-load and finite-capacity stimulus matrices."""
from afdx_ref import fcs,PREAMBLE


def icrm(s):
    s.event(2,'K 64')
    clock=[5,0,64]
    def new(stage,idx,ic=1,rm=1,skew=20):
        s.stage(stage);vl=2000+idx;s.config(vl,idx,ic=ic,rm=rm,skew=skew);return vl
    def change(step):
        t=s.t;clock[1]=(clock[1]+(t-clock[0])//clock[2])&65535;clock[0]=t;clock[2]=step;s.clock_step(step)
    def aligned_start():
        start=max(s.t,max(s.ends.values())+96,s.last_config+17,s.init_at+64)
        end=start+71;phase=15 if clock[2]==16 else 16
        end+=(phase-(end-clock[0]))%clock[2]
        return end-71
    vl=new('ic_seq',100,1,0)
    for sn in (7,8,10,13,14,14,0,1,0,2,255,1,255,2,254,1,100,99,100,101):s.send(s.body(vlid=vl,sn=sn))
    vl=new('ic_nets',101,1,0)
    for net,sn in [('A',5),('A',6),('A',7),('B',5),('B',6),('B',7),('A',9),('B',10)]:s.send(s.body(vlid=vl,sn=sn,net=net),net=net)
    vl=new('ic_off',102,0,0)
    for sn in (5,5,3,200,0,77):s.send(s.body(vlid=vl,sn=sn))
    vl=new('rm_pair',103)
    for sn in range(10):s.pair(vlid=vl,sn=sn,first='A' if sn<5 else 'B')
    vl=new('rm_same',104)
    for sn in range(5):s.pair(vlid=vl,sn=sn,delay=0,when=aligned_start())
    vl=new('rm_single',105)
    for sn in range(10):s.send(s.body(vlid=vl,sn=sn,net='B'),net='B')
    vl=new('rm_loss',106)
    for sn in range(1,6):
        start=max(s.t,max(s.ends.values())+96)
        if sn!=3:s.send(s.body(vlid=vl,sn=sn),when=start,advance=False)
        s.send(s.body(vlid=vl,sn=sn,net='B'),net='B',when=start+300,advance=False);s.t=max(s.ends.values())+96
    vl=new('rm_skew',107,0,1,20)
    for sn,delta in ((1,20),(2,21)):
        start=aligned_start();s.pair(vlid=vl,sn=sn,delay=delta*64,when=start)
    s.t=max(s.ends.values())+2500;s.config(2208,108,ic=0,rm=1,skew=0)
    for sn,delta in ((1,0),(2,1)):
        start=aligned_start();s.pair(vlid=2208,sn=sn,delay=delta*64,when=start)
    s.t=max(s.ends.values())+2500;s.config(2210,111,ic=0,rm=1,skew=20)
    for n,sn,before,delay in ((1,11,17,1299),(20,12,1,1324)):
        # 根据线上实际字节数对齐帧尾；两组分别让整个 e+1..e+16 窗口在 T 的一侧。
        s.t=max(s.t,max(s.ends.values())+2000)
        duration=(55+max(n,17))
        end=s.t+duration-1;end+=(-before-(end-clock[0]))%64
        s.pair(n=n,vlid=2210,sn=sn,delay=delay,when=end-duration+1)
    s.t=max(s.ends.values())+2500;s.config(2211,112,ic=0,rm=1,skew=20)
    start=aligned_start();body=s.body(vlid=2211,sn=13)
    for i,net in enumerate(('A','B','A')):
        b=bytearray(body);b[11]=0x20 if net=='A' else 0x40
        s.send(bytes(b),net=net,when=start+i*768,advance=False)
    s.t=max(s.ends.values())+2500
    s.t=max(s.ends.values())+2500;change(16);s.config(2209,109,ic=0,rm=1,skew=4095)
    start=aligned_start();s.pair(vlid=2209,sn=1,delay=4000*16,when=start)
    s.t=max(s.ends.values())+2500;change(64)
    vl=new('rm_ahead',110,0,1,4095)
    for i,sn in enumerate((10,11,13,140,14,139,140,13,141,0,77,0,0,255,1,254,128,1,2,129,1)):
        net='A' if i%2==0 else 'B';s.send(s.body(vlid=vl,sn=sn,net=net),net=net)
    s.stage('rm_modes')
    for k,(ic,rm) in enumerate(((0,0),(0,1),(1,0),(1,1))):s.config(2300+k,120+k,ic=ic,rm=rm,skew=20)
    for k in range(4):
        for sn in (1,2,3,5,9):s.pair(vlid=2300+k,sn=sn)
    s.stage('cfg_keep');s.config(2310,124,ic=1,rm=1,skew=4095,maximum=20)
    s.config(2311,125,nets=1,ic=1,rm=1,skew=4095)
    for sn,n in ((1,1),(2,21),(3,20),(5,21),(4,1)):s.send(s.body(n,vlid=2310,sn=sn))
    for net,sn in (('A',1),('B',5),('A',2),('B',3),('A',3)):
        s.send(s.body(vlid=2311,sn=sn,net=net),net=net)
    s.stage('rm_wrap');z=s.reset(0xfb80,64);clock[:]=[z+4,0xfb80,64];s.config(2400,130,ic=1,rm=1,skew=20)
    wrap=z+4+(65536-0xfb80)*64
    for sn in range(6):s.pair(vlid=2400,sn=sn,when=wrap-6100+2000*sn-71)
    s.stage('aging');change(16);s.config(2500,140,ic=0,rm=1,skew=100);s.config(2501,141,ic=0,rm=1,skew=100)
    first=aligned_start()
    for net,vl in (('A',2500),('B',2501)):s.send(s.body(vlid=vl,sn=5,net=net),net=net,when=first,advance=False)
    later=first+(65536+10)*16
    for net,vl,sn in (('A',2500,5),('B',2501,4)):s.send(s.body(vlid=vl,sn=sn,net=net),net=net,when=later,advance=False)
    s.t=max(s.ends.values())+96
    vl=new('reset',150,1,1,20)
    a_start=max(s.t,max(s.ends.values())+96);_,e=s.send(s.body(1471,vlid=vl,sn=50),when=a_start,advance=False)
    s.send(s.body(1471,vlid=vl,sn=50,net='B'),net='B',when=e+500,advance=False)
    cut=e+750;s.event(cut-1,'B 1');s.reset(0,64,when=cut);clock[:]=[cut+4,0,64]
    s.send(s.body(1,vlid=vl,sn=51),when=cut+1000,advance=False)
    s.send(s.body(1,vlid=vl,sn=52),when=s.init_at-64,advance=False)
    s.t=max(s.ends.values())+250
    s.send(s.body(vlid=vl,sn=175))
    s.t=max(s.ends.values())+202;s.event(s.t,f'C map {vl:x} {0x1000|150:x}');s.last_config=s.t;s.t+=17
    s.send(s.body(vlid=vl,sn=176,net='B'),net='B')
    s.t=max(s.ends.values())+202
    value=1|6|8|16|(20<<5)|(1471<<17)
    s.event(s.t,f'C cfg {150:x} {value:x}');s.last_config=s.t;s.t+=17
    s.pair(vlid=vl,sn=177)


def ring(s):
    s.stage('fit');s.config(1000,0)
    for n in (511,512):s.send(s.body(n));s.t=max(s.ends.values())+2000
    s.stage('big')
    for n in (513,1471):s.send(s.body(n));s.send(s.body(10));s.t=max(s.ends.values())+2000
    s.stage('part')
    for n in (212,213):
        start=max(s.t,max(s.ends.values())+2500);_,be=s.send(s.body(512,net='B'),net='B',when=start,advance=False)
        _,ae=s.send(s.body(300),when=be+16-(300+55)+1,advance=False)
        s.send(s.body(n),when=ae+9,gap=8,advance=False);s.t=max(s.ends.values())+2500
    s.stage('ic');s.config(1001,1,ic=1,rm=0)
    for sn,n in ((1,10),(3,513),(2,10)):s.send(s.body(n,vlid=1001,sn=sn))


def dq(s):
    s.stage('dq');s.config(1000,0,ic=1,rm=1,skew=4095)
    _,end=s.send(s.body(1471,sn=1),advance=False)
    for i,sn in enumerate((2,3,4)):s.send(s.body(1,sn=sn,net='B'),net='B',when=end+64-71+i*80,advance=False)
    s.t=max(s.ends.values())+2500
    for sn in (2,3,4):s.send(s.body(1,sn=sn))
    s.send(s.body(1,sn=6,net='B'),net='B')


def load(s):
    s.stage('load')
    for i in range(64):s.config(3000+i,i,ic=i&1,rm=(i>>1)&1,skew=100)
    sequence=[0]*64;prior={};start=max(s.t,s.last_config+17)
    for i in range(1600):
        vl=s.rng.randrange(64);mode=s.rng.randrange(100)
        n=1471 if i%25==0 else s.rng.choice((1,1,1,17,18,32,64))
        sn=sequence[vl]
        if mode>=96:sn=(sn+3)%255 or 1
        if 92<=mode<96 and vl in prior:
            body=prior[vl];n=int.from_bytes(body[38:40],'big')-8
        else:
            body=s.body(n,vlid=3000+vl,sn=sn);sequence[vl]=1 if sn==255 else sn+1;prior[vl]=body
        a=bytearray(body);b=bytearray(body);a[11]=0x20;b[11]=0x40
        if 70<=mode<78:
            other=(vl+s.rng.randrange(1,64))%64;sn2=sequence[other]
            b=bytearray(s.body(n,vlid=3000+other,sn=sn2,net='B'));sequence[other]=1 if sn2==255 else sn2+1
        if 83<=mode<88:
            target=a if i&1 else b;target[0]^=1
        if 88<=mode<92:
            target=a if i&1 else b;target[4:6]=b'\xbe\xef'
        wa=bytearray(PREAMBLE+a+fcs(a));wb=bytearray(PREAMBLE+b+fcs(b))
        if 78<=mode<83:
            target=wa if i&1 else wb;target[-1]^=1
        assert len(wa)==len(wb)
        s.send(net='A',when=start,wire=bytes(wa),advance=False);s.send(net='B',when=start+200,wire=bytes(wb),advance=False)
        start+=8*len(wa)+96 # 保留原随机负载的提交时间，原生高负载另由系统性能阶段覆盖。
    s.t=max(s.ends.values())+96
