"""Collect completed T77 v2 evidence and write the final bounded report."""
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from v2_source_check import ROOT, EVIDENCE, REVISION, TZ, digest, save, stamp
sys.path.insert(0, str(ROOT / 'tools'))
import eda
import psutil


def load(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def copy(source, target):
    target = EVIDENCE / 'v2_raw' / target
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    return target.relative_to(EVIDENCE).as_posix()


def local_time(value):
    return datetime.fromisoformat(value).astimezone(TZ).strftime('%Y-%m-%d %H:%M:%S')


def warning_records(path, pattern):
    lines = path.read_text(encoding='utf-8-sig', errors='replace').splitlines()
    return [dict(line=i + 1, message=line, context=lines[i + 1:i + 3])
            for i, line in enumerate(lines) if re.search(pattern, line)]


def main():
    text = load(EVIDENCE / 'v2_text_equivalence.json')
    graph = load(EVIDENCE / 'v2_final_vqm_comparison.json')
    sims = load(EVIDENCE / 'v2_simulations.json')
    synth = load(EVIDENCE / 'v2_synthesis.json')
    routes = load(EVIDENCE / 'v2_route_tests.json')
    e2e = load(EVIDENCE / 'v2_end_to_end.json')
    gui = load(EVIDENCE / 'v2_gui_simulation.json') if (EVIDENCE / 'v2_gui_simulation.json').exists() else {}
    if not text['passed'] or not graph['passed'] or not sims['complete'] or not sims['passed']:
        raise RuntimeError('Compatibility acceptance incomplete')
    if len(routes['cases']) != 1 or 'collected' not in routes or 'finished' not in e2e:
        raise RuntimeError('Complete R1 and the replacement end-to-end test before reporting')
    cancelled = load(EVIDENCE / 'v2_route_R2.json')
    if cancelled.get('tools_launched') is not False:
        raise RuntimeError('Superseded R2 was not cancelled')
    route_rows = [routes['cases'][0], dict(e2e, label='E2E', matches_delivery=e2e['accepted'],
                  expected_vqm_sha256=e2e.get('vqm_sha256'))]
    for name in ('summary.md', 'status.json', 'execution_context.json', 'manifest.json'):
        saved = EVIDENCE / ('v1_' + name)
        before = subprocess.check_output(['git', 'show', REVISION + ':docs/evidence/t77_rtl_compat/' + name], cwd=ROOT)
        if saved.exists() and saved.read_bytes() != before:
            raise RuntimeError('Historical evidence differs: ' + name)
        saved.write_bytes(before)
    card = Path('E:/2026_Embedded_FPGA/cards/T77_rtl_modelsim_compat.md')
    copy(card, 'task_card_v2.md')
    baseline_source = load(EVIDENCE / 'original_source_comparison.json')
    source_bindings = {r['path']: text['source_files'][r['path']]['before_sha256'] == r['baseline_sha256']
                       for r in baseline_source['files']}
    if len(source_bindings) != 35 or not all(source_bindings.values()):
        raise RuntimeError('Original source no longer bound to the baseline snapshot')
    save(EVIDENCE / 'v2_original_source_binding.json', dict(passed=True, files=source_bindings,
         note='All 35 original bytes from parent commit match the designated baseline synthesis source snapshot.'))

    compiled = load(ROOT / 'out/latest_v2_direct.json')
    compile_folder = Path(compiled['folder'])
    compile_logs = {name: copy(compile_folder / (name + '.log'), 'compile/' + name + '.log')
                    for name in ('modelsim', 'iverilog', 'vlib')}
    for name in ('summary.json', 'tool_metrics.json'):
        copy(compile_folder / name, 'compile/' + name)
    compilation = dict(passed=compiled['passed'], modelsim_errors=0, modelsim_warnings=0,
                       iverilog_exit_code=compiled['jobs'][-1]['exit_code'],
                       iverilog_diagnostic_lines=(compile_folder / 'iverilog.log').read_text().splitlines(),
                       jobs=compiled['jobs'], logs=compile_logs, direct_rtl=True)
    save(EVIDENCE / 'v2_compilation.json', compilation)
    copy(ROOT / 'out/t77_v2/diagnostic_fixture_checks.json', 'diagnostic_fixture_checks.json')
    tcl = load(ROOT / 'out/t77_v2_latest_tcl_direct_default.json')
    for name in ('summary.json', 'tool_metrics.json', 'tcl_probe.log', 'entry.do'):
        copy(Path(tcl['folder']) / name, 'tcl_entry/' + name)

    first = ROOT / 'out/sim/tb_elinx/20261103_083017_659233'
    for name in ('summary.json', 'tool_metrics.json', 'compile.log', 'simulation.log'):
        copy(first / name, 'initial_tb_elinx_warning_rejection/' + name)
    warnings = {}
    sim_rows = []
    reference = ROOT.parent / 'c3_frag1030/docs/evidence/t75_frag1030/summary.md'
    reference_text = reference.read_text(encoding='utf-8-sig')
    reference_rows = []
    for row in sims['results']:
        result = load(Path(row['summary']))
        folder = Path(result['folder'])
        for name in ('summary.json', 'tool_metrics.json', 'compile.log', 'simulation.log', 'check.log', 'check_summary.json'):
            if (folder / name).exists():
                copy(folder / name, 'sim/' + row['test'] + '/' + name)
        warnings[row['test']] = warning_records(folder / 'simulation.log', r'\*\* Warning:')
        job = next(j for j in result['jobs'] if j['name'] == 'simulation')
        items = result.get('check', {}).get('items')
        match = re.search(r'(?m)^\| ' + row['test'] + r' \| RTL \| PASS \| (\d+) \| ([^|]+) \|.*$', reference_text)
        if not match or int(match[1]) != result['checks']:
            raise RuntimeError('T75 check-count binding failed')
        reference_items = match[2].strip()
        if reference_items.isdigit() and int(reference_items) != items:
            raise RuntimeError('T75 independent-item count differs')
        reference_rows.append(match[0])
        sim_rows.append(dict(test=row['test'], checks=result['checks'], independent_items=items,
            warnings=result['simulation_diagnostics']['Warning'], rx_assertion_messages=result['rx_assertion_messages'],
            unexpected_warnings=len(result['unexpected_simulation_warnings']),
            errors=result['errors'], passed=result['passed'], seconds=job['seconds'],
            started=local_time(result['started']), finished=local_time(result['finished']),
            native_summary=row['summary']))
    save(EVIDENCE / 'v2_simulation_acceptance.json', dict(passed=all(r['passed'] for r in sim_rows), results=sim_rows,
         t75_reference=str(reference), t75_reference_sha256=digest(reference.read_bytes()), reference_rows=reference_rows))
    for name in ('analysis.log', 'export.log', 'tool_metrics.json', 'summary.json'):
        copy(Path(synth['folder']) / name, 'synthesis/' + name)
    warnings['official_synthesis'] = warning_records(Path(synth['folder']) / 'analysis.log', r'^Warning')
    warnings['official_synthesis_end_to_end'] = warning_records(Path(e2e['folder']) / 'analysis.log', r'^Warning')
    for case in route_rows:
        for phase in ('pack', 'timing', 'route'):
            log = Path(case['folder']) / (phase + '.log')
            if log.exists():
                warnings[case['label'] + '_' + phase] = warning_records(log, r'\[(?:WARN|WARNING)\]|^Warning')
    warnings['modelsim_compile'] = warning_records(compile_folder / 'modelsim.log', r'\*\* Warning:')
    warnings['iverilog_compile'] = []
    save(EVIDENCE / 'v2_warnings.json', dict(counts={k: len(v) for k, v in warnings.items()}, records=warnings))

    for case in route_rows:
        folder = Path(case['folder'])
        for name in ('pack.log', 'timing.log', 'route.log', 'tool_metrics.json', 'summary.json',
                     'pack.tcl', 'timing.tcl', 'route.tcl', 'analysis.log', 'export.log'):
            if (folder / name).exists():
                copy(folder / name, case['label'] + '/' + name)
        output = folder / 'project/AFDX_EndSystem.runs/imple_1'
        for suffix in ('.place', '.tan.rpt', '.slack.rpt', '_utilization_placed.rpt', '.edi'):
            path = output / ('AFDX_EndSystem' + suffix)
            if path.exists():
                copy(path, case['label'] + '/' + path.name)

    resources = []
    for name in ('v2_synth_runner.json', 'v2_sims_runner.json', 'v2_route_tests.json', 'v2_end_to_end.json'):
        resources.extend(load(EVIDENCE / name).get('resources', []))
    remaining = []
    all_jobs = compiled['jobs'] + synth['jobs']
    all_jobs += [j for r in sims['results'] for j in load(Path(r['summary']))['jobs']]
    all_jobs += [j for r in route_rows for j in r['jobs']]
    for job in all_jobs:
        try:
            if psutil.Process(job['pid']).create_time() == job['created']:
                remaining.append(job)
        except psutil.NoSuchProcess:
            pass
    peers = []
    for p in routes['protected_before']:
        row = {k: p[k] for k in ('pid', 'created', 'name')}
        try:
            row['same_process_still_running'] = psutil.Process(p['pid']).create_time() == p['created']
        except psutil.NoSuchProcess:
            row['same_process_still_running'] = False
        peers.append(row)
    now = stamp()
    status = dict(status='COMPLETE_V2' if e2e['accepted'] and gui.get('passed') else
                  'STOPPED_E2E_GATE' if not e2e['accepted'] else 'GUI_NOT_VERIFIED',
        report_time=now, branch='t77', parent_commit=REVISION,
        compatibility_passed=True, text_equivalence_passed=True, official_input_audit_passed=True,
        original_source_binding_passed=True, vqm_structure_passed=True, compiled_both_tools=True,
        five_direct_rtl_simulations_passed=True, checks_and_independent_items_equal_to_t75=True,
        end_to_end_accepted=e2e['accepted'], gui_behavioral_simulation_passed=gui.get('passed', False),
        fixed_vqm_r2_cancelled=True,
        route_tests_authorized_by_appendix=True,
        route_tests={r['label']: {k: r.get(k) for k in ('completed', 'matches_delivery', 'timing_closed',
            'exact_cluster_locks', 'exact_delivery_timing', 'expected_vqm_sha256', 'error', 'route_wrapper_error')}
            for r in route_rows},
        min_launch_free_memory_gib=min(r['free_memory_gib'] for r in resources),
        min_launch_e_free_gib=min(r['e_free_gib'] for r in resources),
        remaining_owned_tool_processes=remaining, peer_process_presence_at_closeout=peers,
        no_subagents=True, no_heartbeat=True, no_scheduled_tasks=True, no_push=True,
        no_merge=True, no_amend=True, no_lock_edits=True, no_optimization=True,
        total_deadline='2026-11-04 05:26:50')
    if remaining:
        raise RuntimeError('An owned tool is still active')
    save(EVIDENCE / 'status.json', status)
    context = dict(task_card=str(card), task_card_sha256=digest(card.read_bytes()),
        initial_head=REVISION, report_time=now, total_deadline=status['total_deadline'],
        configured_behavioral_simulator=load(EVIDENCE / 'v1_execution_context.json')['configured_behavioral_simulator'],
        direct_source_environment='AFDX_MODELSIM_DECL_ORDER=0', maximum_owned_elinx=1, maximum_owned_modelsim=1,
        route_tests='R1 existing original VQM, then modified RTL full build_1030 --route --pres 1.30. R2 cancelled. Route budgets <=3600 seconds.',
        native_logs='Unmodified native timestamps; report tables use converted timestamps')
    save(EVIDENCE / 'execution_context.json', context)

    r1 = routes['cases'][0]
    if r1['matches_delivery'] and e2e['accepted']:
        conclusion = 'R1 精确复现基准；改动后源码的完整端到端流程也通过正时序、零失败端点、锁定与 P0 门槛。本轮未出现两条路径一正一负的情况。'
    elif not e2e['accepted']:
        conclusion = '改动后源码的端到端门槛未通过，按用户要求停止，不改锁定、不用 --no-tiles、不追加优化或重试。兼容编译与文本等价通过不能替代这一失败。'
    else:
        conclusion = 'R1 与改动后源码端到端结果不同，分别保留原始时序、打包与锁定证据；需按差异分析理解，不能只按 VQM 字节不同归因于 RTL。'
    lines = [
        '# T77 v2 执行报告', '',
        f'命令行兼容验收 **PASS**：21 处声明已加 `MODEL_TECH` 分支，综合输入文本等价、实际综合入口核对、双工具编译、五项直接 RTL 仿真与检查数通过。最终端到端构建：**{"PASS" if e2e["accepted"] else "FAIL"}**；eLinx 行为仿真界面路径：**{"PASS" if gui.get("passed") else "未验证"}**。最终结论以各门槛独立实测为准。', '',
        f'报告时间：{now}。工作区 `c3_t77`，分支 `t77`，从 `{REVISION}` 继续；本报告随最终本地提交保存。总截止为 {status["total_deadline"]}。', '',
        '## 实现与文本等价', '',
        '- 仅修改指定 7 份 RTL 的 21 条声明。位宽、属性、初始化表达式和电路逻辑不变；带初始化 wire 仅在 ModelSim 分支拆成提前声明与原位置连续赋值。`$fatal` / `$finish_and_return` 保留原样。',
        '- ModelSim 自动定义 `MODEL_TECH`；非 ModelSim 分支保留原声明位置。Python 与 Tcl 仿真入口默认直接编译 RTL，验收显式设置 `AFDX_MODELSIM_DECL_ORDER=0`、`AFDX_CE_DIV=2`。',
        '- `iverilog -g2001 -E`，命令行不定义任何宏；保留 Icarus 内建宏，未定义 `MODEL_TECH`。逐 token 保序比较，并独立核对去空行后的原始字节。7 份文件各自相同，完整 `elinx/afdx_all.v` 展开后的 99,689 个 token 也完全相同；没有 token 排序或名称归一化。',
        '- 35 份原始输入字节绑定到指定基准的冻结源码；未改动的 27 份 RTL 和综合入口逐字节保持不变。详见 `v2_original_source_binding.json`、`v2_source_edits.json`、`v2_text_equivalence.json`；可复核脚本为 `v2_source_check.py`。',
        '- `quartus_map` 原生 Source Files Read 表中 34 份用户 RTL 与预处理证明的清单及哈希完全一致；QSF 仅列一个 `afdx_all.v`，分析日志确认该入口的 42 个设计单元。其余读入均为安装目录厂商库或本次 db 自动生成文件，无未核对入口，见 `v2_synthesis_inputs.json`。', '',
        '## 编译、直接 RTL 仿真与警告', '',
        'ModelSim `vlog -vlog01compat`、Icarus `iverilog -g2001 -s AFDX_top` 整顶层编译均成功，0 错误、0 警告。`v2_compilation.json` 保存 PID、创建时刻、命令、预算与日志。未手动定义 `MODEL_TECH`。', '',
        '| 测试 | 结果 | 自检数 | 独立核对项 | 原生警告 | 仿真秒数 | 开始 | 结束 |',
        '|---|---|---:|---:|---:|---:|---|---|',
    ]
    for r in sim_rows:
        lines.append(f'| {r["test"]} | PASS | {r["checks"]} | {r["independent_items"] if r["independent_items"] is not None else "—"} | {r["warnings"]} | {r["seconds"]} | {r["started"]} | {r["finished"]} |')
    lines += ['',
        '全部检查数及独立核对项与 T75 相同，Error/Fatal/RAMCOLL/RX_ASSERT/未知警告均为 0。五项均直接编译 34 份 RTL，无兼容副本、无网表替换。详情见 `v2_simulation_acceptance.json`，逐项日志、完整输入哈希与进程收据在 `v2_raw/sim/`。', '',
        '首轮 `tb_elinx` 自检 PASS 9,238 项，但旧运行器因 84 条警告返回 FAIL，原始失败记录完整保留在 `v2_raw/initial_tb_elinx_warning_rejection/`。随后只在仿真入口识别已知诊断并完整记录：未定义 `$finish_and_return`（vsim-PLI-3003），以及 `raw_write_data`、`next_limit` 两个默认模式不读取的可选输入未连接警告。未抑制日志或修改 RTL 断言。出现任何 `[RX_ASSERT]` 消息仍判失败；Error/Fatal/RAMCOLL 和未知警告也仍判失败。7 项离线夹具验证这些判定，不构成功能仿真证据。', '',
        '这五项没有触发上述断言；不证明未定义的 `$finish_and_return` 被触发后能够终止仿真。yosys 辅助网表兼容不在本次范围。编译、仿真、综合的每条警告及上下文见 `v2_warnings.json`；官方综合 64 条警告未抑制。', '',
        'Tcl 原生入口验证默认值与显式 0 都返回同一组 34 份原 RTL，见 `v2_raw/tcl_entry/`。eLinx 的 ModelSim 安装路径已只读核对；界面行为仿真的实际状态、隔离工程和进程证据见 `v2_gui_simulation.json`。未重跑完整评委入口。', '',
        ('界面实际仿真已通过；记录的工程仅为本任务隔离副本。' if gui.get('passed') else
         '界面验证未完成：窗口工具两次 launch_app 超时，按快捷方式工作目录启动也未获得 eLinx 窗口，系统同时出现 SmartScreen 进程。没有操作安全界面。已核实身份并取消本任务阻塞的启动控制器，未触碰安全进程或 T75/T76；已请用户手动打开隔离工程后继续。这一项保留未验证，不能以 CLI 通过替代。'), '',
        '## 综合不确定性', '',
        '| VQM | SHA256 |', '|---|---|',
    ]
    for label, info in graph['files'].items():
        lines.append(f'| {label} | `{info["sha256"]}` |')
    lines += ['',
        '逐项比较见 `v2_final_vqm_comparison.json`。所有文件均为 115,027,164 bytes；去掉注释行后的排序行集合相同。逐个核对 65,255 个同名单元（62,274 个 lcell、2,981 个 RAM 段）的类型、全部功能参数及带顺序的端口 token，并核对 134 条赋值与顶层端口声明，名称映射为恒等映射。排序仅用于差异分类，未替代主要的源码 token 等价门槛。', '',
        'GUI 的 `02199801…` 与基准 `3cd8f5f8…` 去掉整行 // 注释后仍有 2,739 个对应行位置不同，保序比较不相同；与 v1 的 `e9e1734c…` 也有 2,739 处。基准/v1/v2 初次综合两两均为 2,729 处。这些差异是文本排列，未找到名字、功能参数或连接变化。见 `v2_gui_ordered_comparison.json`、`v2_gui_structure.json`。', '',
        '三次历史 QSF 除输入/输出路径及 GUI 工程创建时间外，功能设置逐行相同；默认 QDF 完全相同，QPF 仅有注释和日期元数据差别。三次均启用 Parallel Synthesis、seed=1，允许最多 6 个处理器，但原生统计的平均使用数 1.00、最大使用数 1。GUI/基准/v1 的原生墙钟耗时分别为 15:27、17:52、04:20；没有足够的历史全机负载采样，不能把耗时差或特定排列变化归因于负载。设置、路径、CPU 统计和原始日志摘录见 `v2_synthesis_environment.json`。', '',
        '最可能的环节是 VQM 导出时未固定的等价节点枚举/序列化顺序；这是基于差异仅在排列且逻辑记录相同的推断，尚未定位到具体内部容器或路径/进程地址因素。证据不支持将原因直接定为并行处理器数量。', '',
        '按追加要求，在唯一一次端到端构建的隔离 QSF 副本设置 `NUM_PARALLEL_PROCESSORS=1`；原生报告确认 Maximum allowed=1。导出 VQM 为 `96d14e2f…`，与基准的保序非注释行仍有 2,729 处不同；本次探测没有恢复基准顺序，不能宣称该设置已使输出固定。见 `v2_single_processor_ordered.json`。没有再开额外综合重试来寻找相同哈希。', '',
        f'初次 v2 官方 map/export：{synth["started"]} 至 {synth["finished"]}。后续用户批准 R1，并以改动后源码完整构建取代固定 VQM 的 R2；总预算放宽为 5 小时。R2 在工具启动前取消，见 `v2_route_R2.json`。旧串行控制器在 R1 后被已有收据门槛阻止，不是 R1 原生流程失败。', '',
        '### R1 与最终端到端验收', '',
        'R1 使用官方 `run_pack.tcl` 的 `udm_parse_vqm` 导入 v1 原样网表 `e9e1734c…`，重新原生打包、综合后时序、锁定布线，未重新综合或复用旧 ECP。最终端到端流程调用未经修改的 `build_1030.main()`，参数为 `--route --pres 1.30`，仅在运行副本新增上述单处理器设置；从改动后 RTL 重新综合并使用新网表完成全部流程。两条流程均使用新输出目录、默认全部锁定及 P0，未传 `--no-tiles`、未改锁定或重新优化；R1 完成后才启动端到端构建。综合预算 1,800 秒，路由预算 3,600 秒。', '',
        '| 测试 | 原生布线完成 | 本项门槛通过 | 保留/预期锁定簇 | 缺失/新增/偏移 | setup ps | hold ps | setup 失败/总数 | hold 失败/总数 | P0 |',
        '|---|---|---|---|---|---:|---:|---|---|---|',
    ]
    for r in route_rows:
        n = r['native']; l = n.get('locks', {}); clocks = n.get('timing', {}).get('clocks', [])
        c = clocks[0] if clocks else {}
        lines.append(f'| {r["label"]} | {r["completed"]} | {r["matches_delivery"]} | {l.get("retained", "—")}/{l.get("expected", "—")} | {l.get("missing", "—")}/{l.get("extra", "—")}/{l.get("moved", "—")} | {c.get("setup_worst_slack", "—")} | {c.get("hold_worst_slack", "—")} | {c.get("setup_fail_ends", "—")}/{c.get("setup_total_ends", "—")} | {c.get("hold_fail_ends", "—")}/{c.get("hold_total_ends", "—")} | {n.get("p0_unchanged", False)} |')
    lines += ['', '| 流程 | 开始 | 结束 | 墙钟秒数 | LUT / FF | CLB / Memory | Pins / DSP / PLL |',
              '|---|---|---|---:|---|---|---|']
    for r in route_rows:
        resources_row = r['native'].get('resources', {})
        lines.append(f'| {r["label"]} | {r["started"]} | {r["finished"]} | {r["elapsed_seconds"]} | '
            f'{resources_row.get("lut", "—")} / {resources_row.get("ff", "—")} | '
            f'{resources_row.get("clb", "—")} / {resources_row.get("memory", "—")} | '
            f'{resources_row.get("pins", "—")} / {resources_row.get("dsp", "—")} / {resources_row.get("pll", "—")} |')
    lines += ['', conclusion, '',
        '时序按数据库原始 ps 精度判定，未用四舍五入值放宽门槛。锁定计数只含 CLB/M4K，P0 的 172 个 I/O pad 单独核对；`v2_placement_xyz.json` 独立核对全部 X/Y/Z，并确认 R1、端到端与基准的 `.place` 逐字节相同。初版采集器把 I/O pad 也计入簇集合，收尾已从同一原生 `.place` 只读重算；初版收据与实际执行的采集脚本留在 `v2_raw/`，没有因此重跑 EDA。', '',
        '每项的 VQM 哈希、资源、原始时序字段、落位/P0 明细、错误、PID/创建时刻/命令/预算、开始结束及输入不变性见 `v2_route_R1.json`、`v2_end_to_end.json`。原生流程日志、`.place`、时序与资源报告在 `v2_raw/R1/`、`v2_raw/E2E/`。大体积检查点与布线产物保留在相应 `out/t77_route/` 和 `out/build1030/`，未纳入 Git。', '',
        '### 交付需要的文件与步骤', '',
        '1. 携带本提交的完整源码、工程和脚本；若携带已验证网表，则为每份 VQM 一并携带其 SHA256、匹配的检查点、锁定、布线及原生时序证据。基准旧时序与本次新网表的时序分别绑定，不混用。',
        '2. 携带同提交的工程及脚本，特别是 `elinx/AFDX_EndSystem.epr`、`elinx/AFDX_EndSystem_assignment_defaults.qdf`、`elinx/constraints_t62.json`（P0）、`elinx/timing_only.sdc`、`elinx/tiles_1030.edc`；保留本报告和完整 `tools/`、本证据目录中的运行脚本及其 Python 依赖。',
        '3. 使用与本机相同的 eLinx 3.0.7 / EQ6HL130 / CSG484_H 安装组件。R1 启动时记录原生 pack、综合时序和 route 脚本哈希；端到端收尾再次读取并确认三份安装脚本与 R1 相同。`constraints.edc` 与 `imple_constraints.edc` 在隔离输出目录按上述不变输入生成，前者包含 8 ns / 0.30 ns、P0 和 PRES，后者再添加全部锁定。',
        '4. 在工程根目录设置仿真 `AFDX_MODELSIM_DECL_ORDER=0`，eLinx 行为仿真顶层为 `tb_elinx`。从源码重建使用 `tools/build_1030.py --route --pres 1.30`；本次单处理器探测的完整封装和唯一执行收据为 `v2_end_to_end.py`、`v2_end_to_end.json`。已有 VQM 的直接官方打包/布线路径见 `v2_route.py --label <新标签> --vqm <路径> --sha256 <完整哈希> --deadline <本次截止>`，无需原始综合数据库。',
        '5. 核对新输出自身 VQM 哈希、默认锁定的全部落位与 0 偏移、172 个 P0 管脚，以及数据库原始精度 setup > 0、hold >= 0、setup/hold 均 0 失败端点。数值是否精确回到 +29/+604 ps 在上表另行报告。若不满足，只保留结果并停止，不放宽锁定或另行优化。', '',
        '原有时序证据绑定基准 VQM；本次改动后源码的端到端结果独立绑定其新网表与相应布线输出。上述单机试验不等于跨安装或跨机器的普遍确定性证明。未实际创建或修改交付包。', '',
        '## 资源、边界与历史', '',
        f'- 有记录的工具启动前采样：可用内存最小 {status["min_launch_free_memory_gib"]:.3f} GiB，E 盘最小 {status["min_launch_e_free_gib"]:.3f} GiB；资源与进程身份详见各 runner 收据。最多 1 个本任务 eLinx、1 个本任务 ModelSim；v2 综合、R1、最终端到端构建串行，五项仿真自身串行。',
        '- T75/T76 工作区只读，未结束或挂起其进程。收尾 PID/创建时刻核对见 `status.json`；记录的本任务工具均已退出。未写禁止目录、eLinx 设置或 `~/.codex/`；未派子代理、heartbeat、定时任务、定时续接、push、合并或 amend。',
        '- `v1_summary.md`、`v1_status.json`、`v1_execution_context.json`、`v1_manifest.json` 保留 d3cffda5 上的 v1 停止现场，原综合和编译失败日志未覆盖。本轮可从 `status.json`、本报告、`manifest.json` 进入。', '',
        'Skills used：`windows-toolbox` 用于 Windows 命令、路径、进程身份和原始产物核对；`computer-use` 用于界面启动诊断及隔离工程验证。', '',
        'Subagents used：无。', '',
    ]
    (EVIDENCE / 'summary.md').write_text('\n'.join(lines), encoding='utf-8')
    manifest = {p.relative_to(EVIDENCE).as_posix(): dict(bytes=p.stat().st_size, sha256=digest(p.read_bytes()))
                for p in sorted(EVIDENCE.rglob('*')) if p.is_file() and p.name != 'manifest.json'
                and '__pycache__' not in p.parts}
    save(EVIDENCE / 'manifest.json', dict(files=manifest, report_time=now))
    print(json.dumps(dict(status=status['status'], compatibility_passed=True,
        route_matches={r['label']: r['matches_delivery'] for r in route_rows},
        files=len(manifest), report=str(EVIDENCE / 'summary.md')), indent=2))


if __name__ == '__main__':
    main()
