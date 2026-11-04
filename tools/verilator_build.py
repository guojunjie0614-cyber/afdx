"""Build timing-enabled simulations with the Verilator shipped inside eLinx.

The original RTL is untouched. An isolated simulation copy maps Icarus-only
$finish_and_return(1) assertions to standard $fatal(1). Native compilation uses
an explicit C++20 compiler, without requiring make or changing system PATH.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
VERILATOR = Path('C:/Program Files (x86)/eHiWay/eLinx3.0/verilator/verilator.exe')


def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def snapshot(folder):
    edits = []
    task_names = set()
    for source in (ROOT/'tb').rglob('*'):
        if source.suffix in ('.v', '.vh'):
            task_names.update(re.findall(r'\btask\s+(?:automatic\s+)?(\w+)', source.read_text(encoding='utf-8-sig')))
    task_call = re.compile(r'(?<![\w$.])((?:[A-Za-z_]\w*\.)*(?:'+ '|'.join(sorted(task_names)) + r')\s*\([^;]*?\);)')
    for subdir in ('rtl', 'tb'):
        for source in (ROOT/subdir).rglob('*'):
            if not source.is_file() or source.suffix not in ('.v', '.vh'):
                continue
            text = source.read_text(encoding='utf-8-sig')
            # The bundled Windows preprocessor drops this test-only include.
            # Its standalone -E output retains the body, whereas the parent
            # -E output omits it. Expand the exact header in simulation copies.
            headers = 0
            if subdir == 'tb':
                text, headers = re.subn(r'`include\s+"download_test_tasks\.vh"',
                    lambda _: '\n'+(ROOT/'tb/lib/download_test_tasks.vh').read_text(encoding='utf-8-sig')+'\n', text)
            text, n = re.subn(r'\$finish_and_return\(1\)', '$fatal(1)', text)
            # 5.006 inlines a bare task directly under fork into separate fork
            # branches. An explicit sequential block preserves each task call.
            wrapped = [0]
            def fork_block(match):
                def wrap(call):
                    wrapped[0] += 1
                    return 'begin ' + call[1] + ' end '
                return 'fork' + task_call.sub(wrap, match[1]) + match[2]
            text = re.sub(r'\bfork\b(.*?)\b(join(?:_any|_none)?)\b', fork_block, text, flags=re.S)
            relative = source.relative_to(ROOT)
            zero_delay = 0
            if relative.as_posix() in ('tb/lib/gmii_monitor.v', 'tb/lib/line_monitor.v'):
                # These monitors sample synchronous NBA-driven buses before NBA.
                # Skip only the zero inactive-region suspension; a positive
                # SAMPLE_DELAY retains its original post-edge sampling time.
                text, zero_delay = re.subn(r'#\(SAMPLE_DELAY\);',
                    'if (SAMPLE_DELAY != 0) #(SAMPLE_DELAY);', text)
            target = folder/relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding='utf-8')
            if n or wrapped[0] or zero_delay or headers:
                edits.append({'path': str(relative), 'fatal_exit_replacements': n,
                              'fork_task_blocks': wrapped[0], 'zero_delay_guards': zero_delay,
                              'expanded_test_headers': headers})
    save(folder/'adaptations.json', edits)
    return folder


def prepare_runtime(source, target):
    shutil.copytree(source/'include', target, dirs_exist_ok=True)
    config = (target/'verilated_config.h.in').read_text(encoding='utf-8')
    config = config.replace('@PACKAGE_NAME@', 'Verilator').replace('@PACKAGE_VERSION@', '5.006').replace('@VERILATOR_VERSION_INTEGER@', '5006000')
    (target/'verilated_config.h').write_text(config, encoding='utf-8')
    # Verilator 5.006 predates libc++ moving coroutines from experimental to std.
    compat = target/'experimental/coroutine'
    compat.parent.mkdir(exist_ok=True)
    compat.write_text('#include <coroutine>\nnamespace std { namespace experimental {\nusing std::coroutine_handle; using std::coroutine_traits;\nusing std::suspend_always; using std::suspend_never;\nusing std::noop_coroutine; using std::noop_coroutine_handle; using std::noop_coroutine_promise;\n}}\n', encoding='ascii')


def command(args, cwd, log, env=None, timeout=1800):
    begin = time.monotonic()
    with log.open('w', encoding='utf-8') as stream:
        from process_guard import run
        p = run(args, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout,
                metrics=log.with_suffix(log.suffix+'.resources.json'))
    if p.returncode:
        raise RuntimeError(f'exit={p.returncode}: {log}')
    return round(time.monotonic()-begin, 3)


def build(top, output, sources, runtime, compiler, jobs=4, params=(), extra=()):
    output.mkdir(parents=True, exist_ok=True)
    obj = output/'obj'
    obj.mkdir(exist_ok=True)
    env = os.environ.copy()
    # The eLinx executable still supplies the parser, elaborator and scheduler.
    env['VERILATOR_ROOT'] = str(runtime.parent).replace('\\', '/')
    env['PATH'] = str(compiler.parent) + os.pathsep + env.get('PATH', '')
    args = [VERILATOR, '--cc', '--main', '--timing', '--assert', '--compiler', 'clang',
            '--top-module', top, '--prefix', 'Vsim', '--Mdir', obj.as_posix(),
            '--output-split', '15000', '--output-split-cfuncs', '2000',
            '-Wno-fatal', '-Wno-TIMESCALEMOD', '-Wno-WIDTH', '-Wno-PINMISSING',
            '-DAFDX_CE_DIV=2', '-I'+(sources/'tb/lib').as_posix(),
            '-y', (sources/'tb/lib').as_posix(), *('-G'+p for p in params), *extra,
            *(p.as_posix() for p in sorted((sources/'rtl').glob('*.v'))),
            (sources/'tb'/(top+'.v')).as_posix()]
    result = {'top': top, 'parameters': list(params), 'verilator': str(VERILATOR), 'commands': []}
    result['verilate_seconds'] = command(args, output, output/'verilate.log', env)
    result['commands'].append(list(map(str,args)))
    cpp = sorted(obj.glob('*.cpp')) + [runtime/n for n in ('verilated.cpp','verilated_threads.cpp','verilated_timing.cpp')]
    common = [compiler, '-std=c++20', '-O1', '-DNDEBUG', '-DVL_TIME_CONTEXT',
              '-I'+str(obj), '-I'+str(runtime), '-I'+str(runtime/'vltstd')]
    def compile_one(source):
        target = obj/(source.stem+'.o')
        args = [*common, '-c', source, '-o', target]
        command(args, output, obj/(source.stem+'.build.log'), env)
        return target
    begin = time.monotonic()
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        objects = list(pool.map(compile_one, cpp))
    result['cpp_seconds'] = round(time.monotonic()-begin,3)
    response = obj/'objects.rsp'
    response.write_text('\n'.join('"'+p.as_posix()+'"' for p in objects)+'\n', encoding='utf-8')
    exe = output/'simulation.exe'
    # 5.006 can emit unused endpoint stimulus RAM as a 32 MB stack-local
    # initialization temporary. Reserve address space for that generated code;
    # Windows commits stack pages on demand. This changes no simulated timing.
    link_args = [compiler, '@'+str(response), '-o', exe, '-static', '-Wl,--stack,134217728']
    result['link_seconds'] = command(link_args, output, output/'link.log', env)
    result['commands'].append(list(map(str, link_args)))
    result['executable'] = str(exe)
    save(output/'build.json', result)
    return exe


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('top')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--runtime-source', type=Path, required=True)
    p.add_argument('--compiler', type=Path, required=True)
    p.add_argument('--jobs', type=int, default=4)
    p.add_argument('--param', action='append', default=[])
    p.add_argument('--generate-only', action='store_true')
    a = p.parse_args()
    output = a.out.resolve(); output.mkdir(parents=True, exist_ok=True)
    sources = snapshot(output/'sources')
    runtime = output/'runtime/include'
    prepare_runtime(a.runtime_source, runtime)
    exe = build(a.top, output, sources, runtime, a.compiler, a.jobs, a.param)
    print('BUILT '+str(exe), flush=True)


if __name__ == '__main__':
    main()
