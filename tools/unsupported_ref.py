"""615A不支持操作的初始化拒绝：从真实GMII记录核对，不读取RTL。"""
import json,struct
from load_ref import be,tftp,udp_frames

def records(folder):
    cases={}
    for line in (folder/'unsupported_results.txt').read_text().splitlines():
        f=line.split()
        if f[0]=='B':
            i,start,version,port,group,suffix=map(int,f[1:]);cases[i]=dict(start=start,version=version,port=port,name='DEMC3_1.L'+chr(group)+chr(suffix))
        elif f[0]=='C':
            i,before,after,loaded_before,loaded_after=map(int,f[1:]);cases[i].update(status_before=before,status_after=after,loaded_before=loaded_before,loaded_after=loaded_after)
        elif f[0]=='E':i,end=map(int,f[1:]);cases[i]['end']=end
    return cases

def check(folder):
    cases=records(folder);checks=0
    def ck(ok,label):
        nonlocal checks
        checks+=1
        if not ok:raise AssertionError('unsupported initialization: '+label)
    frames=sorted((cy,side,eth,sp,dp,p) for side,name in enumerate(('loader_gmii.txt','target_gmii.txt')) for cy,eth,sp,dp,p in udp_frames(folder/name) if (sp,dp)!=(3001,4001))
    pcap=bytearray(struct.pack('<IHHIIII',0xa1b23c4d,2,4,0,0,65535,1))
    ck(len(cases)==4,'LCI and LNO in A4 and A3')
    for i,c in cases.items():
        wire=[row for row in frames if c['start']<=row[0]<=c['end']]
        decoded=[(side,sp,dp,tftp(p)) for cy,side,eth,sp,dp,p in wire]
        ck([d['op'] for _,_,_,d in decoded]==[1,3,4],'only RRQ, initialization DATA1 and ACK1; no ERROR or operation transfer')
        side,source,port,request=decoded[0];ck(side==0 and port==c['port'] and request['name']==c['name'] and request['mode']=='octet','actual operation request name/port/mode')
        side,tid,peer,response=decoded[1];ck(side==1 and peer==source and tid!=port and response['block']==1,'new target transfer TID and DATA1')
        ck(bytes.fromhex(response['data'])==b'\0\0\0\x09'+c['version'].to_bytes(2,'big')+b'\x10\x02\0','file length, configured version, status1002 and empty description')
        side,ack_source,ack_dest,ack=decoded[2];ck(side==0 and ack_source==source and ack_dest==tid and ack['block']==1,'initialization ACK1')
        ck(c['status_before']==c['status_after'] and c['loaded_before']==c['loaded_after'],'public load status and byte count unchanged')
        for cy,side,eth,sp,dp,p in wire:
            ns=cy*8;pcap+=struct.pack('<IIII',ns//10**9,ns%10**9,len(eth),len(eth))+eth
    (folder/'unsupported.pcap').write_bytes(pcap)
    result=dict(items=checks,errors=0,cases=cases,pcap_packets=sum(1 for row in frames if any(c['start']<=row[0]<=c['end'] for c in cases.values())))
    (folder/'unsupported_check.json').write_text(json.dumps(result,indent=2)+'\n')
    print(f'[CHECK] unsupported_init PASS items={checks} cases={len(cases)} errors=0')
    return result
