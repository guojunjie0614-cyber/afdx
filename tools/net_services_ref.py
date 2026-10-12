"""最小五功能顶层测试：生成输入，独立解码真实端口记录；网表再与RTL比对。"""
import argparse,json,struct
from pathlib import Path
from afdx_ref import build_frame,line_bytes
from load_ref import files,tftp,lus,udp_frames
from snmp_ref import request,decode_message

def vectors(folder):
    out=folder/'vectors';out.mkdir(exist_ok=True)
    lur,header,data=files(16)
    get=request(1,0,'1.3.6.1.2.1.1.1.0',7,b'public')
    fault=line_bytes(build_frame(bytes(range(64)),vlid=101,user_id=0x2344,sn=7,
                                 src_ip=0x0a000002,dst_ip=0xe0e00065,sport=3001,dport=4001))
    allbytes=bytearray();offsets=[]
    for content in (get,lur,header,data,fault):
        offsets.extend((len(allbytes),len(content)));allbytes+=content
    assert len(allbytes)<=2048
    (out/'bytes.hex').write_text(''.join(f'{b:02x}\n' for b in allbytes+bytes(2048-len(allbytes))),encoding='ascii')
    (out/'offsets.txt').write_text(' '.join(map(str,offsets))+'\n',encoding='ascii')
    (out/'data.bin').write_bytes(data)

def check(folder,reference=None):
    checks=[]
    def ck(value,label):
        checks.append(dict(ok=bool(value),label=label))
    rows=[line.split() for line in (folder/'net_services.txt').read_text().splitlines()]
    functions={r[1]:dict(start_cycle=int(r[2]),end_cycle=int(r[3]),cycles=int(r[3])-int(r[2])) for r in rows if r[0]=='F'}
    ck(set(functions)=={'users','integrity','snmp','rtc','upload','download'},'all five functions complete including upload and download')
    ck(next(r[1:] for r in rows if r[0]=='I')==['1','1','1','1'],'one IC error, normal A/B duplicate rejected at each endpoint, no delivery of bad SN')
    ck(next(r[1:] for r in rows if r[0]=='U')==['1','1'],'one user delivery in each direction')
    rtc=next(r[1:] for r in rows if r[0]=='T');ck(int(rtc[0])==1 and abs(int(rtc[1]))<=40,'one RTC sync, clock difference within 40 ns')
    ck(bytes.fromhex(next(r[1] for r in rows if r[0]=='R'))==(folder/'vectors/data.bin').read_bytes(),'loaded RAM equals independent 16-byte data')
    responses=[bytes.fromhex(r[5]) for r in rows if r[0]=='D' and r[2]=='161']
    ck(len(responses)==1,'one SNMP response');snmp=decode_message(responses[0])
    ck(snmp['op']==2 and snmp['request_id']==7 and snmp['error']==0 and b'C3 AFDX endpoint' in responses[0],'standard BER GetResponse, ID and sysDescr')
    captures={};tftp_frames=[];ntp=[]
    for es in (1,2):
        for net in ('a','b'):
            frames=list(udp_frames(folder/f'es{es}_{net}.txt'));captures[f'es{es}_{net}']=len(frames)
            ck(bool(frames),f'ES{es} network {net} sends valid CRC frames')
            if net=='a':
                for cycle,eth,sp,dp,payload in frames:
                    if sp==123 and dp==123:ntp.append(payload)
                    elif sp not in (3001,161,42000) and dp not in (4001,161,42000):tftp_frames.append((cycle,eth,tftp(payload)))
    ck(len(ntp)==2 and [p[0]&7 for p in ntp]==[3,4] and all(len(p)==48 and p[0]>>3&7==4 for p in ntp),'standard NTP client and server packets')
    ck(ntp[1][24:32]==ntp[0][40:48],'NTP Origin echoes client Transmit')
    tftp_frames=[f for f in tftp_frames if f[0]<=functions["upload"]["end_cycle"]]
    decoded=[d for _,_,d in sorted(tftp_frames)]
    ck({d['op'] for d in decoded}=={1,2,3,4},'TFTP upload has RRQ,WRQ,DATA,ACK and no ERROR')
    status=[];lui=0
    for d in decoded:
        if d['op']==3:
            data=bytes.fromhex(d['data'])
            if data[4:6]==b'A4':
                if len(data)==9:lui+=1;ck(data==bytes.fromhex('000000094134000100'),'A4 LUI accepted')
                elif data[6:8]!=b'\0\1' or len(data)!=38:status.append(lus(data))
    ck(lui==1 and [s['status'] for s in status]==[1,2,2,3],'LUI/list/header/data/final status sequence')
    ck([s['counter'] for s in status]==[1,2,3,4] and status[-1]['ratio']==100,'LUS counter and completion ratio')
    pcap=bytearray(struct.pack('<IHHIIII',0xa1b23c4d,2,4,0,0,65535,1))
    for cycle,eth,_ in sorted(tftp_frames):
        ns=cycle*8;pcap+=struct.pack('<IIII',ns//10**9,ns%10**9,len(eth),len(eth))+eth
    (folder/'upload.pcap').write_bytes(pcap)
    if reference:
        for name in ('net_services.txt','es1_a.txt','es1_b.txt','es2_a.txt','es2_b.txt','es2_rx_a.txt'):
            ck((folder/name).read_bytes()==(reference/name).read_bytes(),'netlist/RTL exact external record '+name)
    from download_ref import check as check_download
    download=check_download(folder,("es1_a.txt","es2_a.txt"))
    ck(download["errors"]==0 and download["cases"][0]["received"]==16,"download exact 16 bytes from loaded RAM")
    errors=sum(not c['ok'] for c in checks)
    result=dict(download=download,items=len(checks)+download["items"],errors=errors,functions=functions,rtc_error_ns=int(rtc[1]),snmp=snmp,
                frames=captures,tftp_packets=len(tftp_frames),status=status,ram_bytes=16,checks=checks,rtl_reference=str(reference) if reference else None)
    (folder/'check_summary.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    for c in checks:
        if not c['ok']:print('[CHECK_FAIL] '+c['label'])
    print(f'[CHECK] tb_net_services {"FAIL" if errors else "PASS"} items={result["items"]} errors={errors} rtc_error_ns={rtc[1]}')
    return errors

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('action',choices=('vectors','check'));p.add_argument('--dir',required=True,type=Path);p.add_argument('--rtl-reference',type=Path)
    a=p.parse_args();raise SystemExit(check(a.dir,a.rtl_reference) if a.action=='check' else vectors(a.dir))
