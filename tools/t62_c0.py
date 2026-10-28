"""C0 source reconstruction and exact P1.55 release gate; no license repair."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import psutil
import eda
import t62_runtime as runtime
from t61_metrics import read_place, timing_statistics
import t62_constraints

ROOT=Path(__file__).resolve().parents[1]
CANDIDATE=ROOT.parent/'c3_t62_c0'
OUT=ROOT/'out/t62'


def main():
    manifest=json.loads((OUT/'manifest.json').read_text(encoding='utf-8'))
    base=OUT/'C0/P1.55'
    number=1
    while (base/f'attempt_{number:02d}').exists():
        number+=1
    attempt=base/f'attempt_{number:02d}'
    attempt.mkdir(parents=True,exist_ok=False)
    identity=runtime.capture(psutil.Process())
    # manifest v1 also captured a newly authored coordinator-only GUI helper.
    # It is not a candidate input. Explicitly separate that known driver; no
    # missing synthesis, implementation, audit or runtime input is tolerated.
    coordinator_only={'tools/t62_c0.py','tools/t62_gui_prepare.py'}
    frozen={**{k:v['sha256'] for k,v in manifest['source_closure'].items()},
            **manifest['setting_hashes'],
            **{k:v for k,v in manifest['scripts'].items() if k not in coordinator_only}}
    for name,digest in frozen.items():
        if eda.sha(CANDIDATE/name)!=digest:
            raise ValueError('C0 frozen input differs: '+name)
    config=dict(candidate=str(CANDIDATE),worker=identity,started=runtime.now(),frozen_files=frozen,
        manifest_sha256=eda.sha(OUT/'manifest.json'),license_policy='No environment override or retry on license failure',
        allowed_stages=['source synthesis','P1.55 implementation','full timing report'],
        coordinator_only_files=sorted(coordinator_only),native_synthesis_attempt=1)
    runtime.save(attempt/'config.json',config)
    state=json.loads((OUT/'status.json').read_text())
    state['items']['C0']=dict(status='running',phase='source_synthesis_license_check',worker=identity,
                            attempt=str(attempt),logs=str(attempt/'synthesis.log'))
    state.update(updated=runtime.now(),phase='C0_gate_and_independent_preparation')
    runtime.save(OUT/'status.json',state)
    env=os.environ.copy()
    env.update(ELINX_HOME='E:/2026_Embedded_FPGA/setup_pack',AFDX_PYTHON=sys.executable)
    shell=shutil.which('pwsh.exe') or shutil.which('powershell.exe')
    jobs=[]
    def execute(name,command):
        with (attempt/(name+'.log')).open('xb') as stream:
            process=psutil.Popen(command,cwd=CANDIDATE,env=env,stdout=stream,
                stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
            item=dict(stage=name,started=runtime.now(),**runtime.capture(process),log=str(attempt/(name+'.log')))
            runtime.save(attempt/'active_worker_job.json',item)
            item.update(exit_code=process.wait(),finished=runtime.now())
            jobs.append(item)
            runtime.save(attempt/'worker_jobs.json',jobs)
        return item['exit_code']
    result=dict(status='running',candidate='C0',run_completed=False,control_reproduced=None,
        constraints_applied=None,functional_passed=None,timing_closed=None,valid_for_comparison=None,
        eligible_for_combination=None,started=runtime.now(),attempt=str(attempt),retries=0)
    try:
        code=execute('synthesis',[shell,'-NoProfile','-File',str(CANDIDATE/'elinx/synth.ps1')])
        summary=json.loads((CANDIDATE/'out/latest_AFDX_top.json').read_text(encoding='utf-8'))
        result.update(synthesis=summary)
        if code or not summary.get('completed'):
            logs='\n'.join(p.read_text(encoding='utf-8-sig',errors='replace')
                           for p in Path(summary['folder']).glob('*.log'))
            license_error=bool(re.search(r'Error\s*\(292026\)|Specified license file does not exist',logs,re.I))
            result.update(status='blocked' if license_error else 'failed',
                reason_code='license' if license_error else 'tool_error',
                reason='C0 first source synthesis Error(292026); no license change or license retry permitted' if license_error
                       else summary.get('error','Source synthesis failed'))
            return
        if execute('implementation',[shell,'-NoProfile','-File',str(CANDIDATE/'elinx/impl.ps1')]):
            raise RuntimeError('C0 native implementation failed')
        route=json.loads((CANDIDATE/'out/latest_AFDX_top_route.json').read_text(encoding='utf-8'))
        result['route']=route
        if not route.get('completed'):
            raise RuntimeError(route.get('error','C0 route incomplete'))
        if execute('full_report',[sys.executable,'-B',str(CANDIDATE/'tools/report_routed_timing.py')]):
            raise RuntimeError('C0 full report failed')
        report=json.loads((CANDIDATE/'out/latest_AFDX_top_full_timing.json').read_text(encoding='utf-8'))
        metrics=timing_statistics(report['timing_database'])
        clusters,pins=read_place(Path(route['output'])/'AFDX_EndSystem.place')
        pin_checks=[dict(port=row['port'],passed=bool(pins.get(row['port'])
            and pins[row['port']]['package_pin']==row['pin']
            and pins[row['port']]['coordinates']==row['xyz'])) for row in t62_constraints.load_spec()['pins']]
        physical=len(pins)==172 and all(row['passed'] for row in pin_checks)
        expected=dict(setup_worst_slack_ps=-184,setup_failed_endpoints=10,setup_endpoint_count=53882,
                      hold_worst_slack_ps=229,hold_failed_endpoints=0)
        checks={key:metrics[key]==value for key,value in expected.items()}
        checks.update(edge8=metrics['edge_classes']['8ns']['endpoints']==51424,
            edge16=metrics['edge_classes']['16ns']['endpoints']==2458,pins=physical,
            clock=len(metrics['clocks'])==1 and metrics['clocks'][0]['name']=='clk'
                  and metrics['clocks'][0]['period']==8000,
            resources=all(route['resources'][key]==value for key,value in dict(lut=39895,ff=20885,memory=404,pins=172).items()),
            mcp=report['invalid_registers']==0 and report['uncovered_internal_arcs']==0,
            uncertainty=report['setup_uncertainty_ns']==0.30)
        # Checkpoint differences are evidence, never silently treated as C4's paired control.
        synthdir=Path(summary['netlist']).parent
        identity_checks={name:eda.sha(synthdir/name)==digest for name,digest in manifest['canonical_synth_files'].items()
                         if name.endswith(('.vqm','.ecp','_cluster.xml')) and (synthdir/name).is_file()}
        runtime.save(attempt/'gate.json',dict(passed=all(checks.values()),checks=checks,expected=expected,
            raw_metrics=metrics,physical=pin_checks,canonical_file_matches=identity_checks))
        result.update(status='completed',reason_code=None,run_completed=True,
            control_reproduced=all(checks.values()),constraints_applied=physical,timing_closed=metrics['timing_closed'],
            valid_for_comparison=all(checks.values()),metrics=metrics,report=report,
            other_pres_release=all(checks.values()),canonical_file_matches=identity_checks)
    except Exception as error:
        result.update(status='failed',reason_code='tool_error',reason=str(error))
    finally:
        result.update(finished=runtime.now(),jobs=jobs)
        runtime.save(attempt/'result.json',result)
        runtime.save(OUT/'C0/result.json',result)
        state=json.loads((OUT/'status.json').read_text())
        state['items']['C0']={key:result.get(key) for key in ['status','reason_code','reason','control_reproduced']}
        state['items']['C0'].update(result=str(OUT/'C0/result.json'),worker=identity)
        state['updated']=runtime.now()
        runtime.save(OUT/'status.json',state)


if __name__=='__main__':
    main()
