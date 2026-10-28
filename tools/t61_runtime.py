"""T61 isolated stage-E worker; coordinator owns admission and status.json.

One Python process per candidate avoids cross-thread eda.Flow monkeypatching.
Run: python -B tools/t61_runtime.py worker --config <frozen candidate JSON>
No retry, simulation, acceptance promotion, or artifact cleanup is performed.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback
import uuid

GIB = 1024 ** 3
BUDGETS = dict(analysis=3600, export=300, pack=1200, timing=1200, route=7200, report=1800)


def now():
    return datetime.now().astimezone().isoformat()


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            value.update(block)
    return value.hexdigest().upper()


def save(path, value):
    """Atomic replacement only for this attempt's own status/result pointers."""
    path = Path(path)
    temporary = path.with_name(path.name + '.' + str(os.getpid()) + '.' + uuid.uuid4().hex + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    for retry in range(8):
        try:
            os.replace(temporary, path)
            return
        except PermissionError:
            if retry == 7:
                raise
            time.sleep(0.05 * (retry + 1))


def verify_frozen(root, frozen):
    observed = {}
    for name, expected in frozen.items():
        path = Path(name)
        path = path if path.is_absolute() else root / path
        actual = digest(path)
        if actual != expected.upper():
            raise ValueError('Frozen input changed: ' + str(path))
        observed[name] = actual
    return observed


class ResourceBlocked(RuntimeError):
    pass


class BoundedFlow:
    """Drop-in Flow with independent native-tool budgets and owned-PID guards."""
    context = None

    def __init__(self, kind, name, deadline):
        if deadline:
            raise ValueError('T61 has no overall deadline')
        context = self.context
        self.root = context['root']
        stamp = datetime.now().strftime('%Y%m%d_%H%M%S_%f')
        self.folder = self.root / 'out' / kind / name / stamp
        self.folder.mkdir(parents=True, exist_ok=False)
        self.jobs = []
        self.result = dict(name=name, started=now(), folder=str(self.folder),
            scope='T61 stage E; no external I/O timing budget or delivery acceptance',
            attempt_id=context['config']['attempt_id'], memory_floor_gib=3,
            disk_floor_gib=8, overall_deadline=None, native_tool_budgets_seconds=BUDGETS)
        context['flows'].append(self)

    def _resources(self):
        psutil = self.context['psutil']
        disks = {str(path): shutil.disk_usage(path).free for path in self.context['disk_paths']}
        return dict(available_memory_bytes=psutil.virtual_memory().available, disk_free_bytes=disks)

    def _capture(self, process):
        return dict(pid=process.pid, created=process.create_time(), cwd=process.cwd(), command=process.cmdline())

    def _kill_owned(self, owned):
        psutil = self.context['psutil']
        actions = []
        for item in reversed(list(owned.values())):
            try:
                process = psutil.Process(item['pid'])
                matches = (process.create_time() == item['created']
                    and os.path.normcase(process.cwd()) == os.path.normcase(item['cwd'])
                    and process.cmdline() == item['command'])
                if matches:
                    process.kill()
                actions.append(dict(identity=item, killed=matches,
                    reason='owned PID/create-time/cwd/command match' if matches else 'identity changed; untouched'))
            except psutil.NoSuchProcess:
                actions.append(dict(identity=item, killed=False, reason='already exited'))
            except psutil.AccessDenied:
                actions.append(dict(identity=item, killed=False, reason='identity inaccessible; untouched'))
        return actions

    def job(self, name, command, budget=900, cwd=None):
        if name not in BUDGETS:
            raise ValueError('Not a T61 stage-E native tool: ' + name)
        budget = BUDGETS[name]
        command = list(map(str, command))
        executable = Path(command[0]).name.lower()
        wanted = {'analysis': 'quartus_map.exe', 'export': 'quartus_cdb.exe'}.get(name, 'implementation.exe')
        if executable != wanted:
            raise ValueError('Unexpected native executable for ' + name)
        verify_frozen(self.root, self.context['config'].get('frozen_files', {}))
        resources = self._resources()
        if resources['available_memory_bytes'] < 3 * GIB:
            self.context['resource_blocked'] = 'Available memory below 3 GiB before ' + name
            raise ResourceBlocked(self.context['resource_blocked'])
        if any(free < 8 * GIB for free in resources['disk_free_bytes'].values()):
            self.context['resource_blocked'] = 'Drive free space below 8 GiB before ' + name
            raise ResourceBlocked(self.context['resource_blocked'])
        psutil = self.context['psutil']
        owned = {}
        peak = 0
        minimum_memory = resources['available_memory_bytes']
        minimum_disks = dict(resources['disk_free_bytes'])
        reason = None
        kill_actions = []
        log_path = self.folder / (name + '.log')
        with log_path.open('xb') as stream:
            process = psutil.Popen(command, cwd=str(cwd or self.folder), stdout=stream,
                stderr=subprocess.STDOUT, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            started = time.monotonic()
            identity = self._capture(process)
            owned[process.pid] = identity
            active = dict(name=name, started=now(), command=command, cwd=str(cwd or self.folder),
                pid=identity['pid'], created=identity['created'], log=str(log_path),
                budget_seconds=budget, status='running', resources_at_start=resources)
            save(self.folder / 'active_job.json', active)
            last_save = started
            while process.poll() is None:
                rss = 0
                try:
                    members = [process] + process.children(recursive=True)
                except psutil.NoSuchProcess:
                    members = []
                for child in members:
                    try:
                        observed = self._capture(child)
                        owned[child.pid] = observed
                        rss += child.memory_info().rss
                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                        continue
                peak = max(peak, rss)
                resources = self._resources()
                minimum_memory = min(minimum_memory, resources['available_memory_bytes'])
                for path, free in resources['disk_free_bytes'].items():
                    minimum_disks[path] = min(minimum_disks[path], free)
                elapsed = time.monotonic() - started
                if elapsed > budget:
                    reason = 'native_tool_timeout'
                elif any(free < 8 * GIB for free in resources['disk_free_bytes'].values()):
                    reason = 'disk_floor_8gib'
                if reason:
                    kill_actions = self._kill_owned(owned)
                    try:
                        process.wait(timeout=10)
                    except psutil.TimeoutExpired:
                        reason += '; owned_root_did_not_exit'
                    break
                if time.monotonic() - last_save >= 5:
                    save(self.folder / 'active_job.json', dict(active, elapsed_seconds=elapsed,
                        peak_tree_bytes=peak, owned_processes=list(owned.values()), resources=resources))
                    last_save = time.monotonic()
                time.sleep(0.5)
        info = dict(active, status='finished' if process.poll() is not None else 'attention',
            exit_code=process.returncode, stop_reason=reason, finished=now(),
            seconds=time.monotonic() - started, peak_tree_bytes=peak,
            minimum_available_memory_bytes=minimum_memory, minimum_disk_free_bytes=minimum_disks,
            owned_processes=list(owned.values()), termination_actions=kill_actions)
        self.jobs.append(info)
        save(self.folder / 'tool_metrics.json', self.jobs)
        save(self.folder / 'active_job.json', info)
        if process.returncode or reason:
            raise RuntimeError('%s: exit=%s reason=%s; %s' % (name, process.returncode, reason, log_path))
        return log_path.read_text(encoding='utf-8-sig', errors='replace')

    def finish(self):
        self.result.update(finished=now(), jobs=self.jobs)
        save(self.folder / 'summary.json', self.result)
        # Each worker has an isolated root; these are not coordinator status files.
        save(self.root / 'out' / ('latest_' + self.result['name'] + '.json'), self.result)


def _call_main(module):
    previous = sys.argv
    try:
        sys.argv = [str(Path(module.__file__))]
        return module.main()
    finally:
        sys.argv = previous


def compare_control(config, route, full):
    """Exact observed control values; path tie ordering is informational only."""
    reference = config.get('reference_full_summary')
    if not reference:
        return None, dict(reason='No full reference summary supplied; control not assessed')
    baseline = load(reference)
    reference_route = load(Path(baseline['route']) / 'summary.json')
    current_proof = load(Path(full['audit']) / 'netlist.json')
    reference_proof = load(Path(baseline['audit']) / 'netlist.json')
    checks = {}
    def compare(label, actual, expected):
        checks[label] = dict(actual=actual, expected=expected, passed=actual == expected)
    compare('resources', route['resources'], reference_route['resources'])
    for field in ('setup_uncertainty_ns', 'constrained_registers', 'invalid_registers',
                  'internal_register_arcs', 'uncovered_internal_arcs'):
        compare(field, full[field], baseline[field])
    compare('multicycle_definitions', current_proof['patterns'], reference_proof['patterns'])
    for field in ('endpoint_count', 'failed_endpoints', 'invalid_requirements'):
        compare('timing.' + field, full['timing'][field], baseline['timing'][field])
    actual_clocks = {row['name']: row for row in full['timing']['clocks']}
    expected_clocks = {row['name']: row for row in baseline['timing']['clocks']}
    compare('clock_names', sorted(actual_clocks), sorted(expected_clocks))
    for name in sorted(actual_clocks.keys() & expected_clocks.keys()):
        for field in ('period', 'waveform', 'setup_worst_slack', 'hold_worst_slack',
                      'setup_fail_ends', 'setup_total_ends', 'hold_fail_ends', 'hold_total_ends',
                      'setup_total_violation', 'hold_total_violation'):
            compare('clock.' + name + '.' + field, actual_clocks[name][field], expected_clocks[name][field])
    reference_constraint = config.get('reference_constraint_path')
    if reference_constraint:
        compare('constraint_file_sha256', current_proof['constraints_sha256'].upper(), digest(reference_constraint))
    return all(value['passed'] for value in checks.values()), dict(checks=checks,
        note='Equal WNS is not evidence of equal placement; tied path ordering is not a control gate',
        path_counts_actual=full['timing']['groups'], path_counts_reference=baseline['timing']['groups'])


def worker(config_path):
    config_path = Path(config_path).resolve()
    config = load(config_path)
    root = Path(config['root']).resolve()
    if root != Path(__file__).resolve().parents[1]:
        raise ValueError('Worker must run from the selected candidate copy')
    if config['experiment_id'] not in ('E1', 'E2', 'E3', 'E4', 'E5', 'E6'):
        raise ValueError('Unknown stage E experiment')
    attempt_id = config['attempt_id']
    if not attempt_id or any(char not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for char in attempt_id):
        raise ValueError('Invalid attempt ID')
    attempt = root / 'out/t61/runtime' / attempt_id
    attempt.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    result = dict(experiment_id=config['experiment_id'], attempt_id=attempt_id, started=now(),
        terminal_status='failed', reason=None, run_completed=False, control_reproduced=None,
        constraints_applied=None, timing_constraints_verified=None, timing_closed=None, valid_for_comparison=None,
        input_identities=config.get('input_identities', {}), raw_metrics=None,
        attempts=[], evidence=dict(config=str(config_path), config_sha256=digest(config_path), attempt=str(attempt)))
    context = dict(root=root, config=config, flows=[], resource_blocked=None)
    try:
        import psutil
        import eda
        import official_impl
        import official_synth
        import report_routed_timing
        import t61_constraints
        from t61_metrics import timing_statistics, placement_statistics
        context['psutil'] = psutil
        context['disk_paths'] = [Path(path).resolve() for path in config.get('disk_paths', [root.anchor])]
        BoundedFlow.context = context
        eda.Flow = BoundedFlow
        t61_constraints.install_guard(root)
        os.chdir(root)
        result['worker_identity'] = dict(pid=os.getpid(), created=psutil.Process().create_time(), cwd=str(root))
        result['frozen_files_verified'] = verify_frozen(root, config.get('frozen_files', {}))
        initial_free = {str(path): shutil.disk_usage(path).free for path in context['disk_paths']}
        result['resources_at_admission'] = dict(available_memory_bytes=psutil.virtual_memory().available,
            disk_free_bytes=initial_free, reservation_bytes=3 * GIB)
        if psutil.virtual_memory().available < 3 * GIB:
            raise ResourceBlocked('Available memory below 3 GiB at worker admission')
        if any(free < 8 * GIB for free in initial_free.values()):
            raise ResourceBlocked('A monitored drive is below its 8 GiB floor')
        if shutil.disk_usage(root).free < 11 * GIB:
            raise ResourceBlocked('Candidate drive admission requires 8 GiB floor plus 3 GiB reservation')
        if config['experiment_id'] == 'E1':
            if _call_main(official_synth):
                raise RuntimeError('Official synthesis failed; inspect isolated summary')
        if _call_main(official_impl):
            raise RuntimeError('Official implementation failed; inspect isolated summary')
        route_path = root / 'out/latest_AFDX_top_route.json'
        route = load(route_path)
        result['evidence']['route_summary'] = str(Path(route['folder']) / 'summary.json')
        # The legacy report helper unlinks a newly created temporary config.
        # Give it a retained candidate-local config first, so it restores bytes.
        routed_config = Path(route['output']) / 'AFDX_EndSystem.tr.cfg.pb'
        routed_config.resolve().relative_to((root / 'out').resolve())
        if not routed_config.exists():
            routed_config.write_bytes(report_routed_timing.REPORT_CONFIG)
            result['evidence']['retained_initial_report_config'] = str(routed_config)
        full = report_routed_timing.report(route_path, None)
        result['evidence']['full_summary'] = str(Path(full['folder']) / 'summary.json')
        if not full.get('completed'):
            raise RuntimeError('Full routed timing report failed: ' + str(full.get('error')))
        result['run_completed'] = True
        metrics = timing_statistics(full['timing_database'])
        metrics_path = attempt / 'timing_metrics.json'
        save(metrics_path, metrics)
        result['evidence']['timing_metrics'] = str(metrics_path)
        synthesis = load(root / 'out/latest_AFDX_top.json')
        cluster_xml = Path(synthesis['netlist']).with_name('AFDX_EndSystem_cluster.xml')
        placement = placement_statistics(Path(route['output']) / 'AFDX_EndSystem.place', cluster_xml)
        placement_path = attempt / 'placement_metrics.json'
        save(placement_path, placement)
        result['evidence']['placement_metrics'] = str(placement_path)
        result['raw_metrics'] = {key: value for key, value in metrics.items() if key != 'nearcritical_endpoints'}
        result['raw_metrics']['resources'] = route['resources']
        result['timing_closed'] = metrics['timing_closed']
        result['control_reproduced'], result['control_comparison'] = compare_control(config, route, full)
        proof = load(Path(full['audit']) / 'netlist.json')
        result['timing_constraints_verified'] = bool(proof['passed'] and full['timing']['passed']
            and full['setup_uncertainty_ns'] == 0.30
            and len(full['timing']['clocks']) == 1 and full['timing']['clocks'][0]['period'] == 8000)
        if config['experiment_id'] in ('E1', 'E2'):
            result['constraints_applied'] = None
            result['constraints_reason'] = 'Not applicable: automatic pins and no added region'
            result['valid_for_comparison'] = result['timing_constraints_verified']
        else:
            result['constraints_reason'] = 'Physical placement must be checked by coordinator before comparison'
            result['valid_for_comparison'] = None
        verify_frozen(root, config.get('frozen_files', {}))
        result.update(terminal_status='completed', reason='Native route and full endpoint report completed; no W5 performed')
    except Exception as error:
        blocked = isinstance(error, ResourceBlocked) or context.get('resource_blocked')
        result.update(terminal_status='blocked' if blocked else 'failed',
            reason=context.get('resource_blocked') or str(error), traceback=traceback.format_exc())
        if result['run_completed']:
            result['valid_for_comparison'] = False
    finally:
        result['finished'] = now()
        result['elapsed_seconds'] = time.monotonic() - started
        result['attempts'] = [dict(attempt_id=attempt_id, started=result['started'], finished=result['finished'],
            elapsed_seconds=result['elapsed_seconds'], terminal_status=result['terminal_status'],
            reason=result['reason'], flows=[str(flow.folder) for flow in context['flows']])]
        result['tool_jobs'] = [job for flow in context['flows'] for job in flow.jobs]
        result['evidence']['result'] = str(attempt / 'result.json')
        save(attempt / 'result.json', result)
    print(json.dumps(dict(experiment_id=result['experiment_id'], terminal_status=result['terminal_status'],
                          result=result['evidence']['result']), ensure_ascii=False), flush=True)
    return 0 if result['terminal_status'] == 'completed' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    item = sub.add_parser('worker')
    item.add_argument('--config', type=Path, required=True)
    args = parser.parse_args()
    return worker(args.config)


if __name__ == '__main__':
    raise SystemExit(main())
