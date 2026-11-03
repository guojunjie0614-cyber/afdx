"""Audit the exact MCP register set and its clock-enable cones in an official VQM."""
import argparse
import collections
import csv
import fnmatch
import functools
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import sys

from adapt_gui_vqm import CELL, OUTPUTS

def native_name(name):
    result = '|'.join(token.split(':')[-1] for token in name.lstrip('\\').split('|'))
    # The T60 wrapper adds exactly one known hierarchy level; retain engine scope.
    return result[3:] if result.startswith('es|') else result

def signals(value):
    value=re.sub(r"\b\d+'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_]+",'',value)
    return tuple(re.findall(r'\\[^\s{},]+|\b[A-Za-z_$][\w$]*(?:\[\d+\])?',value))

def _timing_constraints(path):
    source=path.read_text(encoding='utf-8-sig')
    source='\n'.join(line for line in source.splitlines() if not line.lstrip().startswith('#'))
    collections_by_name={}
    collection=re.compile(r'set (\w+) \[get_cells \{([^}]+)\}\]',re.S)
    for m in collection.finditer(source):
        if m[1] in collections_by_name:raise ValueError('Duplicate register collection')
        collections_by_name[m[1]]=m[2].split()
    source=collection.sub('',source)
    lines=[line.strip() for line in source.splitlines() if line.strip()]
    clock='create_clock -name clk -period 8.000 [get_ports {clk}]'
    if lines.count(clock)!=1:raise ValueError('Exactly one 8 ns main clock is required')
    rule=re.compile(r'set_multicycle_path -(setup|hold) ([012]) -from \$(\w+) -to \$(\w+)')
    uncertainty_rule=re.compile(r'set_clock_uncertainty -setup (\d+(?:\.\d+)?) \[get_clocks \{clk\}\]')
    pairs=collections.defaultdict(dict)
    uncertainty=0.0
    for line in lines:
        if line==clock:continue
        # Physical routing values used by the prescribed scan; no timing exceptions.
        if re.fullmatch(r'set_global_assignment -name PRES_FAC_MULT (?:1\.3|1\.30|1\.40|1\.45|1\.50|1\.55|1\.60|1\.70)',line):continue
        # Setup over-constraint: a clock property, not a path exception. Hold keeps 0 ns.
        m=uncertainty_rule.fullmatch(line)
        if m:
            if uncertainty:raise ValueError('Duplicate clock uncertainty')
            uncertainty=float(m.group(1))
            if uncertainty<0:raise ValueError('Clock uncertainty must be nonnegative')
            continue
        m=rule.fullmatch(line)
        if not m:raise ValueError('Unrecognized timing exception: '+line)
        kind,multiplier,start,end=m.groups()
        if start not in collections_by_name or end not in collections_by_name:raise ValueError('Unknown register collection')
        def scope(name):
            roots=set()
            for pattern in collections_by_name[name]:
                match=re.fullmatch(r'\*(loader|snmp)\|\*half_rate\.engine\|[A-Za-z_][A-Za-z_0-9]*\*~I',pattern)
                if not match:raise ValueError('Collection must select an engine register stem: '+pattern)
                roots.add(match[1])
            if len(roots)!=1:raise ValueError('A collection may not cross engines')
            return next(iter(roots))
        if scope(start)!=scope(end):raise ValueError('MCP crosses engine boundaries')
        if int(multiplier)!=(2 if kind=='setup' else 0):raise ValueError('This eLinx version requires setup 2 / hold 0 for same-edge hold')
        if kind in pairs[(start,end)]:raise ValueError('Duplicate MCP')
        pairs[(start,end)][kind]=int(multiplier)
    if not pairs or any(set(v)!={'setup','hold'} for v in pairs.values()):raise ValueError('Every MCP needs setup and hold')
    if set(collections_by_name)!={n for pair in pairs for n in pair}:raise ValueError('Unused register collection')
    return [(tuple(collections_by_name[a]),tuple(collections_by_name[b])) for a,b in pairs],uncertainty

def constraints(path):
    # T62 checks the complete physical membership before extracting pure SDC.
    # Existing T61 guard imports this function only in T61 checkouts, where the
    # T62 policy does not exist; their frozen behavior is unchanged.
    policy=Path(__file__).resolve().parents[1]/'elinx/constraints_t62.json'
    if policy.is_file():
        from t62_constraints import split
        timing=split(path.read_text(encoding='utf-8-sig'))['timing']
        class TimingText:
            def read_text(self,encoding='utf-8-sig'):return timing
        result=_timing_constraints(TimingText())
        if result[1]!=0.30:raise ValueError('T62 requires exactly 0.30 ns setup uncertainty')
        return result
    return _timing_constraints(path)

@functools.lru_cache(None)
def matcher(patterns):
    module=patterns[0].split('|')[0].lstrip('*')
    return module+'|half_rate.engine|',tuple(p.rsplit('|',1)[1][:-3] for p in patterns)

def matches(name,patterns):
    prefix,stems=matcher(patterns);name=name.lstrip('\\')
    return name.startswith(prefix) and name.endswith('~I') and name[len(prefix):].startswith(stems)

def _single_cycle_engine_endpoint(name):
    # These new command outputs deliberately retain the unmodified 8 ns SDC.
    # Do not infer a multicycle exception merely from their engine hierarchy.
    return re.fullmatch(r'loader\|half_rate\.engine\|deny_format\[[0-2]\]~I', name) is not None


def enable_behavior(cells, registers, phases, source):
    """Conservatively prove CE-low hold and each phase bit's reset/toggle truth table."""
    from itertools import product
    from adapt_gui_vqm import LCELL
    unknown=frozenset((0,1))
    aliases={}
    for m in re.finditer(r'(?m)^assign\s+([^;]+?)\s*=\s*([^;]+);',source):
        left=signals(m[1])
        if len(left)==1:aliases[left[0]]=m[2].strip()
    combinational={}
    for c in cells:
        if c['kind']=='stratix_lcell':
            for n in signals(c['ports'].get('combout','')):combinational[n]=c
    all_phases=set().union(*phases.values())
    def evaluator(fixed):
        @functools.lru_cache(None)
        def value(expression):
            expression=expression.strip()
            if expression in fixed:return frozenset((fixed[expression],))
            if expression in ("1'b0",'0'):return frozenset((0,))
            if expression in ("1'b1",'1'):return frozenset((1,))
            if expression in registers:return unknown
            if expression in aliases:return value(aliases[expression])
            if expression in combinational:return lut(combinational[expression])
            return unknown
        def lut(cell):
            params=cell['params']
            if params.get('operation_mode','normal')!='normal':return unknown
            mask=params.get('lut_mask')
            if mask is None:return unknown
            bits=[value(cell['ports'].get(p,LCELL[p])) for p in ('dataa','datab','datac','datad','inverta')]
            outputs=set()
            for a,b,c,d,invert in product(*bits):
                index=(a^invert)+2*b+4*c+8*d
                outputs.add((int(mask,16)>>index)&1)
            return frozenset(outputs)
        return value,lut
    value,_=evaluator({**dict.fromkeys(all_phases,0),'reset':0})
    stalls={net:value(c['ports'].get('ena',"1'b1"))==frozenset((0,)) for net,c in registers.items()
            if '|half_rate.engine|' in c['native']}
    phase_failures=[]
    for net in sorted(all_phases):
        cell=registers[net];ports=cell['ports'];good=ports.get('clk')=='clk'
        good &= cell['params'].get('register_cascade_mode','off')=='off'
        for reset in (0,1):
            for old in (0,1):
                evaluate,lut=evaluator({net:old,'reset':reset})
                possibilities=set()
                for ena,clear in product(evaluate(ports.get('ena',"1'b1")),evaluate(ports.get('sclr',"1'b0"))):
                    possibilities.update((old,) if not ena else (0,) if clear else lut(cell))
                good &= possibilities==({0} if reset else {1-old})
        if not good:phase_failures.append(cell['native'])
    return stalls,phase_failures


def audit(vqm,sdc,destination,*,fingerprint=True,pure_sdc=False):
    data=vqm.read_text(encoding='utf-8').replace('\r\n','\n')
    # New builds validate physical pins independently and provide pure timing.
    # Preserve the frozen placement policy for all existing callers.
    pairs,uncertainty=_timing_constraints(sdc) if pure_sdc else constraints(sdc)
    if pure_sdc and uncertainty != 0.30:
        raise ValueError('Exactly 0.30 ns setup uncertainty is required')
    cells=[];drivers={};registers={};ram=[]
    for m in CELL.finditer(data):
        kind,name=m['kind'],m['name']
        ports={key:value.strip() for key,value in re.findall(r'\.(\w+)\s*\(([^()]*)\)',m['body'])}
        params=dict(re.findall(r'\.(\w+)\s*=\s*"([^"]+)"',m['params']))
        cell=dict(kind=kind,name=name,native=native_name(name),ports=ports,params=params)
        cells.append(cell)
        if kind=='stratix_lcell':
            output=ports.get('regout','')
            if output:
                if len(signals(output))!=1:raise ValueError('Unparsed register output: '+output)
                registers[signals(output)[0]]=cell
            dependencies=tuple(n for p in ('dataa','datab','datac','datad','cin','cin0','cin1','inverta') for n in signals(ports.get(p,'')))
            for pin in ('combout','cout','cout0','cout1'):
                for net in signals(ports.get(pin,'')):drivers[net]=dependencies
        else:
            ram.append(cell)
    expected=len(re.findall(r'(?m)^(?:stratix_lcell|stratix_ram_block)\s',data))
    if expected!=len(cells) or not registers:raise ValueError('Incomplete VQM parse')
    for m in re.finditer(r'(?m)^assign\s+([^;]+?)\s*=\s*([^;]+);',data):
        lhs=signals(m[1]);rhs=signals(m[2])
        if len(lhs)==1:drivers[lhs[0]]=rhs
    phase={}
    for module in ('loader','snmp'):
        phase_matches=[net for net,cell in registers.items() if re.fullmatch(module+r'_ce_q(?:\[\d+\])?(?:~.*)?',cell['native'])]
        if not phase_matches:raise ValueError('No preserved CE phase registers for '+module)
        phase[module]=set(phase_matches)
    @functools.lru_cache(None)
    def leaves(net):
        if net in registers:return frozenset([net])
        if net not in drivers:return frozenset(['unresolved:'+net])
        return frozenset().union(*(leaves(n) for n in drivers[net]))
    stalls,phase_failures=enable_behavior(cells,registers,phase,data)
    phase_loads=collections.Counter()
    rows=[];invalid=[];by_module=collections.Counter();uncovered=[];nonregisters=[]
    single_cycle=[];single_cycle_nets=set();invalid_single_cycle=[]
    for cell in cells:
        selected=any(matches(cell['native'],a) or matches(cell['native'],b) for a,b in pairs)
        if selected and not cell['ports'].get('regout'):nonregisters.append(cell['native'])
    for net,cell in registers.items():
        start='\\'+cell['native'];end=start
        selected=[pair for pair in pairs if matches(start,pair[0]) or matches(end,pair[1])]
        if selected and _single_cycle_engine_endpoint(cell['native']):
            raise ValueError('Explicit single-cycle command register entered an MCP collection: '+cell['native'])
        if not selected:
            if '|half_rate.engine|' in cell['native']:
                if _single_cycle_engine_endpoint(cell['native']):
                    module=cell['native'].split('|')[0]
                    cone=frozenset().union(*(leaves(n) for n in signals(cell['ports'].get('ena',"1'b1"))))
                    phase_hits=phase.get(module,set()) & cone
                    wrong_phase=set().union(*(v for k,v in phase.items() if k!=module)) & cone
                    valid=(len(phase_hits)==1 and not wrong_phase
                           and cell['ports'].get('clk')=='clk' and stalls[net])
                    entry=dict(register=cell['native'],setup_requirement_ns=8.0,
                               ce=';'.join(sorted(phase_hits)),valid=valid,
                               reason='Explicit command endpoint retains single-cycle timing; no SDC exception')
                    single_cycle.append(entry)
                    if valid:single_cycle_nets.add(net)
                    else:invalid_single_cycle.append(entry)
                else:uncovered.append(cell['native'])
            continue
        name=cell['native'];module=name.split('|')[0]
        good_scope=module in phase and name.startswith(module+'|half_rate.engine|')
        cone=frozenset().union(*(leaves(n) for n in signals(cell['ports'].get('ena',"1'b1"))))
        phase_hits=phase.get(module,set()) & cone
        wrong_phase=set().union(*(v for k,v in phase.items() if k!=module)) & cone
        expected_phase=';'.join(sorted(phase_hits))
        valid=good_scope and len(phase_hits)==1 and not wrong_phase and cell['ports'].get('clk')=='clk' and stalls[net]
        phase_loads.update(phase_hits)
        row=dict(module=module,register=name,enable=cell['ports'].get('ena',"1'b1"),
                 ce=expected_phase,ce_in_enable_cone=len(phase_hits)==1,disabled_between_ce_ticks=stalls[net],valid=valid,
                 enable_terminals=';'.join(sorted(cone)))
        rows.append(row);by_module[module]+=1
        if not valid:invalid.append(row)
    illegal_ram=[c['native'] for c in ram if '|half_rate.engine|' in c['native']]
    if not rows or set(by_module)!={'loader','snmp'}:raise ValueError('Both engine register sets must be nonempty')
    allowed=collections.defaultdict(set)
    for from_patterns,to_patterns in pairs:
        starts={net for net,c in registers.items() if matches(c['native'],from_patterns)}
        ends={net for net,c in registers.items() if matches(c['native'],to_patterns)}
        if not starts or not ends:
            raise ValueError('Empty mapped MCP collection: '+str((from_patterns,to_patterns)))
        for net in ends:allowed[net].update(starts)
    missing_arcs=[];arc_count=0
    for net,cell in registers.items():
        if '|half_rate.engine|' not in cell['native']:continue
        module=cell['native'].split('|')[0]
        inputs=(n for p in ('dataa','datab','datac','datad','cin','cin0','cin1','inverta',
                           'regcascin','ena','sclr','sload','aclr') for n in signals(cell['ports'].get(p,'')))
        cone=frozenset().union(*(leaves(n) for n in inputs))
        internal={n for n in cone if n in registers and registers[n]['native'].startswith(module+'|half_rate.engine|')}
        arc_count+=len(internal)
        if net not in single_cycle_nets:
            missing_arcs.extend((registers[n]['native'],cell['native']) for n in internal-allowed[net])
    # Consolidated local builds already snapshot their inputs; hashing is optional.
    result=dict(setup_uncertainty_ns=uncertainty,
                constrained_registers=len(rows),by_module=dict(by_module),invalid_registers=len(invalid),
                ram_cells_in_engine=illegal_ram,all_registers=len(registers),ram_cells=len(ram),
                selected_non_register_cells=nonregisters,uncovered_engine_registers=uncovered,
                internal_register_arcs=arc_count,uncovered_internal_arcs=len(missing_arcs),
                patterns=pairs,phase_registers={k:sorted(v) for k,v in phase.items()},
                single_cycle_engine_registers=single_cycle,invalid_single_cycle_registers=invalid_single_cycle,
                phase_reset_toggle_failures=phase_failures,ce_bank_register_loads=dict(phase_loads),
                max_ce_bank_register_load=max(phase_loads.values(),default=0),
                passed=not phase_failures and not invalid and not invalid_single_cycle and not illegal_ram and not nonregisters and not uncovered and not missing_arcs)
    if fingerprint:
        result.update(netlist_sha256=hashlib.sha256(vqm.read_bytes()).hexdigest(),
                      constraints_sha256=hashlib.sha256(sdc.read_bytes()).hexdigest())
    else:
        result['fingerprinting'] = 'omitted: caller uses an isolated input snapshot'
    destination.mkdir(parents=True,exist_ok=True)
    with (destination/'registers.csv').open('w',newline='',encoding='utf-8-sig') as f:
        writer=csv.DictWriter(f,list(rows[0]));writer.writeheader();writer.writerows(rows)
    (destination/'netlist.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    (destination/'uncovered_arcs.json').write_text(json.dumps(missing_arcs,indent=2)+'\n')
    return result

def timing(database,pairs,destination):
    connection=sqlite3.connect(database.resolve().as_uri()+'?mode=ro',uri=True)
    connection.row_factory=sqlite3.Row
    clocks=[dict(r) for r in connection.execute('SELECT * FROM elinx_intra_clock_summary')]
    expected=sum(r['setup_total_ends'] for r in clocks)
    groups={};invalid=[];invalid_count=0;endpoints=set();failed_endpoints=set();hold_count=0
    for kind,table in [('setup','longest'),('hold','shortest')]:
        query='SELECT * FROM elinx_intra_clock_'+table+'_sync_path_report'
        for r in connection.execute(query):
            start=native_name(re.sub(r'\|ff/[QD]$','',r['from_cell_name']))
            end=native_name(re.sub(r'\|ff/[QD]$','',r['to_cell_name']))
            # Existing engine paths require their proven 16 ns exception.
            # Explicit single-cycle command endpoints keep the stricter 8 ns.
            applies=(not _single_cycle_engine_endpoint(end) and
                     any(start.startswith(m+'|half_rate.engine|') and end.startswith(m+'|half_rate.engine|')
                         for m in ('loader','snmp')))
            group='multicycle' if applies else 'single_cycle'
            requirement=r['capture_edge']-r['launch_edge']
            wanted=(16000 if applies else 8000) if kind=='setup' else 0
            if requirement!=wanted:
                invalid_count+=1
                if len(invalid)<30:invalid.append(dict(r,kind=kind,expected_edge_ps=wanted))
            if kind=='hold':
                hold_count+=1
                continue
            g=groups.setdefault(group,dict(paths=0,worst_setup_ns=1e9,failed_paths=0))
            g['paths']+=1;g['worst_setup_ns']=min(g['worst_setup_ns'],r['slack']/1000)
            g['failed_paths']+=r['slack']<0
            endpoints.add(r['to_cell_name'])
            if r['slack']<0:failed_endpoints.add(r['to_cell_name'])
    if len(endpoints)!=expected:raise ValueError('Timing report must cover every endpoint')
    result=dict(endpoint_count=len(endpoints),failed_endpoints=len(failed_endpoints),
                counting='all native reported paths; every unique endpoint covered',
                invalid_requirements=invalid_count,groups=groups,hold_paths_checked=hold_count,clocks=clocks,
                passed=not invalid_count and 'multicycle' in groups)
    (destination/'timing.json').write_text(json.dumps(result,indent=2)+'\n')
    (destination/'invalid_timing.json').write_text(json.dumps(invalid,indent=2)+'\n')
    connection.close()
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('netlist',type=Path)
    parser.add_argument('--constraints',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--timing',type=Path)
    parser.add_argument('--refresh',action='store_true',help='Regenerate the SDC register groups from this VQM before auditing')
    args=parser.parse_args()
    if args.refresh:
        from generate_multicycle import generate
        print(json.dumps(generate(args.netlist,args.constraints),indent=2))
    result=audit(args.netlist,args.constraints,args.output)
    print(json.dumps({k:v for k,v in result.items() if k!='patterns'},ensure_ascii=False,indent=2))
    passed=result['passed']
    if args.timing:
        measured=timing(args.timing,result['patterns'],args.output)
        print(json.dumps(measured,ensure_ascii=False,indent=2));passed &= measured['passed']
    return 0 if passed else 1

if __name__=='__main__':raise SystemExit(main())
