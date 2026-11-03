"""T77 delivery reproduction: fresh official pack/timing/locked route from VQM.

No quartus_map, no existing ECP reuse, no lock edits, no optimization or retry.
The two requested tests run serially, each bounded by 3600 seconds.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import shutil
import struct
import sys
import time

from v2_run import (ROOT, EVIDENCE, TZ, GuardedFlow, RESOURCE_CHECKS, identity,
                    protected_processes, stamp, eda, build_1030, official_synth)
import psutil
import official_impl
from t61_metrics import read_place
from synth_check import BASELINE

BASE_SHA = '3cd8f5f8456c9881d083fe67dd7a60ed9c6779909ee1cb10dbf9367dc9729b6e'
V1_SHA = 'e9e1734c570b8344c3666e02ebf1152dd45bd7a74e801d93c73de3a1126839b4'
LOCKS = ROOT / 'elinx/tiles_1030.edc'


def collect_native(flow, expected):
    output = flow.folder / 'project/AFDX_EndSystem.runs/imple_1'
    name = 'AFDX_EndSystem'
    native = dict(output=str(output), native_route_completed=False, errors=[])
    log = flow.folder / 'route.log'
    if log.exists():
        text = log.read_text(encoding='utf-8-sig', errors='replace')
        native['native_route_completed'] = 'All was well!' in text and 'BUILD1030_ROUTE_COMPLETED' in text
    edi = output / (name + '.edi')
    if edi.exists():
        native['errors'] = [line for line in edi.read_text(encoding='utf-8-sig', errors='replace').splitlines()
                            if re.search(r'\[(ERROR|CRIT)\]', line)]
    place = output / (name + '.place')
    if place.exists():
        clusters, ios = read_place(place)
        placed = {k: v[:2] for k, v in clusters.items() if k.startswith('stratix_')}
        native['locks'] = dict(expected=len(expected), placed=len(placed),
            retained=len(expected.keys() & placed.keys()),
            missing=len(expected.keys() - placed.keys()), extra=len(placed.keys() - expected.keys()),
            moved=sum(placed[k] != v for k, v in expected.items() if k in placed),
            missing_names=sorted(expected.keys() - placed.keys()),
            extra_names=sorted(placed.keys() - expected.keys()))
        pins = json.loads((ROOT / 'elinx/constraints_t62.json').read_text(encoding='utf-8-sig'))['pins']
        p0 = [dict(port=row['port'], expected=row, actual=ios.get(row['port']),
                   passed=row['port'] in ios and ios[row['port']]['package_pin'] == row['pin']
                   and ios[row['port']]['coordinates'] == row['xyz']
                   and ios[row['port']]['direction'] == row['direction']) for row in pins]
        native.update(p0_pins=p0, p0_unchanged=len(ios) == 172 and all(row['passed'] for row in p0),
                      place_sha256=eda.sha(place).lower())
    if (output / (name + '.tan.pb')).is_file() and (output / (name + '_utilization_placed.rpt')).is_file():
        resources, timing, resource_file, database = official_impl.reports(output, name)
        native.update(resources=resources, timing=timing, resources_report=str(resource_file),
                      timing_database=str(database), timing_database_sha256=eda.sha(database).lower())
    return native


def run_one(label, vqm, expected_sha, total_deadline):
    receipt = EVIDENCE / ('v2_route_' + label + '.json')
    if receipt.exists():
        raise RuntimeError('Existing test receipt; implicit rerun forbidden')
    stop = min(total_deadline, time.time() + 3600)
    flow = eda.Flow('t77_route', label, datetime.fromtimestamp(stop, TZ).isoformat())
    begin = time.monotonic()
    report = dict(label=label, started=stamp(), deadline=datetime.fromtimestamp(stop, TZ).strftime('%Y-%m-%d %H:%M:%S'),
                  budget_seconds=3600, folder=str(flow.folder), runner=identity(psutil.Process()),
                  input_vqm=str(vqm), expected_vqm_sha256=expected_sha,
                  completed=False, matches_delivery=False, route_called=False,
                  from_existing_vqm=True, fresh_pack=True, resynthesis_performed=False,
                  existing_checkpoint_reused=False, no_tiles=False, pres='1.30')
    eda.save(receipt, report)
    tile_lines, expected = build_1030.load_tile_locks(LOCKS)
    try:
        if eda.sha(vqm).lower() != expected_sha:
            raise RuntimeError('Requested VQM hash mismatch')
        home = official_synth.installation()
        project, synth, implementation, opts, directory, output, constraint = build_1030.prepare(flow, '1.30')
        imported = output / (project.stem + '.vqm')
        shutil.copy2(vqm, imported)
        if eda.sha(imported).lower() != expected_sha:
            raise RuntimeError('VQM copy mismatch')
        report.update(imported_vqm=str(imported), imported_vqm_sha256=expected_sha,
                      tile_locks_sha256=eda.sha(LOCKS).lower(), tile_locks_count=len(tile_lines),
                      source_note='prepare copied RTL for context only. No tool reads RTL in this run; native pack parses the imported VQM.',
                      constraint_sha256=eda.sha(constraint).lower(),
                      timing_sdc_sha256=eda.sha(directory / 'timing_only.sdc').lower())
        report['native_script_sha256'] = {name: eda.sha(home / 'bin/shell/bin' / name).lower()
            for name in ('run_pack.tcl', 'run_synthesized_timing.tcl', 'run_route.tcl')}
        eda.save(receipt, report)
        print('T77_ROUTE_START ' + label + ' ' + str(flow.folder), flush=True)
        official_synth.implementation_stage(flow, home, directory, output, project, synth, opts, 'pack')
        cfg = bytearray.fromhex('00000000640000000a00000003000000caf249710103000000000000000000000000000000')
        struct.pack_into('<iii', cfg, 4, 10000, 1, 2)
        (output / (project.stem + '.tr.cfg.pb')).write_bytes(cfg)
        official_synth.implementation_stage(flow, home, directory, output, project, synth, opts, 'timing')
        resources, timing, _, _ = official_synth.reports(output, project.stem)
        report.update(pack_completed=True, synth_resources=resources, synthesized_timing=timing)
        eda.save(receipt, report)
        report['route_called'] = True
        try:
            build_1030.route(flow, home, project, synth, implementation, opts, directory, output, constraint,
                             (tile_lines, expected))
        except Exception as error:
            # Read native measurements even when strict cluster verification
            # rejects the result. Never alter locks or relaunch the tool.
            report['route_wrapper_error'] = str(error)
        report['native'] = collect_native(flow, expected)
        native = report['native']
        clocks = native.get('timing', {}).get('clocks', [])
        locks = native.get('locks', {})
        locked = (locks.get('placed') == len(expected) and locks.get('retained') == len(expected)
                  and all(locks.get(k) == 0 for k in ('missing', 'extra', 'moved')))
        closed = bool(clocks) and all(c['setup_worst_slack'] > 0 and c['hold_worst_slack'] >= 0
                                     and c['setup_fail_ends'] == c['hold_fail_ends'] == 0 for c in clocks)
        exact_timing = len(clocks) == 1 and all(
            c['setup_worst_slack'] == 29 and c['hold_worst_slack'] == 604
            and c['setup_fail_ends'] == c['hold_fail_ends'] == 0
            and c['setup_total_ends'] == c['hold_total_ends'] == 96142 for c in clocks)
        report.update(completed=native['native_route_completed'], timing_closed=closed,
                      exact_cluster_locks=locked, exact_delivery_timing=exact_timing,
                      matches_delivery=locked and exact_timing and native.get('p0_unchanged', False)
                      and not native['errors'] and native['native_route_completed'])
        print('T77_ROUTE_RESULT ' + label + ' ' + json.dumps({k: report[k] for k in
              ('completed', 'timing_closed', 'exact_cluster_locks', 'exact_delivery_timing', 'matches_delivery')}), flush=True)
    except Exception as error:
        report['error'] = str(error)
        report['native'] = collect_native(flow, expected)
        print('T77_ROUTE_STOP ' + label + ' ' + str(error), flush=True)
    finally:
        report.update(finished=stamp(), elapsed_seconds=round(time.monotonic() - begin, 3), jobs=flow.jobs,
                      input_vqm_unchanged=eda.sha(vqm).lower() == expected_sha,
                      tile_locks_unchanged=eda.sha(LOCKS).lower() == report.get('tile_locks_sha256'))
        flow.result.update(report)
        flow.finish()
        eda.save(receipt, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deadline', required=True)
    parser.add_argument('--label', help='Reproduction label; default runs the authorized R1 then R2')
    parser.add_argument('--vqm', type=Path)
    parser.add_argument('--sha256')
    args = parser.parse_args()
    deadline = datetime.fromisoformat(args.deadline).timestamp()
    if args.label:
        if not re.fullmatch(r'[A-Za-z0-9_]+', args.label) or not args.vqm or not args.sha256:
            raise ValueError('Specify safe label, VQM and expected SHA256 together')
        cases = [(args.label, args.vqm.resolve(), args.sha256.lower())]
    else:
        original = json.loads((EVIDENCE / 'baseline_original.json').read_text(encoding='utf-8'))
        cases = [('R1', Path(original['candidate']), V1_SHA), ('R2', BASELINE, BASE_SHA)]
    before = protected_processes()
    result = dict(started=stamp(), protected_before=before, cases=[])
    for label, vqm, sha in cases:
        if time.time() >= deadline:
            result['error'] = 'Overall task deadline reached; no new test started'
            break
        result['cases'].append(run_one(label, vqm, sha, deadline))
        eda.save(EVIDENCE / 'v2_route_tests.json', result)
    for p in before:
        try:
            p['same_process_still_running'] = psutil.Process(p['pid']).create_time() == p['created']
        except psutil.NoSuchProcess:
            p['same_process_still_running'] = False
    result.update(finished=stamp(), resources=RESOURCE_CHECKS)
    eda.save(EVIDENCE / 'v2_route_tests.json', result)
    return 0 if len(result['cases']) == len(cases) and all(c['completed'] for c in result['cases']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
