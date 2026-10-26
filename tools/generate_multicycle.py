"""Generate sparse register-only MCP groups from the mapped combinational cones."""
import collections
import functools
import json
from pathlib import Path
import re
import sys
from adapt_gui_vqm import CELL

def tokens(value):
    value=re.sub(r"\b\d+'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_]+",'',value)
    return tuple(re.findall(r'\\[^\s{},]+|\b[A-Za-z_$][\w$]*(?:\[\d+\])?',value))

def normal(name):
    return '|'.join(p.split(':')[-1] for p in name.lstrip('\\').split('|'))

def group(cell):
    n=normal(cell['name']);parts=n.split('|')
    if len(parts)!=3 or parts[0] not in ('loader','snmp') or parts[1]!='half_rate.engine':return None
    return parts[0],re.split(r'[\[~]',parts[2])[0]

def generate(netlist,output):
    text=netlist.read_text(encoding='utf-8');regs={};drivers={};groups=collections.defaultdict(set)
    for m in CELL.finditer(text):
        ports={k:v.strip() for k,v in re.findall(r'\.(\w+)\s*\(([^()]*)\)',m['body'])}
        cell=dict(name=m['name'],ports=ports)
        if m['kind']=='stratix_lcell':
            if ports.get('regout'):
                net=tokens(ports['regout'])[0];regs[net]=cell
                if group(cell):groups[group(cell)].add(net)
            deps=tuple(n for p in ('dataa','datab','datac','datad','cin','cin0','cin1','inverta') for n in tokens(ports.get(p,'')))
            for p in ('combout','cout','cout0','cout1'):
                for net in tokens(ports.get(p,'')):drivers[net]=deps
    for m in re.finditer(r'(?m)^assign\s+([^;]+?)\s*=\s*([^;]+);',text):
        lhs=tokens(m[1])
        if len(lhs)==1:drivers[lhs[0]]=tokens(m[2])
    @functools.lru_cache(None)
    def leaves(net):
        if net in regs:return frozenset([net])
        if net not in drivers:return frozenset()
        return frozenset().union(*(leaves(n) for n in drivers[net]))
    relations=collections.defaultdict(set);actual_arcs=0
    for net,cell in regs.items():
        target=group(cell)
        if not target:continue
        inputs=tuple(n for p in ('dataa','datab','datac','datad','cin','cin0','cin1','inverta','regcascin','ena','sclr','sload','aclr') for n in tokens(cell['ports'].get(p,'')))
        source_regs=frozenset().union(*(leaves(n) for n in inputs))
        for source in source_regs:
            source_group=group(regs[source])
            if source_group and source_group[0]==target[0]:
                relations[target].add(source_group);actual_arcs+=1
    uncertainty='0.30'
    if output.is_file():
        match=re.search(r'(?m)^set_clock_uncertainty -setup (\d+(?:\.\d+)?) \[get_clocks \{clk\}\]\s*$',
                        output.read_text(encoding='utf-8-sig'))
        if match:uncertainty=match.group(1)
    lines=['# Main clock stays at 125 MHz; capture/configuration/RAM/output paths keep 8 ns.',
           'create_clock -name clk -period 8.000 [get_ports {clk}]',
           '# Setup over-constraint: the router aims '+uncertainty+' ns earlier; sign-off stays at 8 ns.',
           'set_clock_uncertainty -setup '+uncertainty+' [get_clocks {clk}]','',
           '# Register-only groups follow actual mapped fan-in, avoiding a dense all-to-all matrix.',
           '# Refresh with the netlist checker after RTL changes; all internal arcs must be covered.',
           '# Native eLinx hold 0 preserves the same-edge check (conventional SDC setup 2 / hold 1).']
    potential=0
    for target,sources in sorted(relations.items()):
        module,name=target;prefix=module+'_'+name
        lines+=['',f'set from_{prefix} [get_cells {{']
        lines+=['    *'+a+'|*half_rate.engine|'+b+'*~I' for a,b in sorted(sources)]
        lines+=['}]',f'set to_{prefix} [get_cells {{*{module}|*half_rate.engine|{name}*~I}}]',
                f'set_multicycle_path -setup 2 -from $from_{prefix} -to $to_{prefix}',
                f'set_multicycle_path -hold 0 -from $from_{prefix} -to $to_{prefix}']
        potential+=sum(len(groups[s]) for s in sources)*len(groups[target])
    output.write_bytes(('\n'.join(lines)+'\n').encode())
    return dict(groups=len(relations),actual_register_arcs=actual_arcs,group_pair_upper_bound=potential,
                engine_registers=sum(len(v) for v in groups.values()))

if __name__=='__main__':print(json.dumps(generate(Path(sys.argv[1]),Path(sys.argv[2])),indent=2))
