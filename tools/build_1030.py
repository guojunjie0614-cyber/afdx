"""Consolidated eLinx build from an isolated source snapshot, without hash passes.

Keeps the project's clock, uncertainty, CE constraints and pin assignment.
Synthesis/packing runs without cluster locks; implementation applies the verified
1030 cluster placement locks (elinx/tiles_1030.edc) unless --no-tiles is passed.
This measures internal timing; no external I/O timing budget is invented.
"""
import argparse
from datetime import datetime, timedelta
import json
from pathlib import Path
import re
import shutil
import struct
import time
import xml.etree.ElementTree as ET

import eda
import official_synth
import official_impl
import check_multicycle
import timing_paths_1030
import audit_1030_storage

ROOT = Path(__file__).resolve().parents[1]
TILE_LOCK_RE = re.compile(
    r'set_location_assignment (CLB|M4K)_X(\d+)_Y(\d+)_N0 -to \{(stratix_(?:clb|mem)\d+)\}'
)


def load_tile_locks(path):
    path = Path(path)
    if not path.is_file():
        raise RuntimeError(f'Tile lock file not found: {path}')
    lines = []
    expected = {}
    sites = set()
    for raw in path.read_text(encoding='utf-8-sig').splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        m = TILE_LOCK_RE.fullmatch(line)
        if not m:
            raise RuntimeError(f'Invalid tile lock statement in {path}: {line}')
        kind, x_s, y_s, cluster = m.groups()
        if (kind == 'M4K') != cluster.startswith('stratix_mem'):
            raise RuntimeError(f'Cluster kind mismatch in {path}: {line}')
        xy = (int(x_s), int(y_s))
        site = (kind, xy[0], xy[1])
        if cluster in expected:
            raise RuntimeError(f'Duplicate cluster lock in {path}: {cluster}')
        if site in sites:
            raise RuntimeError(f'Duplicate site lock in {path}: {site}')
        expected[cluster] = xy
        sites.add(site)
        lines.append(line)
    if not lines:
        raise RuntimeError(f'No tile locks found in {path}')
    return lines, expected


def verify_place_locks(place_path, expected):
    placed = {}
    for line in Path(place_path).read_text(encoding='utf-8-sig').splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[0].startswith('stratix_'):
            placed[fields[0]] = (int(fields[1]), int(fields[2]))
    if placed != expected:
        missing = len(set(expected) - set(placed))
        extra = len(set(placed) - set(expected))
        moved = sum(placed.get(k) != v for k, v in expected.items() if k in placed)
        raise RuntimeError(
            f'Placed clusters do not match locked tiles (missing={missing}, extra={extra}, moved={moved}); '
            'pass --no-tiles when building modified RTL'
        )


def log_configuration(path, target):
    path.write_text(
        'log4cpp.rootCategory=DEBUG,A1\n'
        'log4cpp.appender.A1=RollingFileAppender\n'
        f'log4cpp.appender.A1.fileName={target.as_posix()}\n'
        'log4cpp.appender.A1.append=false\n'
        'log4cpp.appender.A1.layout=PatternLayout\n'
        'log4cpp.appender.A1.layout.ConversionPattern=%d [%p] %m%n\n', encoding='utf-8')


def prepare(flow, pres):
    project = ROOT / 'elinx/AFDX_EndSystem.epr'
    doc = ET.parse(project).getroot()
    synth = doc.find("./Runs/Run[@Type='Synthesis']")
    implementation = doc.find("./Runs/Run[@Type='Implementation']")
    opts = {x.attrib['Id']: x.text or '' for x in synth.findall('Option')}
    if (opts['TopModule'], opts['Series'], opts['Device'], opts['Package']) != (
            'AFDX_top', 'eHiChip6', 'EQ6HL130', 'CSG484_H'):
        raise RuntimeError('This runner requires the existing AFDX target configuration')
    directory = flow.folder / 'project'
    directory.mkdir()
    source = flow.folder / 'source'
    shutil.copytree(ROOT / 'rtl', source / 'rtl')
    (source / 'elinx').mkdir()
    shutil.copy2(ROOT / 'elinx/afdx_all.v', source / 'elinx/afdx_all.v')
    shutil.copy2(project, directory / project.name)
    defaults = project.with_name(project.stem + '_assignment_defaults.qdf')
    shutil.copy2(defaults, directory / defaults.name)
    timing = (ROOT / 'elinx/timing_only.sdc').read_text(encoding='utf-8-sig')
    if '-period 8.000' not in timing or '-setup 0.30' not in timing:
        raise RuntimeError('Expected 8 ns clock and 0.30 ns uncertainty')
    spec = json.loads((ROOT / 'elinx/constraints_t62.json').read_text(encoding='utf-8-sig'))
    pins = spec['pins']
    if len(pins) != 172 or len({x['port'] for x in pins}) != 172 or len({x['pin'] for x in pins}) != 172:
        raise RuntimeError('Pin assignment is incomplete or colliding')
    physical = 'set_global_assignment -name PRES_FAC_MULT ' + pres + '\n'
    for item in pins:
        if not re.fullmatch(r'[A-Z]+[0-9]+', item['pin']) or not re.fullmatch(
                r'[A-Za-z_][A-Za-z_0-9]*(?:\[[0-9]+\])?', item['port']):
            raise RuntimeError('Invalid pin assignment')
        physical += 'set_location_assignment PIN_' + item['pin'] + ' -to {' + item['port'] + '}\n'
    constraint = directory / 'constraints.edc'
    constraint.write_text(timing + physical, encoding='utf-8')
    sdc = directory / 'timing_only.sdc'
    sdc.write_text(timing, encoding='utf-8')
    name = project.stem
    output = directory / (name + '.runs') / synth.attrib['Id']
    output.mkdir(parents=True)
    tcl = official_synth.tcl
    settings = [
        'set_global_assignment -name DEVICE EP1S80F1508C6',
        'set_global_assignment -name FAMILY Stratix',
        'set_global_assignment -name INI_VARS "qatm_force_vqm=on;vqmo_gen_svgx_vqm=on"',
        'set_global_assignment -name TOP_LEVEL_ENTITY AFDX_top',
        'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY ' + tcl(output),
        'set_global_assignment -name VERILOG_FILE ' + tcl(source / 'elinx/afdx_all.v'),
        'set_global_assignment -name MAX_RAM_BLOCKS_M512 0',
        'set_global_assignment -name MAX_RAM_BLOCKS_MRAM 0',
        'set_global_assignment -name AUTO_MERGE_PLLS OFF',
        'set_global_assignment -name AUTO_RAM_RECOGNITION ON',
        'set_global_assignment -name AUTO_ROM_RECOGNITION ON',
        'set_global_assignment -name DSP_BLOCK_BALANCING AUTO',
        'set_global_assignment -name STRATIX_OPTIMIZATION_TECHNIQUE SPEED',
        'set_global_assignment -name VERILOG_INPUT_VERSION VERILOG_2001',
    ]
    (directory / (name + '.qsf')).write_text('\n'.join(settings) + '\n', encoding='utf-8')
    (directory / (name + '.qpf')).write_text(
        'QUARTUS_VERSION = "13.0"\nPROJECT_REVISION = "' + name + '"\n', encoding='ascii')
    (output / (name + '.run.psf')).write_text(
        'source ' + tcl(constraint) + '\nread_sdc ' + tcl(sdc) + '\n'
        'set_global_assignment -name TARGET_CONSTRAINT_FILE ' + tcl(constraint) + '\n', encoding='utf-8')
    log_configuration(directory / 'log4cpp.property', output / (name + '.edi'))
    flow.result.update(source_snapshot=str(source), constraint_snapshot=str(constraint),
                       fingerprinting='not performed', obsolete_tile_locks_applied=False,
                       top='AFDX_top', series=opts['Series'], device=opts['Device'],
                       package=opts['Package'], ce_div=2, pres=pres,
                       scope='New RTL; official eLinx internal timing; no external I/O timing budget')
    return project, synth, implementation, opts, directory, output, constraint


def route(flow, home, project, synth, implementation, opts, directory, synth_output, constraint, tile_locks):
    if implementation is None:
        raise RuntimeError('Project has no implementation run')
    name = project.stem
    binary = home / 'bin/shell/bin'
    output = directory / (name + '.runs') / implementation.attrib['Id']
    output.mkdir(parents=True)
    tcl = official_synth.tcl
    if tile_locks is not None:
        tile_lines, expected_locks = tile_locks
        imple_constraint = directory / 'imple_constraints.edc'
        imple_constraint.write_text(
            constraint.read_text(encoding='utf-8') + '\n'.join(tile_lines) + '\n',
            encoding='utf-8',
            newline='\n',
        )
        sdc = directory / 'timing_only.sdc'
        (output / (name + '.run.psf')).write_text(
            'source ' + tcl(imple_constraint) + '\nread_sdc ' + tcl(sdc) + '\n'
            'set_global_assignment -name TARGET_CONSTRAINT_FILE ' + tcl(imple_constraint) + '\n',
            encoding='utf-8',
        )
    else:
        shutil.copy2(synth_output / (name + '.run.psf'), output / (name + '.run.psf'))
    # Request broad samples, while retaining native route analysis behavior.
    # This version may ignore that request; record actual saved path counts.
    shutil.copy2(synth_output / (name + '.tr.cfg.pb'), output / (name + '.tr.cfg.pb'))
    config = output / 'log4cpp.property'
    log_configuration(config, output / (name + '.edi'))
    args = [directory, name, opts['TopModule'], opts['Series'], opts['Device'], opts['Package'],
            synth.attrib['Id'], implementation.attrib['Id']]
    # Preserve the vendor's route/report sequence. An experiment adding a
    # second analysis call in that process ended with native 0xC0000409 after
    # graph serialization; its exact crashing command was not recorded.
    # Broader diagnostic reports must run separately on saved graph/delay
    # copies and must not replace these primary native timing measurements.
    native_route = binary / 'run_route.tcl'
    flow.result['routed_analysis_procedure'] = str(native_route)
    flow.result['routed_analysis_note'] = ('Unmodified official route procedure; '
        'actual saved path counts are read from the resulting database; '
        'expanded diagnostic analysis runs separately if needed')
    script = flow.folder / 'route.tcl'
    script.write_text('setlogfile ' + tcl(config) + ' ' + tcl(output / (name + '.edi')) + '\n'
                      'source ' + tcl(native_route) + '\n'
                      'run_route ' + ' '.join(map(tcl, args)) + '\n'
                      'puts "BUILD1030_ROUTE_COMPLETED"\nexit 0\n', encoding='utf-8')
    log = flow.job('route', [binary / 'Implementation.exe', '-f', script], 7200, cwd=binary)
    if 'All was well!' not in log or 'BUILD1030_ROUTE_COMPLETED' not in log:
        raise RuntimeError('Route completion markers missing')
    if re.search(r'\[(ERROR|CRIT)\]', (output / (name + '.edi')).read_text(errors='replace')):
        raise RuntimeError('Implementation reported errors')
    if tile_locks is not None:
        verify_place_locks(output / (name + '.place'), expected_locks)
        flow.result.update(tile_locks_applied=len(tile_lines), tile_locks_verified=True)
    else:
        flow.result.update(tile_locks_applied=0, tile_locks_verified=False)
    resources, timing, resource_file, database = official_impl.reports(output, name)
    path_report = flow.folder / 'routed_path_families.json'
    families = timing_paths_1030.classify(database, 'routed')
    path_report.write_text(json.dumps(families, indent=2) + '\n', encoding='utf-8')
    setup_sample = families['path_samples']['elinx_intra_clock_longest_sync_path_report']
    flow.result['routed_report_sampling'] = dict(
        requested_paths_per_clock=10000,
        native_timer_setting=families['native_summaries']['elinx_timer_setting'],
        saved_setup_paths=setup_sample['saved_paths'],
        saved_setup_endpoints=setup_sample['saved_endpoints'])
    flow.result['routed_path_families'] = str(path_report)
    clocks = timing['clocks']
    closed = bool(clocks) and all(c['setup_worst_slack'] > 0 and c['hold_worst_slack'] > 0
            and c['setup_fail_ends'] == 0 and c['hold_fail_ends'] == 0 for c in clocks)
    flow.result.update(route_completed=True, timing_closed=closed, route_resources=resources,
                       routed_timing=timing, route_output=str(output),
                       routed_timing_database=str(database), routed_resources_report=str(resource_file))
    for c in clocks:
        print(f"ROUTE clock={c['name']} setup_ns={c['setup_worst_slack']/1000:+.3f} "
              f"hold_ns={c['hold_worst_slack']/1000:+.3f} closed={closed}", flush=True)
    return closed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--route', action='store_true')
    parser.add_argument('--deadline')
    parser.add_argument('--pres', choices=('1.30', '1.40', '1.50', '1.55'), default='1.30')
    parser.add_argument('--tiles', type=Path, default=ROOT / 'elinx/tiles_1030.edc',
                        help='Verified 1030 cluster placement lock file for implementation')
    parser.add_argument('--no-tiles', action='store_true',
                        help='Run free placement without cluster locks (required if RTL changed)')
    args = parser.parse_args()
    deadline = args.deadline or (
        (datetime.now().astimezone() + timedelta(seconds=7200)).isoformat() if args.route else None
    )
    flow = eda.Flow('build1030', 'AFDX_top_1030', deadline)
    begin = time.monotonic()
    flow.result.update(completed=False, timing_closed=False)
    try:
        tile_locks = None
        if args.route and not args.no_tiles:
            tile_locks = load_tile_locks(args.tiles)
            flow.result['tile_locks_file'] = str(args.tiles.resolve())
        home = official_synth.installation()
        project, synth, implementation, opts, directory, output, constraint = prepare(flow, args.pres)
        print('BUILD1030 START ' + str(flow.folder), flush=True)
        passkey = home / 'bin/Passkey/bin'
        analysis = flow.job('analysis', [passkey / 'quartus_map.exe', '--read_settings_files=on',
                         '--write_settings_files=off', project.stem], 3600, cwd=directory)
        if 'Analysis & Synthesis was successful. 0 errors' not in analysis:
            raise RuntimeError('Synthesis did not report success')
        netlist = output / (project.stem + '.vqm')
        flow.job('export', [passkey / 'quartus_cdb.exe', project.stem, '-c', project.stem,
                           '--vqm=' + str(netlist)], 300, cwd=directory)
        if not netlist.is_file() or not netlist.stat().st_size:
            raise RuntimeError('VQM missing')
        storage_report = flow.folder / 'rx_storage_audit.json'
        storage = audit_1030_storage.audit(netlist, storage_report)
        flow.result.update(rx_storage_audit=str(storage_report),
                           rx_storage_audit_passed=storage['passed'])
        if not storage['passed']:
            raise RuntimeError('RX mapped RAM structure or payload write isolation failed; see rx_storage_audit.json')
        proof = check_multicycle.audit(netlist, directory / 'timing_only.sdc',
                                      flow.folder / 'ce_audit', fingerprint=False, pure_sdc=True)
        flow.result.update(netlist=str(netlist), multicycle_audit_passed=proof['passed'])
        if not proof['passed']:
            raise RuntimeError('New netlist fails existing CE/multicycle behavior audit; see ce_audit')
        official_synth.implementation_stage(flow, home, directory, output, project, synth, opts, 'pack')
        # Native 3.0.7 report configuration, validated using an identical VQM.
        # Expand saved paths; requesting one path per endpoint is advisory in
        # this version, so the classifier also deduplicates representatives.
        report_config = bytearray.fromhex(
            '00000000640000000a00000003000000caf249710103000000000000000000000000000000')
        struct.pack_into('<iii', report_config, 4, 10000, 1, 2)
        (output / (project.stem + '.tr.cfg.pb')).write_bytes(report_config)
        official_synth.implementation_stage(flow, home, directory, output, project, synth, opts, 'timing')
        resources, timing, rpt, db = official_synth.reports(output, project.stem)
        path_report = flow.folder / 'synth_path_families.json'
        path_report.write_text(json.dumps(timing_paths_1030.classify(db, 'synthesis'),
                                         indent=2) + '\n', encoding='utf-8')
        flow.result['synthesized_path_families'] = str(path_report)
        clocks = timing['clocks']
        synth_setup_closed = bool(clocks) and all(
            c['setup_worst_slack'] > 0 and c['setup_fail_ends'] == 0 for c in clocks)
        synth_hold_closed = bool(clocks) and all(
            c['hold_worst_slack'] > 0 and c['hold_fail_ends'] == 0 for c in clocks)
        flow.result.update(synthesis_completed=True, resources=resources, synthesized_timing=timing,
                           synthesized_setup_closed=synth_setup_closed,
                           synthesized_hold_closed=synth_hold_closed,
                           synthesized_timing_closed=synth_setup_closed and synth_hold_closed,
                           resources_report=str(rpt), timing_database=str(db))
        for c in clocks:
            print(f"SYNTH clock={c['name']} setup_ns={c['setup_worst_slack']/1000:+.3f} "
                  f"hold_ns={c['hold_worst_slack']/1000:+.3f} "
                  f"setup_fail_ends={c['setup_fail_ends']} hold_fail_ends={c['hold_fail_ends']}", flush=True)
        if args.route:
            if not (synth_setup_closed and synth_hold_closed):
                flow.result['error'] = 'Synthesized setup/hold gate failed; fix failing paths before routing'
                print('BUILD1030 HOLD: synthesized setup/hold gate failed; route skipped', flush=True)
                return 2
            closed = route(flow, home, project, synth, implementation, opts, directory, output, constraint, tile_locks)
            flow.result['completed'] = True
            return 0 if closed and synth_setup_closed and synth_hold_closed else 2
        flow.result['completed'] = True
        print('BUILD1030 SYNTHESIS COMPLETE; routed timing not measured', flush=True)
        return 0 if synth_setup_closed and synth_hold_closed else 2
    except Exception as exc:
        flow.result['error'] = str(exc)
        print('BUILD1030 FAIL: ' + str(exc), flush=True)
        return 1
    finally:
        flow.result['elapsed_seconds'] = round(time.monotonic() - begin, 3)
        flow.finish()


if __name__ == '__main__':
    raise SystemExit(main())
