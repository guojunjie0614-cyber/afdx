"""R139 measurements from raw public application/GMII records, never core M/D."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import zlib


def messages(path, transmit):
    rows=[]
    for number,line in enumerate(path.read_text(encoding='ascii').splitlines(),1):
        p=line.split()
        assert p[0]==('T' if transmit else 'R'),(path,number)
        first,last,vl,length,seq=map(int,p[1:6])
        planned=int(p[6]) if transmit else None
        payload=bytes.fromhex(p[7] if transmit else p[6])
        assert len(payload)==length and last-first+1==length+2,(path,number,'public byte count')
        rows.append(dict(first=first,last=last,vl=vl,length=length,seq=seq,planned=planned,payload=payload))
    assert len({(r['vl'],r['seq']) for r in rows})==len(rows),(path,'duplicate message key')
    return rows


def frames(path):
    rows=[]
    for number,line in enumerate(path.read_text(encoding='ascii').splitlines(),1):
        p=line.split();start,end=map(int,p[:2]);wire=bytes.fromhex(p[2])
        assert len(wire)==end-start+1 and wire[:8]==b'\x55'*7+b'\xd5',(path,number,'GMII framing')
        assert zlib.crc32(wire[8:-4])==int.from_bytes(wire[-4:],'little'),(path,number,'FCS')
        assert wire[20:22]==b'\x08\x00' and wire[22]==0x45 and wire[31]==17,(path,number,'IPv4 UDP')
        ip=wire[22:42]
        assert sum(int.from_bytes(ip[i:i+2],'big') for i in range(0,20,2))%65535==0,(path,number,'IP checksum')
        vl=int.from_bytes(wire[12:14],'big')-256
        frag=int.from_bytes(wire[28:30],'big')
        rows.append(dict(start=start,end=end,vl=vl,offset=(frag&8191)*8,more=bool(frag&8192),
                         payload=wire[42:22+int.from_bytes(wire[24:26],'big')]))
    return rows


def analyse(folder,partial=False):
    folder=Path(folder)
    window=list(map(int,(folder/'window.txt').read_text().split()))
    begin,end,vls,group,mixed,duplex=window[:6]
    burst=window[6] if len(window)>6 else 0
    long_count=window[7] if len(window)>7 else 1
    answer={};groups=[];issues=[];samples=[];source_hashes={}
    for source in range(1+duplex):
        txpath=folder/f'ep{source}_tx.txt';rxpath=folder/f'ep{1-source}_rx.txt'
        tx=messages(txpath,True);rx=messages(rxpath,False)
        if not partial:
            actual_vls={t['vl'] for t in tx}
            if actual_vls!=set(range(vls)):
                issues.append(dict(reason='Declared VL coverage mismatch',source=source,
                    missing=sorted(set(range(vls))-actual_vls),unexpected=sorted(actual_vls-set(range(vls)))))
            for vl in range(vls):
                expected=[];due=begin;sequence=0
                while due<end:
                    length=8192 if mixed==3 and sequence>0 and vl>=vls-long_count else 1472 if mixed==2 and vl==vls-1 else (
                        (1472,3000,8192)[vl-(vls-3)] if mixed==1 and sequence>0 and vl>=vls-3 else group)
                    expected.append((sequence,length,due))
                    if burst:
                        expected.append((sequence+1,length,due));sequence+=2;due+=250000
                    else:
                        sequence+=1;due+=(1 if length<=1471 else (length+8+1471)//1472)*125000
                actual=sorted((t['seq'],t['length'],t['planned']) for t in tx if t['vl']==vl)
                if actual!=expected:issues.append(dict(reason='Offered sequence/length/period coverage mismatch',source=source,vl=vl,
                    expected_messages=len(expected),actual_messages=len(actual)))
        received={(r['vl'],r['seq']):r for r in rx}
        transmit_keys={(t['vl'],t['seq']) for t in tx}
        assert all((r['vl'],r['seq']) in transmit_keys for r in rx),'unexpected receive message'
        fa=frames(folder/f'ep{source}_a.txt');fb=frames(folder/f'ep{source}_b.txt')
        # Distinct physical MAC source bytes may differ; compare IPv4 payloads,
        # fragment offsets, complete frame cycles and VL identities.
        assert [(r['start'],r['end'],r['vl'],r['offset'],r['more'],r['payload']) for r in fa]==[
            (r['start'],r['end'],r['vl'],r['offset'],r['more'],r['payload']) for r in fb], 'A/B frame identity'
        starts=defaultdict(list);previous={};residual=[];first_frames={};complete_frames={};message_index=Counter()
        for f in fa:
            vl=f['vl']
            if vl in previous:residual.append((vl,f['start'],f['start']-previous[vl]-125000))
            if f['offset']==0:
                first_frames[vl,message_index[vl]]=f['start']
                message_index[vl]+=1
            if not f['more']:complete_frames[vl,message_index[vl]-1]=f['end']
            previous[vl]=f['start'];starts[vl].append(f)
        page_events=[];pair_witnesses=[];by_key={(t['vl'],t['seq']):t for t in tx}
        for t in tx:
            key=t['vl'],t['seq'];pages=(t['length']+511)//512
            page_events.append((t['first'],pages))
            if key in complete_frames:page_events.append((complete_frames[key]+1,-pages))
            if burst and t['seq']%2 and key in first_frames and (t['vl'],t['seq']-1) in first_frames:
                prior_key=t['vl'],t['seq']-1
                gap=first_frames[key]-first_frames[prior_key]
                wait_bound=first_frames[prior_key]+125000-t['last']
                pair_witnesses.append(dict(vl=t['vl'],seq=t['seq'],first_input=by_key[prior_key]['first'],
                    second_input=t['first'],second_input_last=t['last'],first_gmii=first_frames[prior_key],
                    second_gmii=first_frames[key],gmii_gap=gap,unavoidable_wait_bound=wait_bound,
                    passed=gap>=125000 and wait_bound>0))
        used=peak=0
        for _,delta in sorted(page_events):used+=delta;peak=max(peak,used)
        answer[f'{source}/total/page_upper_bound']=str(peak)
        answer[f'{source}/total/bag_pairs']=str(len(pair_witnesses))
        answer[f'{source}/total/bag_pair_failures']=str(sum(not r['passed'] for r in pair_witnesses))
        if peak>256:issues.append(dict(reason='Conservative page bound exceeds 256; actual allocation budget not proved',source=source,pages=peak))
        if burst:
            if any(not r['passed'] for r in pair_witnesses):issues.append(dict(reason='BAG pair did not prove waiting',source=source))
            planned=Counter(t['vl'] for t in tx)
            if any(count*125000>end-begin for count in planned.values()):issues.append(dict(reason='Average offered frames exceed declared per-VL capacity',source=source))
        (folder/f't76_budget_{source}.json').write_text(json.dumps(dict(
            conservative_page_upper_bound=peak,page_budget=256,page_budget_proved=peak<=256,
            assumption='Reserve ceil(payload/512) pages at public tx_data first; release only after last GMII fragment ends',
            bag_pairs=pair_witnesses,average_message_counts_by_vl=dict(Counter(t['vl'] for t in tx))),indent=2)+'\n',encoding='utf-8')
        buckets=defaultdict(list)
        for t in tx:
            key=t['vl'],t['seq']
            if key not in received:
                if not partial:issues.append(dict(reason='missing delivery',source=source,vl=t['vl'],seq=t['seq']))
                continue
            r=received[key]
            assert t['payload']==r['payload'],'application byte/order mismatch'
            row=dict(source=source,vl=t['vl'],length=t['length'],seq=t['seq'],tx_first=t['first'],
                tx_last=t['last'],rx_first=r['first'],rx_last=r['last'],planned=t['planned'],
                first_latency=r['first']-t['first'],latency=r['last']-t['first'],
                forced_bag_pair=bool(burst and t['seq']%2))
            row.update(gmii_first=first_frames.get(key),gmii_last=complete_frames.get(key))
            samples.append(row);buckets[t['vl'],t['length']].append(row)
        for (vl,length),rows in sorted(buckets.items()):
            rows.sort(key=lambda r:r['tx_first'])
            cold=rows[0];worst=max(rows,key=lambda r:(r['latency'],-r['tx_first']))
            minimum=min(r['latency'] for r in rows)
            deduction=125000 if burst else 0
            minimum_target=cold['latency'] if burst else minimum
            raw=worst['latency']-minimum_target;jitter=raw-deduction
            # Do not clamp negatives or silently switch to range/period jitter.
            valid=jitter>=0 and (not burst or raw>125000)
            short=length<=1471
            rec=dict(source=source,vl=vl,vlid=f'{vl+256:04X}',length=length,samples=len(rows),
                first_frame_minimum=cold['latency'],observed_minimum=minimum,maximum=worst['latency'],
                bag_deduction=deduction,forced_bag_samples=sum(r['forced_bag_pair'] for r in rows),
                policy='fragment_completion' if not short else 'paired_BAG_wait' if burst else 'periodic_no_BAG_wait',
                note='整条分片消息完成时间，不套单帧抖动门槛' if not short else
                    '首帧不含BAG；背靠背第二条等待BAG，减BAG' if burst else '无样本含 BAG 等待，未减 BAG',
                official_jitter_cycles=jitter,official_jitter_us=jitter*0.008,formula_precondition=valid,
                raw_spread_cycles=raw,observed_spread_cycles=worst['latency']-minimum,
                under_100us=jitter<12500 if short and valid else None,
                internal_50us=jitter<=6250 if short and valid else None,
                short_latency_under_2ms=worst['latency']<=250000 if short else None,
                first_sample=cold,minimum_sample=min(rows,key=lambda r:(r['latency'],r['tx_first'])),worst_sample=worst)
            groups.append(rec)
            key=f'{source}/{vl}/{length}'
            selected=[t for t in tx if t['vl']==vl and t['length']==length]
            delivered=[r for r in rx if r['vl']==vl and r['length']==length]
            inject=sum(max(0,min(t['last']+1,end)-max(t['first']+2,begin)) for t in selected)
            payload=sum(max(0,min(r['last']+1,end)-max(r['first']+2,begin)) for r in delivered)
            values=dict(samples=len(rows),first_min=cold['latency'],observed_min=minimum,
                maximum=worst['latency'],deduction=deduction,jitter=jitter,
                formula_valid=int(valid),inject_bytes=inject,receive_bytes=payload,
                first_tx=cold['tx_first'],first_rx=cold['rx_last'],worst_tx=worst['tx_first'],worst_rx=worst['rx_last'])
            answer.update({key+'/'+metric:str(value) for metric,value in values.items()})
        negative=[r for r in residual if r[2]<0]
        if negative:issues.append(dict(reason='BAG interval shorter than configured',source=source,witness=negative[0]))
        answer[f'{source}/total/inject_bytes']=str(sum(max(0,min(t['last']+1,end)-max(t['first']+2,begin)) for t in tx))
        answer[f'{source}/total/receive_bytes']=str(sum(max(0,min(r['last']+1,end)-max(r['first']+2,begin)) for r in rx))
        answer[f'{source}/total/tx_messages']=str(len(tx));answer[f'{source}/total/rx_messages']=str(len(rx))
        for name in (txpath.name,rxpath.name,f'ep{source}_a.txt',f'ep{source}_b.txt'):
            source_hashes[name]=hashlib.sha256((folder/name).read_bytes()).hexdigest()
        (folder/f't76_bag_{source}.json').write_text(json.dumps(dict(
            residual_cycles=sorted(Counter(r[2] for r in residual).items()),
            plus_one_cycle_samples=[dict(vl=v,gmii_start=s,residual=d) for v,s,d in residual if d==1],
            maximum_positive_residual=max((r[2] for r in residual),default=None)),indent=2)+'\n',encoding='utf-8')
    answer['window/begin']=str(begin);answer['window/end']=str(end)
    answer['window/cycles']=str(end-begin)
    (folder/'t76_python.tsv').write_bytes(''.join(k+'\t'+answer[k]+'\n' for k in sorted(answer)).encode('ascii'))
    result=dict(partial=partial,window_cycles=end-begin,window_ms=(end-begin)*0.000008,
        declared_vls=vls,group=group,mixed=mixed,duplex=duplex,bag_burst=burst,issues=issues,groups=groups,
        source_hashes=source_hashes,formula='Confirmed protocol: periodic=max-min without BAG deduction; paired burst=max-first_frame-BAG')
    if mixed==3:result['long_count']=long_count
    (folder/'t76_samples.json').write_text(json.dumps(samples,indent=2)+'\n',encoding='utf-8')
    (folder/'t76_stats.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('folder',type=Path)
    parser.add_argument('--partial',action='store_true');args=parser.parse_args()
    result=analyse(args.folder,args.partial)
    print(json.dumps(dict(groups=len(result['groups']),issues=len(result['issues']),partial=result['partial'])))
