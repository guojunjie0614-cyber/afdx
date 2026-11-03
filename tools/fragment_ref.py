"""Independent IPv4/UDP AFDX fragment reference. Frames include FCS, optionally preamble."""
import argparse
import json
import struct
import zlib
from pathlib import Path

PREAMBLE = b'\x55'*7 + b'\xd5'

def checksum(data):
    data = bytes(data) + (b'\0' if len(data) % 2 else b'')
    s = sum(struct.unpack('!%dH' % (len(data)//2), data))
    while s >> 16:
        s = (s & 65535) + (s >> 16)
    return (~s) & 65535

def udp_sum(src, dst, udp):
    return checksum(struct.pack('!IIBBH', src, dst, 0, 17, len(udp)) + udp)

def build(payload, vlid=1, ident=1, sn=0, lmax=1471, net='A',
          src=0x0a000001, dst=0xe0000001, sport=1000, dport=2000,
          udp_checksum=True):
    payload = bytes(payload)
    if not 1 <= len(payload) <= 8192 or not 1 <= lmax <= 1471 or net not in ('A','B'):
        raise ValueError('invalid message or configuration')
    if len(payload) <= 1471 and len(payload) > lmax:
        raise ValueError('short message exceeds Lmax')
    udp = struct.pack('!HHHH', sport, dport, len(payload)+8, 0) + payload
    if udp_checksum:
        val = udp_sum(src, dst, udp) or 0xffff
        udp = udp[:6] + struct.pack('!H', val) + udp[8:]
    cap = min(lmax+8,1479)
    frames = []
    pos = 0
    frame_sn = sn
    if not 0 <= frame_sn <= 255:
        raise ValueError('invalid sequence number')
    while pos < len(udp):
        remaining = len(udp)-pos
        n = remaining if remaining <= cap else cap//8*8
        if not n:
            raise ValueError('fragment budget cannot progress')
        mf = pos+n < len(udp)
        flags = (0x2000 if mf else 0) | (pos//8)
        ip = struct.pack('!BBHHHBBHII', 0x45,0,20+n,ident,flags,1,17,0,src,dst)
        ip = ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
        eth = b'\x03\0\0\0'+struct.pack('!H',vlid)+b'\x02\0\0\0\x01'+bytes([0x20 if net=='A' else 0x40])+b'\x08\0'
        body = eth+ip+udp[pos:pos+n]
        body += bytes(max(0, 59-len(body))) + bytes([frame_sn])
        frames.append(body+struct.pack('<I',zlib.crc32(body)))
        frame_sn = 1 if frame_sn == 255 else frame_sn + 1
        pos += n
    return frames

def decode(frame):
    frame = bytes(frame)
    if frame.startswith(PREAMBLE): frame = frame[8:]
    if len(frame) < 64 or len(frame) > 1518 or zlib.crc32(frame[:-4]) != int.from_bytes(frame[-4:],'little'):
        raise ValueError('FCS or frame length')
    if frame[12:14] != b'\x08\0': raise ValueError('EtherType')
    ip = frame[14:]
    ihl = (ip[0] & 15)*4
    if ip[0] >> 4 != 4 or ihl < 20 or 14+ihl > len(frame)-5:
        raise ValueError('IPv4 header')
    total = int.from_bytes(ip[2:4],'big')
    if total < ihl or 14+total > len(frame)-5 or checksum(ip[:ihl]):
        raise ValueError('IPv4 length/checksum')
    flags = int.from_bytes(ip[6:8],'big')
    offset = (flags & 0x1fff)*8
    mf = bool(flags & 0x2000)
    data = ip[ihl:total]
    if flags & 0x8000 or (flags & 0x4000 and (mf or offset)) or not data or (mf and len(data)%8):
        raise ValueError('fragment flags/alignment')
    if ip[9] != 17: raise ValueError('protocol')
    if offset+len(data)>8200: raise ValueError('oversize')
    return dict(vlid=int.from_bytes(frame[4:6],'big'), src=int.from_bytes(ip[12:16],'big'),
        dst=int.from_bytes(ip[16:20],'big'), protocol=ip[9], ident=int.from_bytes(ip[4:6],'big'),
        offset=offset, mf=mf, data=data, sn=frame[-5], frame_length=len(frame))

class Reassembler:
    def __init__(self, timeout=250000000, limit=16):
        self.timeout, self.limit, self.contexts = timeout, limit, {}
    def expire(self, cycle):
        for key, ctx in list(self.contexts.items()):
            if cycle-ctx['last'] >= self.timeout: del self.contexts[key]
    def feed(self, frame, cycle=0):
        self.expire(cycle)
        f = decode(frame)
        key = tuple(f[k] for k in ('vlid','src','dst','protocol','ident'))
        if key not in self.contexts:
            if len(self.contexts)>=self.limit: raise ValueError('context capacity')
            self.contexts[key] = dict(parts={}, total=None, last=cycle)
        c = self.contexts[key]; c['last']=cycle
        start, data = f['offset'], f['data']; end=start+len(data)
        try:
            if any(start < p+len(d) and p < end for p,d in c['parts'].items()): raise ValueError('overlap')
            if c['total'] is not None and (end > c['total'] or (f['mf'] and end >= c['total'])): raise ValueError('inconsistent total')
            if not f['mf']:
                if c['total'] is not None and c['total'] != end: raise ValueError('inconsistent total')
                if any(p+len(d)>end for p,d in c['parts'].items()): raise ValueError('inconsistent total')
                c['total']=end
            c['parts'][start]=data
            pos=0; chunks=[]
            for p,d in sorted(c['parts'].items()):
                if p != pos: return None
                chunks.append(d); pos+=len(d)
            if c['total'] is None or pos != c['total']: return None
            udp=b''.join(chunks)
            if len(udp)<9 or int.from_bytes(udp[4:6],'big') != len(udp) or len(udp)>8200: raise ValueError('UDP length')
            if udp[6:8] != b'\0\0' and udp_sum(f['src'], f['dst'], udp): raise ValueError('UDP checksum')
            del self.contexts[key]
            return udp[8:]
        except ValueError:
            del self.contexts[key]
            raise

def selftest():
    assert checksum(bytes.fromhex('4500001400000000400100007f0000017f000001')) == 0x7ce7
    assert zlib.crc32(b'123456789') == 0xcbf43926
    for n in (1,1464,1471,1472,8192):
        payload=bytes(i%251 for i in range(n)); frames=build(payload)
        r=Reassembler(); got=None
        for f in frames:
            got=r.feed(f)
        assert got == payload
        if n==8192: assert [decode(f)['offset'] for f in frames] == [0,1472,2944,4416,5888,7360]
    assert [decode(f)['sn'] for f in build(bytes(8192),sn=254)] == [254,255,1,2,3,4]
    fs=build(bytes(1472)); r=Reassembler(); r.feed(fs[0])
    try: r.feed(fs[0]); assert False
    except ValueError: pass
    bad=bytearray(fs[0]); bad[-1]^=1
    try: decode(bad); assert False
    except ValueError: pass
    bad=bytearray(fs[-1]); bad[34]^=1; bad[-4:]=struct.pack('<I',zlib.crc32(bad[:-4]))
    r=Reassembler(); r.feed(fs[0])
    try: r.feed(bad); assert False
    except ValueError: pass
    bad=bytearray(fs[0]);bad[16:18]=struct.pack('!H',1491)
    bad[24:26]=b'\0\0';bad[24:26]=struct.pack('!H',checksum(bad[14:34]))
    bad[-4:]=struct.pack('<I',zlib.crc32(bad[:-4]))
    try: decode(bad); assert False
    except ValueError: pass
    try: build(bytes(8193)); assert False
    except ValueError: pass
    r=Reassembler(timeout=2); r.feed(fs[0]); r.expire(2); assert not r.contexts
    print('[RESULT] fragment_ref PASS')

def main():
    p=argparse.ArgumentParser(); p.add_argument('command', choices=['selftest','vectors','analyze']); p.add_argument('path',nargs='?')
    a=p.parse_args()
    if a.command=='selftest': selftest(); return
    if not a.path: p.error('path required')
    path=Path(a.path)
    if a.command=='vectors':
        path.mkdir(parents=True,exist_ok=True)
        for n in (1,1464,1471,1472,8192):
            frames=build(bytes(i%251 for i in range(n)),ident=n)
            (path / ('frames_%d.txt'%n)).write_text(''.join(PREAMBLE.hex()+f.hex()+'\n' for f in frames),encoding='ascii')
        frames=build(bytes(i%251 for i in range(1472)), ident=123)
        bad_fcs=bytearray(frames[0]); bad_fcs[-1]^=1
        bad_udp=bytearray(frames[-1]); bad_udp[34]^=1
        bad_udp[-4:]=struct.pack('<I',zlib.crc32(bad_udp[:-4]))
        alignment=bytearray(frames[0]); alignment[16:18]=struct.pack('!H',1491)
        alignment[24:26]=b'\0\0'; alignment[24:26]=struct.pack('!H',checksum(alignment[14:34]))
        alignment[-4:]=struct.pack('<I',zlib.crc32(alignment[:-4]))
        overlap=bytearray(frames[-1]); overlap[20:22]=struct.pack('!H',1)
        overlap[24:26]=b'\0\0'; overlap[24:26]=struct.pack('!H',checksum(overlap[14:34]))
        overlap[-4:]=struct.pack('<I',zlib.crc32(overlap[:-4]))
        for name, seq in [('bad_fcs',[bad_fcs]), ('bad_udp',[frames[0],bad_udp]),
                          ('overlap',[frames[0],overlap]), ('alignment',[alignment]), ('missing',[frames[0]])]:
            (path / (name+'.txt')).write_text(''.join(PREAMBLE.hex()+bytes(f).hex()+'\n' for f in seq),encoding='ascii')
    else:
        r=Reassembler()
        for line in path.read_text(encoding='ascii').splitlines():
            if not line.strip(): continue
            f=decode(bytes.fromhex(line)); payload=r.feed(bytes.fromhex(line))
            f['data']=f['data'].hex(); f['payload']=None if payload is None else payload.hex()
            print(json.dumps(f))
        if r.contexts: raise SystemExit('incomplete datagram')
if __name__=='__main__': main()

