"""SNMP标准BER向量与独立解码：pyasn1负责ASN.1编码，不共享RTL解析器。"""
import argparse, json, struct, zlib
from pathlib import Path
from pyasn1.type import univ, namedtype, tag
from pyasn1.codec.ber import encoder, decoder


class Binding(univ.Sequence):
    componentType=namedtype.NamedTypes(namedtype.NamedType('name',univ.ObjectIdentifier()),namedtype.NamedType('value',univ.Any()))


class PDU(univ.Sequence):
    componentType=namedtype.NamedTypes(namedtype.NamedType('id',univ.Integer()),namedtype.NamedType('error',univ.Integer()),
        namedtype.NamedType('index',univ.Integer()),namedtype.NamedType('bindings',univ.SequenceOf(componentType=Binding())))


class Message(univ.Sequence):
    componentType=namedtype.NamedTypes(namedtype.NamedType('version',univ.Integer()),
        namedtype.NamedType('community',univ.OctetString()),namedtype.NamedType('pdu',univ.Any()))


BASE='1.3.6.1.4.1.424242.3'
NAMES=['sysDescr','sysUpTime','version','USER_ID','rtc_seconds','rtc_sync_count',
       'accept','drop_dis','drop_full','drop_long','drop_nopage','tx_a','tx_b',
       'a_good','a_fcs','a_len','a_hdr','a_unk','a_cfg','a_ic','a_ovf',
       'b_good','b_fcs','b_len','b_hdr','b_unk','b_cfg','b_ic','b_ovf',
       'rm_drop','deliver','a_gdrop','b_gdrop','snmp_requests','bad_community','traps_sent']
OIDS=['1.3.6.1.2.1.1.1.0','1.3.6.1.2.1.1.3.0']+[f'{BASE}.{i}.0' for i in range(1,35)]
ADDR=[0xa0,0x98,0,2,0x84,0x88]+list(range(0x40,0x47))+list(range(0x48,0x50))+list(range(0x50,0x58))+list(range(0x58,0x5c))+[0x99,0x9a,0x9c]


def pdu_spec(op):
    return PDU().subtype(implicitTag=tag.Tag(tag.tagClassContext,tag.tagFormatConstructed,op))


def request(version,op,oid,request_id,community,value=None):
    p=pdu_spec(op);p['id']=request_id;p['error']=0;p['index']=0
    p['bindings'][0]['name']=univ.ObjectIdentifier(oid)
    p['bindings'][0]['value']=encoder.encode(value if value is not None else univ.Null(''))
    m=Message();m['version']=version;m['community']=community;m['pdu']=encoder.encode(p)
    return encoder.encode(m)


def decode_message(raw):
    m,tail=decoder.decode(raw,asn1Spec=Message());assert not tail
    body=m['pdu'].asOctets();op=body[0]&31
    p,tail=decoder.decode(body,asn1Spec=pdu_spec(op));assert not tail and len(p['bindings']) in (1,2)
    bindings=[decode_binding(b) for b in p['bindings']]
    result=dict(version=int(m['version']),community=m['community'].asOctets().decode('ascii'),op=op,
                request_id=int(p['id']),error=int(p['error']),index=int(p['index']),bindings=bindings)
    result.update(bindings[0]);return result


def decode_binding(b):
    v=b['value'].asOctets();t=v[0]
    if t==4:spec=univ.OctetString()
    elif t==5:spec=univ.Null()
    elif t==6:spec=univ.ObjectIdentifier()
    elif t in (0x41,0x42,0x43):spec=univ.Integer().subtype(implicitTag=tag.Tag(tag.tagClassApplication,tag.tagFormatSimple,t&31))
    elif t in (0x80,0x82):spec=univ.Null().subtype(implicitTag=tag.Tag(tag.tagClassContext,tag.tagFormatSimple,t&31))
    else:spec=univ.Integer()
    value,tail=decoder.decode(v,asn1Spec=spec);assert not tail
    value=str(value) if t==6 else value.asOctets().decode('ascii') if t==4 else (None if t in (5,0x80,0x82) else int(value))
    return dict(oid=str(b['name']),tag=t,value=value)


def vectors(folder):
    folder.mkdir(parents=True,exist_ok=True);vdir=folder/'vectors';vdir.mkdir(exist_ok=True)
    cases=[];data=bytearray();ids=[-1,-129,127,128,32768,2147483647]
    def add(version,op,oid,item=-1,kind='normal',community='public'):
        i=len(cases);rid=ids[i%len(ids)];raw=request(version,op,oid,rid,community)
        cases.append(dict(case=i,version=version,op=op,oid=oid,item=item,kind=kind,community=community,
                          request_id=rid,sport=41000+i,offset=len(data),length=len(raw)))
        data.extend(raw)
    for version in (0,1):
        for i,oid in enumerate(OIDS):add(version,0,oid,i)
    previous='1.3'
    for i,oid in enumerate(OIDS):add(1,1,previous,i,'walk');previous=oid
    add(1,1,previous,-1,'end')
    add(1,0,OIDS[2],-1,'bad','private')
    add(0,0,BASE+'.99.0',-1,'missing')
    add(1,0,BASE+'.99.0',-1,'missing')
    add(1,5,OIDS[3],-1,'unsupported')
    add(1,0,OIDS[34],34,'normal')
    add(1,0,OIDS[3],3,'custom','c3manage')
    # 16字节community和BER合法的长形式长度也属于本代理自己生成的输入范围。
    add(1,0,OIDS[33],33,'long','0123456789abcdef')
    c=cases[-1];raw=data[c['offset']:];data=data[:c['offset']]+raw[:1]+b'\x82\x00'+raw[1:];c['length']+=2
    add(1,0,OIDS[3],3,'idle','0123456789abcdef')
    (vdir/'bytes.hex').write_text('\n'.join(f'{b:02x}' for b in data)+'\n')
    meta=[]
    for c in cases:
        mode=1 if c['kind']=='bad' else 2 if c['kind']=='unsupported' else 3 if c['kind']=='custom' else 4 if c['kind']=='long' else 5 if c['kind']=='idle' else 0
        meta.append(f"{c['case']} {c['offset']} {c['length']} {c['sport']} {ADDR[c['item']] if c['item']>=0 else -1} {mode}")
    (vdir/'cases.txt').write_text('\n'.join(meta)+'\n')
    (vdir/'cases.json').write_text(json.dumps(cases,indent=2)+'\n')
    return cases


def udp_frames(path):
    for line in path.read_text().splitlines():
        net,cycle,length,hexdata=line.split();wire=bytes.fromhex(hexdata)
        assert len(wire)==int(length) and wire[:8]==b'\x55'*7+b'\xd5'
        eth=wire[8:-4];assert int.from_bytes(wire[-4:],'little')==zlib.crc32(eth)
        assert eth[12:14]==b'\x08\x00' and eth[14]==0x45
        sp,dp,n,_=struct.unpack('!HHHH',eth[34:42])
        yield int(cycle),eth,sp,dp,eth[42:42+n-8]


def check(folder):
    cases=json.loads((folder/'vectors/cases.json').read_text());responses={};samples={};summary={};checks=0
    def ck(ok,why):
        nonlocal checks
        checks+=1
        if not ok:raise AssertionError(why)
    for line in (folder/'snmp_results.txt').read_text().splitlines():
        p=line.split()
        if p[0]=='D':
            ck(int(p[1]) not in responses,'no duplicate response')
            responses[int(p[1])]=(int(p[2]),int(p[3]),int(p[4]),bytes.fromhex(p[5]))
            ck(len(bytes.fromhex(p[5]))==int(p[4]),'delivery length')
        elif p[0] in ('B','S'):samples[int(p[1])]=(int(p[2]),int(p[3]))
        elif p[0]=='DESC':descr=bytes.fromhex(p[1]).decode('ascii')
        elif p[0]=='U':ck(p[1:]==[str(len(cases)+7)]*4,'user messages exactly once')
        elif p[0]=='BAD':ck(p[1:]==['0','1'],'bad community delta')
    values={};walk=[]
    for c in cases:
        i=c['case'];silent=c['kind'] in ('bad','unsupported')
        ck((i not in responses)==silent,f'case {i}: response presence')
        if silent:continue
        sp,dp,n,raw=responses[i];r=decode_message(raw)
        ck(sp==161 and dp==c['sport'],f'case {i}: UDP ports')
        ck(len(r['bindings'])==1 and r['op']==2 and r['version']==c['version'] and r['request_id']==c['request_id'] and r['community']==c['community'],f'case {i}: response envelope')
        item=c['item']
        if item>=0:
            ck(r['error']==0 and r['index']==0 and r['oid']==OIDS[item],f'case {i}: OID/error')
            expected_tag=4 if item==0 else 0x43 if item==1 else 0x42 if item in (2,3,4) else 0x41
            ck(r['tag']==expected_tag,f'case {i}: ASN.1 type')
            cycle,value=samples[i]
            ck(r['value']==(descr if item==0 else value),f'case {i}: value={r["value"]} bus={value} cycle={cycle}')
            if item==0:ck(value==int.from_bytes(descr.encode()[:4],'big'),'sysDescr bus first word')
            values.setdefault(NAMES[item],[]).append(dict(case=i,value=r['value'],sample_cycle=cycle,bus=value))
            if c['kind']=='walk':walk.append(r['oid'])
        else:
            ck(r['oid']==c['oid'],'exception OID preserved')
            if c['version']==0:ck((r['error'],r['index'],r['tag'],r['value'])==(2,1,5,None),'v1 noSuchName')
            else:ck((r['error'],r['index'],r['tag'],r['value'])==(0,0,0x82 if c['kind']=='end' else 0x80,None),'v2 exception')
    ck(walk==OIDS,'GetNext complete ordered walk')
    # 实际GMII抓包转换为Ethernet PCAP，再从PCAP读回并交给pyasn1。
    q=next(f for f in udp_frames(folder/'manager_gmii.txt') if f[3]==161)
    a=next(f for f in udp_frames(folder/'agent_gmii.txt') if f[2]==161 and f[3]==q[2])
    pcap=struct.pack('<IHHIIII',0xa1b23c4d,2,4,0,0,65535,1)
    for cycle,eth,*_ in (q,a):
        ns=cycle*8;pcap+=struct.pack('<IIII',ns//10**9,ns%10**9,len(eth),len(eth))+eth
    (folder/'snmp_exchange.pcap').write_bytes(pcap)
    packets=[];pos=24
    while pos<len(pcap):
        sec,ns,n,orig=struct.unpack_from('<IIII',pcap,pos);pos+=16;eth=pcap[pos:pos+n];pos+=n
        length=int.from_bytes(eth[38:40],'big');packets.append(decode_message(eth[42:42+length-8]))
    ck(packets[0]['op']==0 and packets[1]['op']==2 and packets[0]['request_id']==packets[1]['request_id'],'standard PCAP decode')
    summary=dict(errors=0,items=checks,requests=len(cases),responses=len(responses),objects=len(values),walk=len(walk),
                 decoder='pyasn1 BER 0.4.8',pcap_packets=packets,values=values)
    (folder/'check_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(f'[CHECK] tb_sys_snmp PASS items={checks} errors=0 requests={len(cases)} responses={len(responses)} objects={len(values)} walk={len(walk)}')


def gauge(value):
    return univ.Integer(value).subtype(implicitTag=tag.Tag(tag.tagClassApplication,tag.tagFormatSimple,2))


def vectors_settrap(folder):
    vdir=folder/'vectors';vdir.mkdir(parents=True,exist_ok=True)
    cases=[];data=bytearray();user=0x2345;bad=0;traps=0
    def add(version,op,oid,value=None,error=0,community='public',mode=0,expected=None):
        nonlocal user,bad,traps
        i=len(cases);rid=500+i;raw=request(version,op,oid,rid,community,value)
        silent=community!='public'
        if mode==1:traps=1
        if silent:
            bad+=1
            if mode==2:traps+=1
        if op==3 and not silent and error==0:user=int(value)
        if expected is None and op==0:expected=user if oid==OIDS[3] else traps
        cases.append(dict(case=i,version=version,op=op,oid=oid,request_id=rid,sport=43000+i,offset=len(data),length=len(raw),
                          community=community,mode=mode,silent=silent,error=error,user=user,bad=bad,traps=traps,expected=expected,
                          request_binding=decode_message(raw)['bindings'][0]))
        data.extend(raw)
    add(1,0,OIDS[3],community='private')
    add(0,3,OIDS[3],gauge(0x3456));add(0,0,OIDS[3])
    add(0,3,OIDS[2],gauge(0x1234),error=2)
    add(0,3,OIDS[3],univ.OctetString('oops'),error=3)
    add(0,3,BASE+'.99.0',gauge(1),error=2)
    add(1,3,OIDS[3],gauge(0xabcd));add(1,0,OIDS[3])
    add(1,3,OIDS[2],gauge(0x1234),error=17)
    add(1,3,OIDS[3],univ.OctetString('oops'),error=7)
    add(1,3,BASE+'.99.0',gauge(1),error=17)
    add(1,3,OIDS[3],gauge(0x5678),community='private')
    add(1,0,OIDS[3]);add(1,0,OIDS[35])
    add(1,0,OIDS[35],mode=1)
    add(1,0,OIDS[3],community='private',mode=2)
    add(1,0,OIDS[35]);add(1,0,OIDS[3])
    add(1,0,OIDS[35],mode=3)
    add(1,0,OIDS[3],community='private')
    add(0,0,OIDS[35]);add(1,0,OIDS[3])
    (vdir/'bytes.hex').write_text('\n'.join(f'{b:02x}' for b in data)+'\n')
    (vdir/'cases.txt').write_text('\n'.join(f"{c['case']} {c['offset']} {c['length']} {c['sport']} {c['mode']} {int(c['silent'])} {c['user']}" for c in cases)+'\n')
    (vdir/'cases.json').write_text(json.dumps(cases,indent=2)+'\n')


def check_settrap(folder):
    cases=json.loads((folder/'vectors/cases.json').read_text());responses={};observations={};traps=[];checks=0
    def ck(ok,why):
        nonlocal checks
        checks+=1
        if not ok:raise AssertionError(why)
    for line in (folder/'snmp_results.txt').read_text().splitlines():
        p=line.split()
        if p[0]=='D':
            i=int(p[1]);ck(i not in responses,'one response per request')
            responses[i]=(int(p[2]),int(p[3]),decode_message(bytes.fromhex(p[5])))
            ck(len(bytes.fromhex(p[5]))==int(p[4]),'response length')
        elif p[0]=='T':
            ck(int(p[1])==len(traps) and p[3:5]==['161','162'],'Trap sequence and UDP ports')
            ck(len(bytes.fromhex(p[6]))==int(p[5]),'Trap length')
            r=decode_message(bytes.fromhex(p[6]));r['delivery_cycle']=int(p[2]);traps.append(r)
        elif p[0]=='C':observations[int(p[1])]=list(map(int,p[2:]))
        elif p[0]=='U':ck(p[1:]==['29']*4,'user deliveries')
    for c in cases:
        i=c['case'];ck(observations[i]==[c['user'],c['traps'],c['traps'],c['bad']],f'case {i}: configuration/notifications {observations[i]}')
        ck((i not in responses)==c['silent'],f'case {i}: response presence')
        if c['silent']:continue
        sp,dp,r=responses[i]
        ck(sp==161 and dp==c['sport'],'response ports')
        ck(r['version']==c['version'] and r['op']==2 and r['request_id']==c['request_id'] and r['community']==c['community'],'response envelope')
        ck(r['error']==c['error'] and r['index']==(1 if c['error'] else 0),'error status/index')
        ck(len(r['bindings'])==1 and r['oid']==c['oid'],'response binding')
        if c['op']==3:ck(r['bindings'][0]==c['request_binding'],f'case {i}: Set value echoed')
        else:ck(r['value']==c['expected'] and r['tag']==(0x42 if c['oid']==OIDS[3] else 0x41),'Get reads actual object')
    ck(len(traps)==2,'exactly coldStart and authenticationFailure')
    for r,event in zip(traps,(1,5)):
        ck((r['version'],r['op'],r['community'],r['error'],r['index'])==(1,7,'public',0,0),'SNMPv2-Trap envelope')
        ck(len(r['bindings'])==2,'two required Trap bindings')
        first,second=r['bindings']
        ck(first['oid']==OIDS[1] and first['tag']==0x43,'first binding sysUpTime TimeTicks')
        ck(0<=r['delivery_cycle']//1250000-first['value']<=1 and first['value']>0,'Trap uptime close to notification time')
        ck(second==dict(oid='1.3.6.1.6.3.1.1.4.1.0',tag=6,value=f'1.3.6.1.6.3.1.1.5.{event}'),'standard notification OID')
    # 从实际GMII记录取Set请求、匹配的回应和coldStart，PCAP读回仍用标准BER解码器。
    q=next(f for f in udp_frames(folder/'manager_gmii.txt') if f[3]==161 and decode_message(f[4])['op']==3)
    frames=list(udp_frames(folder/'agent_gmii.txt'))
    a=next(f for f in frames if f[2]==161 and f[3]==q[2]);t=next(f for f in frames if f[3]==162)
    data=struct.pack('<IHHIIII',0xa1b23c4d,2,4,0,0,65535,1)
    for cycle,eth,*_ in (q,a,t):
        ns=cycle*8;data+=struct.pack('<IIII',ns//10**9,ns%10**9,len(eth),len(eth))+eth
    (folder/'snmp_set_trap.pcap').write_bytes(data)
    pos=24;decoded=[]
    while pos<len(data):
        sec,ns,n,orig=struct.unpack_from('<IIII',data,pos);pos+=16;eth=data[pos:pos+n];pos+=n
        length=int.from_bytes(eth[38:40],'big');decoded.append(decode_message(eth[42:42+length-8]))
    ck([p['op'] for p in decoded]==[3,2,7],'PCAP Set/Response/Trap standard decode')
    ck(decoded[0]['request_id']==decoded[1]['request_id'] and decoded[0]['bindings']==decoded[1]['bindings'],'PCAP Set response matches')
    result=dict(items=checks,errors=0,requests=len(cases),responses=len(responses),traps=traps,user_each=29,
                set_versions=[0,1],set_values=[0x3456,0xabcd],final_user_id=0xabcd,pcap_packets=decoded)
    (folder/'check_summary.json').write_text(json.dumps(result,indent=2)+'\n')
    print(f'[CHECK] tb_sys_snmp_settrap PASS items={checks} errors=0 requests={len(cases)} responses={len(responses)} traps={len(traps)}')


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('action',choices=['vectors','check','settrap_vectors','settrap_check']);p.add_argument('--dir',type=Path,required=True);a=p.parse_args()
    if a.action=='vectors':vectors(a.dir)
    elif a.action=='check':check(a.dir)
    elif a.action=='settrap_vectors':vectors_settrap(a.dir)
    else:check_settrap(a.dir)
