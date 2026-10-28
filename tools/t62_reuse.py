"""One PRES run from a read-only synthesis record; no synthesis/packing copy.

The native run_route.tcl uses synthName only for load_pb_ver (line 61) and
udm_load_checkpoint (line 67). A task-local directory junction gives those reads
a short path to the same frozen source; every run has its own output. Long
relative concatenations failed version loading in the recorded C4 preparation.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

import eda
import official_impl
import official_synth
import report_routed_timing
import t62_constraints
import t62_runtime

ROOT = Path(__file__).resolve().parents[1]
NAME = 'AFDX_EndSystem'


def link_synthesis(synth, runs, evidence):
    """Create only an owned junction; never change the target or its attributes."""
    runs=Path(runs)
    runs.resolve().relative_to((ROOT/'out').resolve())
    target=runs/'synth_1'
    if target.exists():
        raise ValueError('Synthesis input junction already exists')
    for name in [NAME+'.ver.pb',NAME+'_eHiChip6.ecp']:
        if len(str(target/name))>=248:
            raise ValueError('Native input path is too long even with a local junction')
    command=['cmd.exe','/d','/c','mklink','/J',str(target),str(Path(synth).resolve())]
    result=subprocess.run(command,cwd=ROOT,capture_output=True,check=True,
                          creationflags=subprocess.CREATE_NO_WINDOW)
    if not target.is_junction() or target.resolve()!=Path(synth).resolve():
        raise ValueError('Junction does not identify the frozen synthesis source')
    checks={name:eda.sha(target/name)==eda.sha(Path(synth)/name)
            for name in [NAME+'.ver.pb',NAME+'_eHiChip6.ecp']}
    if not all(checks.values()):
        raise ValueError('Native input files differ through junction')
    t62_runtime.save(Path(evidence)/'synthesis_read_chain.json',dict(
        command=command,stdout=result.stdout.decode('mbcs',errors='replace'),junction=str(target),read_only_source=str(Path(synth).resolve()),
        input_checks=checks,native_read_only_uses=['run_route.tcl:61 load_pb_ver','run_route.tcl:67 udm_load_checkpoint'],
        actual_native_load_verified=None))
    return 'synth_1'


def run(source, pres):
    source = Path(source).resolve()
    synthesis = json.loads((source/'summary.json').read_text(encoding='utf-8-sig'))
    if not synthesis.get('completed'):
        raise ValueError('A completed frozen synthesis record is required')
    netlist = Path(synthesis['netlist'])
    if eda.sha(netlist) != synthesis['netlist_sha256']:
        raise ValueError('Frozen VQM changed')
    synth = source/'project'/ (NAME+'.runs/synth_1')
    frozen = {p.name: eda.sha(p) for p in synth.iterdir() if p.is_file()}
    required = [NAME+'.ver.pb', NAME+'_eHiChip6.ecp']
    if any(name not in frozen for name in required):
        raise ValueError('Frozen version/checkpoint missing')
    flow = t62_runtime.Flow('implementation', 'AFDX_top_P'+pres, None)
    started = time.monotonic()
    try:
        project = flow.folder/'project'
        output = project/(NAME+'.runs/imple_1')
        output.mkdir(parents=True)
        t62_constraints.generate(project, pres)
        constraint = project/'constraints.edc'
        psf = output/(NAME+'.run.psf')
        psf.write_text('source '+official_synth.tcl(constraint)+'\nread_sdc '
            +official_synth.tcl(project/'timing_only.sdc')+'\nset_global_assignment -name TARGET_CONSTRAINT_FILE '
            +official_synth.tcl(constraint)+'\n', encoding='utf-8')
        logconfig = output/'log4cpp.property'
        logconfig.write_text('log4cpp.rootCategory=DEBUG,A1\nlog4cpp.appender.A1=RollingFileAppender\n'
            'log4cpp.appender.A1.fileName='+(output/(NAME+'.edi')).as_posix()+'\n'
            'log4cpp.appender.A1.append=false\nlog4cpp.appender.A1.layout=PatternLayout\n'
            'log4cpp.appender.A1.layout.ConversionPattern=%d [%p] %m%n\n', encoding='utf-8')
        binary = official_synth.installation()/'bin/shell/bin'
        native = binary/'run_route.tcl'
        native_source = native.read_text(encoding='utf-8-sig')
        uses = [line for line in native_source.splitlines() if '$synthName' in line]
        if len(uses) != 2 or not uses[0].startswith('load_pb_ver ') or 'udm_load_checkpoint' not in uses[1]:
            raise ValueError('Native synthesis read chain changed')
        synth_name = link_synthesis(synth,output.parent,flow.folder)
        arguments = [project,NAME,synthesis['top'],synthesis['series'],synthesis['device'],
                     synthesis['package'],synth_name,'imple_1']
        script = flow.folder/'route.tcl'
        script.write_text('setlogfile '+official_synth.tcl(logconfig)+' '
            +official_synth.tcl(output/(NAME+'.edi'))+'\nsource '+official_synth.tcl(native)+'\n'
            'proc t62_pres_trace {command code result operation} {\n'
            ' if {[lindex $command 2] eq "PRES_FAC_MULT"} {puts "T62_PRES [lindex $command 3] code=$code"}\n}\n'
            'trace add execution set_global_assignment leave t62_pres_trace\n'
            'run_route '+' '.join(map(official_synth.tcl,arguments))+'\n'
            'puts "T62_ROUTE_COMPLETED"\nexit 0\n', encoding='utf-8')
        # Verify every actual include, not just the aggregate Verilog file.
        official_synth.project_settings(flow,None)
        settings = [ROOT/'elinx/constraints_t62.json', ROOT/'elinx/constraints.edc',
                    ROOT/'elinx/AFDX_EndSystem.epr', ROOT/'elinx/AFDX_EndSystem_assignment_defaults.qdf']
        flow.result.update(synthesis=str(source),output=str(output),pres=pres,
            source_synth_name=synth_name, source_read_only_files=frozen,
            constraint_file=str(constraint),constraint_sha256=eda.sha(constraint),
            native_script_sha256=eda.sha(native),
            setting_hashes={p.relative_to(ROOT).as_posix():eda.sha(p) for p in settings})
        audit = __import__('check_multicycle').audit(netlist,constraint,flow.folder/'multicycle_audit')
        if not audit['passed']:
            raise ValueError('Mapped MCP audit failed')
        log = flow.job('route',[binary/'Implementation.exe','-f',script],7200,cwd=binary)
        edi = (output/(NAME+'.edi')).read_text(encoding='utf-8-sig',errors='replace')
        if 'T62_ROUTE_COMPLETED' not in log or 'All was well!' not in log or re.search(r'\[(ERROR|CRIT)\]',edi):
            raise RuntimeError('Native route failed; preserve raw logs')
        if 'T62_PRES '+pres+' code=0' not in log:
            raise RuntimeError('PRES assignment was not observed')
        resources,timing,resource_file,database = official_impl.reports(output,NAME)
        from t61_metrics import read_place
        clusters,pins = read_place(output/(NAME+'.place'))
        checks=[]
        for row in t62_constraints.load_spec()['pins']:
            got=pins.get(row['port'])
            checks.append(dict(port=row['port'],passed=bool(got and got['package_pin']==row['pin']
                and got['coordinates']==row['xyz']),actual=got))
        t62_runtime.save(flow.folder/'physical_check.json',dict(pins=checks,passed=all(r['passed'] for r in checks)))
        if len(pins)!=172 or not all(r['passed'] for r in checks):
            raise ValueError('Actual P0 placement differs')
        if frozen!={p.name:eda.sha(p) for p in synth.iterdir() if p.is_file()}:
            raise ValueError('Read-only shared synthesis source changed')
        flow.result.update(completed=True,timing_closed=official_impl.timing_closed(timing['clocks']),
            constraints_applied=True,resources=resources,timing=timing,timing_database=str(database),
            resources_report=str(resource_file))
    except Exception as error:
        flow.result.update(completed=False,error=str(error))
    finally:
        flow.result['elapsed_seconds']=time.monotonic()-started
        flow.finish()
    if flow.result.get('completed'):
        return report_routed_timing.report(flow.folder/'summary.json',None)
    return flow.result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--pres',choices=t62_constraints.PRES,required=True)
    args=parser.parse_args()
    t62_runtime.install()
    return 0 if run(args.source,args.pres).get('completed') else 1


if __name__=='__main__':
    raise SystemExit(main())
