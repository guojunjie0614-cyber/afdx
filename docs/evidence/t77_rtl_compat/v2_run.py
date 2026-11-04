"""T77 v2 bounded official map/export or serial direct-RTL simulations."""
import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = Path(__file__).resolve().parent
TZ = timezone(timedelta(hours=8))
for key, value in dict(AFDX_PYTHON='E:/anaconda3/python.exe',
    MODELSIM_HOME='E:/Verilog/ModelSim/setup_pack/win64',
    ELINX_HOME='E:/2026_Embedded_FPGA/setup_pack', AFDX_CE_DIV='2',
    AFDX_MEM_FLOOR_GB='3', AFDX_MODELSIM_DECL_ORDER='0',
    AFDX_SIM_TIMEOUT_SECONDS='7200', AFDX_LATEST_PREFIX='t77_v2_').items():
    os.environ[key] = value
sys.path.insert(0, str(ROOT / 'tools'))
import psutil
import eda
import build_1030
import official_synth
from synth_check import compare, BASELINE


def stamp():
    return datetime.now(TZ).strftime('%Y-%m-%d %H:%M:%S')


def identity(p):
    return dict(pid=p.pid, created=p.create_time(), name=p.name(), command=p.cmdline())


def protected_processes():
    found = {}
    for p in psutil.process_iter(['cmdline']):
        try:
            cmd = ' '.join(p.info['cmdline'] or []).lower().replace('\\', '/')
            if any('/' + part + '/' in cmd for part in ('c3_frag1030', 'c3_t76')):
                for q in [p] + p.children(recursive=True):
                    found[q.pid] = identity(q)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return list(found.values())


RESOURCE_CHECKS = []


class GuardedFlow(eda.Flow):
    def job(self, name, command, budget=900, cwd=None):
        available = psutil.virtual_memory().available / 1024**3
        disk = eda.free_disk_bytes(ROOT.anchor) / 1024**3
        simulations = len(eda.modelsim_slot_pids())
        synthesis = sum(1 for p in psutil.process_iter(['name']) if
                        (p.info['name'] or '').lower() in ('quartus_map.exe', 'quartus_cdb.exe'))
        executable = Path(command[0]).name.lower()
        check = dict(time=stamp(), job=name, executable=executable, free_memory_gib=available,
                     e_free_gib=disk, global_modelsim_slots=simulations,
                     global_official_synthesis=synthesis)
        RESOURCE_CHECKS.append(check)
        if available < 3 or disk < 8:
            raise RuntimeError('Launch floors not met; other jobs untouched')
        if executable == 'vsim.exe' and simulations >= 10:
            raise RuntimeError('Global ModelSim capacity reached; other jobs untouched')
        if executable.startswith('quartus_') and synthesis >= 6:
            raise RuntimeError('Global official synthesis capacity reached')
        return super().job(name, command, budget, cwd)


eda.Flow = GuardedFlow


def synthesis(deadline):
    stop = min(deadline, time.time() + 1800)
    f = eda.Flow('t77_synth', 'v2_modeltech', datetime.fromtimestamp(stop, TZ).isoformat())
    result = dict(started=stamp(), deadline=datetime.fromtimestamp(stop, TZ).strftime('%Y-%m-%d %H:%M:%S'),
                  folder=str(f.folder), completed=False, route_performed=False)
    eda.save(EVIDENCE / 'v2_synthesis.json', result)
    try:
        home = official_synth.installation()
        project, _, _, _, directory, output, _ = build_1030.prepare(f, '1.30')
        source = f.folder / 'source'
        manifest = json.loads((EVIDENCE / 'v2_text_equivalence.json').read_text(encoding='utf-8'))
        if not manifest['passed']:
            raise RuntimeError('Text-equivalence gate failed')
        result['snapshot_matches_text_proof'] = {
            relative: eda.sha(source / relative).lower() == hashes['after_sha256']
            for relative, hashes in manifest['source_files'].items()}
        if not all(result['snapshot_matches_text_proof'].values()):
            raise RuntimeError('Synthesis snapshot differs from text proof')
        binary = home / 'bin/Passkey/bin'
        log = f.job('analysis', [binary / 'quartus_map.exe', '--read_settings_files=on',
                               '--write_settings_files=off', project.stem], 1800, cwd=directory)
        if 'Analysis & Synthesis was successful. 0 errors' not in log:
            raise RuntimeError('Official success marker absent')
        netlist = output / (project.stem + '.vqm')
        f.job('export', [binary / 'quartus_cdb.exe', project.stem, '-c', project.stem,
                        '--vqm=' + str(netlist)], 300, cwd=directory)
        # A byte/ordered mismatch is an observation in v2, not the acceptance gate.
        result['ordered_comparison'] = compare(netlist)
        result.update(completed=True, netlist=str(netlist), vqm_sha256=eda.sha(netlist).lower())
        print('V2_SYNTHESIS_EXPORTED ' + str(netlist), flush=True)
    finally:
        result.update(finished=stamp(), jobs=f.jobs)
        f.result.update(result)
        f.finish()
        eda.save(EVIDENCE / 'v2_synthesis.json', result)
    return result['completed']


def simulations(deadline):
    expected = dict(tb_elinx=9238, tb_fragmentation=33, tb_sys_basic=5159270,
                    tb_rx_basic=9960369, tb_tx_basic=662983)
    results = []
    for test, count in expected.items():
        options = argparse.Namespace(test=test, deadline=datetime.fromtimestamp(
            min(deadline, time.time() + 7200), TZ).isoformat(), netlist=[], seed=20261007,
            param=[], coverage=False)
        code = eda.sim(options)
        report = json.loads((ROOT / ('out/t77_v2_latest_' + test + '.json')).read_text(encoding='utf-8'))
        compile_job = next((job for job in report['jobs'] if job['name'] == 'compile'), {})
        command = compile_job.get('command', [])
        rtl_paths = [Path(p).resolve() for p in command if Path(p).suffix == '.v' and Path(p).parent == ROOT / 'rtl']
        direct = len(rtl_paths) == 34 and not report.get('modelsim_declaration_order') and not report['replaced_modules']
        passed = code == 0 and report.get('passed') and report.get('checks') == count and direct
        results.append(dict(test=test, passed=bool(passed), checks=report.get('checks'),
                            expected_checks=count, direct_rtl=direct, summary=str(Path(report['folder']) / 'summary.json')))
        eda.save(EVIDENCE / 'v2_simulations.json', dict(results=results, passed=all(r['passed'] for r in results),
                 complete=len(results) == len(expected), adapter_environment='0', ce_div=2))
        if not passed:
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['synth', 'sims'])
    parser.add_argument('--deadline', required=True)
    args = parser.parse_args()
    deadline = datetime.fromisoformat(args.deadline).timestamp()
    receipt = EVIDENCE / ('v2_' + args.mode + '_runner.json')
    if receipt.exists():
        raise RuntimeError('Do not overwrite an existing run receipt')
    report = dict(mode=args.mode, started=stamp(), deadline=datetime.fromtimestamp(deadline, TZ).strftime('%Y-%m-%d %H:%M:%S'),
                  runner=identity(psutil.Process()), protected_before=protected_processes(),
                  per_task_max_official_synthesis=1, per_task_max_modelsim=1,
                  passed=False, completed=False)
    eda.save(receipt, report)
    try:
        report['passed'] = synthesis(deadline) if args.mode == 'synth' else simulations(deadline)
        report['completed'] = True
    except Exception as error:
        report['error'] = str(error)
        print('V2_RUN_ERROR ' + str(error), flush=True)
    finally:
        for p in report['protected_before']:
            try:
                p['same_process_still_running'] = psutil.Process(p['pid']).create_time() == p['created']
            except psutil.NoSuchProcess:
                p['same_process_still_running'] = False
        report.update(finished=stamp(), resources=RESOURCE_CHECKS)
        eda.save(receipt, report)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
