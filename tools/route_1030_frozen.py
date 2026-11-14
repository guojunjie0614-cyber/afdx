"""Route + isolated 10000-path STA from a frozen build1030 synthesis record.

Does not re-run quartus_map or modify synth_1. Supports locking an existing
.place file (finishing placement in seconds) or passing physical cluster
locks / allowlisted placer-router settings for ECO closure.
"""
import argparse
from datetime import datetime, timedelta
import json
from pathlib import Path
import re
import shutil
import sqlite3
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / 'tools') not in sys.path:
    sys.path.insert(0, str(ROOT / 'tools'))

import eda
import official_impl
import official_synth
import timing_paths_1030

NAME = 'AFDX_EndSystem'
PARAMS = (
    'TIMING_TRADEOFF_LAMBDA', 'HEAP_SPREAD_BETA', 'HEAP_CONVERGE', 'HEAP_STALL_MAX',
    'HEAP_WEIGHT_ADD', 'REFINE_RLIM', 'DETAILED_PLACER_ALGORITHM', 'ALPHA', 'INIT_SA',
    'INNERNUM', 'ASTAR_FAC', 'ACC_MULT', 'FIRST_ITER_PRESFAC', 'MAX_ROUTER_ITERATION',
)
NUMBER = re.compile(r'[0-9]+(?:\.[0-9]+)?')
PHYSICAL_RE = [re.compile(p) for p in (
    r'create_pblock (\w+) -from X(\d+)_Y(\d+) -to X(\d+)_Y(\d+)',
    r'add_insts_to_pblock (\w+) -to \{([^{}]+)\}',
    r'add_cells_to_pblock (\w+) -to \{([^{}]+)\}',
    r'set_location_assignment (?:CLB|M4K)_X\d+_Y\d+_N\d+ -to \{?[\w\\:|\[\]~.]+\}?',
)]


def log_configuration(path, target):
    path.write_text(
        'log4cpp.rootCategory=DEBUG,A1\n'
        'log4cpp.appender.A1=RollingFileAppender\n'
        f'log4cpp.appender.A1.fileName={target.as_posix()}\n'
        'log4cpp.appender.A1.append=false\n'
        'log4cpp.appender.A1.layout=PatternLayout\n'
        'log4cpp.appender.A1.layout.ConversionPattern=%d [%p] %m%n\n',
        encoding='utf-8',
    )


def locks_from_place(place_path):
    lines = []
    for line in Path(place_path).read_text(encoding='utf-8-sig').splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[0].startswith('stratix_'):
            cluster = fields[0]
            x, y = int(fields[1]), int(fields[2])
            kind = 'M4K' if cluster.startswith('stratix_mem') else 'CLB'
            lines.append(f'set_location_assignment {kind}_X{x}_Y{y}_N0 -to {{{cluster}}}')
    if not lines:
        raise RuntimeError(f'No stratix_* clusters found in {place_path}')
    return lines


def read_physical(path):
    lines = [
        line.strip()
        for line in Path(path).read_text(encoding='utf-8-sig').splitlines()
        if line.strip() and not line.lstrip().startswith('#')
    ]
    for line in lines:
        if not any(rule.fullmatch(line) for rule in PHYSICAL_RE):
            raise RuntimeError('Unsupported physical statement: ' + line)
    return lines


def family(name):
    name = re.sub(r'ram_block1a\d+', 'ram_block1a*', name)
    return re.sub(r'(?<!banks)(?<!bank)\[\d+\]', '[*]', name)


def summarize_db(db_path):
    con = sqlite3.connect(Path(db_path).resolve().as_uri() + '?mode=ro', uri=True)
    con.row_factory = sqlite3.Row
    clocks = [dict(r) for r in con.execute('SELECT * FROM elinx_intra_clock_summary')]
    rows = [
        dict(r)
        for r in con.execute(
            'SELECT * FROM elinx_intra_clock_longest_sync_path_report ORDER BY slack, path_id'
        )
    ]
    groups = {}
    for row in rows:
        if row['slack'] >= 0:
            continue
        key = (family(row['from_cell_name']), family(row['to_cell_name']))
        if key not in groups:
            groups[key] = {
                'from_family': key[0],
                'to_family': key[1],
                'rows': 0,
                'endpoints': set(),
                'worst_slack_ps': row['slack'],
                'levels': row['levels'],
                'logic_delay': row['logic_delay'],
                'net_delay': row['net_delay'],
            }
        groups[key]['rows'] += 1
        groups[key]['endpoints'].add(row['to_cell_name'])
    con.close()
    top_families = []
    for g in sorted(groups.values(), key=lambda x: x['worst_slack_ps'])[:25]:
        g['unique_endpoints'] = len(g.pop('endpoints'))
        top_families.append(g)
    return {
        'clocks': clocks,
        'saved_setup_rows': len(rows),
        'unique_failing_endpoints_in_sample': len({r['to_cell_name'] for r in rows if r['slack'] < 0}),
        'top_failing_families': top_families,
    }


def run_expanded_report(flow, binary, imple_output):
    exp_dir = flow.folder / 'expanded'
    exp_proj = exp_dir / 'project'
    exp_out = exp_proj / (NAME + '.runs/imple_1')
    exp_out.mkdir(parents=True, exist_ok=False)
    for suffix in ('ver.pb', 'tbg.pb', 'pack.dly.pb', 'place.dly.pb', 'route.dly.pb'):
        src = imple_output / f'{NAME}.{suffix}'
        shutil.copy2(src, exp_out / src.name)
    config = bytearray.fromhex(
        '00000000640000000a00000003000000caf249710103000000000000000000000000000000'
    )
    struct.pack_into('<iii', config, 4, 10000, 1, 2)
    (exp_out / f'{NAME}.tr.cfg.pb').write_bytes(config)
    logcfg = exp_dir / 'log4cpp.property'
    log_configuration(logcfg, exp_dir / 'report.edi')
    tcl = official_synth.tcl
    script = exp_dir / 'report.tcl'
    script.write_text(
        f'setlogfile {tcl(logcfg)} {tcl(exp_dir / "report.edi")}\n'
        f'source {tcl(binary / "run_timing_report.tcl")}\n'
        f'run_tming_report {tcl(exp_proj)} {NAME} AFDX_top eHiChip6 EQ6HL130 imple_1\n'
        'puts "ISOLATED_ROUTED_REPORT_COMPLETED"\nexit 0\n',
        encoding='utf-8',
    )
    log = flow.job('expanded_report', [binary / 'Implementation.exe', '-f', script], 600, cwd=binary)
    if 'All was well!' not in log or 'ISOLATED_ROUTED_REPORT_COMPLETED' not in log:
        raise RuntimeError('Expanded timing report completion markers missing')
    return exp_out / f'{NAME}.tan.pb'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='Completed build1030 synthesis folder')
    parser.add_argument('--tag', required=True)
    parser.add_argument('--pres', default='1.30')
    parser.add_argument('--set', action='append', default=[], metavar='NAME=VALUE')
    parser.add_argument('--lock-place', type=Path, help='Lock all clusters from an existing .place file')
    parser.add_argument('--physical', type=Path, help='Cluster lock / pblock .edc file')
    parser.add_argument('--budget-seconds', type=int, default=7200)
    args = parser.parse_args()

    if not NUMBER.fullmatch(args.pres):
        raise SystemExit('PRES must be a plain number')
    settings = {}
    for item in args.set:
        name, _, value = item.partition('=')
        if name not in PARAMS or not NUMBER.fullmatch(value):
            raise SystemExit('Unsupported setting: ' + item)
        settings[name] = value
    if args.lock_place and args.physical:
        raise SystemExit('Specify at most one of --lock-place or --physical')

    source = args.source.resolve()
    synth_summary = json.loads((source / 'summary.json').read_text(encoding='utf-8-sig'))
    if not synth_summary.get('synthesis_completed') or not synth_summary.get('synthesized_timing_closed'):
        raise RuntimeError('Source synthesis did not pass synthesized setup/hold gates')
    synth_dir = source / 'project' / f'{NAME}.runs/synth_1'
    if not (synth_dir / f'{NAME}_eHiChip6.ecp').is_file():
        raise RuntimeError(f'Missing packed checkpoint in {synth_dir}')

    extra_lines = []
    if args.lock_place:
        extra_lines = locks_from_place(args.lock_place)
    elif args.physical:
        extra_lines = read_physical(args.physical)

    deadline = (datetime.now().astimezone() + timedelta(seconds=args.budget_seconds)).isoformat()
    flow = eda.Flow('build1030_route', f'AFDX_top_1030_{args.tag}', deadline)
    begin = time.monotonic()
    flow.result.update(
        completed=False,
        timing_closed=False,
        source_synthesis=str(source),
        tag=args.tag,
        pres=args.pres,
        settings=settings,
        locked_cluster_lines=len(extra_lines),
        synthesized_timing=synth_summary['synthesized_timing'],
        synthesized_resources=synth_summary['resources'],
    )
    print(f'FROZEN_ROUTE START {flow.folder}', flush=True)
    try:
        home = official_synth.installation()
        binary = home / 'bin/shell/bin'
        tcl = official_synth.tcl
        project_dir = flow.folder / 'project'
        runs_dir = project_dir / f'{NAME}.runs'
        imple_out = runs_dir / 'imple_1'
        imple_out.mkdir(parents=True)

        # Link synth_1 via read-only directory junction
        synth_link = runs_dir / 'synth_1'
        subprocess.run(
            ['cmd.exe', '/d', '/c', 'mklink', '/J', str(synth_link), str(synth_dir)],
            cwd=ROOT,
            capture_output=True,
            check=True,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )

        timing_sdc = (ROOT / 'elinx/timing_only.sdc').read_text(encoding='utf-8-sig')
        spec = json.loads((ROOT / 'elinx/multicycle_spec.json').read_text(encoding='utf-8-sig'))
        phys_lines = [f'set_global_assignment -name PRES_FAC_MULT {args.pres}']
        for k, v in settings.items():
            phys_lines.append(f'set_global_assignment -name {k} {v}')
        for item in spec['pins']:
            phys_lines.append(f"set_location_assignment PIN_{item['pin']} -to {{{item['port']}}}")
        phys_lines.extend(extra_lines)
        constraint = project_dir / 'constraints.edc'
        sdc_file = project_dir / 'timing_only.sdc'
        constraint.write_text(timing_sdc + '\n'.join(phys_lines) + '\n', encoding='utf-8', newline='\n')
        sdc_file.write_text(timing_sdc, encoding='utf-8', newline='\n')

        (imple_out / f'{NAME}.run.psf').write_text(
            f'source {tcl(constraint)}\n'
            f'read_sdc {tcl(sdc_file)}\n'
            f'set_global_assignment -name TARGET_CONSTRAINT_FILE {tcl(constraint)}\n',
            encoding='utf-8',
        )
        shutil.copy2(synth_dir / f'{NAME}.tr.cfg.pb', imple_out / f'{NAME}.tr.cfg.pb')
        logcfg = imple_out / 'log4cpp.property'
        log_configuration(logcfg, imple_out / f'{NAME}.edi')

        cluster_xml = imple_out / 'loaded_cluster.xml'
        native_route = binary / 'run_route.tcl'
        route_args = [
            project_dir, NAME, 'AFDX_top', 'eHiChip6', 'EQ6HL130', 'CSG484_H', 'synth_1', 'imple_1'
        ]
        script = flow.folder / 'route.tcl'
        script.write_text(
            f'setlogfile {tcl(logcfg)} {tcl(imple_out / (NAME + ".edi"))}\n'
            f'source {tcl(native_route)}\n'
            'proc dump_clusters_hook {command code result operation} {\n'
            f'  if {{$code == 0}} {{puts "CLUSTER_EXPORT [catch {{udm_write_cluster {tcl(cluster_xml)}}}]"}}\n'
            '}\n'
            'trace add execution excute_check_preplace leave dump_clusters_hook\n'
            f'run_route {" ".join(map(tcl, route_args))}\n'
            'puts "BUILD1030_ROUTE_COMPLETED"\nexit 0\n',
            encoding='utf-8',
        )

        log = flow.job('route', [binary / 'Implementation.exe', '-f', script], args.budget_seconds, cwd=binary)
        if 'All was well!' not in log or 'BUILD1030_ROUTE_COMPLETED' not in log:
            raise RuntimeError('Route completion markers missing')
        edi_text = (imple_out / f'{NAME}.edi').read_text(errors='replace')
        if re.search(r'\[(ERROR|CRIT)\]', edi_text):
            raise RuntimeError('Implementation reported errors in .edi')

        resources, timing, resource_file, database = official_impl.reports(imple_out, NAME)
        exp_db = run_expanded_report(flow, binary, imple_out)
        exp_summary = summarize_db(exp_db)
        (flow.folder / 'expanded_summary.json').write_text(
            json.dumps(exp_summary, indent=2) + '\n', encoding='utf-8'
        )
        clocks = timing['clocks']
        closed = bool(clocks) and all(
            c['setup_worst_slack'] > 0
            and c['hold_worst_slack'] > 0
            and c['setup_fail_ends'] == 0
            and c['hold_fail_ends'] == 0
            for c in clocks
        )
        flow.result.update(
            completed=True,
            route_completed=True,
            timing_closed=closed,
            route_resources=resources,
            routed_timing=timing,
            route_output=str(imple_out),
            cluster_xml=str(cluster_xml),
            place_file=str(imple_out / f'{NAME}.place'),
            routed_timing_database=str(database),
            expanded_timing_database=str(exp_db),
            expanded_summary=exp_summary,
            routed_resources_report=str(resource_file),
        )
        for c in clocks:
            print(
                f"ROUTE clock={c['name']} setup_ns={c['setup_worst_slack']/1000:+.3f} "
                f"hold_ns={c['hold_worst_slack']/1000:+.3f} "
                f"setup_fail={c['setup_fail_ends']} hold_fail={c['hold_fail_ends']} "
                f"tns_ns={c['setup_total_violation']/1000:.3f} closed={closed}",
                flush=True,
            )
        return 0 if closed else 2
    except Exception as exc:
        flow.result['error'] = str(exc)
        print('FROZEN_ROUTE FAIL: ' + str(exc), flush=True)
        return 1
    finally:
        flow.result['elapsed_seconds'] = round(time.monotonic() - begin, 3)
        flow.finish()


if __name__ == '__main__':
    raise SystemExit(main())
