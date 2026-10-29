"""T64: serial official coverage entry, immutable provenance and UCDB reports.

No HDL, existing runner, test list, thresholds or global setting is changed.
The detached worker owns the eight-hour deadline and its own process tree.
"""
import argparse
from collections import Counter, defaultdict
import csv
from datetime import datetime, timedelta, timezone
import hashlib
import json
import msvcrt
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback
import uuid

import psutil

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'out/t64'
EVIDENCE = ROOT / 'docs/evidence/t64_f1_coverage'
FROZEN = 'e5cd815020448820c2de7c587f288554defb74bc'
MS = Path('E:/Verilog/ModelSim/setup_pack/win64')
PYTHON = Path('E:/anaconda3/python.exe')
TZ8 = timezone(timedelta(hours=8))
GIB = 1024 ** 3
NATIVE = {'vsim.exe', 'vsimk.exe', 'vish.exe', 'vlog.exe', 'vlib.exe', 'vopt.exe', 'vcover.exe'}


def now():
    return datetime.now().astimezone().isoformat()


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    os.replace(temp, path)


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest().upper()


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, encoding='utf-8').strip()


def relative(path):
    return Path(path).resolve().relative_to(ROOT).as_posix()


def identity(process):
    return dict(pid=process.pid, created=process.create_time(),
                command=process.cmdline(), cwd=process.cwd())


def alive(item):
    try:
        process = psutil.Process(item['pid'])
        return process.create_time() == item['created']
    except psutil.NoSuchProcess:
        return False


def processes():
    rows = []
    for process in psutil.process_iter(['name']):
        name = (process.info['name'] or '').lower()
        if name in NATIVE or name in {'python.exe', 'elinx_synthesis.exe', 'implementation.exe', 'quartus_map.exe'}:
            try:
                rows.append(dict(name=name, **identity(process)))
            except psutil.NoSuchProcess:
                pass
            except psutil.AccessDenied:
                rows.append(dict(name=name, pid=process.pid, inaccessible=True))
    return rows


def slots(rows):
    # Count a GUI/CLI launcher with its kernel once, as in F1's controlled entry.
    kernel_parents = set()
    for row in rows:
        if row['name'] == 'vsimk.exe':
            try:
                kernel_parents.add(psutil.Process(row['pid']).ppid())
            except psutil.NoSuchProcess:
                pass
    return sum(row['name'] in NATIVE and row['pid'] not in kernel_parents for row in rows)


def cases():
    rows = []
    for line in (ROOT / 'sim/tests.txt').read_text(encoding='utf-8-sig').splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.strip().split('|')
        params = fields[1].split(',') if len(fields) > 1 and fields[1] else []
        rows.append(dict(index=len(rows), test=fields[0], parameters=params,
                         key=[fields[0], sorted(params), 2, 20261007]))
    if len(rows) != 40 or len({json.dumps(x['key']) for x in rows}) != 40:
        raise RuntimeError('Expected exactly 40 unique frozen cases')
    return rows


def diagnostics(folder):
    result = dict(Error=0, Fatal=0, Warning=0, FAIL=0, RAMCOLL=0)
    for path in Path(folder).glob('*.log'):
        text = path.read_text(encoding='utf-8-sig', errors='replace')
        for kind in ('Error', 'Fatal', 'Warning'):
            result[kind] += len(re.findall(r'(?m)^\s*(?:#\s*)?\*\* ' + kind + r'(?:\s*\([^)]*\))?:', text))
        for kind in ('FAIL', 'RAMCOLL'):
            result[kind] += len(re.findall(r'\b' + kind + r'\b', text))
    return result


def verify_files(manifest):
    changed = [name for name, digest in manifest.items()
               if not (ROOT / name).is_file() or sha(ROOT / name) != digest]
    if changed:
        raise RuntimeError('Frozen files changed: ' + repr(changed))


def preflight(folder):
    if git('rev-parse', 'HEAD') != FROZEN or git('branch', '--show-current') != 't63':
        raise RuntimeError('Wrong branch or frozen HEAD; no checkout is performed')
    status = git('status', '--porcelain=v1')
    unexpected = [line for line in status.splitlines() if line[3:] != 'tools/t64_coverage.py']
    if unexpected:
        raise RuntimeError('Unexpected original working-tree changes: ' + repr(unexpected))
    observed = processes()
    conflicts = [r for r in observed if r.get('cwd', '').lower() == str(ROOT).lower()
                 and r['pid'] != os.getpid() and 't64_coverage.py' not in ' '.join(r.get('command', []))]
    if conflicts:
        raise RuntimeError('Other target-worktree execution is active: ' + repr(conflicts))
    memory = psutil.virtual_memory().available
    disk = shutil.disk_usage(ROOT).free
    if memory < 5 * GIB or disk < 8 * GIB or slots(observed) >= 10:
        raise RuntimeError('Preflight resource guard: 5 GiB RAM, 8 GiB disk, <10 existing ModelSim slots required')
    registry = []
    for path in (ROOT / 'out/coord/admission.json', ROOT / 'out/t63/coord/admission.json'):
        if path.exists():
            data = load(path)
            live = [r for r in data.get('leases', []) if alive(r['owner'])]
            registry.append(dict(path=relative(path), sha256=sha(path), live_leases=live))
            if live:
                raise RuntimeError('Existing live admission lease')
    names = git('ls-files', '-z').split('\x00')
    originals = {n: sha(ROOT / n) for n in names if n and (ROOT / n).is_file()}
    versions = {}
    for name in ('vsim.exe', 'vlog.exe', 'vcover.exe'):
        exe = MS / name
        versions[name] = dict(path=str(exe), sha256=sha(exe), bytes=exe.stat().st_size,
                             modified=exe.stat().st_mtime,
                             version=subprocess.check_output([str(exe), '-version'], text=True).strip())
    versions['python'] = dict(path=str(PYTHON), sha256=sha(PYTHON), version=sys.version,
                              modified=PYTHON.stat().st_mtime)
    units = {}
    for path in sorted((ROOT / 'rtl').glob('*.v')):
        for module in re.findall(r'(?m)^module\s+(\w+)', path.read_text(encoding='utf-8-sig')):
            if module in units:
                raise RuntimeError('Duplicate RTL design unit: ' + module)
            units[module] = relative(path)
    result = dict(head=FROZEN, branch='t63', started=now(), started_utc8=datetime.now(TZ8).isoformat(),
                  worktree=str(ROOT), status=status, owner=identity(psutil.Process()),
                  observed_processes=observed, modelsim_slots=slots(observed),
                  available_memory_bytes=memory, disk_free_bytes=disk, registry=registry,
                  original_files=originals, units=units, rtl_file_count=29,
                  versions=versions, cases=cases(), tool_sha256=sha(__file__),
                  environment=dict(AFDX_CE_DIV='2', seed=20261007,
                                   AFDX_PYTHON=str(PYTHON), MODELSIM_HOME=str(MS),
                                   AFDX_MEM_LIMIT_GB=os.environ.get('AFDX_MEM_LIMIT_GB', '10'),
                                   AFDX_MEM_FLOOR_GB=os.environ.get('AFDX_MEM_FLOOR_GB', '5')))
    save(folder / 'freeze.json', result)
    return result


def reuse(folder, frozen):
    old = load(ROOT / 'sim/reference/regression.json')
    if old['SourceCommit'] != '92ab7d7ea0dd5ad3db443eb5b2d7aa7afd613516' or old['CE_DIV'] != 2:
        raise RuntimeError('Unexpected ordinary F1 reference')
    pp = load(ROOT / 'docs/evidence/t63_f1b_preprocess.json')
    pp_root = ROOT / 'out/t63/F1b/preprocess'
    tb_names = [n for n in frozen['original_files'] if n.startswith('tb/') and Path(n).suffix in {'.v', '.vh'}]
    for name in tb_names:
        if (pp_root / 'current' / name).read_bytes() != (ROOT / name).read_bytes():
            raise RuntimeError('F1b preprocessor evidence no longer covers ' + name)
        baseline = subprocess.check_output(['git', 'show', old['SourceCommit'] + ':' + name], cwd=ROOT)
        if baseline != (pp_root / 'baseline' / name).read_bytes():
            raise RuntimeError('F1 source does not match saved preprocess baseline: ' + name)
    for row in pp['runs']:
        mode = row['mode']
        for version, field in (('baseline', 'baseline_sha256'), ('current', 'current_sha256')):
            p = pp_root / version / (mode + '_effective.v')
            if sha(p).lower() != row[field].lower():
                raise RuntimeError('Saved effective HDL hash mismatch')
        if not row['equal'] or row['baseline_sha256'] != row['current_sha256']:
            raise RuntimeError('Effective HDL differs')
    if git('diff', old['SourceCommit'], FROZEN, '--', 'rtl', 'tools/eda.py', 'sim/tests.txt',
           'sim/run.ps1', 'sim/regress.ps1'):
        raise RuntimeError('Unexpected RTL or simulation semantics difference')
    prior_inputs = load(ROOT / 'out/t63/F1_final_v2/inputs.json')['files']
    for name in frozen['original_files']:
        if name.startswith(('rtl/', 'tools/')) and name not in {'tools/t62_runtime.py', 'tools/t63_verify_gui.py'}:
            if name not in prior_inputs or frozen['original_files'][name] != prior_inputs[name]:
                raise RuntimeError('F1 runner/generator/checker dependency differs: ' + name)
    matrix = []
    for case, row in zip(frozen['cases'], old['Runs']):
        key = [row['Test'], sorted(filter(None, row['Param'].split(','))), 2, 20261007]
        if key != case['key']:
            raise RuntimeError('Ordinary reference case identity mismatch')
        p = ROOT / row['Folder'] / 'summary.json'
        summary = load(p)
        diff = [relative(x['path']) for x in summary['inputs'] if sha(x['path']) != x['sha256'].upper()]
        if set(diff) != {'tb/lib/sys_endpoint.v', 'tb/lib/top_stream_endpoint.v'}:
            raise RuntimeError('Unexpected ordinary dependency difference')
        if not summary.get('passed') or summary['ce_div'] != 2 or sorted(summary['parameters']) != key[1]:
            raise RuntimeError('Ordinary result is not valid for requested case')
        compile_job = next(j for j in summary['jobs'] if j['name'] == 'compile')
        if '+define+AFDX_CE_DIV=2' not in compile_job['command'] or any('NETLIST' in v for v in compile_job['command']):
            raise RuntimeError('Ordinary macro/configuration differs')
        for job in summary['jobs']:
            if job['name'] == 'vectors' and '--seed' in job['command']:
                if job['command'][job['command'].index('--seed') + 1] != '20261007':
                    raise RuntimeError('Ordinary vector seed mismatch')
        log = (p.parent / 'compile.log').read_text(encoding='utf-8-sig')
        if frozen['versions']['vlog.exe']['version'] not in log:
            raise RuntimeError('Ordinary compiler version differs')
        diag = diagnostics(p.parent)
        if any(diag.values()):
            raise RuntimeError('Ordinary diagnostics nonzero')
        matrix.append(dict(**case, decision='reusable', source=relative(p), sha256=sha(p),
                           dependency_count=len(summary['inputs']), byte_changed=diff,
                           effective_hdl_equal=True, macros=['AFDX_CE_DIV=2'], diagnostics=diag,
                           checks=summary['checks'], check_items=summary.get('check', {}).get('items'),
                           reason='Only F1b inactive SYS_TOP_NETLIST branches changed; saved full CE2 effective HDL matches; unchanged RTL, vectors, checkers, seed and compiler version'))
    evidence = dict(source_commit=old['SourceCommit'], current_commit=FROZEN,
                    source_reference_sha256=sha(ROOT / 'sim/reference/regression.json'),
                    preprocess_source='docs/evidence/t63_f1b_preprocess.json',
                    preprocess_sha256=sha(ROOT / 'docs/evidence/t63_f1b_preprocess.json'),
                    full_tb_files_verified=len(tb_names), cases=matrix, supplement_cases=[],
                    runner_difference='t62_runtime only changed registry default and opt-in environment configuration guard; simulation command generation in tools/eda.py is unchanged',
                    environment_limit='Old executable hashes were not recorded; saved compiler version and executable paths match, and current executable modification times predate the ordinary run. Current hashes are frozen for this batch.')
    save(folder / 'reuse.json', evidence)
    return evidence


def terminate_owned(owned):
    actions = []
    for item in reversed(list(owned.values())):
        match = alive(item)
        if match:
            try:
                psutil.Process(item['pid']).kill()
            except psutil.NoSuchProcess:
                match = False
        actions.append(dict(identity=item, killed=match))
    return actions


def run(folder):
    # An OS byte-range lock and one persistent current.json prevent duplicate owners.
    with (BASE / 'execution.lock').open('a+b') as lock:
        lock.seek(0)
        lock.write(b'0')
        lock.flush()
        lock.seek(0)
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        start = time.monotonic()
        state = dict(status='preflight', owner=identity(psutil.Process()), folder=relative(folder), started=now())
        save(folder / 'state.json', state)
        try:
            frozen = preflight(folder)
            reuse(folder, frozen)
            verify_files(frozen['original_files'])
            deadline = datetime.now().astimezone() + timedelta(hours=8)
            env = os.environ.copy()
            # regress.ps1 reads the standard latest pointers after each serial
            # case; a custom prefix would silently select unrelated old data.
            prefix = ''
            env.update(AFDX_PYTHON=str(PYTHON), MODELSIM_HOME=str(MS), AFDX_CE_DIV='2',
                       AFDX_LATEST_PREFIX=prefix, PYTHONDONTWRITEBYTECODE='1')
            command = ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                       '-File', str(ROOT / 'sim/regress.ps1'), '-Coverage', '-Seed', '20261007',
                       '-Deadline', deadline.isoformat()]
            before = set((ROOT / 'out/regress').glob('coverage_*'))
            owned = {}
            stop_reason = None
            minimum_memory = psutil.virtual_memory().available
            minimum_disk = shutil.disk_usage(ROOT).free
            with (folder / 'regression.log').open('xb') as stream:
                process = psutil.Popen(command, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                       stdout=stream, stderr=subprocess.STDOUT,
                                       creationflags=subprocess.CREATE_NO_WINDOW)
                owned[process.pid] = identity(process)
                state.update(status='running', command=command, worker=owned[process.pid],
                             deadline=deadline.isoformat(), latest_prefix=prefix, owned_processes=list(owned.values()))
                save(folder / 'state.json', state)
                saved = time.monotonic()
                while process.poll() is None:
                    try:
                        children = [process] + process.children(recursive=True)
                    except psutil.NoSuchProcess:
                        children = []
                    for child in children:
                        try:
                            owned[child.pid] = identity(child)
                        except psutil.NoSuchProcess:
                            pass
                    minimum_memory = min(minimum_memory, psutil.virtual_memory().available)
                    minimum_disk = min(minimum_disk, shutil.disk_usage(ROOT).free)
                    if datetime.now().astimezone() >= deadline:
                        stop_reason = 'whole_batch_8h_deadline'
                    elif minimum_disk < 8 * GIB:
                        stop_reason = 'disk_below_8gib'
                    if stop_reason:
                        state['termination_actions'] = terminate_owned(owned)
                        process.wait(timeout=15)
                        break
                    if time.monotonic() - saved >= 30:
                        state.update(updated=now(), elapsed_seconds=time.monotonic() - start,
                                     owned_processes=list(owned.values()), minimum_memory_bytes=minimum_memory,
                                     minimum_disk_bytes=minimum_disk)
                        save(folder / 'state.json', state)
                        saved = time.monotonic()
                    time.sleep(1)
            batches = set((ROOT / 'out/regress').glob('coverage_*')) - before
            state.update(exit_code=process.returncode, stop_reason=stop_reason, regression_finished=now(),
                         minimum_memory_bytes=minimum_memory, minimum_disk_bytes=minimum_disk,
                         owned_processes=list(owned.values()))
            if len(batches) != 1:
                raise RuntimeError('Expected one unique official batch directory: ' + repr(batches))
            batch = batches.pop()
            state['batch_summary'] = relative(batch / 'summary.json')
            save(folder / 'state.json', state)
            verify_files(frozen['original_files'])
            if process.returncode or stop_reason:
                raise RuntimeError('Regression failed or stopped; all attempts preserved')
            data = load(batch / 'summary.json')
            if len(data['Runs']) != 40 or any(x['Status'] != 'PASS' or x['Exit'] for x in data['Runs']):
                raise RuntimeError('Official regression is incomplete or not all PASS')
            collect(folder, batch / 'summary.json')
            state.update(status='reports_ready', completed=True)
        except Exception:
            state.update(status='failed', completed=False, error=traceback.format_exc())
            (folder / 'exception.txt').write_text(state['error'], encoding='utf-8')
        finally:
            state.update(finished=now(), finished_utc8=datetime.now(TZ8).isoformat(),
                         seconds=time.monotonic() - start)
            save(folder / 'state.json', state)
            msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            print(json.dumps(dict(status=state['status'], folder=str(folder), seconds=state['seconds'])), flush=True)
        return 0 if state['status'] == 'reports_ready' else 1


def vcover(folder, label, arguments):
    command = [str(MS / 'vcover.exe'), *map(str, arguments)]
    p = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=600, creationflags=subprocess.CREATE_NO_WINDOW)
    text = p.stdout.decode('utf-8', errors='replace')
    (folder / (label + '.log')).write_text(text, encoding='utf-8')
    if p.returncode or re.search(r'(?m)^\s*\*\* (?:Error|Fatal):', text):
        raise RuntimeError('vcover ' + label + ' failed; raw log retained')
    return text


def output_files(folder):
    ignored = {'summary.json', 'tool_metrics.json', 'active_job.json', 'waiting_resource.json',
               'run.do', 'simulation.wlf', 'coverage.ucdb', 'modelsim.ini', 'transcript'}
    return {p.relative_to(folder).as_posix(): p for p in folder.rglob('*')
            if p.is_file() and not p.relative_to(folder).parts[0] in {'work', 'sources'}
            and p.name not in ignored and p.suffix != '.log'}


def collect(folder, summary_path):
    frozen = load(folder / 'freeze.json')
    reference = load(folder / 'reuse.json')
    batch = load(summary_path)
    reports = folder / 'reports'
    reports.mkdir(exist_ok=True)
    inputs = []
    rows = []
    for case, result, reused in zip(frozen['cases'], batch['Runs'], reference['cases']):
        if case['key'] != [result['Test'], sorted(filter(None, (result['Param'] or '').split(','))), 2, 20261007]:
            raise RuntimeError('Coverage batch identity/order mismatch')
        current = Path(result['Folder'])
        summary = load(current / 'summary.json')
        if not summary['passed'] or summary['ce_div'] != 2 or summary['code_coverage']['metrics'] != 'sbceft':
            raise RuntimeError('Invalid coverage result')
        ucdb = Path(result['Ucdb'])
        if ucdb != current / 'coverage.ucdb' or ucdb != Path(summary['code_coverage']['ucdb']):
            raise RuntimeError('UCDB origin mismatch')
        label = f"{case['index']:02d}_{case['test']}"
        names = vcover(reports, label + '_testnames', ['testnames', ucdb])
        if case['test'] + '_' + current.name not in names:
            raise RuntimeError('UCDB test identity mismatch')
        vcover(reports, label + '_summary', ['report', '-code', 'bcesft', '-showenabledcodecov', ucdb])
        compile_rtl = next(j for j in summary['jobs'] if j['name'] == 'compile_rtl')['command']
        compile_tb = next(j for j in summary['jobs'] if j['name'] == 'compile')['command']
        sim = next(j for j in summary['jobs'] if j['name'] == 'simulation')
        if '+cover=sbceft' not in compile_rtl or any('+cover=' in arg for arg in compile_tb):
            raise RuntimeError('RTL/TB instrumentation differs from requested scope')
        if '-coverage' not in sim['command'] or '-batch' not in sim['command']:
            raise RuntimeError('Simulator coverage/batch option missing')
        diag = diagnostics(current)
        ordinary = ROOT / reused['source']
        old = load(ordinary)
        checks_equal = summary['checks'] == old['checks']
        items_equal = summary.get('check', {}).get('items') == old.get('check', {}).get('items')
        oldfiles = output_files(ordinary.parent)
        newfiles = output_files(current)
        comparisons = []
        for name in sorted(oldfiles.keys() | newfiles.keys()):
            a, b = oldfiles.get(name), newfiles.get(name)
            equal = a is not None and b is not None and sha(a) == sha(b)
            comparisons.append(dict(file=name, equal=equal,
                                    ordinary_sha256=sha(a) if a else None,
                                    coverage_sha256=sha(b) if b else None))
        # The deterministic output set includes vectors, raw traffic, decoded
        # protocol records, independent check reports, PCAP and R97 metrics.
        compared = checks_equal and items_equal and all(r['equal'] for r in comparisons)
        rows.append(dict(**case, passed=summary['passed'], folder=relative(current),
                         checks=summary['checks'], check_items=summary.get('check', {}).get('items'),
                         diagnostics=diag, seconds=sum(j['seconds'] for j in summary['jobs']),
                         simulation_seconds=sim['seconds'], simulation_budget_seconds=sim['budget_seconds'],
                         ordinary_source=relative(ordinary), checks_equal=checks_equal,
                         check_items_equal=items_equal, output_comparisons=comparisons,
                         all_outputs_equal=compared, summary_sha256=sha(current / 'summary.json')))
        inputs.append(dict(index=case['index'], test=case['test'], parameters=case['parameters'],
                           ucdb=relative(ucdb), sha256=sha(ucdb), bytes=ucdb.stat().st_size))
    save(folder / 'comparison.json', rows)
    save(folder / 'ucdb_inputs.json', inputs)
    if any(any(r['diagnostics'].values()) for r in rows):
        raise RuntimeError('Coverage diagnostics are nonzero; review comparison.json')
    merged = folder / 'merged.ucdb'
    vcover(reports, 'merge', ['merge', '-checkinputs', '-ucdbchecks', merged,
                              *[ROOT / row['ucdb'] for row in inputs]])
    vcover(reports, 'merged_testnames', ['testnames', merged])
    vcover(reports, 'all_units_summary', ['report', '-code', 'bcesft', '-showenabledcodecov', merged])
    for unit in frozen['units']:
        vcover(reports, unit + '_summary', ['report', '-du=work.' + unit, '-code', 'bcesft',
                                           '-showenabledcodecov', '-output', reports / (unit + '_summary.txt'), merged])
        vcover(reports, unit + '_uncovered', ['report', '-du=work.' + unit, '-code', 'bcesft',
                                             '-details', '-zeros', '-output', reports / (unit + '_uncovered.txt'), merged])
    verify_files(frozen['original_files'])
    save(folder / 'collection.json', dict(passed=all(r['all_outputs_equal'] for r in rows), input_count=len(inputs), unit_count=len(frozen['units']),
                                         merged_ucdb=relative(merged), merged_sha256=sha(merged),
                                         merged_bytes=merged.stat().st_size, source_unchanged=True,
                                         summary=relative(summary_path), finished=now()))


METRICS = ['Statements', 'Branches', 'Conditions', 'Expressions',
           'FSM States', 'FSM Transitions', 'Toggles']


def metric(covered, total):
    # Integer arithmetic makes the two-decimal truncation reproducible.
    return dict(covered=covered, total=total, missed=total-covered,
                percent=(covered * 10000 // total) / 100 if total else None)


def du_dump(folder):
    """Read only the complete native DU prefix, never instance duplicates."""
    scope = {}
    branches = []
    toggles = {}
    units = load(folder / 'freeze.json')['units']
    excerpts = []

    def consume(block):
        nonlocal scope
        text = ''.join(block)
        pairs = dict(re.findall(r'^\s*(Name|Type|Count|Flags)\s*:\s*(.*?)\s*$', text, re.M))
        src = re.search(r'File info\s*:\s*name = (.*?) line = (\d+)', text)
        if src:
            pairs.update(source=src[1], line=int(src[2]))
        if block[0].strip().endswith('Scope -'):
            scope = dict(**pairs, raw=text)
            if pairs.get('Type') == 'UCDB_TOGGLE':
                toggles[pairs['Name']] = pairs.get('line')
            return
        if not text.startswith('Cover item -') or pairs.get('Type') != 'UCDB_BRANCHBIN' or pairs.get('Count') != '0':
            return
        match = re.match(r'work\.(\w+)(?:::|/|$)', scope.get('Name', ''))
        if not match or match[1] not in units:
            return
        start = len(excerpts) + 1
        excerpts.extend((scope['raw'] + text).splitlines())
        branches.append(dict(unit=match[1], metric='Branches', source=units[match[1]],
                             source_line=pairs['line'], item=scope['Name'] + '/' + pairs['Name'], bins=1,
                             report='branch_uncovered_native.txt', report_line=start,
                             report_end=len(excerpts)))

    block = []
    with (folder / 'du_native_dump.txt').open(encoding='utf-8') as stream:
        for line in stream:
            if line.strip().endswith('Scope -') or line.startswith('Cover item -'):
                if block:
                    consume(block)
                block = [line]
            else:
                block.append(line)
    if block:
        consume(block)
    (EVIDENCE / 'branch_uncovered_native.txt').write_text('\n'.join(excerpts) + '\n', encoding='utf-8')
    return branches, toggles


def uncovered_index(folder, units):
    index, toggles = du_dump(folder)
    for unit, source in units.items():
        path = folder / 'reports' / (unit + '_uncovered.txt')
        section = None
        source_line = None
        fsm = None
        for number, line in enumerate(path.read_text(encoding='utf-8-sig').splitlines(), 1):
            heading = re.match(r'^(\w+) Coverage:$', line)
            if heading:
                section = heading[1]
            header = re.match(r'^Line\s+(\d+) Item\s+(\d+)\s+(.*)', line)
            if header:
                source_line = int(header[1])
            if line.startswith('FSM_ID: '):
                fsm = line.split(': ', 1)[1]
            item = None
            count = 1
            if section in {'Condition', 'Expression'}:
                missed = re.match(r'^\s*(.*?)\s+N\s{2,}(.*)', line)
                if missed:
                    item = missed[1] + ' | ' + missed[2].strip()
            elif section == 'Statement':
                missed = re.match(r'^\s+(\d+)\s+(\d+)\s*$', line)
                if missed:
                    source_line = int(missed[1])
                    item = 'item ' + missed[2]
            elif section == 'FSM':
                missed = re.match(r'^\s*(\d+)\s+(\d+)\s+(\S+\s+->\s+\S+)', line)
                if missed:
                    source_line = int(missed[1])
                    item = fsm + ': ' + missed[3].strip() + ' [Trans_ID=' + missed[2] + ']'
            elif section == 'Toggle':
                missed = re.match(r'^\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+\.\d+)\s*$', line)
                if missed:
                    node = missed[1]
                    low, high = map(int, missed.group(2, 3))
                    width = 1
                    for left, right in re.findall(r'\[(\d+)-(\d+)\]', node):
                        width *= abs(int(left) - int(right)) + 1
                    count = width * ((low == 0) + (high == 0))
                    sample = re.sub(r'\[(\d+)-\d+\]', r'[\1]', node)
                    source_line = toggles.get('work.' + unit + '::' + sample)
                    # These unused high FSM bits are printed by the report but
                    # omitted from the optimized DU dump. Bind the actual reg
                    # declaration, retaining both missed direction bins.
                    if source_line is None:
                        source_line = {('afdx_rx_parse', 'length_phase[2]'):116,
                                       ('afdx_tx_free', 'phase[2]'):46}.get((unit, node))
                    item = node + ' | missing ' + ', '.join(
                        direction for direction, missing in [('1->0', low == 0), ('0->1', high == 0)] if missing)
            if item is not None:
                index.append(dict(unit=unit, metric={'FSM': 'FSM Transitions'}.get(section, section + 's'),
                                  source=source, source_line=source_line, item=item, bins=count,
                                  report=path.name, report_line=number, report_end=number))
    return index


def classify_gap(row):
    u, n, m, item = row['unit'], row['source_line'], row['metric'], row['item']
    reset_lines = dict(afdx_app_tx=126, afdx_app_rx=68, afdx_mac_tx=81,
                       afdx_ntp_fraction=37, afdx_rx_deliver=63, afdx_rx_engine=338,
                       afdx_tx_buf=100, afdx_tx_engine=220, afdx_tx_free=80, afdx_snmp=326)
    if m == 'FSM Transitions':
        if reset_lines.get(u) == n or (u == 'afdx_snmp_engine' and n == 2062) or (u == 'afdx_615a_engine' and n == 2265):
            return 'A', 'R01'
        if u == 'afdx_rtc' and n in {932, 940}:
            return 'A', 'R02'
        if u == 'afdx_snmp_engine' and n in {1473, 1481}:
            return 'C', 'F01'
        if u == 'afdx_615a_engine':
            return 'U', 'F02'
        if u == 'afdx_rtc' and n == 731:
            return 'U', 'F03'
        return 'U', 'F04'
    if u == 'afdx_ram_sdp' and n in {14, 15, 16}:
        return 'C', 'C01'
    if u == 'afdx_crc32_d8' and 'bit_index' in item:
        return 'C', 'C02'
    if u == 'afdx_tx_free' and n == 52 and m == 'Expressions':
        return 'C', 'C03'
    if m == 'Toggles' and ((u == 'afdx_rx_parse' and item.startswith('length_phase[2] |'))
                          or (u == 'afdx_tx_free' and item.startswith('phase[2] |'))):
        return 'B', 'B04'
    padding = constant_padding(row)
    if padding and padding['low'] >= padding['boundary']:
        return 'B', 'B05'
    if u == 'afdx_615a_engine' and n in {1764, 1765, 1769, 1770, 1774, 1775, 1779, 1780}:
        return 'B', 'B01'
    if (u, n) in {('afdx_app_tx', 173), ('afdx_app_rx', 81), ('afdx_ntp_fraction', 85), ('afdx_rx_engine', 593)} and m in {'Statements', 'Branches'}:
        return 'B', 'B02'
    if u == 'afdx_ram_sdp' and n in {47, 48} and m != 'Toggles':
        return 'A', 'A08'
    if (u == 'afdx_app_tx' and n is not None and 79 <= n <= 90) or (u == 'afdx_app_rx' and n in {54, 55}):
        return 'A', 'A01'
    if u == 'afdx_rx_engine' and n in {556, 557} and m in {'Statements', 'Branches'}:
        return 'A', 'A02'
    if u == 'afdx_snmp_engine' and n in {1090, 1140, 1141, 1142, 1181, 1182, 1183}:
        return 'A', 'A03'
    if u == 'afdx_615a_engine' and n in {1462, 1463, 1464, 1465, 1515, 1548, 1550, 1551, 1553,
            1571, 1572, 1573, 1588, 1589, 1590, 1974, 1982, 1986, 1994, 2029, 2030,
            2110, 2114, 2140, 2161, 2165, 2169, 2177, 2187, 2216} and m in {'Statements', 'Branches'}:
        return 'A', 'A04'
    if u == 'afdx_rtc' and n in {458, 459, 460, 461, 463, 464, 807, 808, 809, 810, 811}:
        return 'A', 'A05'
    if u == 'afdx_timebase' and m == 'Toggles':
        return 'A', 'A06'
    if m == 'Toggles':
        node = item.split(' |', 1)[0].split('[', 1)[0]
        counter_names = dict(afdx_snmp_engine={'traps_sent','next_traps_sent','bad_community','next_bad_community'},
                             afdx_snmp={'requests','uptime','uptime_cycles'},
                             afdx_615a_engine={'retry_total','next_retry_total'}, afdx_rtc={'sync_count'})
        if (u == 'afdx_cfg' and node.startswith('count_')) or node in counter_names.get(u, set()):
            return 'A', 'A09'
    if u == 'afdx_rtc' and n is not None and 420 <= n <= 432 and m in {'Statements', 'Branches'}:
        return 'A', 'A07'
    if u == 'afdx_tx_builder' and n in {422, 478}:
        return 'U', 'U01'
    return 'U', 'U00'


def constant_padding(row):
    if row['metric'] != 'Toggles' or not row['source_line']:
        return None
    declaration = (ROOT / row['source']).read_text(encoding='utf-8-sig').splitlines()[row['source_line']-1]
    match = re.search(r"wire\s*\[(\d+):0\]\s*(\w+)\s*=\s*\{(\d+)'b0,", declaration)
    node = re.match(r'^(\w+)\[(\d+)(?:-(\d+))?\]( \|.*)$', row['item'])
    if not match or not node or match[2] != node[1]:
        return None
    return dict(name=node[1],low=int(node[2]),high=int(node[3] or node[2]),
                boundary=int(match[1])+1-int(match[3]),suffix=node[4])


def publish(folder):
    frozen = load(folder / 'freeze.json')
    verify_files(frozen['original_files'])
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    units = frozen['units']
    module_metrics = {}
    for unit in units:
        text = (folder / 'reports' / (unit + '_summary.txt')).read_text()
        matches = re.findall(r'^    (Branches|Conditions|Expressions|FSM States|FSM Transitions|Statements|Toggles)\s+(\d+)\s+(\d+)\s+(\d+)\s+([0-9.]+)%', text, re.M)
        metrics = {}
        for name, total, hits, misses, percent in matches:
            value = metric(int(hits), int(total))
            if value['missed'] != int(misses):
                raise RuntimeError('Raw summary count arithmetic failed')
            metrics[name] = value
        if set(metrics) != set(METRICS):
            raise RuntimeError('Missing summary metric')
        metrics['FSM'] = metric(metrics['FSM States']['covered'] + metrics['FSM Transitions']['covered'],
                                metrics['FSM States']['total'] + metrics['FSM Transitions']['total'])
        module_metrics[unit] = metrics
    total = {name: metric(sum(values[name]['covered'] for values in module_metrics.values()),
                          sum(values[name]['total'] for values in module_metrics.values()))
             for name in [*METRICS, 'FSM']}
    all_units = set(re.findall(r'=== Design Unit: work\.(\w+)', (folder / 'reports/all_units_summary.log').read_text()))
    if all_units != set(units):
        raise RuntimeError('Instrumented DU union differs from current RTL units')
    index = []
    for row in uncovered_index(folder, units):
        padding = constant_padding(row)
        if padding and padding['low'] < padding['boundary'] <= padding['high']:
            directions = row['bins'] // (padding['high']-padding['low']+1)
            for low, high in [(padding['low'],padding['boundary']-1), (padding['boundary'],padding['high'])]:
                bits = str(low) if low == high else str(low)+'-'+str(high)
                index.append(dict(row, item=padding['name']+'['+bits+']'+padding['suffix'],
                                  bins=(high-low+1)*directions))
        else:
            index.append(row)
    source_texts = {name: (ROOT / name).read_text(encoding='utf-8-sig').splitlines() for name in units.values()}
    for number, row in enumerate(index, 1):
        row['id'] = f'T64-{number:04d}'
        row['classification'], row['analysis_group'] = classify_gap(row)
        row['source_text'] = source_texts[row['source']][row['source_line']-1] if row['source_line'] else None
    missing_locations = [x['id'] for x in index if not x['source_line']]
    if missing_locations:
        raise RuntimeError('Unresolved source locators: ' + repr(missing_locations))
    reconciled = {}
    for unit in units:
        observed = Counter()
        for row in index:
            if row['unit'] == unit:
                observed[row['metric']] += row['bins']
        expected = {name: module_metrics[unit][name]['missed'] for name in METRICS}
        if any(observed[name] != count for name, count in expected.items()):
            raise RuntimeError('Uncovered index does not reconcile for ' + unit + ': ' + repr((observed, expected)))
        reconciled[unit] = expected
    comparisons = load(folder / 'comparison.json')
    names_text = (folder / 'reports/merged_testnames.log').read_text()
    expected_names = {row['test'] + '_' + Path(row['folder']).name for row in comparisons}
    actual_names = {s.strip() for s in names_text.splitlines() if re.fullmatch(r'tb_\w+_\d{8}_\d{6}_\d+', s.strip())}
    if actual_names != expected_names or len(actual_names) != 40:
        raise RuntimeError('Merged UCDB test set differs from the 40 successful attempts')
    save(EVIDENCE / 'coverage.json', dict(source_commit=FROZEN, ce_div=2, seed=20261007,
         rtl_files=29, rtl_design_units=29, units=units, metrics=total, modules=module_metrics,
         aggregation='Sum each source design unit once; numerator=covered bins, denominator=all bins; no instance averaging, no exclusions; FSM=states+transitions',
         rounding='Truncate to two decimal places using integer arithmetic; zero denominator is N/A',
         index_reconciled=True, index_rows=len(index), index_missed_bins={k:total[k]['missed'] for k in METRICS},
         category_bins=dict(Counter({c:sum(x['bins'] for x in index if x['classification']==c) for c in ['A','B','C','U']}))))
    with (EVIDENCE / 'uncovered_index.csv').open('w', encoding='utf-8', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(index[0]))
        writer.writeheader()
        writer.writerows(index)
    with (EVIDENCE / 'modules.csv').open('w', encoding='utf-8', newline='') as stream:
        fields = ['unit', 'source'] + [name + '_' + field for name in [*METRICS, 'FSM'] for field in ['covered','total','percent']]
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for unit, values in module_metrics.items():
            writer.writerow(dict(unit=unit, source=units[unit], **{name+'_'+field: values[name][field] for name in [*METRICS,'FSM'] for field in ['covered','total','percent']}))
    for name in ['freeze.json','reuse.json','comparison.json','ucdb_inputs.json','collection.json']:
        shutil.copyfile(folder / name, EVIDENCE / name)
    raw = EVIDENCE / 'raw'
    raw.mkdir(exist_ok=True)
    for path in (folder / 'reports').iterdir():
        if path.name.endswith(('_summary.txt','_uncovered.txt','_testnames.log')) or path.name == 'merge.log':
            (raw / path.name).write_text(path.read_text(encoding='utf-8-sig'), encoding='utf-8')
    # report entries are relative to the evidence directory.
    index_path = EVIDENCE / 'uncovered_index.csv'
    content = index_path.read_text(encoding='utf-8')
    for unit in units:
        content = content.replace(',' + unit + '_uncovered.txt,', ',raw/' + unit + '_uncovered.txt,')
    index_path.write_text(content, encoding='utf-8')
    save(EVIDENCE / 'index_validation.json', dict(passed=True, by_module=reconciled,
         categories={c:dict(rows=sum(x['classification']==c for x in index),bins=sum(x['bins'] for x in index if x['classification']==c)) for c in ['A','B','C','U']},
         groups={g:dict(rows=sum(x['analysis_group']==g for x in index),bins=sum(x['bins'] for x in index if x['analysis_group']==g)) for g in sorted({x['analysis_group'] for x in index})},
         full_source_locations=True, merged_test_names=sorted(actual_names), original_files_unchanged=True))
    print(json.dumps(dict(metrics=total,index_rows=len(index),groups=load(EVIDENCE/'index_validation.json')['groups']), ensure_ascii=False))


def launch():
    BASE.mkdir(parents=True, exist_ok=True)
    current = BASE / 'current.json'
    if current.exists():
        raise RuntimeError('T64 already has a unique run. Inspect current.json and process identities; never relaunch blindly.')
    folder = BASE / datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    folder.mkdir()
    current.write_text(json.dumps(dict(folder=relative(folder), created=now()), indent=2) + '\n', encoding='utf-8')
    flags = subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_BREAKAWAY_FROM_JOB
    with (folder / 'worker.stdout.log').open('xb') as out, (folder / 'worker.stderr.log').open('xb') as err:
        child = psutil.Popen([str(PYTHON), '-B', '-u', '-X', 'utf8', str(Path(__file__).resolve()),
                              'run', '--folder', str(folder)], cwd=ROOT, stdin=subprocess.DEVNULL,
                             stdout=out, stderr=err, close_fds=True, creationflags=flags)
        record = dict(owner=identity(child), launcher=identity(psutil.Process()), folder=relative(folder),
                      started=now(), creationflags=flags,
                      purpose='One native serial regression worker; no heartbeat, task scheduler or model continuation')
        save(folder / 'launch.json', record)
        save(current, record)
    print(json.dumps(record, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('entry', choices=['launch', 'run', 'collect', 'wait', 'publish'])
    parser.add_argument('--folder', type=Path)
    parser.add_argument('--summary', type=Path)
    args = parser.parse_args()
    if args.entry == 'launch':
        launch()
        return 0
    folder = args.folder or ROOT / load(BASE / 'current.json')['folder']
    if args.entry == 'run':
        return run(folder)
    if args.entry == 'collect':
        collect(folder, args.summary or ROOT / load(folder / 'state.json')['batch_summary'])
        return 0
    if args.entry == 'publish':
        publish(folder)
        return 0
    launch_record = load(folder / 'launch.json')
    if alive(launch_record['owner']):
        psutil.Process(launch_record['owner']['pid']).wait()
    state = load(folder / 'state.json')
    print(json.dumps(state, ensure_ascii=False))
    return 0 if state['status'] == 'reports_ready' else 1


if __name__ == '__main__':
    raise SystemExit(main())
