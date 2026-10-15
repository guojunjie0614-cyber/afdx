"""按 eLinx Run Synthesis 的官方流程生成 VQM、资源和综合后时序。"""
import argparse
import os
from pathlib import Path
import re
import shutil
import sqlite3
import time
import xml.etree.ElementTree as ET

import eda

ROOT = Path(__file__).resolve().parents[1]


def installation():
    if os.environ.get('ELINX_HOME'):
        home = Path(os.environ['ELINX_HOME']).resolve()
    else:
        executable = shutil.which('Implementation.exe')
        if not executable:
            raise RuntimeError('Set ELINX_HOME or put bin/shell/bin on PATH')
        home = Path(executable).resolve().parents[3]
    for relative in ('bin/Passkey/bin/quartus_map.exe', 'bin/Passkey/bin/quartus_cdb.exe',
                     'bin/shell/bin/Implementation.exe', 'bin/shell/bin/run_pack.tcl',
                     'bin/shell/bin/run_synthesized_timing.tcl'):
        if not (home / relative).is_file():
            raise RuntimeError('Missing eLinx component: ' + relative)
    return home


def tcl(value):
    return '"' + str(value).replace('\\', '/').replace('$', '\\$').replace(
        '[', '\\[').replace('"', '\\"') + '"'


def project_settings(flow, requested_top):
    project = ROOT / 'elinx/AFDX_EndSystem.epr'
    document = ET.parse(project).getroot()
    run = document.find("./Runs/Run[@Type='Synthesis']")
    options = {item.attrib['Id']: item.text or '' for item in run.findall('Option')}
    top = options['TopModule']
    if requested_top and requested_top != top:
        raise RuntimeError('Top must match the synthesis top in the project: ' + top)
    source_set = document.find("./FileSets/FileSet[@Name='" + run.attrib['SrcSet'] + "']")
    sources = [(project.parent / item.attrib['Path'].lstrip('/')).resolve()
               for item in source_set.findall('File')]
    constraint_set = document.find("./FileSets/FileSet[@Name='" + run.attrib['ConstrsSet'] + "']")
    constraints = [(project.parent / item.attrib['Path'].lstrip('/')).resolve()
                   for item in constraint_set.findall('File')]
    if len(constraints) != 1:
        raise RuntimeError('This entry requires one project constraint file')
    for path in sources + constraints:
        if not path.is_file():
            raise RuntimeError('Missing project input: ' + path.name)
    flow.result.update(project=project.relative_to(ROOT).as_posix(), top=top,
                       series=options['Series'], device=options['Device'], package=options['Package'],
                       engine='eLinx Run Synthesis', source_hashes={
                           path.relative_to(ROOT).as_posix(): eda.sha(path) for path in sources})
    return project, run, options, sources, constraints[0]


def prepare_project(folder, project, run, options, sources, constraint):
    name = project.stem
    directory = folder / 'project'
    output = directory / (name + '.runs') / run.attrib['Id']
    output.mkdir(parents=True)
    shutil.copy2(project, directory / project.name)
    defaults = project.with_name(name + '_assignment_defaults.qdf')
    shutil.copy2(defaults, directory / defaults.name)
    constraint_copy = directory / constraint.name
    shutil.copy2(constraint, constraint_copy)
    qsf = project.with_suffix('.qsf')
    by_name = {path.name: path for path in sources}
    if len(by_name) != len(sources):
        raise RuntimeError('Duplicate project source names')
    if qsf.is_file():
        # 保留界面生成的全部综合选项和文件顺序，仅重定位输入与输出路径。
        lines = []
        used_sources = set()
        for line in qsf.read_text(encoding='utf-8-sig').splitlines():
            match = re.match(r'(set_global_assignment\s+-name\s+)(\S+)\s+(.+)$', line)
            if match:
                prefix, key, value = match.groups()
                if key.endswith('_FILE'):
                    basename = Path(value.strip('"{}').replace('\\', '/')).name
                    if basename in by_name:
                        value = tcl(by_name[basename])
                        used_sources.add(basename)
                    elif basename == constraint.name:
                        value = tcl(constraint_copy)
                    else:
                        raise RuntimeError('Unrecognized project file setting: ' + key)
                elif key == 'TOP_LEVEL_ENTITY' and value.strip('"{}') != options['TopModule']:
                    raise RuntimeError('The project and generated QSF synthesis tops differ')
                elif key == 'PROJECT_OUTPUT_DIRECTORY':
                    value = tcl(output)
                line = prefix + key + ' ' + value
            lines.append(line)
        if used_sources != set(by_name):
            raise RuntimeError('The project and generated QSF source lists differ')
    else:
        # QSF 是界面运行产物，干净检出时按 EPR 的当前器件、语言和优化设置生成。
        if options['Series'] != 'eHiChip6' or options['LanguageVersion'] != 'VERILOG_2001':
            raise RuntimeError('Generate a QSF with Run Synthesis for this series/language')
        if options['OptimizationTechnique'] != '1':
            raise RuntimeError('Generate a QSF with Run Synthesis for this optimization setting')
        lines = [
            'set_global_assignment -name DEVICE EP1S80F1508C6',
            'set_global_assignment -name FAMILY Stratix',
            'set_global_assignment -name INI_VARS "qatm_force_vqm=on;vqmo_gen_svgx_vqm=on"',
            'set_global_assignment -name TOP_LEVEL_ENTITY ' + options['TopModule'],
            'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY ' + tcl(output),
        ]
        lines += ['set_global_assignment -name VERILOG_FILE ' + tcl(path) for path in sources]
        lines += [
            'set_global_assignment -name MAX_RAM_BLOCKS_M512 0',
            'set_global_assignment -name MAX_RAM_BLOCKS_MRAM 0',
            'set_global_assignment -name AUTO_MERGE_PLLS OFF',
            'set_global_assignment -name AUTO_RAM_RECOGNITION ON',
            'set_global_assignment -name AUTO_ROM_RECOGNITION ON',
            'set_global_assignment -name DSP_BLOCK_BALANCING AUTO',
            'set_global_assignment -name STRATIX_OPTIMIZATION_TECHNIQUE SPEED',
            'set_global_assignment -name VERILOG_INPUT_VERSION ' + options['LanguageVersion'],
        ]
    (directory / qsf.name).write_text('\n'.join(lines) + '\n', encoding='utf-8')
    (directory / (name + '.qpf')).write_text(
        'QUARTUS_VERSION = "13.0"\nPROJECT_REVISION = "' + name + '"\n', encoding='ascii')
    (output / (name + '.run.psf')).write_text(
        'source ' + tcl(constraint_copy) + '\nread_sdc ' + tcl(constraint_copy) + '\n'
        'set_global_assignment -name TARGET_CONSTRAINT_FILE ' + tcl(constraint_copy) + '\n',
        encoding='utf-8')
    (directory / 'log4cpp.property').write_text(
        'log4cpp.rootCategory=DEBUG,A1\n'
        'log4cpp.appender.A1=RollingFileAppender\n'
        'log4cpp.appender.A1.fileName=' + (output / (name + '.edi')).as_posix() + '\n'
        'log4cpp.appender.A1.maxBackupIndex=1\n'
        'log4cpp.appender.A1.append=false\n'
        'log4cpp.appender.A1.layout=PatternLayout\n'
        'log4cpp.appender.A1.layout.ConversionPattern=%d [%p] %m%n\n', encoding='utf-8')
    return directory, output


def implementation_stage(flow, home, directory, output, project, run, options, stage):
    binary = home / 'bin/shell/bin'
    name = project.stem
    arguments = [directory, name, options['TopModule'], options['Series'], options['Device']]
    if stage == 'pack':
        arguments.append(options['Package'])
    arguments.append(run.attrib['Id'])
    procedure = 'run_pack' if stage == 'pack' else 'run_synthesized_timing'
    script = flow.folder / (stage + '.tcl')
    script.write_text(
        'setlogfile ' + tcl(directory / 'log4cpp.property') + ' ' + tcl(output / (name + '.edi')) + '\n'
        'source ' + tcl(binary / (procedure + '.tcl')) + '\n'
        + procedure + ' ' + ' '.join(map(tcl, arguments)) + '\n'
        'puts "OFFICIAL_STAGE_COMPLETED ' + stage + '"\nexit 0\n', encoding='utf-8')
    log = flow.job(stage, [binary / 'Implementation.exe', '-f', script], 1200, cwd=binary)
    if 'All was well!' not in log or 'OFFICIAL_STAGE_COMPLETED ' + stage not in log:
        raise RuntimeError('Official ' + stage + ' stage did not complete')
    edi = (output / (name + '.edi')).read_text(errors='replace')
    if re.search(r'\[(ERROR|CRIT)\]', edi):
        raise RuntimeError('Official ' + stage + ' stage reported an error')


def reports(output, name):
    resource_file = output / (name + '_utilization_synth.rpt')
    text = resource_file.read_text(errors='replace')
    if 'Synthesis Status : Successful' not in text:
        raise RuntimeError('Missing successful synthesis resource report')
    resources = {key: int(re.search(r'Total ' + label + r'\s*:\s*(\d+)', text).group(1))
                 for key, label in (('lut', 'LUTs'), ('ff', 'FFs'), ('clb', 'CLBs'),
                                    ('memory', 'Memorys'), ('pins', 'Pins'), ('dsp', 'DSPs'), ('pll', 'PLLs'))}
    database = output / (name + '.tan.pb')
    connection = sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True)
    connection.row_factory = sqlite3.Row
    try:
        clocks = [dict(row) for row in connection.execute('SELECT * FROM elinx_intra_clock_summary')]
        path = dict(connection.execute(
            'SELECT * FROM elinx_intra_clock_longest_sync_path_report ORDER BY slack,path_id LIMIT 1').fetchone())
    finally:
        connection.close()
    if not clocks:
        raise RuntimeError('No constrained clocks in the synthesized timing report')
    return resources, {'clocks': clocks, 'worst_setup_path': path}, resource_file, database


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--top', help='兼容参数，必须与工程综合顶层相同')
    parser.add_argument('--deadline')
    args = parser.parse_args()
    started = time.monotonic()
    flow = eda.Flow('synth', args.top or 'AFDX_top', args.deadline)
    try:
        home = installation()
        project, run, options, sources, constraint = project_settings(flow, args.top)
        directory, output = prepare_project(flow.folder, project, run, options, sources, constraint)
        settings = [project, constraint, project.with_name(project.stem + '_assignment_defaults.qdf')]
        if project.with_suffix('.qsf').is_file():
            settings.append(project.with_suffix('.qsf'))
        flow.result['setting_hashes'] = {path.relative_to(ROOT).as_posix(): eda.sha(path) for path in settings}
        passkey = home / 'bin/Passkey/bin'
        print('OFFICIAL SYNTH START output=' + flow.folder.relative_to(ROOT).as_posix(), flush=True)
        analysis = flow.job('analysis', [passkey / 'quartus_map.exe', '--read_settings_files=on',
                                       '--write_settings_files=off', project.stem], 3600, cwd=directory)
        if 'Analysis & Synthesis was successful. 0 errors' not in analysis:
            raise RuntimeError('Analysis and synthesis did not report success')
        netlist = output / (project.stem + '.vqm')
        flow.job('export', [passkey / 'quartus_cdb.exe', project.stem, '-c', project.stem,
                           '--vqm=' + str(netlist)], 300, cwd=directory)
        if not netlist.is_file() or not netlist.stat().st_size:
            raise RuntimeError('VQM export is missing')
        implementation_stage(flow, home, directory, output, project, run, options, 'pack')
        implementation_stage(flow, home, directory, output, project, run, options, 'timing')
        resources, timing, resource_file, database = reports(output, project.stem)
        inputs = {**flow.result['source_hashes'], **flow.result['setting_hashes']}
        if any(eda.sha(ROOT / relative) != digest for relative, digest in inputs.items()):
            raise RuntimeError('Project inputs changed during synthesis')
        flow.result.update(completed=True, resources=resources, timing=timing,
                           netlist=str(netlist), netlist_sha256=eda.sha(netlist),
                           resources_report=str(resource_file), timing_database=str(database),
                           elapsed_seconds=round(time.monotonic() - started, 3))
        clock = next(row for row in timing['clocks'] if row['name'] == 'clk')
        print('OFFICIAL SYNTH PASS ' + ' '.join(f'{key}={value}' for key, value in resources.items())
              + f" setup_ns={clock['setup_worst_slack']/1000:+.3f}"
              + f" hold_ns={clock['hold_worst_slack']/1000:+.3f} fmax_mhz={clock['fmax']:.3f}"
              + f" elapsed_s={flow.result['elapsed_seconds']}", flush=True)
        return 0
    except Exception as error:
        flow.result.update(completed=False, error=str(error), elapsed_seconds=round(time.monotonic() - started, 3))
        print('OFFICIAL SYNTH FAIL: ' + str(error), flush=True)
        return 1
    finally:
        flow.finish()


if __name__ == '__main__':
    raise SystemExit(main())
