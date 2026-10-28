"""One frozen T62 round-2 job. Only the coordinator queues jobs/retries.

Each native call uses the INI hash/GUI guard and independent stage budgets.
No latest pointer or artifact from an unlisted manual probe may be reused.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import sys
import traceback

import psutil
import eda
import official_synth
import official_impl
import report_routed_timing
import t62_runtime as runtime
import t62_constraints
from t61_metrics import timing_statistics,read_place

ROOT=Path(__file__).resolve().parents[1]


def load(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def verify(config):
    runtime.environment_guard()
    for name,digest in config['frozen_files'].items():
        path=Path(name)
        path=path if path.is_absolute() else ROOT/path
        if eda.sha(path)!=digest:
            raise RuntimeError('Frozen input changed: '+str(path))


def invoke(main,arguments):
    sys.argv=['t62_worker',*list(map(str,arguments))]
    return main()


def pointer(prefix,name):
    path=ROOT/'out'/(prefix+'latest_'+name+'.json')
    value=load(path)
    folder=Path(value['folder'])
    folder.resolve().relative_to((ROOT/'out').resolve())
    if any(folder.name==name for name in ['20261028_030759_171685','20261028_030940_045129','20261028_032912_739975']):
        raise RuntimeError('Excluded manual license probe cannot be reused')
    return value


def gate(config,prefix,result):
    if invoke(official_synth.main,[]):
        summary=pointer(prefix,'AFDX_top');result['synthesis']=summary
        raise RuntimeError(summary.get('error','Source synthesis failed'))
    synthesis=pointer(prefix,'AFDX_top');result['synthesis']=synthesis
    verify(config)
    if invoke(official_impl.main,['--synthesis',Path(synthesis['folder'])/'summary.json']):
        raise RuntimeError('C0 P1.55 implementation failed')
    route=pointer(prefix,'AFDX_top_route');result['route']=route
    verify(config)
    report=report_routed_timing.report(Path(route['folder'])/'summary.json',None)
    if not report.get('completed'):raise RuntimeError(report.get('error','Full report failed'))
    metrics=timing_statistics(report['timing_database'])
    clusters,pins=read_place(Path(route['output'])/'AFDX_EndSystem.place')
    pin_checks=[dict(port=row['port'],actual=pins.get(row['port']),passed=bool(pins.get(row['port'])
        and pins[row['port']]['package_pin']==row['pin'] and pins[row['port']]['coordinates']==row['xyz']))
        for row in t62_constraints.load_spec()['pins']]
    expected=dict(setup_worst_slack_ps=-184,setup_failed_endpoints=10,setup_endpoint_count=53882,
                  hold_worst_slack_ps=229,hold_failed_endpoints=0)
    checks={name:metrics[name]==value for name,value in expected.items()}
    checks.update(edge8=metrics['edge_classes']['8ns']['endpoints']==51424,
        edge16=metrics['edge_classes']['16ns']['endpoints']==2458,
        clock=len(metrics['clocks'])==1 and metrics['clocks'][0]['name']=='clk' and metrics['clocks'][0]['period']==8000,
        resources=all(route['resources'][k]==v for k,v in dict(lut=39895,ff=20885,memory=404,pins=172).items()),
        P0=len(pins)==172 and all(row['passed'] for row in pin_checks),
        MCP=report['invalid_registers']==0 and report['uncovered_internal_arcs']==0,
        uncertainty=report['setup_uncertainty_ns']==0.30)
    synth=Path(synthesis['netlist']).parent
    reference=load(config['reference_manifest'])['canonical_synth_files']
    identities={name:dict(expected=reference[name],actual=eda.sha(synth/name),same=eda.sha(synth/name)==reference[name])
        for name in ['AFDX_EndSystem.vqm','AFDX_EndSystem_eHiChip6.ecp','AFDX_EndSystem_cluster.xml']}
    proof=dict(passed=all(checks.values()),checks=checks,expected=expected,actual=metrics,physical=pin_checks,
               canonical_identities=identities,identity_note='Differences are reported; C4p remains independently frozen canonical reference')
    runtime.save(Path(config['attempt'])/'gate.json',proof)
    result.update(status='completed',run_completed=True,control_reproduced=proof['passed'],
        constraints_applied=checks['P0'],timing_closed=official_impl.timing_closed(metrics['clocks']),
        valid_for_comparison=proof['passed'],gate=proof,metrics=metrics,resources=route['resources'],report=report,
        source_synthesis=str(Path(synthesis['folder'])))


def directed(config,prefix,result):
    spec=config['directed']
    flow=runtime.Flow('directed',spec['test'],None)
    try:
        library=eda.modelsim_dir()
        rtl=sorted((ROOT/'rtl').glob('*.v'))
        sources=rtl+sorted((ROOT/'tb/lib').glob('*.v'))+[ROOT/spec['bench']]
        sources+=[ROOT/path for path in spec.get('extra_sources',[])]
        flow.result['inputs']=[dict(path=str(path),sha256=eda.sha(path)) for path in sources]
        flow.job('vlib',[library/'vlib.exe','work'],30)
        compile_log=flow.job('compile',[library/'vlog.exe','-vlog01compat',
            '+define+AFDX_CE_DIV=2','+incdir+'+str(ROOT/'tb/lib'),*sources],120)
        if not re.search(r'Errors: 0, Warnings: 0',compile_log):raise RuntimeError('Directed compile diagnostics')
        script=flow.folder/'run.do';script.write_text('onerror {quit -code 1}\nonbreak {quit -code 1}\nrun -all\nquit -code 0\n',encoding='ascii')
        log=flow.job('simulation',[library/'vsim.exe','-batch',spec['test'],'-wlf','simulation.wlf','-do','do run.do'],900)
        rows=re.findall(r'\[RESULT\]\s+(\w+)\s+(PASS|FAIL)\s+checks=(\d+)\s+errors=(\d+)',log)
        good=bool(rows and rows[-1][0]==spec['test'] and all(row[1]=='PASS' and row[3]=='0' for row in rows)
                  and int(rows[-1][2])>=spec.get('minimum_checks',1))
        diagnostics={key:len(re.findall(r'\*\* '+key+':',log)) for key in ['Error','Fatal','Warning']}
        diagnostics['RAMCOLL']=log.count('RAMCOLL')
        flow.result.update(passed=good and not any(diagnostics.values()),diagnostics=diagnostics,checks=int(rows[-1][2]) if rows else None)
        if not flow.result['passed']:raise RuntimeError('Directed cycle comparison failed')
        result.update(status='completed',functional_passed=True,directed=flow.result)
    finally:
        flow.finish()


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--config',type=Path,required=True)
    args=parser.parse_args();config=load(args.config);attempt=Path(config['attempt'])
    if Path(config['root']).resolve()!=ROOT:raise ValueError('Worker root differs from frozen config')
    result=dict(job_id=config['job_id'],candidate=config['candidate'],round_id='round_02',mode=config['mode'],
        status='running',started=runtime.now(),owner=runtime.capture(psutil.Process()),run_completed=False,
        control_reproduced=None,constraints_applied=None,functional_passed=None,timing_closed=None,
        valid_for_comparison=None,eligible_for_combination=None,config=str(args.config),config_sha256=eda.sha(args.config))
    runtime.save(attempt/'worker_status.json',result)
    prefix=config['job_id']+'_';os.environ['AFDX_LATEST_PREFIX']=prefix
    os.environ['AFDX_CE_DIV']='2';os.environ['ELINX_HOME']='E:/2026_Embedded_FPGA/setup_pack'
    runtime.install()
    try:
        verify(config)
        mode=config['mode']
        if mode=='c0_gate':gate(config,prefix,result)
        elif mode=='synth':
            if invoke(official_synth.main,[]):
                result['synthesis']=pointer(prefix,'AFDX_top');raise RuntimeError(result['synthesis'].get('error','Synthesis failed'))
            result.update(status='completed',synthesis=pointer(prefix,'AFDX_top'),run_completed=True)
        elif mode=='route':
            import t62_reuse
            report=t62_reuse.run(config['source'],config['pres'])
            if not report.get('completed'):raise RuntimeError(report.get('error','PRES route/report failed'))
            route=load(Path(report['route'])/'summary.json');metrics=timing_statistics(report['timing_database'])
            result.update(status='completed',run_completed=True,constraints_applied=route['constraints_applied'],
                timing_closed=official_impl.timing_closed(metrics['clocks']),valid_for_comparison=True,
                report=report,route=route,metrics=metrics,resources=route['resources'])
        elif mode=='sim':
            arguments=['sim','--test',config['test']]
            for param in config.get('parameters',[]):arguments+=['--param',param]
            if config.get('netlist'):arguments+=['--netlist',config['netlist']]
            code=invoke(eda.main,arguments);summary=pointer(prefix,config['test'])
            result['simulation']=summary
            if code or not summary.get('passed'):raise RuntimeError(summary.get('error','Simulation failed'))
            result.update(status='completed',run_completed=True,functional_passed=True)
        elif mode=='directed':directed(config,prefix,result)
        elif mode=='app':
            import t62_app_smoke
            if t62_app_smoke.main():raise RuntimeError('Application small stimulus failed')
            result.update(status='completed',run_completed=True,functional_passed=True,application=pointer(prefix,'app_small'))
        else:raise ValueError('Unknown frozen job mode')
        verify(config)
    except Exception as error:
        text=str(error);reason='environment_changed' if isinstance(error,runtime.EnvironmentChanged) else 'resource_budget' if isinstance(error,runtime.ResourceBlocked) else 'timeout' if 'timeout' in text.lower() else 'tool_error'
        if result.get('synthesis',{}).get('folder'):
            logs='\n'.join(path.read_text(encoding='utf-8-sig',errors='replace')
                for path in Path(result['synthesis']['folder']).glob('*.log'))
            if re.search(r'Error\s*\(292026\)|Specified license file does not exist',logs,re.I):reason='license'
        if config['mode'] in ['sim','directed','app'] and reason=='tool_error':reason='regression_failed'
        result.update(status='blocked' if reason in ['environment_changed','resource_budget','license'] else 'failed',reason_code=reason,error=text,traceback=traceback.format_exc())
    finally:
        result['finished']=runtime.now()
        runtime.save(attempt/'result.json',result);runtime.save(attempt/'worker_status.json',result)
    return 0 if result['status']=='completed' else 1


if __name__=='__main__':raise SystemExit(main())
