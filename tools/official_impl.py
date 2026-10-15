"""接续官方综合，使用安装包原始脚本的默认布局布线流程。"""
import argparse
import json
from pathlib import Path
import re
import shutil
import sqlite3
import time
import xml.etree.ElementTree as ET

import eda
import official_synth

ROOT = Path(__file__).resolve().parents[1]


def check_inputs(synthesis):
    for relative, digest in {**synthesis['source_hashes'], **synthesis['setting_hashes']}.items():
        if eda.sha(ROOT / relative) != digest:
            raise RuntimeError('Project inputs changed; run synth.ps1 again: ' + relative)
    netlist = Path(synthesis['netlist'])
    if eda.sha(netlist) != synthesis['netlist_sha256']:
        raise RuntimeError('Synthesis netlist changed; run synth.ps1 again')


def reports(output, name):
    resource_file = output / (name + '_utilization_placed.rpt')
    text = resource_file.read_text(encoding='utf-8', errors='replace')
    if 'Successful' not in text:
        raise RuntimeError('Missing successful implementation resource report')
    resources = {key: int(re.search(r'Total ' + label + r'\s*:\s*(\d+)', text).group(1))
                 for key, label in (('lut', 'LUTs'), ('ff', 'FFs'), ('clb', 'CLBs'),
                                    ('memory', 'Memorys'), ('pins', 'Pins'), ('dsp', 'DSPs'), ('pll', 'PLLs'))}
    database = output / (name + '.tan.pb')
    connection = sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True)
    connection.row_factory = sqlite3.Row
    try:
        clocks = [dict(row) for row in connection.execute('SELECT * FROM elinx_intra_clock_summary')]
        worst = connection.execute(
            'SELECT * FROM elinx_intra_clock_longest_sync_path_report ORDER BY slack,path_id LIMIT 1').fetchone()
        timing = {'clocks': clocks, 'worst_setup_path': dict(worst) if worst else None}
    finally:
        connection.close()
    if not clocks:
        raise RuntimeError('No constrained clocks in the routed timing report')
    return resources, timing, resource_file, database


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deadline')
    args = parser.parse_args()
    flow = eda.Flow('implementation', 'AFDX_top_route', args.deadline)
    started = time.monotonic()
    try:
        home = official_synth.installation()
        binary = home / 'bin/shell/bin'
        native = binary / 'run_route.tcl'
        if not native.is_file():
            raise RuntimeError('Missing official implementation script')
        synthesis = json.loads((ROOT / 'out/latest_AFDX_top.json').read_text(encoding='utf-8'))
        if not synthesis.get('completed'):
            raise RuntimeError('Run synth.ps1 successfully before impl.ps1')
        check_inputs(synthesis)
        constraint = ROOT / 'elinx/constraints.edc'
        if 'set_multicycle_path' in constraint.read_text(encoding='utf-8-sig'):
            from check_multicycle import audit
            audit_path = flow.folder / 'multicycle_audit'
            proof = audit(Path(synthesis['netlist']), constraint, audit_path)
            flow.result['multicycle_audit'] = str(audit_path)
            if not proof['passed']:
                raise RuntimeError('Multicycle register/enable/cone audit failed: ' + str(audit_path))
        directory = Path(synthesis['folder']).resolve() / 'project'
        directory.relative_to((ROOT / 'out').resolve())
        project = ROOT / synthesis['project']
        document = ET.parse(project).getroot()
        run = document.find("./Runs/Run[@Type='Synthesis']")
        implementation = document.find("./Runs/Run[@Type='Implementation']")
        if implementation is None:
            raise RuntimeError('Project has no implementation run')
        name = project.stem
        output = directory / (name + '.runs') / implementation.attrib['Id']
        output.mkdir(parents=True, exist_ok=True)
        shutil.copy2(directory / (name + '.runs') / run.attrib['Id'] / (name + '.run.psf'),
                     output / (name + '.run.psf'))
        config = output / 'log4cpp.property'
        config.write_text(
            'log4cpp.rootCategory=DEBUG,A1\n'
            'log4cpp.appender.A1=RollingFileAppender\n'
            'log4cpp.appender.A1.fileName=' + (output / (name + '.edi')).as_posix() + '\n'
            'log4cpp.appender.A1.maxBackupIndex=1\n'
            'log4cpp.appender.A1.append=false\n'
            'log4cpp.appender.A1.layout=PatternLayout\n'
            'log4cpp.appender.A1.layout.ConversionPattern=%d [%p] %m%n\n', encoding='utf-8')
        script = flow.folder / 'route.tcl'
        arguments = [directory, name, synthesis['top'], synthesis['series'], synthesis['device'],
                     synthesis['package'], run.attrib['Id'], implementation.attrib['Id']]
        script.write_text(
            'setlogfile ' + official_synth.tcl(config) + ' ' + official_synth.tcl(output / (name + '.edi')) + '\n'
            'source ' + official_synth.tcl(native) + '\n'
            'run_route ' + ' '.join(map(official_synth.tcl, arguments)) + '\n'
            'puts "OFFICIAL_STAGE_COMPLETED route"\nexit 0\n', encoding='utf-8')
        shutil.copy2(native, flow.folder / native.name)
        flow.result.update(scope='Official default placed/routed internal timing; no I/O timing budget',
                           synthesis=synthesis['folder'], output=str(output),
                           source_hashes=synthesis['source_hashes'], setting_hashes=synthesis['setting_hashes'],
                           native_script_sha256=eda.sha(native))
        print('OFFICIAL ROUTE START output=' + flow.folder.relative_to(ROOT).as_posix(), flush=True)
        log = flow.job('route', [binary / 'Implementation.exe', '-f', script], 7200, cwd=binary)
        if 'All was well!' not in log or 'OFFICIAL_STAGE_COMPLETED route' not in log:
            raise RuntimeError('Official route completion markers missing')
        edi = (output / (name + '.edi')).read_text(encoding='utf-8', errors='replace')
        if re.search(r'\[(ERROR|CRIT)\]', edi):
            raise RuntimeError('Official route reported an error')
        resources, timing, resource_file, database = reports(output, name)
        check_inputs(synthesis)
        closed = all(row['setup_worst_slack'] >= 0 and row['hold_worst_slack'] >= 0 for row in timing['clocks'])
        flow.result.update(completed=True, timing_closed=closed, resources=resources, timing=timing,
                           resources_report=str(resource_file), timing_database=str(database),
                           elapsed_seconds=round(time.monotonic() - started, 3))
        for clock in timing['clocks']:
            print(f"OFFICIAL ROUTE COMPLETE clock={clock['name']} period_ns={clock['period']/1000:.3f}"
                  + f" setup_ns={clock['setup_worst_slack']/1000:+.3f}"
                  + f" hold_ns={clock['hold_worst_slack']/1000:+.3f} fmax_mhz={clock['fmax']:.3f}"
                  + f" setup_fail_ends={clock['setup_fail_ends']}/{clock['setup_total_ends']}"
                  + f" hold_fail_ends={clock['hold_fail_ends']}/{clock['hold_total_ends']}"
                  + f" timing_closed={closed}", flush=True)
        return 0
    except Exception as error:
        flow.result.update(completed=False, error=str(error))
        print('OFFICIAL ROUTE FAIL: ' + str(error), flush=True)
        return 1
    finally:
        flow.result['elapsed_seconds'] = round(time.monotonic() - started, 3)
        flow.finish()


if __name__ == '__main__':
    raise SystemExit(main())
