"""Check the unchanged run_app.do small input under T62 global admission."""
import json
from pathlib import Path
import re
import sys
from official_synth import tcl

import eda
import t62_runtime as runtime

ROOT=Path(__file__).resolve().parents[1]


def main():
    flow=runtime.Flow('preparation','app_small',None)
    inputs=[ROOT/'sim/run_app.do',ROOT/'sim/vectors/app/small_stimulus.txt',ROOT/'sim/vectors/app/vl_config.txt']
    inputs+=sorted((ROOT/'rtl').glob('*.v'))+sorted((ROOT/'tb/lib').glob('*'))+[ROOT/'tb/tb_app_entry.v']
    frozen={str(path):eda.sha(path) for path in inputs if path.is_file()}
    name='t62_small_'+flow.folder.name
    # The reference entry stays read-only. Add only environment checks to its
    # two external-tool stages in this attempt's private execution copy.
    source=(ROOT/'sim/run_app.do').read_text(encoding='utf-8-sig')
    prefix='proc t62_ini_guard {} {exec '+tcl(sys.executable)+' -B '+tcl(ROOT/'tools/t62_runtime.py')+' check-env}\n'
    for marker in ['proc app_entry::compile {folder} {','proc app_entry::simulate {folder} {']:
        if source.count(marker)!=1:raise ValueError('App stage marker changed')
        source=source.replace(marker,marker+'\n    t62_ini_guard',1)
    script=flow.folder/'run_app_guarded.do'
    script.write_text(prefix+source,encoding='utf-8')
    command='do '+tcl(script)+' sim/vectors/app/small_stimulus.txt sim/vectors/app/vl_config.txt '+name
    try:
        # Outer vsim is a Tcl coordinator. Child compile/simulation retain
        # independent 120/900s guards, with time for the entry's analysis work.
        flow.result.update(outer_script_budget_seconds=1200,child_compile_budget_seconds=120,
                           child_simulation_budget_seconds=900,reserved_modelsim_slots=2)
        log=flow.job('app_small',[eda.modelsim_dir()/'vsim.exe','-batch','-do',command],1200,cwd=ROOT)
        compile_log=(ROOT/'out/app'/name/'compile.log').read_text(encoding='utf-8-sig',errors='replace')
        simulation=(ROOT/'out/app'/name/'simulation.log').read_text(encoding='utf-8-sig',errors='replace')
        diagnostics={key:len(re.findall(r'\*\* '+key+':',compile_log+simulation)) for key in ['Error','Fatal','Warning']}
        diagnostics['RAMCOLL']=(compile_log+simulation).count('RAMCOLL')
        passed='APP ENTRY PASS' in log and 'APP ENTRY FAIL' not in log and not any(diagnostics.values())
        if any(eda.sha(Path(path))!=digest for path,digest in frozen.items()):
            raise ValueError('App input changed')
        flow.result.update(passed=passed,diagnostics=diagnostics,app_output=str(ROOT/'out/app'/name),
                           app_summary=(ROOT/'out/app'/name/'summary.txt').read_text(encoding='utf-8-sig'))
    except Exception as error:
        flow.result.update(passed=False,error=str(error))
    finally:
        flow.result['input_hashes']=frozen
        flow.finish()
        runtime.save(ROOT/'out/t62/preparation/app_small_result.json',flow.result)
    print(json.dumps({key:value for key,value in flow.result.items() if key not in ['input_hashes','jobs']},ensure_ascii=False))
    return 0 if flow.result.get('passed') else 1


if __name__=='__main__':
    raise SystemExit(main())
