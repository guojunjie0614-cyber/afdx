"""T63 A 线：从只读综合记录做一次布局布线，可附加白名单内的布局/装箱参数。

读链、P0 落点校验和完整时序报告与 t62_reuse.py 相同。附加参数写在约束文件的
物理部分，原生 run_route.tcl 在 InitialAssignment 之后读取；用 Tcl trace 记录
每个参数最后一次赋值，确认实际生效。时序程序与批准版本逐字相同，多周期审计
用批准的 P1.55 程序做。结果汇总写到 out/t63/A/<tag>.json。
"""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# 准入记录放在 T63，不写 T62 的证据目录；D 线共用同一目录。
os.environ.setdefault('AFDX_T62_COORD', str(ROOT / 'out/t63/coord'))
Path(os.environ['AFDX_T62_COORD']).mkdir(parents=True, exist_ok=True)

import argparse
import json
import re
import time

import eda
import official_impl
import official_synth
import report_routed_timing
import t62_constraints
import t62_runtime
from t61_metrics import read_place, timing_statistics
from t62_reuse import NAME, link_synthesis

PARAMS = ('TIMING_TRADEOFF_LAMBDA', 'HEAP_SPREAD_BETA', 'HEAP_CONVERGE', 'HEAP_STALL_MAX',
          'HEAP_WEIGHT_ADD', 'REFINE_RLIM', 'DETAILED_PLACER_ALGORITHM', 'ALPHA', 'INIT_SA',
          'INNERNUM', 'ASTAR_FAC', 'ACC_MULT', 'FIRST_ITER_PRESFAC', 'MAX_ROUTER_ITERATION')
NUMBER = re.compile(r'[0-9]+(?:\.[0-9]+)?')
# B 线物理语句：区域、按实例/单元入区、单 Tile 定位。其他语句一律拒绝。
PHYSICAL = [re.compile(p) for p in (
    r'create_pblock (\w+) -from X(\d+)_Y(\d+) -to X(\d+)_Y(\d+)',
    r'add_insts_to_pblock (\w+) -to \{([^{}]+)\}',
    r'add_cells_to_pblock (\w+) -to \{([^{}]+)\}',
    r'set_location_assignment (?:CLB|M4K)_X\d+_Y\d+_N\d+ -to \{?[\w\\:|\[\]~.]+\}?')]


def read_physical(path):
    lines = [line.strip() for line in Path(path).read_text(encoding='utf-8-sig').splitlines()
             if line.strip() and not line.lstrip().startswith('#')]
    for line in lines:
        if not any(rule.fullmatch(line) for rule in PHYSICAL):
            raise SystemExit('Unsupported physical statement: ' + line)
    return lines


def program(pres, settings, extra=()):
    spec = t62_constraints.load_spec()
    pins = t62_constraints.physical(spec, '1.55').splitlines()[1:]
    lines = ['set_global_assignment -name PRES_FAC_MULT ' + pres]
    lines += ['set_global_assignment -name %s %s' % item for item in settings.items()]
    physical = '\n'.join(lines + pins + list(extra)) + '\n'
    return dict(full=spec['timing_sdc'] + physical, timing=spec['timing_sdc'], physical=physical)


def region_check(extra, cluster_xml, place):
    """每个按实例入区的簇都必须落在矩形内（簇按模块装箱，成员前缀一致）。"""
    boxes, members = {}, {}
    for line in extra:
        match = PHYSICAL[0].fullmatch(line)
        if match:
            name, x0, y0, x1, y1 = match.groups()
            boxes[name] = (int(x0), int(y0), int(x1), int(y1))
        match = PHYSICAL[1].fullmatch(line)
        if match:
            members.setdefault(match.group(1), []).extend(
                item.strip().lstrip('\\') + '|' for item in match.group(2).split(';'))
    if not members:
        return None
    clusters, current = {}, None
    with open(cluster_xml, encoding='utf-8') as stream:
        for line in stream:
            match = re.search(r'<CLUSTER name="([^"]+)"', line)
            if match:
                current = clusters.setdefault(match.group(1), [])
                continue
            match = re.search(r'<MOLECULE name="([^"]+)"', line)
            if match and current is not None:
                current.append(match.group(1).lstrip('\\'))
    places = {}
    for line in Path(place).read_text(encoding='utf-8-sig').splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[0].startswith('stratix_'):
            places[fields[0]] = (int(fields[1]), int(fields[2]))
    result = {}
    for name, prefixes in members.items():
        x0, y0, x1, y1 = boxes[name]
        inside = outside = 0
        bad = []
        for cluster, molecules in clusters.items():
            if molecules and all(any(m.startswith(p) for p in prefixes) for m in molecules):
                x, y = places[cluster]
                if min(x0, x1) <= x <= max(x0, x1) and min(y0, y1) <= y <= max(y0, y1):
                    inside += 1
                else:
                    outside += 1
                    bad.append([cluster, x, y])
        result[name] = dict(box=boxes[name], inside=inside, outside=outside, examples=bad[:5],
                            passed=inside > 0 and outside == 0)
    return result


def observed_values(log):
    values = {}
    for name, value, code in re.findall(r'^T63_PARAM (\S+) (\S+) code=(\d+)', log, re.M):
        values[name] = dict(value=value, code=int(code))
    return values


def run(source, pres, settings, tag, extra=(), place_only=False):
    source = Path(source).resolve()
    synthesis = json.loads((source / 'summary.json').read_text(encoding='utf-8-sig'))
    if not synthesis.get('completed'):
        raise ValueError('A completed synthesis record is required')
    netlist = Path(synthesis['netlist'])
    if eda.sha(netlist) != synthesis['netlist_sha256']:
        raise ValueError('Frozen VQM changed')
    synth = source / 'project' / (NAME + '.runs/synth_1')
    frozen = {p.name: eda.sha(p) for p in synth.iterdir() if p.is_file()}
    flow = t62_runtime.Flow('implementation', 'AFDX_top_' + tag, None)
    started = time.monotonic()
    summary = dict(tag=tag, pres=pres, settings=settings, physical=list(extra), place_only=place_only,
                   source=str(source), folder=str(flow.folder))
    try:
        project = flow.folder / 'project'
        output = project / (NAME + '.runs/imple_1')
        output.mkdir(parents=True)
        data = program(pres, settings, extra)
        for key, name in [('full', 'constraints.edc'), ('timing', 'timing_only.sdc'),
                          ('physical', 'physical_only.edc')]:
            (project / name).write_text(data[key], encoding='utf-8', newline='\n')
        constraint = project / 'constraints.edc'
        approved = flow.folder / 'approved_P1.55.edc'
        approved.write_text(t62_constraints.render('1.55')['full'], encoding='utf-8', newline='\n')
        (output / (NAME + '.run.psf')).write_text(
            'source ' + official_synth.tcl(constraint) + '\nread_sdc '
            + official_synth.tcl(project / 'timing_only.sdc')
            + '\nset_global_assignment -name TARGET_CONSTRAINT_FILE '
            + official_synth.tcl(constraint) + '\n', encoding='utf-8')
        logconfig = output / 'log4cpp.property'
        logconfig.write_text('log4cpp.rootCategory=DEBUG,A1\nlog4cpp.appender.A1=RollingFileAppender\n'
            'log4cpp.appender.A1.fileName=' + (output / (NAME + '.edi')).as_posix() + '\n'
            'log4cpp.appender.A1.append=false\nlog4cpp.appender.A1.layout=PatternLayout\n'
            'log4cpp.appender.A1.layout.ConversionPattern=%d [%p] %m%n\n', encoding='utf-8')
        binary = official_synth.installation() / 'bin/shell/bin'
        native = binary / 'run_route.tcl'
        synth_name = link_synthesis(synth, output.parent, flow.folder)
        arguments = [project, NAME, synthesis['top'], synthesis['series'], synthesis['device'],
                     synthesis['package'], synth_name, 'imple_1']
        watched = ' '.join(('PRES_FAC_MULT',) + PARAMS)
        cluster_xml = output / 'loaded_cluster.xml'
        hooks = ''
        if extra:
            hooks += ('proc t63_physical {command code result operation} {puts "T63_PHYSICAL code=$code [string range $command 0 120]"}\n'
                      'foreach c {create_pblock add_insts_to_pblock add_cells_to_pblock set_location_assignment} {trace add execution $c leave t63_physical}\n'
                      'proc t63_preplace {command code result operation} {\n'
                      ' if {$code == 0} {puts "T63_CLUSTER_EXPORT [catch {udm_write_cluster ' + official_synth.tcl(cluster_xml) + '}]"}\n}\n'
                      'trace add execution excute_check_preplace leave t63_preplace\n')
        if place_only:
            hooks += ('proc t63_placed {command code result operation} {\n'
                      ' puts "T63_PLACE_RETURN code=$code"\n if {$code == 0} {puts "T63_ROUTE_COMPLETED"; puts "All was well!"; exit 0}\n exit 33\n}\n'
                      'trace add execution try_place leave t63_placed\n')
        script = flow.folder / 'route.tcl'
        script.write_text('setlogfile ' + official_synth.tcl(logconfig) + ' '
            + official_synth.tcl(output / (NAME + '.edi')) + '\nsource ' + official_synth.tcl(native) + '\n'
            'proc t63_trace {command code result operation} {\n'
            ' set name [lindex $command 2]\n'
            ' if {[lsearch -exact {' + watched + '} $name] >= 0} {puts "T63_PARAM $name [lindex $command 3] code=$code"}\n}\n'
            'trace add execution set_global_assignment leave t63_trace\n' + hooks +
            'run_route ' + ' '.join(map(official_synth.tcl, arguments)) + '\n'
            'puts "T63_ROUTE_COMPLETED"\nexit 0\n', encoding='utf-8')
        official_synth.project_settings(flow, None)
        settings_files = [ROOT / 'elinx/constraints_t62.json', ROOT / 'elinx/constraints.edc',
                          ROOT / 'elinx/AFDX_EndSystem.epr', ROOT / 'elinx/AFDX_EndSystem_assignment_defaults.qdf']
        flow.result.update(synthesis=str(source), output=str(output), pres=pres, settings=settings,
            source_synth_name=synth_name, source_read_only_files=frozen,
            constraint_file=str(constraint), constraint_sha256=eda.sha(constraint),
            native_script_sha256=eda.sha(native),
            setting_hashes={p.relative_to(ROOT).as_posix(): eda.sha(p) for p in settings_files})
        audit = __import__('check_multicycle').audit(netlist, approved, flow.folder / 'multicycle_audit')
        if not audit['passed']:
            raise ValueError('Mapped MCP audit failed')
        try:
            log = flow.job('route', [binary / 'Implementation.exe', '-f', script], 7200, cwd=binary)
        finally:
            route_log = flow.folder / 'route.log'
            if route_log.exists():
                text = route_log.read_text(encoding='utf-8-sig', errors='replace')
                summary['physical_trace'] = re.findall(r'^T63_PHYSICAL .*$', text, re.M)
                summary['native_errors'] = re.findall(r'^\[(?:ERROR|CRIT)\].*$', text, re.M)[:10]
        edi = (output / (NAME + '.edi')).read_text(encoding='utf-8-sig', errors='replace')
        if 'T63_ROUTE_COMPLETED' not in log or 'All was well!' not in log or re.search(r'\[(ERROR|CRIT)\]', edi):
            raise RuntimeError('Native route failed; see raw logs')
        if extra:
            summary['region_check'] = region_check(extra, cluster_xml, output / (NAME + '.place'))
            if summary['region_check'] and not all(r['passed'] for r in summary['region_check'].values()):
                raise RuntimeError('Region members placed outside their pblock')
        values = observed_values(log)
        wanted = dict(settings, PRES_FAC_MULT=pres)
        applied = {name: values.get(name) for name in wanted}
        summary['applied'] = applied
        if any(row is None or row['code'] or float(row['value']) != float(wanted[name])
               for name, row in applied.items()):
            raise RuntimeError('A requested setting was not the last accepted value: ' + json.dumps(applied))
        if place_only:
            summary.update(completed=True, place_sha256=eda.sha(output / (NAME + '.place')))
            flow.result.update(completed=False, place_only=True)
        else:
            resources, timing, resource_file, database = official_impl.reports(output, NAME)
            clusters, pins = read_place(output / (NAME + '.place'))
            checks = [dict(port=row['port'], passed=bool(pins.get(row['port'])
                           and pins[row['port']]['package_pin'] == row['pin']
                           and pins[row['port']]['coordinates'] == row['xyz']))
                      for row in t62_constraints.load_spec()['pins']]
            if len(pins) != 172 or not all(row['passed'] for row in checks):
                raise ValueError('Actual P0 placement differs')
            if frozen != {p.name: eda.sha(p) for p in synth.iterdir() if p.is_file()}:
                raise ValueError('Read-only shared synthesis source changed')
            flow.result.update(completed=True, timing_closed=official_impl.timing_closed(timing['clocks']),
                constraints_applied=True, resources=resources, timing=timing, timing_database=str(database),
                resources_report=str(resource_file), applied=applied)
            summary.update(place_sha256=eda.sha(output / (NAME + '.place')), resources=resources)
    except Exception as error:
        flow.result.update(completed=False, error=str(error))
        summary['error'] = str(error)
    finally:
        flow.result['elapsed_seconds'] = time.monotonic() - started
        flow.finish()
    if flow.result.get('completed'):
        report = report_routed_timing.report(flow.folder / 'summary.json', None)
        if report.get('completed'):
            stats = timing_statistics(report['timing_database'])
            near = stats['nearcritical_endpoints']
            summary.update(completed=True, timing_closed=stats['timing_closed'],
                setup_ps=stats['setup_worst_slack_ps'], hold_ps=stats['hold_worst_slack_ps'],
                failed=stats['setup_failed_endpoints'], hold_failed=stats['hold_failed_endpoints'],
                endpoints=stats['setup_endpoint_count'],
                below_0p1ns=sum(row['slack'] < 100 for row in near),
                below_0p5ns=stats['below_0p5ns'], below_0p8ns=stats['below_0p8ns'],
                negative_sum_ps=stats['endpoint_min_setup_negative_slack_sum_ps'],
                modules={k: v.get('failed_endpoints') for k, v in stats['endpoint_module_groups'].items()
                         if v.get('failed_endpoints')},
                worst=[dict(slack=r['slack'], start=r['from_cell_name'], end=r['to_cell_name'],
                            levels=r.get('levels'), logic=r.get('logic_delay'), net=r.get('net_delay'))
                       for r in near[:10]],
                timing_database=report['timing_database'])
        else:
            summary['error'] = 'full timing report failed: ' + str(report.get('error'))
    summary['elapsed_seconds'] = round(time.monotonic() - started, 1)
    target = ROOT / 'out/t63/A' / (tag + '.json')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--pres', default='1.55')
    parser.add_argument('--set', action='append', default=[], metavar='NAME=VALUE')
    parser.add_argument('--tag', required=True)
    parser.add_argument('--physical', type=Path, help='区域/定位语句文件（白名单格式）')
    parser.add_argument('--place-only', action='store_true', help='布局完成即停，用于合法性探针')
    args = parser.parse_args()
    if not NUMBER.fullmatch(args.pres):
        raise SystemExit('PRES must be a plain number')
    settings = {}
    for item in args.set:
        name, _, value = item.partition('=')
        if name not in PARAMS or not NUMBER.fullmatch(value):
            raise SystemExit('Unsupported setting: ' + item)
        settings[name] = value
    t62_runtime.install()
    extra = read_physical(args.physical) if args.physical else []
    summary = run(args.source, args.pres, settings, args.tag, extra, args.place_only)
    keys = ('tag', 'setup_ps', 'hold_ps', 'failed', 'below_0p1ns', 'place_sha256', 'error')
    print(json.dumps({k: summary.get(k) for k in keys}, ensure_ascii=False))
    return 0 if summary.get('completed') else 1


if __name__ == '__main__':
    raise SystemExit(main())
