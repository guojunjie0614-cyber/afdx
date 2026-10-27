"""L8 performance from GMII byte intervals and independently matched M/D rows."""
import collections


def measure(sysrows,endpoints,gmii,samples,expect):
    windows={};marks=[(c,p[2]) for c,_,p in sysrows if p[0]=='P']
    for c,_,p in sysrows:
        if p[0]=='F' and p[2] in ('begin','end'):
            windows.setdefault(p[3],{})[p[2]]=c
    def overlap(a,b,start,end):return max(0,min(b,end)-max(a,start))
    def stats(values):
        return dict(samples=len(values),max=max(values) if values else None,
                    mean=sum(values)/len(values) if values else None,
                    max_us=max(values)*0.008 if values else None,
                    mean_us=sum(values)*0.008/len(values) if values else None)
    result={}
    required={'light_d0','light_d257','throughput_d0','throughput_d257','duplex_d0','duplex_d257','gbe77_d0','gbe77_d257','gbe81_d0','gbe81_d257'}
    expect(required<={name for _,name in marks},'light/ten-VL/77/81 phases')
    for k,(stage_start,stage) in enumerate(marks):
        if stage not in required:continue
        stage_end=marks[k+1][0] if k+1<len(marks) else 1<<62
        near_limit=stage.startswith('gbe81')
        vls=81 if near_limit else 77 if stage.startswith('gbe77') else 10
        throughput=stage.startswith(('throughput','duplex','gbe'))
        directions=(1,2) if stage.startswith(('duplex','light','gbe')) else (1,)
        bag=125000
        if throughput:
            window=windows.get(stage,{})
            expect(set(window)=={'begin','end'},'L8 explicit measurement window '+stage)
            begin,end=window.get('begin',stage_start),window.get('end',stage_start)
            duration=end-begin
            expect(duration>=2500000,'L8 at least 20ms stable window '+stage)
            expect(begin-stage_start>=2*bag,'L8 two BAG warmup rounds '+stage)
        else:
            begin,end=stage_start,stage_end;duration=None
        stage_result=dict(window=[begin,end] if throughput else None,
            measured_cycles=duration,measured_ms=duration*0.000008 if duration else None,directions={})
        expected_delay=257 if stage.endswith('d257') else 0
        for source_number in directions:
            source=endpoints[source_number];destination=endpoints[3-source_number]
            all_messages=[m for m in source['messages'] if m['stage']==stage]
            selected=[m for m in all_messages if not throughput or begin<=m['cycle']<end]
            expect(bool(selected) and all(m['result']=='accept' for m in all_messages),'L8 every offered message accepted '+stage)
            expect(all(len(m['deliveries'])==1 for m in all_messages),'L8 every accepted message delivered exactly once '+stage)
            expect(all((m['words'][0]&7)==7 for m in all_messages),'L8 both networks enabled '+stage)
            if throughput:
                expect({m['vl'] for m in selected}==set(range(vls)) and all(m['n']==1471 and m['words'][1]==bag for m in selected),
                       'full payload VLs with BAG 1ms '+stage)
                for vl in range(vls):
                    mm=[m for m in all_messages if m['vl']==vl]
                    expect(len(mm)>=23 and all(b['cycle']-a['cycle']==bag for a,b in zip(mm,mm[1:])),
                           f'L8 one submission per BAG ES{source_number} VL{vl} {stage}')
            else:
                expect(len({m['vl'] for m in all_messages})==1,'L8 light load one VL '+stage)
                for a,b in zip(all_messages,all_messages[1:]):
                    expect(b['cycle']-a['cycle']>a['words'][1],'L8 light submissions slower than BAG '+stage)
            bad_tx=sum(source['pulse_stages'][stage][n] for n in ('drop_dis','drop_full','drop_long','drop_nopage'))
            bad_rx=sum(destination['pulse_stages'][stage][net+'_'+n] for net in ('a','b') for n in ('fcs','len','hdr','unk','cfg','ic','ovf','gdrop'))
            expect(bad_tx==bad_rx==0,'L8 no loss/error counter increase '+stage)
            delivered=sum(m['result']=='accept' and len(m['deliveries'])==1 for m in all_messages)
            rm=destination['pulse_stages'][stage]['rm_drop']
            expect(rm==delivered,'L8 one normal redundancy rejection per delivery '+stage)
            metrics=dict(vls=vls if throughput else 1,accepted=len(all_messages),delivered=delivered,rm_drop=rm,abnormal_pulses=bad_tx+bad_rx,
                         measurement_messages=len(selected),gmii={},BAG_wait_definition='max(P_slow+BAG-M,0)')
            if throughput and duration>0:
                for net in ('A','B'):
                    frames=[f for f in source['gmii_tx'] if f['net']==net and f.get('message',{}).get('stage')==stage]
                    frame_bytes=sum(overlap(f['start']+8,f['end'],begin,end) for f in frames)
                    payload_bytes=sum(overlap(f['start']+50,f['start']+50+f['message']['n'],begin,end) for f in frames)
                    rates=dict(frame_bytes=frame_bytes,payload_bytes=payload_bytes,
                               frame_mbps=frame_bytes*1000/duration,payload_mbps=payload_bytes*1000/duration)
                    metrics['gmii'][net]=rates
                    if not near_limit:
                        minimum=900 if vls==77 else 117.68
                        expect(rates['payload_mbps']>=minimum,f'ES{source_number} {net} GMII UDP throughput >= {minimum}Mbps {stage}')
                ds=[d for m in all_messages for d in m['deliveries']]
                payload=sum(overlap(d['cycle'],d['cycle']+d['n'],begin,end) for d in ds)
                metrics['delivered_payload_bytes']=payload;metrics['delivered_mbps']=payload*1000/duration
                if not near_limit:
                    expect(metrics['delivered_mbps']>=(900 if vls==77 else 117.68),'delivery throughput floor '+stage)
                count_d=sum(begin<=d['cycle']<end for d in ds)
                count_rm=sum(begin<=t<end for t in destination['pulses']['rm_drop'])
                expect(count_rm==count_d,'L8 window rm_drop equals delivered messages '+stage)
                metrics['window_deliveries']=count_d;metrics['window_rm_drop']=count_rm
            tx=[];rx=[];e2e=[];tx_adjusted=[];e2e_adjusted=[];bags=[]
            for m in selected:
                if len(m['deliveries'])!=1:continue
                d=m['deliveries'][0];f=d['frame'];sent=f.get('source')
                if not sent:continue
                delay=f.get('link_delay')
                expect(delay==expected_delay,'L8 intended link delay '+stage)
                delay=delay or 0
                tx_value=sent['start']-m['cycle']
                rx_value=d['cycle']+d['n']-1-(f['gmii_end']-1)
                total=d['cycle']+d['n']-1-m['cycle']-delay
                previous=m.get('previous')
                bag_wait=max(0,previous['start']+m['words'][1]-m['cycle']) if previous else 0
                tx.append(tx_value);rx.append(rx_value);e2e.append(total);bags.append(bag_wait)
                tx_adjusted.append(tx_value-bag_wait);e2e_adjusted.append(total-bag_wait)
                if not near_limit:
                    expect(0<rx_value<=250000,'L8 receive last-byte latency <=2ms '+stage)
                    expect(0<=tx_value-(bag_wait if throughput else 0)<=250000,'L8 TX latency <=2ms after BAG allowance '+stage)
                    expect(0<total-(bag_wait if throughput else 0)<=250000,'L8 end-to-end latency <=2ms after BAG allowance '+stage)
                    if throughput:
                        expect(0<total<=25973,'raw end-to-end latency <= 207.784us '+stage)
            metrics.update(T_tx=stats(tx),T_rx=stats(rx),T_e2e_link_removed=stats(e2e),
                T_tx_BAG_removed=stats(tx_adjusted),T_e2e_BAG_and_link_removed=stats(e2e_adjusted),BAG_wait=stats(bags))
            intervals=[];schedule_errors=[];light_groups={}
            for vl in {m['vl'] for m in selected}:
                ms=sorted((m for m in all_messages if m['vl']==vl and m['frame']),key=lambda m:m['frame']['start'])
                for a,b in zip(ms,ms[1:]):
                    if throughput and not begin<=b['cycle']<end:continue
                    fa=a['frame']['frames'][0].get('gmii');fb=b['frame']['frames'][0].get('gmii')
                    if fa and fb:
                        intervals.append(fb['start']-fa['start']-b['words'][1])
                        if a['n']==b['n']:
                            schedule_errors.append((fb['start']-fa['start'])-(b['cycle']-a['cycle']))
            if not throughput:
                for n in sorted({m['n'] for m in selected}):
                    group=[(m,t,e) for m,t,e in zip(selected,tx,e2e) if m['n']==n]
                    expect(len(group)==8,'light fixed-length group has eight repeated messages')
                    times=[m['cycle'] for m,_,_ in group]
                    tv=[t for _,t,_ in group];ev=[e for _,_,e in group]
                    light_groups[str(n)]=dict(samples=len(group),T_tx=stats(tv),T_e2e=stats(ev),
                        accepted_intervals=stats([b-a for a,b in zip(times,times[1:])]),
                        tx_jitter_cycles=max(tv)-min(tv),e2e_jitter_cycles=max(ev)-min(ev))
                metrics['light_groups']=light_groups
                metrics['tx_jitter_cycles']=max(g['tx_jitter_cycles'] for g in light_groups.values())
                metrics['e2e_jitter_cycles']=max(g['e2e_jitter_cycles'] for g in light_groups.values())
                metrics['jitter_definition']='max(T_tx)-min(T_tx), independently for each fixed payload length; max over groups'
                expect(metrics['tx_jitter_cycles']<=7 and metrics['e2e_jitter_cycles']<=7,'light jitter <= seven cycles '+stage)
                metrics['average_payload_mbps']=sum(m['n'] for m in all_messages)*1000/(stage_end-stage_start)
                expect(max(e2e,default=0)<=25973,'light end-to-end latency floor '+stage)
                metrics['jitter']=dict(max=metrics['tx_jitter_cycles'],max_us=metrics['tx_jitter_cycles']*0.008,
                                       samples=sum(g['samples'] for g in light_groups.values()))
            else:
                metrics['jitter']=stats(intervals)
                if not near_limit:expect(bool(intervals) and all(v==0 for v in intervals),'full-load TX jitter zero '+stage)
            metrics['scheduling_interval_error']=stats([abs(v) for v in schedule_errors])
            metrics['raw_gap_minus_BAG']=stats(intervals)
            metrics['formula_limit']=max((m['w_limit'] for m in selected),default=0)
            metrics['formula_limit_us']=metrics['formula_limit']*0.008
            stage_result['directions'][f'es{source_number}_to_es{3-source_number}']=metrics
        result[stage]=stage_result
    return result


# R97 uses public GMII SFD and application records; legacy measure() above is unchanged.
def measure_r97(folder, stages=None, output=None):
    from pathlib import Path
    import json
    folder=Path(folder)
    windows={};offers=collections.defaultdict(list);current='initial';offer_vlid=False
    for line in (folder/'sys_events.txt').read_text(encoding='ascii').splitlines():
        p=line.split()
        if p and p[0]=='G' and len(p)>3 and p[2]=='OFFER_VLID':offer_vlid=True
        if p and p[0]=='P':current=p[2]
        if p and p[0]=='O':offers[current,int(p[2]),int(p[3])].append((int(p[5]),int(p[4])))
        if p and p[0]=='F' and p[2] in ('begin','end'):windows.setdefault(p[3],{})[p[2]]=int(p[1])
    endpoints={}
    for es in (1,2):
        ms=[];stage='initial';by_vl=collections.defaultdict(list);offer_index=collections.Counter();txpulses=collections.Counter()
        tx_vlids={};wire_inputs=[];wire_index=0
        for line in (folder/f'es{es}_tx/events.txt').read_text(encoding='ascii').splitlines():
            p=line.split()
            if p[0]=='P':stage=p[2]
            elif p[0]=='E':txpulses[stage,p[2]]+=1
            elif p[0]=='C' and p[2]=='tx' and (int(p[3],16)&7)==2:tx_vlids[int(p[4],16)]=int(p[3],16)>>3
            elif p[0]=='A':wire_inputs.append(p)
            elif p[0]=='M':
                n=int(p[3]);cycle=int(p[10]) if len(p)>11 else int(p[1])
                first=int(p[8]) if len(p)>9 and p[8].lstrip('-').isdigit() else cycle-n+1
                maxrun=int(p[9]) if len(p)>9 and p[9].isdigit() else 0
                m=dict(id=len(ms)+1,stage=stage,cycle=cycle,vl=int(p[2]),n=n,data=p[7],tx={},rx={},delivery=None,
                       first=first,maxrun=maxrun,stream=len(p)>11,stalls=int(p[11]) if len(p)>11 else max(0,cycle-first+1-n))
                offervl=next((k for k,v in tx_vlids.items() if v==m['vl']),m['vl']) if offer_vlid else m['vl']
                if wire_inputs:
                    a=wire_inputs[wire_index];wire_index+=1
                    assert int(a[1])==m['cycle'] and int(a[3])==n and a[4]==m['data'], 'public tx_data payload and end match core M'
                    assert tx_vlids[int(a[2],16)]==m['vl'] and int(a[5])==first, 'public tx_data VLID and first match core M'
                    assert int(a[6])==m['stalls'] and int(a[7])==m['maxrun'], 'public tx_data stall record'
                key=(stage,es,offervl);index=offer_index[key];offer_index[key]+=1
                if key in offers:
                    assert index<len(offers[key]) and offers[key][index][1]==m['n'],'planned release matching'
                    m['release']=offers[key][index][0];m['planned']=True
                else:m['release']=m['cycle'];m['planned']=False  # Legacy captures lack a separate planned-release record.
                ms.append(m);by_vl[m['vl']].append(m)
        assert not wire_inputs or wire_index==len(wire_inputs), 'every public tx_data message accounted for'
        endpoints[es]=dict(messages=ms,by_vl=by_vl,txpulses=txpulses,tx_vlids=tx_vlids)
        for net in ('A','B'):
            for kind,dest in [('tx',es),('rx',3-es)]:
                cursor=collections.Counter()
                for line in (folder/f'es{dest}_gmii_{kind}/dump_{net.lower()}.txt').read_text(encoding='ascii').splitlines():
                    p=line.split();wire=p[3];raw=int(wire[24:28],16)
                    vl=tx_vlids[raw] if raw in tx_vlids else raw-(100 if es==1 else 2000)
                    assert vl in by_vl and cursor[vl]<len(by_vl[vl]),('unmatched GMII',es,net,vl)
                    m=by_vl[vl][cursor[vl]];cursor[vl]+=1
                    assert int(p[2])*2==len(wire) and wire[100:100+2*m['n']]==m['data'],('GMII payload',es,net,m['id'])
                    m[kind][net]=(int(p[1])+7,wire)
                    if kind=='rx':assert wire==m['tx'][net][1],('link bytes',es,net,m['id'])
                assert all(cursor[v]==len(mm) for v,mm in by_vl.items()),('GMII counts',es,net,kind)
        cursor=collections.Counter();stage='initial';pulses=collections.Counter()
        for line in (folder/f'es{3-es}_rx/events.txt').read_text(encoding='ascii').splitlines():
            p=line.split()
            if p[0]=='P':stage=p[2]
            elif p[0]=='E':pulses[stage,p[2]]+=1
            elif p[0]=='D':
                vl=int(p[3]);assert vl in by_vl and cursor[vl]<len(by_vl[vl]),'unmatched delivery'
                m=by_vl[vl][cursor[vl]];cursor[vl]+=1
                assert int(p[6])==m['n'] and p[7]==m['data'],'delivery payload/order'
                m['delivery']=(int(p[8])+2 if len(p)>9 else int(p[1]),p[2]);m['header_bytes']=2 if len(p)>9 else 0
        assert all(cursor[v]==len(mm) for v,mm in by_vl.items()),'exactly one delivery'
        endpoints[es]['pulses']=pulses
    scope=sorted({m['stage'] for ep in endpoints.values() for m in ep['messages'] if (m['stage'] in stages if stages else m['stage'].startswith(('var_','gbe77_')))})
    answer={};frame_rows=[]
    metrics=('L_gmii','L_tx','L_rx','L_rx_last','L_app','L_app_last','L_release_app','L_release_app_last','L_entry_first','L_entry_last')
    def stats_len(samples):
        result=dict(samples=len(samples),min='NA',max='NA',jitter='NA',vl='NA',len='NA',min_frame='NA',max_frame='NA')
        if not samples:return result
        groups=collections.defaultdict(list)
        for vl,n,i,v in samples:groups[(vl,n)].append((i,v))
        result['min']=min(v for _,_,_,v in samples);result['max']=max(v for _,_,_,v in samples)
        best=-1;witness=None
        for (vl,n) in sorted(groups):
            rows=groups[(vl,n)];lo=min(v for _,v in rows);hi=max(v for _,v in rows)
            li=min(i for i,v in rows if v==lo);hi_id=min(i for i,v in rows if v==hi)
            delta=hi-lo
            if delta>best or (delta==best and witness is not None and (vl<witness[0] or (vl==witness[0] and n<witness[1]))):
                best=delta;witness=(vl,n,li,hi_id)
        result.update(jitter=best,vl=witness[0],len=witness[1],min_frame=witness[2],max_frame=witness[3])
        return result
    for stage in scope:
        assert stage in windows and set(windows[stage])=={'begin','end'},('measurement window',stage)
        begin,end=windows[stage]['begin'],windows[stage]['end'];assert end>begin
        stage_lengths=sorted({m['n'] for ep in endpoints.values() for m in ep['messages'] if m['stage']==stage})
        for es in (1,2):
            direction=f'es{es}_to_es{3-es}';ep=endpoints[es];ms=[m for m in ep['messages'] if m['stage']==stage]
            selected=[m for m in ms if begin<=m['cycle']<end]
            prefix=f'{stage}/{direction}/accepted/all'
            answer[prefix+'/offered/messages']=len(ms);answer[prefix+'/delivered/messages']=sum(m['delivery'] is not None for m in ms)
            answer[prefix+'/redundancy/rejections']=ep['pulses'][stage,'rm_drop']
            assert ep['pulses'][stage,'rm_drop']==len(ms),('redundancy',stage,es)
            assert all(not ep['pulses'][stage,net+'_'+event] for net in ('a','b') for event in ('fcs','len','hdr','unk','cfg','ic','ovf','gdrop')),('error pulses',stage,es)
            answer[prefix+'/throughput/window_cycles']=end-begin
            answer[prefix+'/throughput/payload_bytes']=sum(max(0,min(m['delivery'][0]+m['n'],end)-max(m['delivery'][0],begin)) for m in ms)
            interval=0;previous={}
            for m in ms:
                for net in ('A','B'):
                    k=(m['vl'],net);now=m['tx'][net][0]
                    bag=125000
                    if stage.startswith('var_') and not stage.startswith('var_high'):bag=(125000,250000,500000,1000000)[m['vl']//8]
                    if k in previous and begin<=m['cycle']<end:interval=max(interval,abs(now-previous[k]-bag))
                    previous[k]=now
            answer[prefix+'/tx_interval_jitter/max']=interval
            # R120-1 injection side: handshake bytes and stalls at the application port.
            inject=stalls=stallmax=lag=0;lagsamples=0;drops=overflow=errors=0
            for m in ms:
                first=m['first'];cycle=m['cycle'];n=m['n']
                if begin<=first<end and cycle<end:
                    inject+=n;stalls+=m['stalls'];stallmax=max(stallmax,m['maxrun'])
                    if m['planned']:
                        lag=max(lag,first-m['release']);lagsamples+=1
                elif first<end and cycle>=begin:
                    inject+=min(n,max(0,min(cycle+1,end)-max(first+(2 if m['stream'] else 0),begin)))
            for (st,event),count in ep['txpulses'].items():
                if st==stage and event in ('drop_dis','drop_full','drop_long','drop_nopage'):drops+=count
                if event in ('a_ovf','b_ovf'):overflow+=count
                if event in ('a_fcs','a_len','a_hdr','a_unk','a_cfg','a_ic','a_ovf','a_gdrop','b_fcs','b_len','b_hdr','b_unk','b_cfg','b_ic','b_ovf','b_gdrop'):errors+=count
            answer[prefix+'/integrity/dropped']=drops
            answer[prefix+'/integrity/duplicate']=sum(m['delivery'] is not None for m in ms)-len(ms)
            answer[prefix+'/integrity/overflow']=overflow
            answer[prefix+'/integrity/errors']=errors
            answer[prefix+'/inject/payload_bytes']=inject
            answer[prefix+'/inject/window_cycles']=end-begin
            answer[prefix+'/inject/mbps']=inject*1000.0/(end-begin)
            answer[prefix+'/inject/stall_cycles']=stalls
            answer[prefix+'/inject/stall_maxrun']=stallmax
            answer[prefix+'/inject/lag_max']=lag if lagsamples else 'NA'
            answer[prefix+'/inject/lag_samples']=lagsamples
            buckets=collections.defaultdict(list);entry_samples=[]
            for m in ms:
                d,winner=m['delivery']
                for net in ('A','B'):
                    tx=m['tx'][net][0];rx=m['rx'][net][0]
                    assert rx-tx==(257 if stage.endswith('_d257') else 0),'link delay'
                    values=dict(L_gmii=rx-tx,L_tx=tx-m['cycle'])
                    if net==winner:
                        values.update(L_rx=d-rx,L_rx_last=d+m['n']-1-rx,L_app=d-m['cycle'],L_app_last=d+m['n']-1-m['cycle'],
                                      L_release_app=d-m['release'],L_release_app_last=d+m['n']-1-m['release'],
                                      L_entry_first=d-m.get('header_bytes',0)-m['first'],L_entry_last=d+m['n']-1-m['first'])
                        if begin<=m['cycle']<end:entry_samples.append((m['vl'],m['n'],m['id'],d+m['n']-1-m['first']))
                    for scope_net in (([net,'accepted'] if net==winner else [net]) if begin<=m['cycle']<end else []):
                        for group in ['all',str(m['n'])]:
                            for metric,value in values.items():
                                if metric.startswith('L_entry') and net!=winner:continue
                                buckets[scope_net,group,metric].append((value,m['vl'],m['id']))
                    frame_rows.append(dict(stage=stage,direction=direction,net=net,frame=m['id'],vl=m['vl'],length=m['n'],accepted=net==winner,in_window=begin<=m['cycle']<end,M=m['cycle'],release=m['release'],TX_SFD=tx,RX_SFD=rx,D=d if net==winner else None,**values))
            for net in ('accepted','A','B'):
                for group in ['all']+list(map(str,stage_lengths)):
                    for metric in metrics:
                        rows=buckets[net,group,metric];key=f'{stage}/{direction}/{net}/{group}/{metric}'
                        stats=dict(samples=len(rows),min='NA',max='NA',jitter='NA',vl='NA',min_frame='NA',max_frame='NA')
                        if rows:
                            by_vl=collections.defaultdict(list)
                            for value,vl,frame in rows:by_vl[vl].append((value,frame))
                            candidates=[]
                            for vl,rr in by_vl.items():
                                lo=min(v for v,f in rr);hi=max(v for v,f in rr)
                                candidates.append((-(hi-lo),vl,min(f for v,f in rr if v==lo),min(f for v,f in rr if v==hi)))
                            neg,vl,low,high=min(candidates)
                            stats.update(min=min(v for v,_,_ in rows),max=max(v for v,_,_ in rows),jitter=-neg,vl=vl,min_frame=low,max_frame=high)
                        answer.update({key+'/'+k:v for k,v in stats.items()})
            for k,v in stats_len(entry_samples).items():answer[f'{prefix}/jitter_r119/{k}']=v
    output=Path(output) if output else folder/'r97_python.tsv'
    output.write_bytes(''.join(k+'\t'+str(answer[k])+'\n' for k in sorted(answer)).encode('ascii'))
    (folder/'r97_frames.json').write_text(json.dumps(frame_rows,separators=(',',':')),encoding='utf8')
    return answer



def check_r97_var(folder, measured):
    import json
    from pathlib import Path
    folder=Path(folder);frames=json.loads((folder/'r97_frames.json').read_text())
    accepted_all=[f for f in frames if f['accepted']];accepted=[f for f in accepted_all if f['in_window']];requirements=[]
    def requirement(ok,label,**details):
        requirements.append(dict(status='PASS' if ok else 'FAIL',label=label,**details))
    required={kind+'_d'+str(delay) for kind in ('var_fixed','var_cycle','var_high','var_burst') for delay in (0,257)}
    requirement({f['stage'] for f in accepted}==required,'all eight variable stages present')
    starts={};begins={};current='initial'
    for line in (folder/'sys_events.txt').read_text().splitlines():
        p=line.split()
        if p[0]=='P':current=p[2]
        elif p[0]=='O':starts[current]=min(starts.get(current,int(p[5])),int(p[5]))
        elif p[0]=='F' and p[2]=='begin':begins[p[3]]=int(p[1])
    for stage in sorted({f['stage'] for f in accepted}):
        requirement(begins[stage]-starts[stage]>=(250000 if stage.startswith('var_high') else 2000000),stage+' warmup >=2 maximum BAG')
        for direction in ('es1_to_es2','es2_to_es1'):
            rows=[f for f in accepted if f['stage']==stage and f['direction']==direction]
            key=f'{stage}/{direction}/accepted/all';duration=measured[key+'/throughput/window_cycles']
            rate=measured[key+'/throughput/payload_bytes']*1000/duration
            inject=measured[key+'/inject/mbps']
            requirement(duration>=2500000,stage+' '+direction+' window >=20ms')
            count=collections.Counter(f['vl'] for f in rows);vls=80 if stage.startswith('var_high') else 32
            requirement(set(count)==set(range(vls)) and min(count.values(),default=0)>=8,stage+' '+direction+' >=8 frames per VL')
            requirement({f['length'] for f in rows}=={1,17,256,1024,1471},stage+' '+direction+' five payload lengths')
            if stage.startswith('var_high'):
                requirement(inject>=100,stage+' '+direction+' injection payload >=100Mbps',measured_inject_mbps=inject)
            else:requirements.append(dict(status='REPORT',label=stage+' '+direction+' offered-load throughput',measured_mbps=inject))
            requirement(all(f['L_entry_last']<=250000 for f in accepted_all if f['stage']==stage and f['direction']==direction),stage+' '+direction+' all-frame R119 latency <=2000us')
            requirement(all(f['L_gmii']<=250000 and f['L_app']<=250000 for f in accepted_all if f['stage']==stage and f['direction']==direction),stage+' '+direction+' all-frame first-byte latency <=2000us')
            jitter=measured[key+'/jitter_r119/jitter'];lag=measured[key+'/inject/lag_max']
            requirement(isinstance(jitter,(int,float)) and 0<=jitter<=6250,stage+' '+direction+' same-VL same-length jitter <=50us',cycles=jitter)
            requirement(lag=='NA' or lag<=1471,stage+' '+direction+' injection lag <= one maximum payload',cycles=lag)
            for metric in ('dropped','duplicate','overflow'):
                requirement(measured[key+'/integrity/'+metric]==0,stage+' '+direction+' no '+metric)
    (folder/'r97_requirements.json').write_text(json.dumps(requirements,indent=2),encoding='utf8')
    for row in requirements:print('[R97 '+row['status']+'] '+row['label']+' '+str({k:v for k,v in row.items() if k not in ('status','label')}))
    return requirements
