"""复制界面综合网表，补齐仿真约定，运行原样自检测试。"""
import argparse
import json
import os
import re
import shutil
import sys
from datetime import datetime, timedelta
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / 'rtl/AFDX_top.v').is_file())
sys.path.append(str(ROOT / 'tools'))
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
import eda
from adapt_gui_vqm import adapt
from modelsim_compat import adapt_text

RECORDS = ('net_services.txt', 'es1_a.txt', 'es1_b.txt', 'es2_a.txt',
           'es2_b.txt', 'es2_rx_a.txt', 'download_results.txt')
MODELS = ('220model.v', 'altera_mf.v', 'altera_primitives.v',
          'stratix_atoms.v', 'stratixiv_atoms.v')


def adapt_simulation_source(relative_path, text):
    """Adapt only disposable RTL/TB copies, retaining unconnected inputs as Z."""
    text, records = adapt_text(relative_path, text)
    text, count = re.subn(r'\$finish_and_return\(1\)', '$fatal(1)', text)
    if count:
        records.append({'path': relative_path, 'action': 'portable_failure_exit', 'count': count})
    optional = {
        'rtl/afdx_app_tx.v': ('.read_data(memory_q));', '.read_data(memory_q),.raw_write_data());'),
        'rtl/afdx_app_rx.v': ('.data(q_data));', '.data(q_data),.next_limit());'),
    }
    if relative_path in optional:
        old, new = optional[relative_path]
        if text.count(old) != 1:
            raise ValueError('Optional port adaptation changed: ' + relative_path)
        text = text.replace(old, new)
        records.append({'path': relative_path, 'action': 'explicit_open_optional_input',
                        'original': old, 'replacement': new})
    return text, records


def compare_external_records(folder, reference):
    """Preserve missing-file evidence without treating absent output as equal."""
    comparison = {}
    for name in RECORDS:
        actual, expected = folder / name, reference / name
        present = actual.is_file() and expected.is_file()
        comparison[name] = {
            'netlist_exists': actual.is_file(),
            'reference_exists': expected.is_file(),
            'equal': actual.read_bytes() == expected.read_bytes() if present else None,
        }
    eda.save(folder / 'external_record_comparison.json', comparison)
    exact = {name: row['equal'] for name, row in comparison.items()}
    eda.save(folder / 'exact_external_records.json', exact)
    return exact


def run_case(test, deadline, netlist=None, model_dir=None, reference=None):
    mode = 'gui' if netlist else 'rtl'
    flow = eda.Flow('gui_netlist', test + '_' + mode, deadline)
    sources = []
    originals = {}
    copied = []
    adaptations = []
    flow.result.update(mode=mode, rtl_reference=str(reference) if reference else None,
                       available_memory_start_bytes=eda.psutil.virtual_memory().available,
                       subprocess_environment={key: os.environ.get(key) for key in
                           ('MODELSIM_HOME', 'ELINX_HOME', 'LM_LICENSE_FILE', 'MGLS_LICENSE_FILE')},
                       ce_div=2)

    def copy(source, relative):
        source = Path(source)
        destination = flow.folder / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        originals[str(source)] = eda.sha(source)
        shutil.copy2(source, destination)
        if eda.sha(destination) != originals[str(source)]:
            raise RuntimeError('输入文件复制校验失败：' + source.name)
        copied.append({'source': str(source), 'snapshot': relative,
                       'sha256': originals[str(source)]})
        return relative

    def copy_hdl(source):
        relative = source.relative_to(ROOT).as_posix()
        original = copy(source, 'original_sources/' + relative)
        text, records = adapt_simulation_source(relative, (flow.folder / original).read_bytes().decode('utf-8-sig'))
        target = Path('compile_sources') / relative
        destination = flow.folder / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(text.encode('utf-8'))
        adaptations.extend(records)
        copied[-1].update(compile_source=target.as_posix(), adapted_sha256=eda.sha(destination))
        return target.as_posix()

    try:
        for name in ('gui_netlist.py', 'modelsim_compat.py', 'adapt_gui_vqm.py', 'eda.py'):
            copy(ROOT / 'tools' / name, 'original_sources/tools/' + name)
        if netlist:
            copy(netlist, 'original.vqm')
            flow.result['adaptation'] = adapt(flow.folder / 'original.vqm', flow.folder / 'simulation.vqm')
            sources.append('simulation.vqm')
            for name in MODELS:
                sources.append(copy(model_dir / name, name))
        else:
            for path in sorted((ROOT / 'rtl').glob('*.v')):
                sources.append(copy_hdl(path))
        for path in sorted((ROOT / 'tb/lib').iterdir()):
            if path.suffix in ('.v', '.vh'):
                name = copy_hdl(path)
                if path.suffix == '.v':
                    sources.append(name)
        sources.append(copy_hdl(ROOT / 'tb' / (test + '.v')))
        checker = flow.folder / 'original_sources/tools/net_services_ref.py'
        if test == 'tb_net_services':
            for name in ('net_services_ref.py', 'load_ref.py', 'download_ref.py', 'snmp_ref.py', 'afdx_ref.py'):
                copy(ROOT / 'tools' / name, 'original_sources/tools/' + name)
            flow.job('vectors', [sys.executable, '-B', '-X', 'utf8', checker, 'vectors', '--dir', flow.folder], 60)
            if reference:
                baseline = json.loads((reference / 'summary.json').read_text(encoding='utf-8'))
                if not baseline.get('passed') or baseline.get('mode') != 'rtl':
                    raise RuntimeError('RTL reference must be a completed passing RTL run')
                shared = {path: value == baseline['inputs'].get(path) for path, value in originals.items()
                          if Path(path).is_relative_to(ROOT / 'tb') or Path(path).name in
                          ('net_services_ref.py', 'load_ref.py', 'download_ref.py', 'snmp_ref.py', 'afdx_ref.py')}
                vectors = {p.name: p.read_bytes() == (reference / 'vectors' / p.name).read_bytes()
                           for p in (flow.folder / 'vectors').iterdir() if p.is_file()}
                flow.result.update(same_reference_inputs=shared, same_reference_vectors=vectors)
                if not all(shared.values()) or not all(vectors.values()):
                    raise RuntimeError('本次 RTL/VQM 测试输入或向量不一致')
        eda.save(flow.folder / 'modelsim_adaptations.json', adaptations)
        eda.save(flow.folder / 'input_manifest.json', copied)
        flow.result['modelsim_adaptations'] = len(adaptations)
        (flow.folder / 'run.do').write_text(
            'onerror {quit -code 1}\nonbreak {quit -code 1}\nrun -all\nquit -code 0\n', encoding='ascii')
        sim = eda.modelsim_dir()
        flow.job('library', [sim / 'vlib.exe', 'work'], 60)
        compile_log = flow.job('compile', [sim / 'vlog.exe', '-vlog01compat', '+incdir+compile_sources/tb/lib',
                                          '+define+AFDX_CE_DIV=2', *(['+define+SYS_TOP_NETLIST'] if netlist else []), *sources], 600)
        flow.result['compile_diagnostics'] = {kind: len(re.findall(r'\*\* ' + kind + r'(?: \([^\n]*?\))?:', compile_log))
                                              for kind in ('Error', 'Fatal', 'Warning')}
        if re.search(r'\*\* (Error|Fatal)', compile_log):
            raise RuntimeError('编译出错，见 compile.log')
        print('GUI NETLIST START ' + test + ' mode=' + mode + ' output=' + str(flow.folder), flush=True)
        log = flow.job('simulation', [sim / 'vsim.exe', '-batch', '-t', '1ps', 'work.' + test,
                                    '-wlf', 'simulation.wlf', '-do', 'do run.do'], 5 * 3600)
        rows = re.findall(r'\[RESULT\]\s+(\w+)\s+(PASS|FAIL)\s+checks=(\d+)\s+errors=(\d+)', log)
        diagnostics = {kind: len(re.findall(r'\*\* ' + kind + ':', log)) for kind in ('Error', 'Fatal', 'Warning')}
        # 轮询读次数会随RTL延迟变化；网表必须与同次RTL参考的检查数完全一致。
        expected = '9238'
        if test == 'tb_net_services':
            if reference:
                expected = json.loads((reference / 'summary.json').read_text(encoding='utf-8'))['results'][0][2]
            else:
                expected = rows[0][2] if len(rows) == 1 and int(rows[0][2]) > 0 else 'invalid'
        flow.result.update(results=rows, diagnostics=diagnostics, mode=mode)
        if rows != [(test, 'PASS', expected, '0')] or diagnostics['Error'] or diagnostics['Fatal'] or 'RAMCOLL' in log:
            raise RuntimeError('测试没有完整通过，见 simulation.log')
        if test == 'tb_net_services':
            if reference:
                comparisons = compare_external_records(flow.folder, reference)
                flow.result['exact_external_records'] = comparisons
            command = [sys.executable, '-B', '-X', 'utf8', checker, 'check', '--dir', flow.folder]
            if reference:
                command += ['--rtl-reference', reference]
            flow.job('check', command, 120)
            flow.result['check'] = json.loads((flow.folder / 'check_summary.json').read_text(encoding='utf-8'))
            if flow.result['check']['errors']:
                raise RuntimeError('外部报文检查失败')
            if reference:
                if not all(comparisons.values()):
                    raise RuntimeError('网表与 RTL 的外部记录不一致')
        if any(eda.sha(Path(path)) != value for path, value in originals.items()):
            raise RuntimeError('运行期间原始输入发生变化')
        flow.result.update(passed=True, inputs=originals)
        seconds = next(job['seconds'] for job in flow.jobs if job['name'] == 'simulation')
        print(f'GUI NETLIST PASS {test} mode={mode} checks={expected} errors=0 simulation_s={seconds}', flush=True)
        return flow.folder
    except Exception as error:
        flow.result.update(passed=False, error=str(error), inputs=originals)
        # Flow.job raises on tool failure. Keep diagnostics even when it does
        # not return, without discarding or replacing the original failure log.
        for stage, key in (('compile', 'compile_diagnostics'), ('simulation', 'diagnostics')):
            path = flow.folder / (stage + '.log')
            if path.exists():
                log = path.read_text(encoding='utf-8-sig', errors='replace')
                flow.result[key] = {kind: len(re.findall(r'\*\* ' + kind + r'(?: \([^\n]*?\))?:', log))
                                    for kind in ('Error', 'Fatal', 'Warning')}
                if stage == 'simulation':
                    flow.result['results'] = re.findall(r'\[RESULT\]\s+(\w+)\s+(PASS|FAIL)\s+checks=(\d+)\s+errors=(\d+)', log)
        if (flow.folder / 'check_summary.json').exists():
            flow.result['check'] = json.loads((flow.folder / 'check_summary.json').read_text(encoding='utf-8'))
        print(f'GUI NETLIST FAIL {test} mode={mode}: {error}', flush=True)
        raise
    finally:
        if reference:
            flow.result['exact_external_records'] = compare_external_records(flow.folder, reference)
        eda.save(flow.folder / 'modelsim_adaptations.json', adaptations)
        eda.save(flow.folder / 'input_manifest.json', copied)
        flow.result['modelsim_adaptations'] = len(adaptations)
        flow.result['inputs_unchanged'] = {path: Path(path).is_file() and eda.sha(Path(path)) == value
                                           for path, value in originals.items()}
        flow.finish()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test', choices=('tb_elinx', 'tb_net_services'), default='tb_elinx')
    parser.add_argument('--netlist', type=Path, default=ROOT / 'elinx/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm')
    parser.add_argument('--deadline', help='任务截止时间，默认从启动起五小时')
    args = parser.parse_args()
    deadline = args.deadline or (datetime.now().astimezone() + timedelta(hours=5)).isoformat()
    try:
        if not args.netlist.is_file():
            raise RuntimeError('找不到界面综合网表，请先在 eLinx 中运行 Run Synthesis')
        model_dir = eda.elinx_bin().parents[2] / 'Simulation/elinx_lib'
        reference = run_case(args.test, deadline) if args.test == 'tb_net_services' else None
        run_case(args.test, deadline, args.netlist.resolve(), model_dir, reference)
        return 0
    except Exception as error:
        print('GUI NETLIST ENTRY FAIL: ' + str(error), flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
