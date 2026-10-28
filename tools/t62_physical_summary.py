"""Read actual round-2 placements and recheck frozen synthesis sources.

This is reporting only. Named-molecule movement is a placement comparison,
not a functional mapping or proof that different packed cells are equivalent.
"""
from collections import Counter
import json
from pathlib import Path
import xml.etree.ElementTree as ET

import eda
from t61_metrics import module_name,read_place,placement_statistics

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/t62'


def load(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def members(path):
    result={};duplicates=[]
    for _,element in ET.iterparse(path,events=('end',)):
        if element.tag!='CLUSTER':continue
        for child in element:
            if child.tag not in ('MOLECULE','IO') or 'name' not in child.attrib:continue
            key=(child.attrib['name'],child.attrib.get('type',child.tag))
            row=(element.attrib['name'],element.attrib['type'],child.attrib.get('loc_s'))
            if key in result:duplicates.append(key)
            result[key]=row
        element.clear()
    if duplicates:raise ValueError('Ambiguous packed member names: '+str(duplicates[:5]))
    return result


def movement(current,baseline):
    common=current.keys()&baseline.keys();moved=[];per_module=Counter();coordinates_changed=0
    for key in sorted(common):
        if current[key]!=baseline[key]:
            per_module[module_name(key[0])]+=1
            coordinates_changed+=current[key][0]!=baseline[key][0]
            if len(moved)<20:moved.append(dict(name=key[0],type=key[1],before=baseline[key],after=current[key]))
    return dict(common_named_molecules=len(common),changed_positions=sum(per_module.values()),
        changed_coordinates=coordinates_changed,
        changed_only_packed_slot_or_resource=sum(per_module.values())-coordinates_changed,
        unchanged_positions=len(common)-sum(per_module.values()),
        only_candidate=len(current.keys()-baseline.keys()),only_control=len(baseline.keys()-current.keys()),
        changed_by_module=dict(per_module),first_twenty_changes=moved,
        identity='Exact native molecule name and type; coordinates, resource type and packed loc_s compared. Unmatched cells are not inferred equivalent.')


def collect(queue):
    pins=load(ROOT/'elinx/constraints_t62.json')['pins'];assert len(pins)==172
    rows={};sources={};membership={};positions={};molecule_positions={}
    for identity,job in queue['jobs'].items():
        if job['mode'] not in ('c0_gate','route') or job['status']!='completed':continue
        result=load(job['result']);route=result['route'];source=queue['items'][job['candidate']]['source']
        folder=Path(source)/'project/AFDX_EndSystem.runs/synth_1'
        cluster=folder/'AFDX_EndSystem_cluster.xml';place=Path(route['output'])/'AFDX_EndSystem.place'
        if source not in membership:membership[source]=members(cluster)
        actual,ios=read_place(place);checks=[]
        for expected in pins:
            observed=ios.get(expected['port'])
            passed=bool(observed and observed['package_pin']==expected['pin']
                and observed['coordinates']==expected['xyz'] and observed['direction']==expected['direction'])
            checks.append(dict(port=expected['port'],expected=expected,actual=observed,passed=passed))
        expected_sources=route.get('source_read_only_files',{})
        if expected_sources:
            if source in sources and sources[source]['expected_sha256']!=expected_sources:
                raise ValueError('Frozen source identities disagree across routes: '+source)
            if source not in sources:
                files={name:dict(expected=digest,actual=eda.sha(folder/name)) for name,digest in expected_sources.items()}
                sources[source]=dict(expected_sha256=expected_sources,files=files,
                    passed=len(files)==17 and all(v['expected']==v['actual'] for v in files.values()))
        normalized={};missing=[]
        for key,(name,kind,slot) in membership[source].items():
            if name not in actual:missing.append(name);continue
            normalized[key]=(actual[name],kind,slot)
        key=job['candidate']+':'+job['pres'];positions[key]=actual;molecule_positions[key]=normalized
        report=result['report'];clock=report['timing']['clocks'][0]
        control_ok=(report['invalid_registers']==0 and report['uncovered_internal_arcs']==0
            and report['setup_uncertainty_ns']==0.30 and len(report['timing']['clocks'])==1
            and clock['period']==8000 and clock['name']=='clk')
        physical=placement_statistics(place,cluster)
        rows[key]=dict(job_id=identity,result=job['result'],place=str(place),place_sha256=eda.sha(place),
            cluster_xml=str(cluster),cluster_sha256=eda.sha(cluster),source=source,
            P0=dict(passed=len(ios)==172 and set(ios)=={v['port'] for v in pins} and all(v['passed'] for v in checks),
                actual_io_count=len(ios),checks=checks),
            controls_passed=control_ok,missing_packed_clusters=sorted(set(missing)),placement=physical)
    paired={};changed={}
    for pres in ('1.30','1.40','1.45','1.50','1.55','1.60','1.70'):
        c0='C0:'+pres;c4='C4p:'+pres;c2='C2:'+pres
        if c0 in positions and c4 in positions:
            a,b=positions[c0],positions[c4];keys=a.keys()|b.keys()
            differences=[key for key in keys if a.get(key)!=b.get(key)]
            paired[pres]=dict(common_clusters=len(a.keys()&b.keys()),different_positions=len(differences),
                complete_cluster_sets_identical=a.keys()==b.keys(),all_coordinates_identical=not differences)
        if c0 in positions and c2 in positions:changed[pres]=movement(molecule_positions[c2],molecule_positions[c0])
    passed=(len(rows)==21 and len(sources)==3 and all(v['passed'] for v in sources.values())
        and all(v['P0']['passed'] and v['controls_passed'] and not v['missing_packed_clusters']
            and not v['placement']['missing_cluster_positions'] for v in rows.values())
        and len(paired)==7 and all(v['all_coordinates_identical'] and v['complete_cluster_sets_identical'] for v in paired.values()))
    return dict(passed=passed,new_native_runs=0,unique_actual_placements=len(rows),
        C6='Reuses C2; no additional placement counted',frozen_sources=sources,
        actual_placements=rows,C0_C4p_same_PRES=paired,C2_C0_named_molecule_movement=changed)


if __name__=='__main__':
    from t62_runtime import save
    value=collect(load(OUT/'round_02/queue.json'));save(OUT/'physical_comparison.json',value)
    print(json.dumps(dict(passed=value['passed'],actual_placements=value['unique_actual_placements'])))
    raise SystemExit(0 if value['passed'] else 1)
