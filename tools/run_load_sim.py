"""Bounded public-pin load test runner; one official VQM plus one RTL receiver."""
import argparse
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import re
import sys

import eda
from adapt_gui_vqm import adapt

ROOT = Path(__file__).resolve().parents[1]
RECORDS = tuple(f'ep{i}_{kind}.txt' for i in (0, 1)
                for kind in ('tx', 'rx', 'a', 'b', 'events')) + ('window.txt',)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deadline')
    parser.add_argument('--netlist', type=Path)
    parser.add_argument('--reference',type=Path,help='Exact passed RTL run of this stimulus')
    parser.add_argument('--param', action='append', default=[])
    args = parser.parse_args()
    params = dict(VL_COUNT=81,GROUP_LENGTH=1471,MIXED=0,DUPLEX=1,DURATION=12500000,SMOKE=0,SWAP=0,BAG_BURST=0,LONG_COUNT=1)
    for entry in args.param:
        key, value = entry.split('=', 1)
        if key not in params or not value.isdigit():
            parser.error('Invalid parameter: '+entry)
        params[key] = int(value)
    if not (1 <= params['VL_COUNT'] <= 81 and 1 <= params['GROUP_LENGTH'] <= 1471):
        parser.error('VL count or payload outside declared range')
    if params['BAG_BURST'] and (params['MIXED'] or params['GROUP_LENGTH']!=1471):
        parser.error('The confirmed BAG-wait protocol uses maximum single frames only')
    if params['BAG_BURST']==2 and params['VL_COUNT']%3!=0:
        parser.error('The rotating equal-due BAG protocol requires complete groups of three VLs')
    if params['MIXED']==3 and (params['GROUP_LENGTH']!=1471 or params['BAG_BURST'] or not 1<=params['LONG_COUNT']<=params['VL_COUNT']):
        parser.error('Mode 3 requires 1..VL_COUNT long VLs, 1471-byte short messages and no BAG burst')
    if params['MIXED']!=3:params.pop('LONG_COUNT')
    flow = eda.Flow('load_sim', 'tb_t76_load', args.deadline)
    flow.result.update(parameters=params,kind='official_vqm' if args.netlist else 'RTL',passed=False)
    originals = sorted((ROOT/'rtl').glob('*.v')) + [ROOT/'tb/tb_t76_load.v',
        ROOT/'tb/lib/t76_load_endpoint.v',ROOT/'tb/lib/afdx_x_monitor.v',Path(__file__),
        ROOT/'tools/modelsim_sources.py',ROOT/'tools/adapt_gui_vqm.py',ROOT/'tools/eda.py']
    if args.netlist:
        originals.append(args.netlist.resolve())
    try:
        snapshot = flow.folder/'inputs'
        snapshot.mkdir()
        frozen = []
        manifest = {}
        for index, path in enumerate(originals):
            relative=path.relative_to(ROOT) if path.is_relative_to(ROOT) else Path('external')/path.name
            target = snapshot/relative
            target.parent.mkdir(parents=True,exist_ok=True)
            target.write_bytes(path.read_bytes())
            manifest[str(path)] = eda.sha(path)
            if path.suffix == '.v':
                frozen.append(target)
        flow.result['inputs'] = manifest
        rtl_top = next(p for p in frozen if p.name=='AFDX_top.v')
        alias = snapshot/'AFDX_top_rtl.v'
        text = rtl_top.read_text(encoding='utf-8')
        assert text.count('module AFDX_top #(')==1
        alias.write_text(text.replace('module AFDX_top #(', 'module AFDX_top_rtl #(', 1),encoding='utf-8')
        sources = [p for p in frozen if not (args.netlist and p == rtl_top)] + [alias]
        if os.environ.get('AFDX_MODELSIM_DECL_ORDER','1')=='1':
            from modelsim_sources import prepare
            sources,changes=prepare(sources,flow.folder)
            flow.result['modelsim_declaration_order']=changes
            flow.result['compatibility_scope']='Simulation copies only; original RTL unchanged'
        if args.netlist:
            prepared = flow.folder/'simulation.vqm'
            flow.result['adaptation'] = adapt(args.netlist.resolve(),prepared)
            models = eda.elinx_bin().parents[2]/'Simulation/elinx_lib'
            for name in ('220model.v','altera_mf.v','altera_primitives.v','stratix_atoms.v','stratixiv_atoms.v'):
                source = models/name
                target = snapshot/name
                target.write_bytes(source.read_bytes())
                sources.insert(0,target)
                manifest[str(source)] = eda.sha(source)
            sources.insert(0,prepared)
        ms = eda.modelsim_dir()
        flow.job('vlib',[ms/'vlib.exe','work'],60)
        compile_log = flow.job('compile',[ms/'vlog.exe','-vlog01compat','+define+AFDX_CE_DIV=2',*sources],600)
        if not re.search(r'Errors: 0, Warnings: 0',compile_log):
            raise RuntimeError('Compile diagnostics; see compile.log')
        run_do = flow.folder/'run.do'
        run_do.write_text('onerror {quit -code 1}\nonbreak {quit -code 1}\nrun -all\nquit -code 0\n',encoding='ascii')
        command = [ms/'vsim.exe','-batch','-t','1ps','work.tb_t76_load',
            *['-g'+k+'='+str(v) for k,v in params.items()],'-wlf','simulation.wlf','-do','do run.do']
        if args.netlist:
            entry=ROOT/'sim/run_load_post_synth.do'
            (flow.folder/'official_inputs.tcl').write_text(
                'set load_sources [list '+ ' '.join('{'+p.as_posix()+'}' for p in sources)+']\n'+
                'set load_parameters [list '+' '.join('-g'+k+'='+str(v) for k,v in params.items())+']\n',encoding='utf-8')
            log=flow.job('official_entry',[ms/'vsim.exe','-batch','-l','official_transcript.log',
                '-wlf','official_entry.wlf','-do','do {'+entry.as_posix()+'} {'+flow.folder.as_posix()+'}'],86400)
            flow.result['official_do_entry']=str(entry)
        else:
            log = flow.job('simulation',command,86400)
        rows = re.findall(r'\[RESULT\] tb_t76_load (PASS|FAIL) checks=(\d+) errors=(\d+)',log)
        diagnostics = {k:len(re.findall(r'\*\* '+k+':',log)) for k in ('Error','Fatal','Warning')}
        flow.result.update(diagnostics=diagnostics)
        if len(rows)!=1 or rows[0][0]!='PASS' or rows[0][2]!='0' or any(diagnostics.values()) or 'RAMCOLL' in log:
            raise RuntimeError('Simulation not passed; see simulation.log')
        if any(eda.sha(Path(path))!=value for path,value in manifest.items()):
            raise RuntimeError('Input changed during run; frozen inputs retained')
        if args.netlist:
            if not args.reference:raise RuntimeError('Official VQM requires an explicit paired RTL reference')
            reference=json.loads((args.reference/'summary.json').read_text(encoding='utf-8'))
            if reference.get('passed') is not True or reference['parameters']!=params:
                raise RuntimeError('RTL reference did not pass or has different stimulus parameters')
            comparisons={name:(flow.folder/name).read_bytes()==(args.reference/name).read_bytes() for name in RECORDS}
            flow.result.update(rtl_reference=str(args.reference.resolve()),exact_external_records=comparisons)
            if not all(comparisons.values()):raise RuntimeError('Official VQM and paired RTL public records differ')
        flow.result.update(passed=True,checks=int(rows[0][1]),diagnostics=diagnostics,
            records={name:eda.sha(flow.folder/name) for name in RECORDS})
        print('LOAD PUBLIC PIN PASS '+str(flow.folder),flush=True)
        return 0
    except Exception as exc:
        flow.result['error']=str(exc)
        print('LOAD PUBLIC PIN FAIL '+str(exc),flush=True)
        return 1
    finally:
        flow.finish()


if __name__ == '__main__':
    raise SystemExit(main())
