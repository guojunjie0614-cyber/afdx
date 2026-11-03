"""Task-card coverage and stage assertions, using reconstructed capture/event facts only."""
from collections import Counter,defaultdict


def stage_checks(test,frames,rows,params,now,ticks,either,expect):
    stages=defaultdict(list)
    for f in frames:stages[f['stage']].append(f)
    def require(names):expect(set(names)<=set(stages),'stage coverage '+str(names))
    def outcomes(name,expected):
        got=Counter(f.get('result',f.get('observed_category','ignored')) for f in stages[name])
        expect(got==Counter(expected),f'{name} outcomes {dict(got)} != {expected}')
    def delivered(fs):return all(f.get('result')=='deliver' and f.get('delivery') for f in fs)
    def pairs(fs,delay=200):
        groups=defaultdict(list)
        for f in fs:groups[(f.get('idx'),f.get('sn'))].append(f)
        for key,pair in groups.items():
            pair.sort(key=lambda f:(f['end'],f['net']))
            expect(len(pair)==2,f'pair count {key}')
            if len(pair)!=2:continue
            a,b=pair
            expect(a['net']!=b['net'] and b['end']-a['end']==delay,f'pair alignment {key}')
            expect(a.get('payload')==b.get('payload'),f'pair payload {key}')
            expect(a.get('result')=='deliver' and b.get('result')=='rm_drop',f'pair winner {key}')
        return groups
    def gaps(fs,gap):
        fs=sorted(fs,key=lambda f:f['start'])
        expect(all(b['start']-a['end']-1==gap for a,b in zip(fs,fs[1:])),f'wire gaps {gap}')
    def sn_list(name,wanted):expect([f.get('sn') for f in stages[name]]==wanted,f'{name} SN sequence')
    if test=='tb_rx_basic':
        require(('len','nets','map','ports','preamble','gap','all4096'))
        fs=stages['len'];aa=[f for f in fs if f['net']=='A'];bb=[f for f in fs if f['net']=='B']
        expect(len(aa)>=39 and len(bb)==5 and delivered(fs),'len coverage/deliver')
        expect({1,16,17,18,255,256,257,1470,1471}<={f.get('n') for f in aa},'len boundary set')
        expect(all(any(f['payload']==a['payload'] for a in aa) for f in bb),'len B repeats A')
        outcomes('nets',{'deliver':12,'a_cfg':3,'b_cfg':3})
        expect(len({f['idx'] for f in stages['nets']})==3,'nets three VLs')
        outcomes('map',{'deliver':4,'a_unk':2,'a_cfg':2})
        expect({(0,0),(65535,4095)}<={(f.get('vlid'),f.get('idx')) for f in stages['map']},'map extremes')
        fs=stages['ports'];expect(len(fs)>=3 and delivered(fs),'ports deliver')
        expect({0,65535}<={f['sport'] for f in fs} and {0,65535}<={f['dport'] for f in fs},'port extremes')
        fs=stages['preamble'];expect(delivered(fs),'preamble deliver')
        expect({1,2,7,8,9,16}<={f['prefix'] for f in fs} and {f['start']%8 for f in fs}==set(range(8)),'preamble length/phase')
        fs=stages['gap'];expect(len(fs)==50 and delivered(fs),'gap count/deliver')
        gaps(fs[:20],96);gaps(fs[20:40],8)
        expect([f['n'] for f in fs[20:40]]==[1,1471]*10,'gap alternating payload')
        for a,b in zip(fs[40::2],fs[41::2]):
            expect(a['net']=='A' and b['net']=='B' and a['end']==b['end'] and a['idx']!=b['idx'],'gap simultaneous pair')
            expect(a.get('delivery',{}).get('cycle',1<<60)<b.get('delivery',{}).get('cycle',0),'gap A delivered first')
        fs=stages['all4096'];outcomes('all4096',{'deliver':8192,'rm_drop':8192})
        expect({f['idx'] for f in fs}==set(range(4096)) and len({f['vlid'] for f in fs})==4096,'all4096 mapping coverage')
        expect({0,65535}<={f['vlid'] for f in fs} and {f['sn'] for f in fs}=={0,1},'all4096 VLID/SN extremes')
        expect(all((f['control']&31)==31 and (f['control']>>5)&4095==100 for f in fs),'all4096 configuration')
        expect(len(pairs(fs))==8192,'all4096 pair count')
    elif test=='tb_rx_fault':
        require(('fcs','len','preamble','hdr','ok','six'))
        for name in ('fcs','len','preamble','hdr'):
            fs=stages[name];expect(sum(f['net']=='B' for f in fs)>=4,name+' two B cases')
            for index,(bad,good) in enumerate(zip(fs[::2],fs[1::2])):
                want='len' if name=='preamble' else name
                if name=='hdr' and bad.get('length')==63:want='len'
                if bad.get('fragment_reject'):
                    expect(bad.get('observed_category')=='good' and bad.get('result')=='a_ovf' and good.get('result')=='a_ic',name+' isolated fragment reject and same-SN IC')
                else:
                    expect(bad.get('observed_category')==want and good.get('result')=='deliver',name+' bad/repair')
                expect(bad['net']==good['net'],'fault repair network')
                # Except length/header corruption, repair must retain the original SN and data.
                if name=='fcs' and index<8:
                    expect(bad['wire'][8:50]==good['wire'][8:50] and bad['wire'][-5]==good['wire'][-5],'fcs repair header/SN')
        from afdx_ref import fcs,ip_checksum
        from rx_ref import decode,checksum_udp
        # 把双错帧的FCS单独修好后应仍是hdr；有效载荷、SN和其他头字段保留修复关联。
        for i,(bad,good) in enumerate(zip(stages['fcs'][16::2],stages['fcs'][17::2])):
            body=bad['wire'][8:-4];original=good['wire'][8:-4]
            repaired=decode(bad['wire'][:-4]+fcs(body))
            expect(repaired['category']=='hdr' if i<2 else repaired.get('fragment_reject') is True,'FCS outranks header/reassembly')
            expect(bad['wire'][-4:]!=fcs(body) and body[42:]==original[42:],'dual error FCS and repair payload/SN')
            changed={j for j,(a,b) in enumerate(zip(body,original)) if a!=b}
            allowed=({0},{24,25},{20,24,25})[i]
            expect(changed<=allowed and bool(changed),'dual error isolated header mutation')
            expect((body[0]!=3,ip_checksum(body[14:34])!=0,bool(body[20]&0x20))[i],'dual error intended rule')
        for i,bad in enumerate(stages['len'][20::2]):
            body=bad['wire'][8:];expect(len(body)==(63,1519,63)[i] and body[-4:]!=fcs(body[:-4]),'length outranks FCS')
        outcomes('fcs',{'fcs':11,'deliver':11});outcomes('len',{'len':13,'deliver':13})
        outcomes('preamble',{'len':6,'deliver':6});outcomes('hdr',{'hdr':26,'len':2,'a_ovf':2,'a_ic':2,'deliver':28})
        expect(delivered(stages['ok']) and sum(f['net']=='B' for f in stages['ok'])>=2,'ok controls')
        expect(len(stages['ok'])==13,'ok added padding cases')
        for f,(net,n,udp) in zip(stages['ok'][-3:],(('A',1,True),('A',16,True),('B',1,False))):
            b=f['wire'][f['prefix']:-4]
            expect(f['net']==net and f['n']==n and len(b[42+n:59])==17-n and all(b[42+n:59]),'nonzero padding shape')
            expect((b[40:42]!=b'\0\0')==udp and (not udp or checksum_udp(b)==0),'padding excluded from UDP checksum')
        outcomes('six',{'fcs':2,'len':1,'hdr':3,'a_unk':1,'a_ic':1,'rm_drop':1,'deliver':10})
        fs=[f for f in stages['six'] if f['net']=='A' and f.get('observed_category')=='good']
        expect(any(f.get('result')=='a_ic' for f in fs),'six out of order IC')
    elif test=='tb_rx_icrm':
        require(('ic_seq','ic_nets','ic_off','rm_pair','rm_same','rm_single','rm_loss','rm_skew','rm_ahead','rm_modes','cfg_keep','rm_wrap','aging','reset'))
        sn_list('ic_seq',[7,8,10,13,14,14,0,1,0,2,255,1,255,2,254,1,100,99,100,101])
        expect([i+1 for i,f in enumerate(stages['ic_seq']) if f.get('result')=='a_ic']==[4,6,11,13,15,17,18],'ic_seq exact rejects')
        outcomes('ic_seq',{'deliver':13,'a_ic':7});outcomes('ic_nets',{'deliver':7,'b_ic':1})
        outcomes('ic_off',{'deliver':6});outcomes('rm_single',{'deliver':10})
        expect(all(f['net']=='B' for f in stages['rm_single']),'rm_single B only')
        expect(len(pairs(stages['rm_pair']))==10,'rm_pair ten pairs')
        expect(len(pairs(stages['rm_same'],0))==5,'rm_same five ties')
        winners=[f for f in stages['rm_loss'] if f.get('result')=='deliver']
        expect([(f['sn'],f['net']) for f in winners]==[(1,'A'),(2,'A'),(3,'B'),(4,'A'),(5,'A')],'rm_loss winner set')
        outcomes('rm_loss',{'deliver':5,'rm_drop':4})
        fs=stages['rm_skew'];expected=['deliver','rm_drop','deliver','deliver','deliver','rm_drop','deliver','deliver',
            'deliver','deliver','deliver','rm_drop','deliver','rm_drop','deliver','deliver','rm_drop']
        expect([f.get('result') for f in fs]==expected,'rm_skew decisions')
        old=fs[:8]+fs[-2:]
        expect([((now(b['end']+8)-now(a['end']+8))&65535) for a,b in zip(old[::2],old[1::2])]==[20,21,0,1,4000],'rm_skew original time deltas')
        clocks=[(c,int(p[3])) for c,_,p in rows if p[0]=='K']
        for j,(before,delay,n,sn,units) in enumerate(((17,1299,1,11,21),(1,1324,20,12,20))):
            a,b=fs[8+2*j:10+2*j];c,step=max((v for v in clocks if v[0]<=a['end']))
            expect(step==64 and (a['end']+before-c)%step==0 and b['end']-a['end']==delay,'rm_skew exact e=T-'+str(before))
            expect(a['net']=='A' and b['net']=='B' and a['n']==b['n']==n and a['sn']==b['sn']==sn,'rm_skew new pair identity')
            ta={now(t) for t in range(a['end']+1,a['end']+17)};tb={now(t) for t in range(b['end']+1,b['end']+17)}
            expect(len(ta)==len(tb)==1 and {(y-x)&65535 for x in ta for y in tb}=={units},'rm_skew unambiguous arrival delta')
        expect(fs[8]['idx']==fs[10]['idx'] and fs[10]['start']-fs[9]['end']>=2000,'rm_skew shared new VL and spacing')
        trio=fs[12:15]
        expect([f['net'] for f in trio]==['A','B','A'] and len({f['sn'] for f in trio})==1 and len({f['idx'] for f in trio})==1 and trio[0]['idx']!=fs[8]['idx'],'rm_skew separate triple VL')
        expect([b['end']-a['end'] for a,b in zip(trio,trio[1:])]==[768,768],'rm_skew dropped copy does not refresh time')
        sn_list('rm_ahead',[10,11,13,140,14,139,140,13,141,0,77,0,0,255,1,254,128,1,2,129,1])
        expect([i+1 for i,f in enumerate(stages['rm_ahead']) if f.get('result')=='rm_drop']==[5,6,7,8,13,16,18,19],'rm_ahead exact rejects')
        outcomes('rm_ahead',{'deliver':13,'rm_drop':8})
        fs=stages['rm_modes'];modes=defaultdict(list)
        for f in fs:modes[(f['control']>>3)&3].append(f)
        for mode,wanted in enumerate(({'deliver':10},{'deliver':8,'a_ic':1,'b_ic':1},{'deliver':5,'rm_drop':5},{'deliver':4,'rm_drop':4,'a_ic':1,'b_ic':1})):
            expect(Counter(f.get('result') for f in modes[mode])==Counter(wanted),'rm_modes '+str(mode))
        fs=stages['cfg_keep'];expect(len(fs)==10,'cfg_keep frame count')
        expect([(f['sn'],f['n']) for f in fs[:5]]==[(1,1),(2,21),(3,20),(5,21),(4,1)],'cfg_keep max payload sequence')
        expect([(f['net'],f['sn']) for f in fs[5:]]==[('A',1),('B',5),('A',2),('B',3),('A',3)],'cfg_keep network sequence')
        expect([f.get('result') for f in fs]==['deliver','a_cfg','deliver','a_cfg','deliver','deliver','b_cfg','deliver','b_cfg','deliver'],'cfg rejection preserves state')
        groups=pairs(stages['rm_wrap']);expect(len(groups)==6,'rm_wrap six pairs')
        expect(any(now(a['end']+8)>now(b['end']+8) for a,b in groups.values()),'rm_wrap crossing pair')
        fs=stages['aging'];expect(len(fs)==4 and delivered(fs),'aging all delivered')
        expect(all(ticks(fs[i]['end'],fs[i+2]['end'])==65546 for i in (0,1)),'aging full wrap plus ten')
        fs=stages['reset'];ignored=[f for f in fs if f.get('ignored')]
        expect(len(ignored)==2 and sum(f.get('result')=='deliver' for f in fs)==2 and sum(f.get('result')=='rm_drop' for f in fs)==1,'reset outcomes')
        expect(sum(f.get('result')=='deliver' and not f.get('delivery') for f in fs)==1,'reset interrupted delivery')
        inits=[c for c,_,p in rows if p[0]=='I'];cross=ignored[-1] if ignored else None
        expect(cross and any(64<=i-cross['start']<=80 and cross['end']>i for i in inits) and cross['prefix']==8,'reset crossing init segment')
        expect([f.get('result') for f in fs]==['deliver',None,None,'a_unk','b_cfg','deliver','rm_drop'],'reset clears map and cfg')
    elif test=='tb_rx_load':
        require(('load',));fs=stages['load']
        for net in ('A','B'):
            subset=[f for f in fs if f['net']==net];expect(len(subset)>=1500,'load '+net+' frame count');expect(all(b['start']-a['end']-1==7*len(a['wire'])+96 for a,b in zip(subset,subset[1:])), 'load original offered schedule')
        expect(not any(f.get('observed_category')=='ovf' or f.get('result','').endswith('_ovf') for f in fs),'load no overflow')
        expect(either<=len(fs)/100,'load either <=1%')
        expect({(f.get('control',0)>>3)&3 for f in fs if 'control' in f}==set(range(4)),'load IC/RM modes')
        expect(len({f.get('idx') for f in fs if 'idx' in f})>=64,'load 64 VLs')
        expect(sum(f.get('n')==1471 for f in fs)>0 and sum(f.get('n',1471)<100 for f in fs)>len(fs)//2,'load payload distribution')
        expect({'fcs','hdr'}<={f.get('observed_category') for f in fs},'load injected categories')
        expect(any(f.get('result','').endswith('_unk') for f in fs) and any(f.get('result','').endswith('_ic') for f in fs),'load unknown and jump')
        # Compare complete packets with only source-MAC network marker normalized.
        normalized=[]
        for f in fs:
            if f.get('category')=='good':
                b=bytearray(f['wire'][f['prefix']:-4]);b[11]=0;normalized.append(bytes(b))
        expect(len(set(normalized))<len(normalized),'load duplicated packets')
    elif test=='tb_rx_ovf_ring':
        require(('fit','big','part','ic'));expect(params['RX_RING_AW']==9,'ring parameter')
        expect([f.get('n') for f in stages['fit']]==[511,512] and delivered(stages['fit']),'ring full capacity')
        outcomes('big',{'ovf':2,'deliver':2})
        expect([f.get('n') for f in stages['big']]==[513,10,1471,10],'ring too-big recovery')
        fs=stages['part'];expect([f.get('n') for f in fs]==[512,300,212,512,300,213],'ring partial lengths')
        outcomes('part',{'deliver':5,'ovf':1})
        for b,a,last in zip(fs[::3],fs[1::3],fs[2::3]):
            expect(b['net']=='B' and a['net']==last['net']=='A' and a['end']-b['end']==16 and last['start']-a['end']==9,'ring partial alignment')
        fs=stages['ic'];expect([(f['net'],f['sn'],f['n']) for f in fs]==[('A',1,10),('A',3,513),('A',2,10)],'ring IC sequence')
        outcomes('ic',{'deliver':2,'ovf':1})
    elif test=='tb_rx_ovf_dq':
        require(('dq',));expect(params['RX_DQ_AW']==1,'queue parameter');fs=stages['dq']
        expect(len(fs)==8 and all(f.get('observed_category')=='good' for f in fs),'queue all frames good')
        expect([f.get('result') for f in fs]==['deliver','deliver','deliver','b_ovf','rm_drop','rm_drop','deliver','deliver'],'queue rollback decisions')
        expect(fs[-1]['net']=='B' and fs[-1]['sn']==6 and fs[-1]['n']==1,'queue overflow still updates PSN')
        if len(fs)==8:
            e=fs[0]['end'];expect(16<=fs[1]['end']-e<=100 and fs[2]['end']-e>140 and fs[3]['end']-e<=230,'queue overlap alignment');gaps(fs[1:4],8)
    elif test=='tb_rx_net':
        require(('net',));expect(max(c for c,_,_ in rows)<=200000 and max(f['end'] for f in frames)<=200000,'net cycle budget')
        outcomes('net',{'deliver':7,'rm_drop':5,'fcs':1,'hdr':1,'a_ic':1,'b_cfg':1,'a_unk':1})
        groups=pairs(stages['net'][:10]);expect({pair[0]['n'] for pair in groups.values()}=={1,17,18,300,1471},'net pair lengths')
    totals={
        'tb_rx_fault':(124,28,(72,9,17,26,1,0,3,2),(16,4,5,3,0,0,0,0),1,81,81),
        'tb_rx_icrm':(110,84,(108,0,0,0,1,2,9,0),(84,0,0,0,0,3,3,0),48,126,125),
        'tb_rx_ovf_ring':(13,2,(9,0,0,0,0,0,0,4),(2,0,0,0,0,0,0,0),0,11,11),
        'tb_rx_ovf_dq':(4,4,(4,0,0,0,0,0,0,0),(4,0,0,0,0,0,0,1),2,5,5)}
    if test in totals:
        pulses=Counter(p[2] for _,_,p in rows if p[0]=='E');keys=('good','fcs','len','hdr','unk','cfg','ic','ovf')
        got=(sum(f['net']=='A' for f in frames),sum(f['net']=='B' for f in frames),
             tuple(pulses['a_'+k] for k in keys),tuple(pulses['b_'+k] for k in keys),pulses['rm_drop'],pulses['deliver'],sum(p[0]=='D' for _,_,p in rows))
        expect(got==totals[test],f'totals {got}');expect(either==0,'requires either=0')
