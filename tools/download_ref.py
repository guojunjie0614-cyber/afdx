"""按615A Supplement 2 6.4.1/6.4.6独立解码介质卸载；只读公开端口记录。"""
import json, struct
from pathlib import Path
from load_ref import be, tftp, udp_frames, files

def lns(data):
    assert be(data[:4]) == len(data) and data[4:6] in (b'A3', b'A4')
    p = 9 + data[8]
    result = dict(version=data[4:6].decode(), status=be(data[6:8]), description=data[9:p].split(b'\0')[0].decode(),
                  counter=be(data[p:p+2]), exception=be(data[p+2:p+4]), estimated=be(data[p+4:p+6]),
                  ratio=int(data[p+6:p+9]), count=be(data[p+9:p+11]), files=[])
    p += 11
    for _ in range(result['count']):
        n=data[p];p+=1;name=data[p:p+n];p+=n
        assert name.endswith(b'\0')
        status=be(data[p:p+2]);p+=2;n=data[p];p+=1
        result['files'].append(dict(name=name.rstrip(b'\0').decode(), status=status, description=data[p:p+n].split(b'\0')[0].decode()));p+=n
    assert p == len(data)
    return result

def lnr(data):
    assert be(data[:4]) == len(data) and data[4:6] in (b'A3', b'A4')
    p=8;names=[]
    for _ in range(be(data[6:8])):
        n=data[p];p+=1;name=data[p:p+n];p+=n;assert name.endswith(b'\0');names.append(name.rstrip(b'\0').decode())
    n=data[p];p+=1;user=data[p:p+n];p+=n;assert p==len(data)
    return dict(version=data[4:6].decode(),names=names,user_data=user.hex())

def records(folder):
    cases={};exclusions=[];busy=[]
    for line in (folder/'download_results.txt').read_text().splitlines():
        f=line.split()
        if f[0]=='B':
            i,start,size,version,port,mode=map(int,f[1:]);cases[i]=dict(start=start,size=size,version=version,port=port,mode=mode)
        elif f[0]=='E':
            i,end=map(int,f[1:]);cases[i]['end']=end;exclusions.append((cases[i]['start'],end))
        elif f[0]=='Q':
            i,start,end,group=map(int,f[1:]);busy.append(dict(case=i,start=start,end=end,group=group));exclusions.append((start,end))
        elif f[0]=='C':
            i,status,received,retries,lost,nstatus=map(int,f[1:]);cases[i].update(status=status,received=received,retries=retries,lost=lost,nstatus=nstatus)
        elif f[0]=='R':cases[int(f[1])]['data']=bytes.fromhex(f[2]) if len(f)>2 else b''
    return cases,exclusions,busy

def check(folder,source_names=('loader_gmii.txt','target_gmii.txt')):
    cases,_,busy=records(folder);checks=0
    def ck(ok,label):
        nonlocal checks
        checks+=1
        if not ok:raise AssertionError('download: '+label)
    frames=sorted((cy,side,eth,sp,dp,p) for side,name in enumerate(source_names) for cy,eth,sp,dp,p in udp_frames(folder/name) if (sp,dp)!=(3001,4001))
    pcap=bytearray(struct.pack('<IHHIIII',0xa1b23c4d,2,4,0,0,65535,1));reports={}
    for i,c in cases.items():
        wire=[f for f in frames if c['start']<=f[0]<=c['end']]
        pending={};links={};transfers=[]
        for cy,side,eth,sp,dp,p in wire:
            ns=cy*8;pcap+=struct.pack('<IIII',ns//10**9,ns%10**9,len(eth),len(eth))+eth
            d=tftp(p)
            if d['op'] in (1,2):
                ck(dp==c['port'],'configured request port')
                tr=dict(name=d['name'],op=d['op'],side=side,source=sp,blocks={},attempts=[],finished=False)
                pending[(side,sp)]=tr;transfers.append(tr)
            elif d['op'] in (3,4):
                key=(side,sp,dp)
                if key not in links:
                    tr=pending.get((1-side,dp))
                    ck(tr is not None,'DATA/ACK belongs to preceding request')
                    links[key]=tr;links[(1-side,dp,sp)]=tr
                tr=links[key]
                if d['op']==3:
                    b=bytes.fromhex(d['data']);bn=d['block'];tr['attempts'].append(bn)
                    ck(bn==len(tr['blocks'])+1 or tr['blocks'].get(bn)==b,'in-order or identical retransmitted DATA')
                    tr['blocks'][bn]=b
                    if len(b)<512:tr['finished']=True
        init=[t for t in transfers if t['name'].endswith('.LND')]
        ck(len(init)==1,'one LND request');data=init[0]['blocks'][1]
        ck(data==b'\0\0\0\x09'+c['version'].to_bytes(2,'big')+b'\0\x01\0','LND length/version/accepted/description')
        request=[t for t in transfers if t['name'].endswith('.LNR')]
        ck(len(request)==1,'one LNR');listing=lnr(request[0]['blocks'][1]);name='ABSENT.BIN' if c['mode']==3 else 'MEMORY.BIN'
        ck(listing==dict(version=c['version'].to_bytes(2,'big').decode(),names=[name],user_data=''),'LNR version/file/user-data fields')
        status=[lns(t['blocks'][1]) for t in transfers if t['name'].endswith('.LNS')]
        expected=[1,0x1003] if c['mode']==3 else [1,2]+([2] if c['size']>=512 else [])+[0x1003 if c['mode']==2 else 3]
        ck([s['status'] for s in status]==expected,'LNS status sequence')
        ck([s['counter'] for s in status]==list(range(1,len(status)+1)),'LNS counter sequence')
        for s in status:
            ck(s['version']==listing['version'] and s['exception']==0 and s['estimated']==(65535 if s['status']==2 else 0),'LNS version and timers')
            ck(s['count']==(0 if s['status']==1 else 1),'LNS file count')
            ck(s['files']==([] if s['status']==1 else [dict(name=name,status=0x1007 if s['status']==0x1003 else s['status'],description=('FAIL 1' if c['mode']==3 else 'FAIL 5') if s['status']==0x1003 else '')]),'LNS per-file status and description')
        expected_ratio=[0,0] if c['mode']==3 else [0,0]+([51200//c['size']] if c['size']>=512 else [])+[102400//c['size'] if c['mode']==2 else 100]
        # 未收到ACK的第二块不计入目标进度；加载端已经收到它，两个视角分开核对。
        if c['mode']==2:expected_ratio[-1]=51200//c['size']
        ck([s['ratio'] for s in status]==expected_ratio,'LNS acknowledged-byte progress')
        data_files=[t for t in transfers if t['name']=='MEMORY.BIN']
        ck(len(data_files)==(0 if c['mode']==3 else 1),'missing filename rejected before data WRQ')
        original=files(c['size'])[2];actual=b''
        if data_files:
            tr=data_files[0];actual=b''.join(tr['blocks'].values())
            ck(actual==original[:1024] if c['mode']==2 else actual==original,'actual GMII DATA equals uploaded source')
            ck(tr['finished']==(c['mode']!=2),'short/empty final DATA only on completed transfer')
            ck(len(tr['attempts'])-len(tr['blocks'])==(1 if c['mode']==1 else 2 if c['mode']==2 else 0),'actual retransmissions match ACK loss')
            if c['size']%512==0:ck(tr['blocks'][c['size']//512+1]==b'','512 multiple terminates with empty DATA')
        ck(c['data']==actual and c['received']==len(actual),'application reassembly equals GMII records')
        ck(c['status']==(0x503 if c['mode']==2 else 0x103 if c['mode']==3 else 2),'public result register')
        ck(c['retries']==(1 if c['mode']==1 else 2 if c['mode']==2 else 0),'public retry counter delta')
        reports[i]={k:v for k,v in c.items() if k!='data'};reports[i].update(lnr=listing,lns=status,bytes_equal=True)
    for q in busy:
        replies=[tftp(p) for cy,side,eth,sp,dp,p in frames if q['start']<=cy<=q['end'] and side==1 and be(p[:2])==3]
        ck(len(replies)==1,'one busy initialization response')
        data=bytes.fromhex(replies[0]['data'])
        ck(be(data[:4])==len(data)==17 and be(data[6:8])==0x1000 and data[8]==8 and data[9:].startswith(b'BUSY\0'),'busy denied per initialization format')
    (folder/'download.pcap').write_bytes(pcap)
    result=dict(items=checks,errors=0,cases=reports,busy_rejections=len(busy))
    (folder/'download_check.json').write_text(json.dumps(result,indent=2)+'\n')
    print(f'[CHECK] download PASS items={checks} cases={len(cases)} busy={len(busy)} errors=0')
    return result
