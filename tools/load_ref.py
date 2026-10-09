"""独立生成 615A A4/A3/665-1 文件，解码实际 TFTP/PCAP，并核对加载结果。"""
import argparse, binascii, functools, json, operator, struct
from pathlib import Path

def u16(n): return struct.pack('>H', n)
def u32(n): return struct.pack('>I', n)
def be(data): return int.from_bytes(data, 'big')
def even(s): return u16(len(s)) + s + b'\0' * (len(s) % 2)
def crc32_msb(data):
    c = 0xffffffff
    for b in data:
        c ^= b << 24
        for _ in range(8): c = ((c << 1) ^ (0x04c11db7 if c & 0x80000000 else 0)) & 0xffffffff
    return c ^ 0xffffffff

def files(length, version=b'A4'):
    data = bytes((i * 73 + (i >> 3) + 19) & 255 for i in range(length))
    # 665-1 的 PN CC 是除去 CC/分隔符后各字符的 x^8+1 CRC，即逐字节 XOR。
    cc = functools.reduce(operator.xor, b'DEM00010001', 0)
    name, pn = b'DEM0001.LUP', f'DEM{cc:02X}-0001-0001'.encode()
    fields = bytearray(26)
    pn_ptr = len(fields) // 2; fields += even(pn)
    hw_ptr = len(fields) // 2; fields += u16(1) + even(b'DEMC3')
    list_ptr = len(fields) // 2
    fields += u16(1) + u16(0) + even(name) + even(pn) + u32(length // 2) + u16(binascii.crc_hqx(data, 0xffff))
    fields[:26] = u32((len(fields) + 6) // 2) + u16(0x8002) + b''.join(u32(x) for x in (pn_ptr, hw_ptr, list_ptr, 0, 0))
    fields += u16(binascii.crc_hqx(fields, 0xffff))
    fields += u32(crc32_msb(fields + data))
    hname = b'DEM0001.LUH\0'; part = pn + b'\0'
    lur = version + u16(1) + bytes([len(hname)]) + hname + bytes([len(part)]) + part
    lur = u32(len(lur) + 4) + lur
    return lur, bytes(fields), data

def tftp(payload):
    assert len(payload) >= 2
    op = be(payload[:2]); result = dict(op=op)
    if op in (1, 2):
        fields = payload[2:].split(b'\0'); assert len(fields) >= 3 and len(fields)%2 == 1 and not fields[-1]
        result.update(name=fields[0].decode('ascii'), mode=fields[1].decode('ascii').lower())
        result['options'] = {fields[i].decode('ascii').lower(): fields[i+1].decode('ascii') for i in range(2,len(fields)-1,2)}
        assert result['mode'] == 'octet'
    elif op == 3:
        assert 4 <= len(payload) <= 516
        result.update(block=be(payload[2:4]), data=payload[4:].hex(), size=len(payload)-4)
    elif op == 4:
        assert len(payload) == 4; result['block'] = be(payload[2:4])
    elif op == 5:
        assert len(payload) >= 5 and payload[-1] == 0
        result.update(code=be(payload[2:4]), message=payload[4:].split(b'\0')[0].decode('ascii'))
    else: raise AssertionError(f'bad TFTP opcode {op}')
    return result

def lus(data):
    assert be(data[:4]) == len(data) and data[4:6] in (b'A3',b'A4')
    st = be(data[6:8]); p = 9 + data[8]
    result = dict(version=data[4:6].decode(),status=st, description=data[9:p].split(b'\0')[0].decode(), counter=be(data[p:p+2]),
                  ratio=int(data[p+6:p+9].decode()), headers=be(data[p+9:p+11]))
    p += 11
    if result['headers']:
        assert result['headers'] == 1
        n = data[p]; p += 1; result['name'] = data[p:p+n].rstrip(b'\0').decode(); p += n
        n = data[p]; p += 1; result['part'] = data[p:p+n].rstrip(b'\0').decode(); p += n
        result['file_ratio'] = int(data[p:p+3].decode()); result['file_status'] = be(data[p+3:p+5]); p += 5
        n = data[p]; p += 1; result['file_description'] = data[p:p+n].split(b'\0')[0].decode(); p += n
    assert p == len(data)
    return result

def vectors(folder):
    target=folder/'vectors'; target.mkdir(exist_ok=True)
    allbytes=bytearray(); cases=[]
    for case,length in enumerate((1500,1536,1500,1500,1500,1500,1500,1500,1500)):
        row=dict(case=case, length=length, request_port=1059 if case==5 else 59, drop=case in (2,4), corrupt=case==3, exhaust=case==4,
                 protocol_version=0x4133 if case in (6,7) else 0x4134,
                 lur_version=0x4133 if case in (5,7) else 0x4135 if case==8 else 0x4134,
                 option_flags=int(case==0))
        for kind,content in zip(('lur','header','data'),files(length,u16(row['lur_version']))):
            row[kind+'_offset']=len(allbytes);row[kind+'_size']=len(content);allbytes+=content
            (target/f'{case}_{kind}.bin').write_bytes(content)
        cases.append(row)
    (target/'bytes.hex').write_text(''.join(f'{b:02x}\n' for b in allbytes + bytes(65536-len(allbytes))))
    (target/'cases.txt').write_text(''.join(' '.join(str(c[k]) for k in ('case','lur_offset','lur_size','header_offset','header_size','data_offset','data_size','request_port','protocol_version','lur_version','option_flags'))+'\n' for c in cases))
    (target/'cases.json').write_text(json.dumps(cases,indent=2))

def udp_frames(path):
    for line in path.read_text().splitlines():
        _,cycle,n,h=line.split(); raw=bytes.fromhex(h); assert len(raw)==int(n)
        assert raw[:8]==b'\x55'*7+b'\xd5'
        eth=raw[8:-4]; assert binascii.crc32(eth).to_bytes(4,'little')==raw[-4:]
        size=be(eth[38:40]);yield int(cycle),eth,be(eth[34:36]),be(eth[36:38]),eth[42:42+size-8]

def check(folder):
    checks=0
    def ck(ok,why):
        nonlocal checks
        checks+=1
        if not ok: raise AssertionError(why)
    from download_ref import check as check_download, records
    download=check_download(folder)
    download_cases, excluded, _=records(folder)
    from unsupported_ref import check as check_unsupported
    unsupported=check_unsupported(folder)
    excluded.extend((c['start'],c['end']) for c in unsupported['cases'].values())
    cases=json.loads((folder/'vectors/cases.json').read_text()); defaults={}; states={}; packets=[]; ram={}; reports={i:[] for i in range(len(cases))}
    for line in (folder/'load_results.txt').read_text().splitlines():
        f=line.split()
        if f[0]=='D':
            case,sp,dp,n=map(int,f[1:5]);p=bytes.fromhex(f[5]);ck(len(p)==n,'packet length');d=tftp(p);packets.append((case,sp,dp,d))
            if d['op']==3 and d['block']==1 and len(p)>12 and p[8:10] in (b'A3',b'A4'):
                data=p[4:]
                ck(be(data[4:6])==cases[case]['protocol_version'],'target LUI/LUS use configured protocol version')
                if len(data)==9:ck(be(data[6:8])==1,'LUI accepted')
                else:reports[case].append(lus(data))
        elif f[0]=='V': defaults[f[1]]=int(f[2])
        elif f[0]=='C': states[int(f[1])]=list(map(int,f[2:]))
        elif f[0]=='R': ram[int(f[1])]=bytes.fromhex(f[2])
        elif f[0]=='U':ck(f[1:]==['8','8','8','8'],'user delivery exactly once')
    ck(defaults==dict(port=59,timeout=250000000,retries=1,version=0x4134),'615A normative reset values and default A4')
    for c in cases:
        i=c['case'];r=reports[i];success=i not in (3,4,8)
        ck(all(dp==c['request_port'] for case,sp,dp,d in packets if case==i and d['op'] in (1,2)),'configured request port on actual target packets')
        if i==8:
            ck([x['status'] for x in r]==[1,0x1003] and [x['counter'] for x in r]==[1,2],'unsupported A5 initial then aborted LUS')
            ck(all(x['headers']==0 and x['ratio']==0 for x in r),'unsupported A5 never accepts manifest or loads data')
            ck(r[-1]['description']=='FAIL 1' and states[i]==[0x0103,0,3+sum(c['retries'] for j,c in download_cases.items() if j<i)],'unsupported version reports metadata reason 1')
            ck(any(d['op']==5 and d['code']==1 and d['message']=='FAIL 1' for case,sp,dp,d in packets if case==i),'unsupported A5 TFTP rejection')
            ck(not any(d['op']==1 for case,sp,dp,d in packets if case==i),'unsupported A5 no file RRQ')
            continue
        ck([x['status'] for x in r[:3]]==[1,2,2],f'{i} initialization/list/header statuses')
        ck(r[0]['headers']==0 and all(x['headers']==1 for x in r[1:]),'LUS header list phase')
        ck(all(x.get('name','DEM0001.LUH')=='DEM0001.LUH' for x in r),'header filename')
        ck([x['counter'] for x in r]==list(range(1,len(r)+1)),'LUS counters')
        ck(any(0<x['ratio']<100 for x in r),'intermediate numeric progress')
        ck(r[-1]['status']==(3 if success else 0x1003),'final LUS status')
        ck(r[-1]['file_status']==(3 if success else 0x1007),'final per-header status')
        ck((r[-1]['ratio']==100)==success,'100 percent only on verified success')
        status,loaded,retries=states[i]
        ck(status==(2 if success else ((3 if i==3 else 5)<<8)|3),'config status/reason')
        ck(retries-sum(c['retries'] for j,c in download_cases.items() if j<i)==[0,0,1,1,3,3,3,3][i],'cumulative retries: one recovered loss, then two configured exhausted retries')
        ck(loaded==(512 if i==4 else c['length']),'loaded length')
        if success:ck(ram[i]==(folder/f'vectors/{i}_data.bin').read_bytes(),'RAM exact original bytes')
    frames=[]
    for source in ('loader_gmii.txt','target_gmii.txt'):
        for cy,eth,sp,dp,p in udp_frames(folder/source):
            if any(start<=cy<=end for start,end in excluded):continue
            if (sp,dp)!=(3001,4001):tftp(p);frames.append((cy,eth,sp,dp,p))
    frames.sort();pcap=bytearray(struct.pack('<IHHIIII',0xa1b23c4d,2,4,0,0,65535,1))
    for c in cases:
        i=c['case'];header=(folder/f'vectors/{i}_header.bin').read_bytes();original=(folder/f'vectors/{i}_data.bin').read_bytes()
        ck(be(header[:4])*2==len(header) and header[4:6]==b'\x80\x02','665-1 version/word length')
        ck(binascii.crc_hqx(header[:-6],0xffff)==be(header[-6:-4]),'independent header CRC')
        ck(crc32_msb(header[:-4]+original)==be(header[-4:]),'reference Load CRC includes header then data')
        listing=be(header[14:18])*2;ck(be(header[listing:listing+2])==1,'one generated data file')
        q=listing+4;n=be(header[q:q+2]);q+=2;filename=header[q:q+n].decode();q+=(n+1)&~1
        n=be(header[q:q+2]);q+=2+((n+1)&~1)
        ck(be(header[q:q+4])*2==len(original) and be(header[q+4:q+6])==binascii.crc_hqx(original,0xffff),'665 data length and CRC')
        wire=[(cy,sp,dp,tftp(p)) for cy,_,sp,dp,p in frames]
        lur_wire=[d for _,sp,_,d in wire if sp==40001+i*16 and d['op']==3]
        ck(len(lur_wire)==1 and bytes.fromhex(lur_wire[0]['data'])==(folder/f'vectors/{i}_lur.bin').read_bytes(),'actual LUR version and file bytes')
        options={'blksize':'1024','port':'5555'} if c['option_flags'] else {}
        requests=[d for _,sp,_,d in wire if sp in (40000+i*16,40001+i*16) and d['op'] in (1,2)]
        ck(len(requests)==2 and all(d['options']==options for d in requests),'actual RRQ and WRQ optional name/value pairs')
        received=[d for _,sp,_,d in wire if sp==43000+i*16+2 and d['op']==3]
        if i==8:
            ck(not received,'unsupported A5 no data file bytes on wire')
            continue
        ck([d['block'] for d in received]==list(range(1,len(received)+1)),'captured consecutive DATA block numbers')
        actual=b''.join(bytes.fromhex(d['data']) for d in received)
        expected=bytearray(original[:512] if i==4 else original)
        if i==3:expected[512+13]^=0x80
        ck(actual==expected,'actual GMII data file, including deliberate loss/corruption')
        ck(binascii.crc_hqx(actual,0xffff)!=be(header[q+4:q+6]) if i in (3,4) else binascii.crc_hqx(actual,0xffff)==be(header[q+4:q+6]),'wire content CRC outcome')
        ck(received[-1]['size']<512 if i!=4 else received[-1]['size']==512,'terminal short/empty DATA or incomplete exhausted transfer')
        # LUR 标识本次上传端口；对应 header/data RRQ 都必须来自新的目标 TID。
        ck(any(d['op']==1 and d['name']==filename for case,_,_,d in packets if case==i),'data RRQ filename follows 665 header')
    a4_pcap=bytearray(pcap);wire_case=-1
    for cy,eth,sp,dp,p in frames:
        d=tftp(p)
        if d['op']==1 and d['name'].endswith('.LUI'):wire_case+=1
        ns=cy*8;entry=struct.pack('<IIII',ns//10**9,ns%10**9,len(eth),len(eth))+eth;pcap+=entry
        if wire_case==0:a4_pcap+=entry
    (folder/'upload.pcap').write_bytes(pcap)
    (folder/'upload_A4.pcap').write_bytes(a4_pcap)
    # 从标准 Ethernet PCAP 再读回 UDP/TFTP，不读取 RTL 内部状态。
    pos=24;decoded=[]
    while pos<len(pcap):
        _,_,n,_=struct.unpack_from('<IIII',pcap,pos);pos+=16;eth=pcap[pos:pos+n];pos+=n
        decoded.append(tftp(eth[42:42+be(eth[38:40])-8]))
    ck(set(x['op'] for x in decoded)=={1,2,3,4,5},'all five standard TFTP opcodes captured')
    ck(not any(x['op']==6 for x in decoded),'no OACK; all options ignored')
    ck(any(x['op']==3 and x['size']==0 and x['block']==4 for x in decoded),'exact 1536 file ends in empty DATA4')
    # 请求使用规范端口59或配置端口1059，DATA/ACK只使用双方TID。
    ck(all(dp in (59,1059) for _,_,sp,dp,p in frames if be(p[:2]) in (1,2)),'normative/configured request destinations')
    ck(all(sp not in (59,1059) and dp not in (59,1059) for _,_,sp,dp,p in frames if be(p[:2]) in (3,4)),'transfer TIDs')
    result=dict(download=download,unsupported=unsupported,items=checks+download["items"]+unsupported["items"],errors=0,defaults=defaults,test_timeout_cycles=250000,test_retry_limit=2,states=states,request_ports=[c['request_port'] for c in cases],lus=reports,pcap_packets=len(decoded),
                ram_bytes=sum(map(len,ram.values())),protocol_versions=[c['protocol_version'] for c in cases],lur_versions=[c['lur_version'] for c in cases],
                decoder='RFC 1350 octet / RFC 2347 ignored options / 615A A4,A3 / ARINC 665-1',
                protocol_sources=['RFC 1350','RFC 2347','ARINC 615A Supplement 2 sections 6.3.3,6.4','arinc-615a 7b806af231cab992b07edfa42e18250d32da18d5','ARINC 665-1 section 3'])
    (folder/'check_summary.json').write_text(json.dumps(result,indent=2)+'\n')
    (folder/'tftp_decode.json').write_text(json.dumps(decoded,indent=2)+'\n')
    print(f'[CHECK] tb_sys_615a PASS items={result["items"]} errors=0 pcap={len(decoded)} ram_bytes={result["ram_bytes"]}')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('action',choices=('vectors','check'));p.add_argument('--dir',required=True,type=Path)
    a=p.parse_args();globals()[a.action](a.dir)
