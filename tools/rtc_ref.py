"""RFC 4330 报文/时间戳核对；转换向量用 Python 整数运算独立生成。"""
import argparse, json, random, struct
from datetime import datetime, timedelta, timezone
from pathlib import Path
from load_ref import udp_frames

EPOCH = 3155673600  # 2000-01-01 相对 NTP 1900 纪元的秒数。

def vectors(folder):
    out = folder/'vectors';out.mkdir(exist_ok=True)
    ns = [0,1,7,8,500000000,999999000,999999992,999999999]
    rng=random.Random(20261008);ns += [rng.randrange(1000000000) for _ in range(64)]
    (out/'fractions.txt').write_text(''.join(f'{n} {(n<<32)//1000000000:08x}\n' for n in ns))

def timestamp(value):
    sec,frac=value>>32,value&0xffffffff
    ns=(frac*1000000000+(1<<31))>>32
    return dict(raw=f'{value:016x}',seconds=sec,fraction=frac,nanoseconds=ns,
                utc=None if value==0 else (datetime(1900,1,1,tzinfo=timezone.utc)+timedelta(seconds=sec)).strftime('%Y-%m-%dT%H:%M:%S')+f'.{ns:09d}Z')

def decode(payload):
    assert len(payload)==48,'SNTP fixed 48-byte header'
    flags,stratum,poll,precision,delay,dispersion,refid,ref,orig,recv,tx=struct.unpack('!BBBbIIIQQQQ',payload)
    return dict(li=flags>>6,version=(flags>>3)&7,mode=flags&7,stratum=stratum,poll=poll,precision=precision,
                root_delay=delay,root_dispersion=dispersion,reference_id=refid,
                reference=timestamp(ref),originate=timestamp(orig),receive=timestamp(recv),transmit=timestamp(tx))

def check(folder):
    checks=0
    def ck(ok,why):
        nonlocal checks
        checks+=1
        if not ok:raise AssertionError(why)
    frames=[];idle=[];loaded=[];conversions=0
    for line in (folder/'rtc_results.txt').read_text().splitlines():
        f=line.split()
        if f[0]=='S':
            phase=int(f[1]);difference=abs(int(f[4]));(loaded if phase==3 else idle).append(difference)
            if phase!=3:ck(difference<=40,'every idle synchronization is within 40 ns')
        elif f[0]=='H':ck(abs(int(f[2]))<=40,'clock hold after sync stops')
        elif f[0]=='U':ck(f[1:5]==['40','40','40','40'],'user delivery exactly once each way')
        elif f[0]=='F':conversions=int(f[1]);ck(conversions==72,'forward/reverse conversion vector count')
    for es in (1,2):
        for cycle,eth,sp,dp,payload in udp_frames(folder/f'rtc_es{es}_gmii.txt'):
            if (sp,dp)==(123,123):frames.append((cycle,es,eth,payload))
    frames.sort();requests={};responses=[];decoded=[];pair=None
    for cycle,es,eth,payload in frames:
        d=decode(payload);decoded.append(dict(cycle=cycle,es=es,**d))
        ck(d['version']==4 and d['mode'] in (3,4),'SNTPv4 client/server mode')
        ck(d['li']==0 and d['poll']==4 and d['precision']==-26,'fixed LI/poll/precision')
        ck(d['root_delay']==0 and d['root_dispersion']==0,'primary reference root fields')
        for name in ('reference','originate','receive','transmit'):
            t=d[name]
            if t['raw']!='0'*16:
                ck((t['nanoseconds']<<32)//1000000000==t['fraction'],'canonical fraction from integer nanoseconds')
                ck(EPOCH<=t['seconds']<EPOCH+2000,'2000 epoch mapping')
        if d['mode']==3:
            ck(d['stratum']==0 and d['reference_id']==0,'client fixed fields')
            ck(all(d[k]['raw']=='0'*16 for k in ('reference','originate','receive')),'client only sets Transmit timestamp')
            key=(es,d['transmit']['raw']);ck(key not in requests,'distinct client timestamp identifies pending request')
            requests[key]=(cycle,eth,d)
        else:
            ck(d['stratum']==1 and d['reference_id']==int.from_bytes(b'LOCL','big'),'local primary server')
            key=(3-es,d['originate']['raw']);ck(key in requests,'Originate exactly copies corresponding request Transmit')
            request=requests.pop(key);responses.append(d)
            ck(d['receive']['raw']<=d['transmit']['raw'],'server Receive precedes Transmit')
            ck(d['reference']['raw']<=d['receive']['raw'],'reference update precedes reception')
            ck((d['reference']['seconds']-EPOCH,d['reference']['nanoseconds']) in
               ((30,999999000),(1000,999980000),(1007,200000000),(991,700000000)),'Reference timestamp is configured clock update')
            if pair is None:pair=[(request[0],request[1]),(cycle,eth)]
    ck(len(responses)>=28 and len(idle)==20 and len(loaded)==8,'all RTC test phases captured')
    ck(pair is not None,'request/reply PCAP pair exists')
    pcap=bytearray(struct.pack('<IHHIIII',0xa1b23c4d,2,4,0,0,65535,1))
    for cycle,eth in pair:
        ns=cycle*8;pcap+=struct.pack('<IIII',ns//10**9,ns%10**9,len(eth),len(eth))+eth
    (folder/'sntp_exchange.pcap').write_bytes(pcap)
    pos=24;pcap_decoded=[]
    while pos<len(pcap):
        _,_,length,_=struct.unpack_from('<IIII',pcap,pos);pos+=16;eth=pcap[pos:pos+length];pos+=length
        udp_size=int.from_bytes(eth[38:40],'big');pcap_decoded.append(decode(eth[42:42+udp_size-8]))
    ck([x['mode'] for x in pcap_decoded]==[3,4],'PCAP standard client and server decode')
    ck(pcap_decoded[0]['transmit']==pcap_decoded[1]['originate'],'PCAP Originate exact echo')
    summary=dict(items=checks,errors=0,idle_max_ns=max(idle),loaded_max_ns=max(loaded),idle_syncs=len(idle),
                 loaded_syncs=len(loaded),fraction_vectors=conversions,ntp_frames=len(frames),responses=len(responses),
                 pcap_packets=pcap_decoded,decoder='RFC 4330 48-byte NTP header, Python struct')
    (folder/'ntp_decode.json').write_text(json.dumps(decoded,indent=2)+'\n')
    (folder/'check_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(f'[CHECK] tb_sys_rtc PASS items={checks} errors=0 idle_max_ns={max(idle)} ntp_frames={len(frames)}')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('action',choices=('vectors','check'));p.add_argument('--dir',required=True,type=Path)
    a=p.parse_args();globals()[a.action](a.dir)
