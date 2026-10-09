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
    expect(required<={name for _,name in marks},'T16 light/ten-VL/77/81 phases')
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
                       'T16 full payload VLs with BAG 1ms '+stage)
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
                        expect(rates['payload_mbps']>=minimum,f'T16 ES{source_number} {net} GMII UDP throughput >= {minimum}Mbps {stage}')
                ds=[d for m in all_messages for d in m['deliveries']]
                payload=sum(overlap(d['cycle'],d['cycle']+d['n'],begin,end) for d in ds)
                metrics['delivered_payload_bytes']=payload;metrics['delivered_mbps']=payload*1000/duration
                if not near_limit:
                    expect(metrics['delivered_mbps']>=(900 if vls==77 else 117.68),'T16 delivery throughput floor '+stage)
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
                        expect(0<total<=25973,'T16 raw end-to-end latency <= T14 207.784us '+stage)
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
                    expect(len(group)==8,'T10 light fixed-length group has eight repeated messages')
                    times=[m['cycle'] for m,_,_ in group]
                    tv=[t for _,t,_ in group];ev=[e for _,_,e in group]
                    light_groups[str(n)]=dict(samples=len(group),T_tx=stats(tv),T_e2e=stats(ev),
                        accepted_intervals=stats([b-a for a,b in zip(times,times[1:])]),
                        tx_jitter_cycles=max(tv)-min(tv),e2e_jitter_cycles=max(ev)-min(ev))
                metrics['light_groups']=light_groups
                metrics['tx_jitter_cycles']=max(g['tx_jitter_cycles'] for g in light_groups.values())
                metrics['e2e_jitter_cycles']=max(g['e2e_jitter_cycles'] for g in light_groups.values())
                metrics['jitter_definition']='max(T_tx)-min(T_tx), independently for each fixed payload length; max over groups'
                expect(metrics['tx_jitter_cycles']<=7 and metrics['e2e_jitter_cycles']<=7,'T16 light jitter <= T14 seven cycles '+stage)
                metrics['average_payload_mbps']=sum(m['n'] for m in all_messages)*1000/(stage_end-stage_start)
                expect(max(e2e,default=0)<=25973,'T16 light end-to-end latency floor '+stage)
                metrics['jitter']=dict(max=metrics['tx_jitter_cycles'],max_us=metrics['tx_jitter_cycles']*0.008,
                                       samples=sum(g['samples'] for g in light_groups.values()))
            else:
                metrics['jitter']=stats(intervals)
                if not near_limit:expect(bool(intervals) and all(v==0 for v in intervals),'T16 full-load TX jitter zero '+stage)
            metrics['scheduling_interval_error']=stats([abs(v) for v in schedule_errors])
            metrics['raw_gap_minus_BAG']=stats(intervals)
            metrics['formula_limit']=max((m['w_limit'] for m in selected),default=0)
            metrics['formula_limit_us']=metrics['formula_limit']*0.008
            stage_result['directions'][f'es{source_number}_to_es{3-source_number}']=metrics
        result[stage]=stage_result
    return result
