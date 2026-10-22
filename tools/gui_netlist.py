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

RECORDS = ('net_services.txt', 'es1_a.txt', 'es1_b.txt', 'es2_a.txt',
           'es2_b.txt', 'es2_rx_a.txt', 'download_results.txt')
MODELS = ('220model.v', 'altera_mf.v', 'altera_primitives.v',
          'stratix_atoms.v', 'stratixiv_atoms.v')


def run_case(test, deadline, netlist=None, model_dir=None, reference=None):
    mode = 'gui' if netlist else 'rtl'
    flow = eda.Flow('gui_netlist', test + '_' + mode, deadline)
    sources = []
    originals = {}

    def copy(source, relative):
        source = Path(source)
        destination = flow.folder / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        originals[str(source)] = eda.sha(source)
        shutil.copy2(source, destination)
        if eda.sha(destination) != originals[str(source)]:
            raise RuntimeError('输入文件复制校验失败：' + source.name)
        return relative

    try:
        if netlist:
            copy(netlist, 'original.vqm')
            flow.result['adaptation'] = adapt(flow.folder / 'original.vqm', flow.folder / 'simulation.vqm')
            sources.append('simulation.vqm')
            for name in MODELS:
                sources.append(copy(model_dir / name, name))
        else:
            for path in sorted((ROOT / 'rtl').glob('*.v')):
                sources.append(copy(path, 'rtl/' + path.name))
        for path in sorted((ROOT / 'tb/lib').iterdir()):
            if path.suffix in ('.v', '.vh'):
                name = copy(path, 'lib/' + path.name)
                if path.suffix == '.v':
                    sources.append(name)
        sources.append(copy(ROOT / 'tb' / (test + '.v'), test + '.v'))
        checker = ROOT / 'tools/net_services_ref.py'
        if test == 'tb_net_services':
            for name in ('net_services_ref.py', 'load_ref.py', 'download_ref.py', 'snmp_ref.py', 'afdx_ref.py'):
                originals[str(ROOT / 'tools' / name)] = eda.sha(ROOT / 'tools' / name)
            flow.job('vectors', [sys.executable, '-B', '-X', 'utf8', checker, 'vectors', '--dir', flow.folder], 60)
        (flow.folder / 'run.do').write_text(
            'onerror {quit -code 1}\nonbreak {quit -code 1}\nrun -all\nquit -code 0\n', encoding='ascii')
        sim = eda.modelsim_dir()
        flow.job('library', [sim / 'vlib.exe', 'work'], 60)
        compile_log = flow.job('compile', [sim / 'vlog.exe', '-vlog01compat', '+incdir+lib', *sources], 600)
        if re.search(r'\*\* (Error|Fatal)', compile_log):
            raise RuntimeError('编译出错，见 compile.log')
        print('GUI NETLIST START ' + test + ' mode=' + mode + ' output=' + str(flow.folder), flush=True)
        log = flow.job('simulation', [sim / 'vsim.exe', '-c', '-t', '1ps', 'work.' + test,
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
        if rows != [(test, 'PASS', expected, '0')] or diagnostics['Error'] or diagnostics['Fatal']:
            raise RuntimeError('测试没有完整通过，见 simulation.log')
        if test == 'tb_net_services':
            command = [sys.executable, '-B', '-X', 'utf8', checker, 'check', '--dir', flow.folder]
            if reference:
                command += ['--rtl-reference', reference]
            flow.job('check', command, 120)
            flow.result['check'] = json.loads((flow.folder / 'check_summary.json').read_text(encoding='utf-8'))
            if flow.result['check']['errors']:
                raise RuntimeError('外部报文检查失败')
            if reference:
                comparisons = {name: (flow.folder / name).read_bytes() == (reference / name).read_bytes() for name in RECORDS}
                flow.result['exact_external_records'] = comparisons
                flow.result['rtl_reference'] = str(reference)
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
        print(f'GUI NETLIST FAIL {test} mode={mode}: {error}', flush=True)
        raise
    finally:
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
