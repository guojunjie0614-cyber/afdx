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


def program(pres, settings):
    spec = t62_constraints.load_spec()
    pins = t62_constraints.physical(spec, '1.55').splitlines()[1:]
    lines = ['set_global_assignment -name PRES_FAC_MULT ' + pres]
    lines += ['set_global_assignment -name %s %s' % item for item in settings.items()]
    physical = '\n'.join(lines + pins) + '\n'
    return dict(full=spec['timing_sdc'] + physical, timing=spec['timing_sdc'], physical=physical)


def observed_values(log):
    values = {}
    for name, value, code in re.findall(r'^T63_PARAM (\S+) (\S+) code=(\d+)', log, re.M):
        values[name] = dict(value=value, code=int(code))
    return values


def run(source, pres, settings, tag):
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
    summary = dict(tag=tag, pres=pres, settings=settings, source=str(source), folder=str(flow.folder))
    try:
        project = flow.folder / 'project'
        output = project / (NAME + '.runs/imple_1')
        output.mkdir(parents=True)
        data = program(pres, settings)
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
        script = flow.folder / 'route.tcl'
        script.write_text('setlogfile ' + official_synth.tcl(logconfig) + ' '
            + official_synth.tcl(output / (NAME + '.edi')) + '\nsource ' + official_synth.tcl(native) + '\n'
            'proc t63_trace {command code result operation} {\n'
            ' set name [lindex $command 2]\n'
            ' if {[lsearch -exact {' + watched + '} $name] >= 0} {puts "T63_PARAM $name [lindex $command 3] code=$code"}\n}\n'
            'trace add execution set_global_assignment leave t63_trace\n'
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
        log = flow.job('route', [binary / 'Implementation.exe', '-f', script], 7200, cwd=binary)
        edi = (output / (NAME + '.edi')).read_text(encoding='utf-8-sig', errors='replace')
        if 'T63_ROUTE_COMPLETED' not in log or 'All was well!' not in log or re.search(r'\[(ERROR|CRIT)\]', edi):
            raise RuntimeError('Native route failed; see raw logs')
        values = observed_values(log)
        wanted = dict(settings, PRES_FAC_MULT=pres)
        applied = {name: values.get(name) for name in wanted}
        summary['applied'] = applied
        if any(row is None or row['code'] or float(row['value']) != float(wanted[name])
               for name, row in applied.items()):
            raise RuntimeError('A requested setting was not the last accepted value: ' + json.dumps(applied))
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
    summary = run(args.source, args.pres, settings, args.tag)
    keys = ('tag', 'setup_ps', 'hold_ps', 'failed', 'below_0p1ns', 'place_sha256', 'error')
    print(json.dumps({k: summary.get(k) for k in keys}, ensure_ascii=False))
    return 0 if summary.get('completed') else 1


if __name__ == '__main__':
    raise SystemExit(main())
