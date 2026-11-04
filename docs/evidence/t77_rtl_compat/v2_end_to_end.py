"""Run the authorized modified-RTL build_1030 --route --pres 1.30 once.

Only the isolated QSF copy gets NUM_PARALLEL_PROCESSORS=1 for the requested
determinism probe. Source, project constraints, locks and vendor settings stay
unchanged. No retry, fallback placement, optimization or fixed-VQM R2 follows.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import sys
import time

from v2_run import (ROOT, EVIDENCE, TZ, GuardedFlow, RESOURCE_CHECKS, identity,
                    protected_processes, stamp, eda, build_1030)
from v2_route import collect_native
import psutil


class EndToEndFlow(GuardedFlow):
    def job(self, name, command, budget=900, cwd=None):
        if name == 'analysis':
            budget = min(budget, 1800)
        elif name == 'route':
            budget = min(budget, 3600)
        return super().job(name, command, budget, cwd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deadline', required=True)
    args = parser.parse_args()
    receipt = EVIDENCE / 'v2_end_to_end.json'
    if receipt.exists():
        raise RuntimeError('End-to-end receipt exists; implicit retry forbidden')
    r1 = json.loads((EVIDENCE / 'v2_route_R1.json').read_text(encoding='utf-8'))
    if 'finished' not in r1:
        raise RuntimeError('R1 has not finished; no new EDA job started')
    try:
        p = psutil.Process(r1['runner']['pid'])
        if p.create_time() == r1['runner']['created']:
            raise RuntimeError('R1 serial controller is still active; no new EDA job started')
    except psutil.NoSuchProcess:
        pass
    cancelled = json.loads((EVIDENCE / 'v2_route_R2.json').read_text(encoding='utf-8'))
    if cancelled.get('tools_launched') is not False:
        raise RuntimeError('Fixed-VQM R2 cancellation not confirmed')
    os.environ['AFDX_LATEST_PREFIX'] = 't77_e2e_'
    eda.Flow = EndToEndFlow
    old_prepare = build_1030.prepare
    report = dict(started=stamp(), deadline=datetime.fromisoformat(args.deadline).astimezone(TZ).strftime('%Y-%m-%d %H:%M:%S'),
        runner=identity(psutil.Process()), protected_before=protected_processes(),
        requested_num_parallel_processors=1, purpose='Modified RTL full synthesis + fresh pack + default locked route',
        fixed_vqm_r2_cancelled=True, completed=False, accepted=False, pres='1.30', no_tiles=False)
    eda.save(receipt, report)

    def prepare(flow, pres):
        result = old_prepare(flow, pres)
        project, _, _, _, directory, _, _ = result
        qsf = directory / (project.stem + '.qsf')
        before = qsf.read_bytes()
        if b'NUM_PARALLEL_PROCESSORS' in before:
            raise RuntimeError('Unexpected preexisting processor assignment')
        qsf.write_bytes(before + b'set_global_assignment -name NUM_PARALLEL_PROCESSORS 1\n')
        report.update(folder=str(flow.folder), qsf_before_sha256=hashlib.sha256(before).hexdigest(),
                      qsf_after_sha256=eda.sha(qsf).lower(), run_copy_processor_assignment='NUM_PARALLEL_PROCESSORS 1')
        proof = json.loads((EVIDENCE / 'v2_text_equivalence.json').read_text(encoding='utf-8'))
        report['source_snapshot_matches_text_proof'] = {relative: eda.sha(flow.folder / 'source' / relative).lower()
            == record['after_sha256'] for relative, record in proof['source_files'].items()}
        if not all(report['source_snapshot_matches_text_proof'].values()):
            raise RuntimeError('End-to-end snapshot differs from accepted source')
        eda.save(receipt, report)
        return result

    build_1030.prepare = prepare
    saved_argv = sys.argv
    begin = time.monotonic()
    try:
        sys.argv = ['build_1030.py', '--route', '--pres', '1.30', '--deadline', args.deadline]
        code = build_1030.main()
        result = json.loads((ROOT / 'out/t77_e2e_latest_AFDX_top_1030.json').read_text(encoding='utf-8'))
        report.update(build_exit_code=code, build_result=result, jobs=result['jobs'])
        _, expected = build_1030.load_tile_locks(ROOT / 'elinx/tiles_1030.edc')
        from types import SimpleNamespace
        native = collect_native(SimpleNamespace(folder=Path(result['folder'])), expected)
        report['native'] = native
        locks = native.get('locks', {})
        locked = (locks.get('retained') == locks.get('placed') == len(expected)
            and all(locks.get(k) == 0 for k in ('missing', 'extra', 'moved')))
        clocks = native.get('timing', {}).get('clocks', [])
        closed = bool(clocks) and all(c['setup_worst_slack'] > 0 and c['hold_worst_slack'] >= 0
            and c['setup_fail_ends'] == c['hold_fail_ends'] == 0 for c in clocks)
        report.update(completed=native['native_route_completed'], timing_closed=closed, exact_cluster_locks=locked,
            accepted=code == 0 and locked and closed and native.get('p0_unchanged', False) and not native['errors'])
        if result.get('netlist'):
            report.update(netlist=result['netlist'], vqm_sha256=eda.sha(Path(result['netlist'])).lower())
        elif report.get('folder'):
            netlist = Path(report['folder']) / 'project/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm'
            if netlist.exists():
                report.update(netlist=str(netlist), vqm_sha256=eda.sha(netlist).lower())
        if clocks and not closed:
            report['stop_decision'] = 'Nonpositive setup, negative hold or failing endpoints: stop; no lock changes, no no-tiles, no optimization or retry.'
    except Exception as error:
        report['error'] = str(error)
        print('T77_E2E_ERROR ' + str(error), flush=True)
    finally:
        sys.argv = saved_argv
        build_1030.prepare = old_prepare
        report.update(finished=stamp(), elapsed_seconds=round(time.monotonic() - begin, 3), resources=RESOURCE_CHECKS)
        eda.save(receipt, report)
    print('T77_E2E_RESULT ' + json.dumps({k: report[k] for k in ('completed', 'accepted')}, indent=2), flush=True)
    return 0 if report['accepted'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
