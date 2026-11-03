"""Prove mapped-graph identity up to names in the changed VQM region.

LUT masks, every other functional parameter, port names/bit positions and all
unchanged-region boundary nets are preserved. This is stricter than an unlabeled
resource comparison and does not claim general Boolean equivalence.
"""
import argparse
from collections import Counter,defaultdict
import hashlib
import json
from pathlib import Path
import re
import sys

from adapt_gui_vqm import CELL

OUTPUTS={'stratix_lcell':{'combout','regout','cout','cout0','cout1'},
         'stratix_ram_block':{'portadataout','portbdataout'}}
TOKEN=re.compile(r"\\[^\s]+|\d+'[bBhHdD][0-9a-fA-FxXzZ_]+|[A-Za-z_$][A-Za-z_0-9$]*(?:\[\d+(?::\d+)?\])?|~")


def tokens(expression):
    values=TOKEN.findall(expression)
    remainder=TOKEN.sub('',expression)
    if re.sub(r'[\s{},]','',remainder):raise ValueError('Unsupported VQM expression: '+expression)
    return tuple(values)


def parse(path):
    raw=Path(path).read_bytes();text=raw.decode('utf-8-sig').replace('\r\n','\n')
    cells={};provenance=[]
    for m in CELL.finditer(text):
        kind,name,body,param=m['kind'],m['name'],m['body'],m['params']
        params=dict(re.findall(r'(?m)^defparam\s+\S+\s+\.(\w+)\s*=\s*([^;]+);',param))
        if 'created_from' in params:provenance.append(params.pop('created_from'))
        ports={p:tokens(e.strip()) for p,e in re.findall(r'\.(\w+)\s*\(([^)]*)\)',body)}
        cells[name]=(kind,tuple(sorted(params.items())),tuple(sorted(ports.items())))
    assigned=[]
    for lhs,rhs in re.findall(r'(?m)^assign\s+(.+?)\s*=\s*(.+?);',text):
        assigned.append((tokens(lhs),tokens(rhs)))
    top_ports=tuple(re.findall(r'(?m)^\s*(input|output|inout)\s+([^;]+);',text))
    return cells,assigned,top_ports,hashlib.sha256(raw).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('old',type=Path);parser.add_argument('new',type=Path)
    parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    a,aa,ap,ah=parse(args.old);b,ba,bp,bh=parse(args.new)
    common={name for name in a.keys()&b.keys() if a[name]==b[name]}
    ca={k:v for k,v in a.items() if k not in common};cb={k:v for k,v in b.items() if k not in common}
    counts_a=Counter(v[0] for v in a.values());counts_b=Counter(v[0] for v in b.values())
    result=dict(old=str(args.old),new=str(args.new),old_sha256=ah,new_sha256=bh,
        primitive_counts_old=dict(counts_a),primitive_counts_new=dict(counts_b),
        identical_named_cells=len(common),changed_cells_old=len(ca),changed_cells_new=len(cb),
        top_declarations_identical=ap==bp,only_names_proved=False)
    # Unchanged cells and identical assign statements pin every region boundary.
    boundary=set()
    top_names={name for _,decl in ap for name in re.findall(r'[A-Za-z_$][A-Za-z_0-9$]*',decl)}
    for name in common:
        for _,nets in a[name][2]:boundary.update(nets)
    common_assign=Counter(aa)&Counter(ba)
    for (lhs,rhs),count in common_assign.items():boundary.update(lhs+rhs)
    for side,assignments in ((ca,Counter(aa)-common_assign),(cb,Counter(ba)-common_assign)):
        for i,((lhs,rhs),count) in enumerate(assignments.items()):
            for j in range(count):side[f'__assign_{i}_{j}']=('assign',(),(('out',lhs),('in',rhs)))
    import networkx as nx
    def graph(cells):
        g=nx.MultiGraph()
        for name,(kind,params,ports) in cells.items():
            c=('C',name);g.add_node(c,label=('C',kind,params,tuple((p,len(n)) for p,n in ports)))
            for port,nets in ports:
                for bit,net in enumerate(nets):
                    n=('N',net)
                    anchor=net if net in boundary or net=='~' or net.split('[',1)[0] in top_names or re.fullmatch(r"\d+'[bBhHdD].+",net) else ''
                    g.add_node(n,label=('N',anchor))
                    direction='out' if port in OUTPUTS.get(kind,{'out'}) else 'in'
                    g.add_edge(c,n,label=(direction,port,bit))
        return g
    ga,gb=graph(ca),graph(cb)
    result.update(region_nodes_old=len(ga),region_nodes_new=len(gb),
                  region_edges_old=ga.number_of_edges(),region_edges_new=gb.number_of_edges())
    node_match=lambda x,y:x['label']==y['label']
    edge_match=nx.algorithms.isomorphism.categorical_multiedge_match('label',None)
    sys.setrecursionlimit(max(10000,len(ga)*4))
    matcher=nx.algorithms.isomorphism.MultiGraphMatcher(ga,gb,node_match=node_match,edge_match=edge_match)
    proved=counts_a==counts_b and ap==bp and matcher.is_isomorphic()
    result['only_names_proved']=proved
    if proved:
        mapping=matcher.mapping
        # A second direct verification of functional cell records under the
        # discovered bijection catches accidental graph-model omissions.
        for name,(kind,params,ports) in ca.items():
            target=mapping['C',name][1]
            kind2,params2,ports2=cb[target]
            mapped=tuple(sorted((port,tuple(mapping['N',net][1] for net in nets)) for port,nets in ports))
            if (kind,params,mapped)!=(kind2,params2,ports2):raise RuntimeError('Direct mapped-record verification failed')
        result.update(classification='ONLY_NET_OR_INSTANCE_NAMES',
            verified_functional_cell_records=len(a),
            note='All functional parameters and ordered port tokens are identical under the bijection; unchanged cells and boundary nets fixed; created_from metadata excluded',
            renamed_cells={name:mapping['C',name][1] for name in ca if mapping['C',name][1]!=name},
            renamed_nets={n[1]:v[1] for n,v in mapping.items() if n[0]=='N' and n!=v})
    else:result.update(classification='MAPPED_STRUCTURE_OR_CONNECTION_DIFFERENCE',
        note='No name-only isomorphism under fixed boundaries; not a proof of Boolean inequivalence')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in result.items() if k not in ('renamed_cells','renamed_nets')},indent=2))


if __name__=='__main__':main()
