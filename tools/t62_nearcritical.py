"""Export E3 endpoint minima and classify their actual routed path evidence.

Categories are diagnostic inferences, not demonstrated causal improvements.
Native nodes, resource parameters, locations and raw timing values are retained.
"""
from collections import Counter, defaultdict
import json
from pathlib import Path
import re
import sqlite3

import eda
from adapt_gui_vqm import CELL
from check_multicycle import native_name
from t61_metrics import module_name
import t62_runtime as runtime

ROOT=Path(__file__).resolve().parents[1]
DATABASE=ROOT.parent/'c3_t61_e3/out/timing/AFDX_top_full_timing/20261028_004527_667025/full_timing.tan.pb'
SYNTH=ROOT.parent/'c3_t60_r5a_p155/out/synth/AFDX_top/20261027_085802_489925/project/AFDX_EndSystem.runs/synth_1'
GROUPS=('shared_control_net','arithmetic_chain','ram_cross_column','return_selection','long_wire')


def cell_name(resource):
    text=re.sub(r'(?:\|ff)?/[^/]+$','',resource)
    text=re.sub(r'\|port_[ab]_[A-Za-z_]+_dff(?:\[\d+\])?$','',text)
    return native_name(text)


def main():
    mapped={}
    for match in CELL.finditer((SYNTH/'AFDX_EndSystem.vqm').read_text(encoding='utf-8-sig')):
        params=dict(re.findall(r'\.(\w+)\s*=\s*"([^"\n]+)"',match['params']))
        carry=[port for port,value in re.findall(r'\.(cin|cin0|cin1|cout|cout0|cout1)\s*\(\s*([^)]*)\)',match['body'])
               if value.strip() and not re.fullmatch(r"\d+'[bBhH][0-9]+",value.strip())]
        mapped[native_name(match['name'])]=dict(type=match['kind'],operation_mode=params.get('operation_mode'),carry_ports=carry)
    connection=sqlite3.connect(DATABASE.resolve().as_uri()+'?mode=ro',uri=True)
    connection.row_factory=sqlite3.Row
    connection.execute('PRAGMA query_only=ON')
    connection.execute('PRAGMA temp_store=MEMORY')
    try:
        clocks=[dict(row) for row in connection.execute('SELECT * FROM elinx_intra_clock_summary')]
        ends={}
        for native in connection.execute('SELECT * FROM elinx_intra_clock_longest_sync_path_report'):
            row=dict(native)
            prior=ends.get(row['to_cell_name'])
            if prior is None or (row['slack'],row['path_id'])<(prior['slack'],prior['path_id']):
                ends[row['to_cell_name']]=row
        if len(ends)!=53882:
            raise ValueError('E3 full endpoint coverage changed')
        rows=sorted((r for r in ends.values() if r['slack']<800),key=lambda r:(r['slack'],r['path_id']))
        if len(rows)!=550:
            raise ValueError('Expected exactly 550 endpoints below +0.8ns')
        ids={row['path_id'] for row in rows}
        params=','.join('?' for _ in ids)
        nodes=defaultdict(list);properties=defaultdict(list)
        for table,target,order in [('elinx_data_path_node_detail',nodes,'path_node_detail_id'),
                                   ('elinx_cell_property',properties,'cell_id')]:
            query='SELECT * FROM '+table+' WHERE path_type=0 AND sync_type=0 AND path_id IN ('+params+') ORDER BY '+order
            for item in connection.execute(query,tuple(ids)):
                target[item['path_id']].append(dict(item))
    finally:
        connection.close()
    grouped={name:dict(endpoint_count=0,modules=Counter(),worst_slack_ps=None,representative_paths=[]) for name in GROUPS}
    modules=defaultdict(lambda:dict(endpoints=0,failed=0,below_0p5ns=0,below_0p8ns=0))
    interval_counts=Counter()
    for row in rows:
        data=nodes[row['path_id']]
        if not data or data[0]['resource']!=row['from_cell_name'] or data[-1]['resource']!=row['to_cell_name']:
            raise ValueError('Node chain does not match native endpoints: '+str(row['path_id']))
        cell_evidence=[]
        for node in data:
            name=cell_name(node['resource'])
            model=mapped.get(name)
            if model:
                cell_evidence.append(dict(cell=name,location=node['location'],**model))
        locations=[list(map(int,node['location'].split(','))) for node in data]
        longest=max((dict(from_location=data[i-1]['location'],to_location=node['location'],
                          resource=node['resource'],delay_ps=node['incr_delay'])
                     for i,node in enumerate(data) if i and node['delay_type']==1),key=lambda r:r['delay_ps'],default=None)
        arithmetic=[m for m in cell_evidence if m['operation_mode']=='arithmetic' or m['carry_ports']]
        ram=[m for m in cell_evidence if m['type']=='stratix_ram_block']
        ram_nodes=[n for n in data if 'ram_block' in n['resource'] or '|port_b_address_dff' in n['resource']]
        cross=bool((ram or ram_nodes) and len({p[0] for p in locations})>1)
        return_select=('cfg_regs|cfg_rdata' in row['to_cell_name'] and len(data)>4)
        control=bool((row['high_fanout']>=16 and any(re.search(r'(phase|state|enable|ready|valid|grant|request|_we|ena)',n['resource'],re.I) for n in data))
                     or 'snmp|mib_rd' in row['to_cell_name'])
        long=bool(longest and (longest['delay_ps']>=1500 or row['net_delay']>row['logic_delay']))
        tags=[]
        if control:tags.append('shared_control_net')
        if arithmetic:tags.append('arithmetic_chain')
        if cross:tags.append('ram_cross_column')
        if return_select:tags.append('return_selection')
        if long:tags.append('long_wire')
        if not tags:
            raise ValueError('Path requires explicit classification: '+str(row['path_id']))
        # A reproducible mutually exclusive summary; secondary evidence remains.
        primary=next(name for name in ['ram_cross_column','return_selection','arithmetic_chain',
                                       'shared_control_net','long_wire'] if name in tags)
        module=module_name(row['to_cell_name'])
        interval=row['capture_edge']-row['launch_edge']
        interval_counts[str(interval)]+=1
        row.update(edge_interval_ps=interval,edge_class={8000:'8ns',16000:'16ns'}.get(interval,'other'),
            endpoint_module=module,primary_group=primary,secondary_groups=tags,
            classification='inference from the retained actual worst path, not a causal optimization result',
            nodes=data,cell_properties=properties[row['path_id']],mapped_path_cells=cell_evidence,
            arithmetic_evidence=arithmetic,ram_evidence=ram,ram_node_evidence=ram_nodes,
            longest_wire_segment=longest,span_x=max(p[0] for p in locations)-min(p[0] for p in locations),
            span_y=max(p[1] for p in locations)-min(p[1] for p in locations))
        group=grouped[primary]
        group['endpoint_count']+=1;group['modules'][module]+=1
        group['worst_slack_ps']=row['slack'] if group['worst_slack_ps'] is None else min(group['worst_slack_ps'],row['slack'])
        if len(group['representative_paths'])<3:
            group['representative_paths'].append({key:row[key] for key in ['path_id','slack','from_cell_name','to_cell_name','logic_delay','net_delay','levels','high_fanout','longest_wire_segment']})
        stat=modules[module];stat['endpoints']+=1;stat['below_0p8ns']+=1
        stat['failed']+=row['slack']<0;stat['below_0p5ns']+=row['slack']<500
    result=dict(database=str(DATABASE),database_sha256=eda.sha(DATABASE),source_vqm_sha256=eda.sha(SYNTH/'AFDX_EndSystem.vqm'),
        units='native ps',native_clocks=clocks,full_setup_endpoints=len(ends),selected_endpoints=len(rows),
        failed_endpoints=sum(r['slack']<0 for r in rows),below_0p5ns=sum(r['slack']<500 for r in rows),
        interval_counts=dict(interval_counts),groups=grouped,module_distribution=dict(modules),
        method='Complete endpoint minima (to_cell_name); strict slack<800ps. Join native setup/synchronous nodes and cell properties by path_id with path_type=0,sync_type=0. Carry/RAM types come from frozen VQM. Shared-control includes the reviewed SNMP mib_rd combinational control chain even with low fanout. Primary priority RAM-cross-column, return-selection, arithmetic, shared-control, long-wire; all secondary tags retained.',
        limits='Native report stores one worst path per endpoint; this is not an enumeration of every possible source or proof of root cause. No new candidate is added from this list.',
        paths=rows)
    runtime.save(ROOT/'out/t62/nearcritical_baseline.json',result)
    print(json.dumps({k:result[k] for k in ['selected_endpoints','failed_endpoints','below_0p5ns','interval_counts','module_distribution','groups']},ensure_ascii=False))


if __name__=='__main__':
    main()
