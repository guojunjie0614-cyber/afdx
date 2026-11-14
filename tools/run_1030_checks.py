"""Focused Icarus integration checks; no hashes or repeated full regression."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = ['tb_tx_basic', 'tb_tx_bag', 'tb_tx_multi', 'tb_context_pipeline', 'tb_cfg_local_ready', 'tb_sys_cfg',
           'tb_rtc_originate', 'tb_rtc_recovery', 'tb_rtc_banked', 'tb_sys_rtc', 'tb_reassembly_limits',
           'tb_reassembly_transactions', 'tb_reassembly_engine', 'tb_app_payload_pipeline']


def find_icarus(name):
    home = os.environ.get('IVERILOG_HOME')
    if home:
        for executable in (name, name + '.exe'):
            candidate = Path(home) / 'bin' / executable
            if candidate.is_file():
                return str(candidate.resolve())
    found = shutil.which(name)
    if found:
        return found
    for executable in (name + '.exe', name):
        candidate = Path('C:/iverilog/bin') / executable
        if candidate.is_file():
            return str(candidate)
    raise FileNotFoundError(
        f'Icarus {name} not found: checked IVERILOG_HOME/bin, PATH, and C:/iverilog/bin')


def run_case(case, output):
    folder = output / case
    folder.mkdir(parents=True)
    def job(name, args, timeout=1800):
        with (folder / (name + '.log')).open('w', encoding='utf-8') as log:
            p = subprocess.run(list(map(str, args)), cwd=folder, stdout=log,
                               stderr=subprocess.STDOUT, timeout=timeout)
        text = (folder / (name + '.log')).read_text(encoding='utf-8', errors='replace')
        if p.returncode:
            raise RuntimeError(f'{name} exit={p.returncode}; {folder / (name + ".log")}')
        return text
    ref_tx_cases = {'tb_tx_basic', 'tb_tx_bag', 'tb_tx_multi', 'tb_tx_drop', 'tb_tx_net'}
    try:
        if case in ref_tx_cases or case.startswith('tb_rx_'):
            job('vectors', [sys.executable, ROOT/'tools/afdx_ref.py', 'vectors',
                           '--test', case, '--seed', '1', '--out', folder/'vectors'])
        elif case == 'tb_sys_cfg':
            job('vectors', [sys.executable, ROOT/'tools/sys_cases.py', '--test', case,
                           '--seed', '1', '--out', folder/'vectors'])
            for n in ('es1_tx','es1_rx','es2_tx','es2_rx','es1_gmii_tx','es1_gmii_rx','es2_gmii_tx','es2_gmii_rx'):
                (folder/n).mkdir()
        elif case == 'tb_sys_rtc':
            job('vectors', [sys.executable, ROOT/'tools/rtc_ref.py', 'vectors', '--dir', folder])
        sources = sorted((ROOT/'rtl').glob('*.v')) + [ROOT/'tb'/ (case+'.v')]
        if case == 'tb_cfg_local_ready':
            baseline = subprocess.run(
                ['git', 'show', 'c857aba8361e7f9cea74801d4a4d908f49a76436:rtl/afdx_cfg.v'],
                cwd=ROOT, capture_output=True, text=True, encoding='utf-8', check=True).stdout
            legacy = folder/'afdx_cfg_legacy.v'
            legacy.write_text(baseline.replace('module afdx_cfg', 'module afdx_cfg_legacy', 1), encoding='utf-8')
            sources.append(legacy)
        job('compile', [find_icarus('iverilog'), '-g2012', '-DAFDX_CE_DIV=2',
                        '-I', ROOT/'tb/lib', '-y', ROOT/'tb/lib', '-s', case,
                        '-o', folder/'test.vvp', *sources])
        log = job('simulation', [find_icarus('vvp'), folder/'test.vvp'])
        result = re.findall(r'\[RESULT\]\s+(\w+)\s+(PASS|FAIL)\s+checks=(\d+)\s+errors=(\d+)', log)
        if not result or result[-1][0] != case or any(r[1] != 'PASS' or int(r[3]) for r in result):
            raise RuntimeError(f'Simulation failed; {folder / "simulation.log"}')
        if case in ref_tx_cases or case.startswith('tb_rx_'):
            job('check', [sys.executable, ROOT/'tools/afdx_ref.py', 'check', '--test', case, '--dir', folder])
        elif case == 'tb_sys_cfg':
            job('check', [sys.executable, ROOT/'tools/sys_run_checks.py', '--test', case, '--dir', folder])
        elif case == 'tb_sys_rtc':
            job('check', [sys.executable, ROOT/'tools/rtc_ref.py', 'check', '--dir', folder])
        answer = dict(case=case, passed=True, checks=int(result[-1][2]), folder=str(folder))
    except Exception as exc:
        answer = dict(case=case, passed=False, error=str(exc), folder=str(folder))
    print(json.dumps(answer), flush=True)
    return answer


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('cases', nargs='*')
    a = p.parse_args()
    output = ROOT/'out/checks1030'/datetime.now().strftime('%Y%m%d_%H%M%S')
    output.mkdir(parents=True)
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(lambda case: run_case(case, output), a.cases or DEFAULT))
    (output/'summary.json').write_text(json.dumps(results, indent=2)+'\n', encoding='utf-8')
    print('CHECKS1030 ' + ('PASS' if all(r['passed'] for r in results) else 'FAIL') + ' ' + str(output))
    return 0 if all(r['passed'] for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
