"""Independent ARCH v0.3 reference; standard library only, never reads RTL.

vectors writes byte-per-line hex files and decimal metadata. tx.meta starts with
case_count/source_bytes/wire_bytes, then len/en_a/en_b/delay/underrun/reset_cut/
wire_len per case. Source and expected-wire arrays are concatenated in case order.
rx.meta starts with case_count/wire_bytes/output_bytes, then wire_len/output_len/
f_len/f_err/idle/noise per case. RAM files contain initial/final address patterns.
Capture lines: A|B start_cycle byte_count contiguous_lowercase_hex (includes preamble/FCS).
"""
import sys
sys.dont_write_bytecode = True
import argparse
import json
import random
import struct
import zlib
from pathlib import Path

PREAMBLE = b'\x55' * 7 + b'\xd5'


def ip_checksum(data):
    data = bytes(data)
    if len(data) & 1:
        data += b'\0'
    total = sum(struct.unpack('!' + 'H' * (len(data) // 2), data))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return (~total) & 65535


def fcs(frame):
    return struct.pack('<I', zlib.crc32(frame) & 0xffffffff)


def build_frame(payload, *, net='A', vlid=1, user_id=1, sn=0, ident=0,
                src_ip=0x0a000001, dst_ip=0xe0000001, sport=1000, dport=2000):
    payload = bytes(payload)
    if not 1 <= len(payload) <= 1471 or net not in ('A', 'B'):
        raise ValueError('payload length or network')
    eth = b'\x03\0\0\0' + struct.pack('!H', vlid)
    eth += b'\x02\0\0' + struct.pack('!H', user_id) + bytes([0x20 if net == 'A' else 0x40])
    eth += b'\x08\0'
    ip = struct.pack('!BBHHHBBHII', 0x45, 0, len(payload)+28, ident, 0, 1, 17, 0, src_ip, dst_ip)
    ip = ip[:10] + struct.pack('!H', ip_checksum(ip)) + ip[12:]
    udp = struct.pack('!HHHH', sport, dport, len(payload)+8, 0)
    return eth + ip + udp + payload + bytes(max(0, 17-len(payload))) + bytes([sn])


def line_bytes(frame):
    return PREAMBLE + bytes(frame) + fcs(frame)


def selftest():
    checks = 0
    def check(ok):
        nonlocal checks
        checks += 1
        if not ok:
            raise AssertionError(f'reference selftest {checks}')
    check(zlib.crc32(b'123456789') == 0xcbf43926)
    check(fcs(b'123456789') == bytes.fromhex('2639f4cb'))
    # Fixed IPv4 ICMP header, checksum field cleared; one's-complement sum = 0x8318.
    header = bytes.fromhex('4500001400000000400100007f0000017f000001')
    check(ip_checksum(header) == 0x7ce7)
    check(ip_checksum(header[:10]+bytes.fromhex('7ce7')+header[12:]) == 0)
    for n, length in ((1, 64), (17, 64), (18, 65), (1471, 1518)):
        frame = build_frame(bytes(i & 255 for i in range(n)))
        check(len(frame)+4 == length)
        check((zlib.crc32(frame+fcs(frame)) ^ 0xffffffff) == 0xdebb20e3)
        check(ip_checksum(frame[14:34]) == 0)
    print(f'[RESULT] afdx_ref PASS checks={checks} errors=0')


def write_hex(path, values, width=2):
    path.write_text(''.join(f'{x:0{width}x}\n' for x in values), encoding='ascii')


def tx_vectors(out, rng, loop):
    specs = []
    if loop:
        for i in range(224):
            n = (17 if i < 16 else rng.choice([1, 17, 18, 53, 1471, rng.randrange(1,1472)]))
            ena, enb = ((1, 1) if i < 16 else (rng.randrange(2), rng.randrange(2)))
            specs.append((n, ena, enb, 0 if i < 16 else rng.randrange(0, 350), -1, 0))
    else:
        specs += [(17,1,1,0,-1,0)] * 4
        specs += [(17,1,1,phase,-1,0) for phase in range(8)]
        for i,n in enumerate([1,17,18,53,1471]+[rng.randrange(1,1472) for _ in range(8)]):
            for ea,eb in ((1,0),(0,1),(1,1),(0,0)):
                specs.append((n,ea,eb,[0,7,71,503,2,19,1200][i%7],-1,0))
        for under in (0,29,59):
            specs.extend([(17,1,1,0,under,0),(17,1,1,0,-1,0)])
        specs.extend([(180,1,1,0,-1,173),(17,1,1,3,-1,0)])
    source_a, source_b, wire_a, wire_b, meta = [], [], [], [], []
    for i,(n,ea,eb,delay,under,cut) in enumerate(specs):
        payload = bytes(rng.randrange(256) for _ in range(n))
        kwargs = dict(vlid=(i*251+1)&65535, user_id=0x1234, sn=i&255, ident=i)
        a = build_frame(payload, net='A', **kwargs)
        b = build_frame(payload, net='B', **kwargs)
        if under >= 0:
            wa = PREAMBLE+a[:under]+struct.pack('<I', zlib.crc32(a[:under])^0xffffffff)
            wb = PREAMBLE+b[:under]+struct.pack('<I', zlib.crc32(b[:under])^0xffffffff)
        else:
            wa, wb = line_bytes(a), line_bytes(b)
        meta.append((len(a),ea,eb,delay,under,cut,len(wa)))
        source_a.extend(a); source_b.extend(b); wire_a.extend(wa); wire_b.extend(wb)
    (out/'tx.meta').write_text(f'{len(meta)} {len(source_a)} {len(wire_a)}\n'+
                             ''.join(' '.join(map(str,row))+'\n' for row in meta), encoding='ascii')
    for name,data in (('src_a',source_a),('src_b',source_b),('wire_a',wire_a),('wire_b',wire_b)):
        write_hex(out/(name+'.hex'),data)
    return {'cases':len(meta),'source_bytes':len(source_a),'wire_bytes':len(wire_a),'loop':loop}


def rx_vectors(out, rng):
    cases = []
    def good(n=17, prefix=7, idle=8):
        data=build_frame(bytes(rng.randrange(256) for _ in range(n)))
        return (b'\x55'*prefix+b'\xd5'+data+fcs(data),data,len(data)+4,0,idle,rng.randrange(256))
    for n in [1,17,18,1471]+[rng.randrange(1,1472) for _ in range(6)]:
        cases.append(good(n,7,rng.choice([8,96,9,13,101,127])))
    for prefix in (0,1,7,20):
        cases.append(good(17,prefix,96))
    bad = []
    base=good()
    for pos in (8+19,len(base[0])-1):
        wire=bytearray(base[0]); wire[pos]^=1
        bad.append((bytes(wire),bytes(wire[8:-4]),base[2],1))
    for n in (0,1,3,4,5,63):
        body=bytes(rng.randrange(256) for _ in range(n))
        bad.append((b'\xd5'+body,body[:-4] if n>=5 else b'',n,2))
    for n in (1519,1600,3000):
        body=bytes(rng.randrange(256) for _ in range(n))
        bad.append((PREAMBLE+body,body[:1514],1519,2))
    bad += [(b'\x55\x57'+base[0],b'',0,3),(b'\x55'*7,b'',0,3),(b'\x00',b'',0,3)]
    for gap in (8,96):
        for wire,data,flen,err in bad:
            cases.append((wire,data,flen,err,gap,rng.randrange(256)))
            cases.append(good(17,7,gap))
    wire_all, body_all, meta = [], [], []
    for wire,body,flen,err,idle,noise in cases:
        meta.append((len(wire),len(body),flen,err,idle,noise))
        wire_all.extend(wire);body_all.extend(body)
    (out/'rx.meta').write_text(f'{len(meta)} {len(wire_all)} {len(body_all)}\n'+
        ''.join(' '.join(map(str,row))+'\n' for row in meta),encoding='ascii')
    write_hex(out/'rx_wire.hex',wire_all);write_hex(out/'rx_body.hex',body_all)
    return {'cases':len(meta),'wire_bytes':len(wire_all),'output_bytes':len(body_all)}


def vectors(test, seed, out, ram_top=None):
    out.mkdir(parents=True, exist_ok=True)
    rng=random.Random(seed)
    if test.startswith('tb_rx_'):
        from rx_ref import generate
        result=generate(test,seed,out)
    elif test.startswith('tb_tx_'):
        from tx_ref import generate
        result=generate(test,seed,out)
    elif test in ('tb_mac_tx','tb_mac_loop'):
        result=tx_vectors(out,rng,test=='tb_mac_loop')
    elif test=='tb_mac_rx':
        result=rx_vectors(out,rng)
    elif test=='tb_probe_ram':
        depth,width=(65536,13) if ram_top=='probe_p2_array' else (2048,8)
        first=[((i*37)^(i>>8)^(i>>3)^0xa5)&((1<<width)-1) for i in range(depth)]
        final=[(x^((1<<width)-1)) if i%2==0 else x for i,x in enumerate(first)]
        digits=(width+3)//4
        write_hex(out/'ram_first.hex',first,digits);write_hex(out/'ram_final.hex',final,digits)
        result={'depth':depth,'width':width}
    else:
        raise ValueError('unknown vector test')
    result.update(test=test,seed=seed)
    (out/'manifest.json').write_text(json.dumps(result,sort_keys=True,indent=2)+'\n',encoding='ascii')
    print(json.dumps(result,sort_keys=True))


def pcap(dump, out):
    totals=dict(frames=0,good=0,format_bad=0,preamble_bad=0,length_bad=0,fcs_bad=0)
    packets=[]
    for line in dump.read_text(encoding='ascii').splitlines():
        if not line.strip(): continue
        totals['frames']+=1
        try:
            net,start,count,raw=line.split()
            cycle=int(start);wire=bytes.fromhex(raw)
            if net not in ('A','B') or cycle<0 or len(wire)!=int(count) or raw!=raw.lower():
                raise ValueError('capture format')
        except ValueError:
            totals['format_bad']+=1;continue
        bad=False
        if wire[:8]!=PREAMBLE:totals['preamble_bad']+=1;bad=True
        if not 64<=len(wire)-8<=1518:totals['length_bad']+=1;bad=True
        if len(wire)<12 or fcs(wire[8:-4])!=wire[-4:]:totals['fcs_bad']+=1;bad=True
        if not bad:
            totals['good']+=1;packets.append((cycle*8,wire[8:-4]))
    with out.open('wb') as stream:
        stream.write(struct.pack('<IHHIIII',0xa1b23c4d,2,4,0,0,65535,1))
        for stamp,body in packets:
            stream.write(struct.pack('<IIII',stamp//1000000000,stamp%1000000000,len(body),len(body)))
            stream.write(body)
    print(json.dumps(totals,sort_keys=True))
    return totals


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='action',required=True)
    sub.add_parser('selftest')
    p=sub.add_parser('vectors');p.add_argument('--test',required=True);p.add_argument('--seed',type=int,required=True)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--ram-top')
    p=sub.add_parser('pcap');p.add_argument('--dump',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p=sub.add_parser('check');p.add_argument('--test',required=True);p.add_argument('--dir',type=Path,required=True)
    args=parser.parse_args()
    if args.action=='selftest': selftest()
    elif args.action=='vectors': vectors(args.test,args.seed,args.out,args.ram_top)
    elif args.action=='check':
        if args.test.startswith('tb_rx_'):
            from rx_ref import check
        else:
            from tx_ref import check
        result=check(args.test,args.dir)
        (args.dir/'check_summary.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
        return int(result['errors']!=0)
    else:
        result=pcap(args.dump,args.out)
        return int(result['good']!=result['frames'])
    return 0


if __name__=='__main__':
    raise SystemExit(main())
