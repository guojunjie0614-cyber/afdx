"""Collect actual T76 receipts; pending/failed gates are never promoted to PASS.

This is a finite postprocessing step, not a heartbeat or continuation service.
It may be run again explicitly after the bounded simulation queues terminate.
"""
import argparse
from datetime import datetime,timedelta,timezone
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

import psutil

from t76_stats import analyse
from t76_scan_t75 import scan

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/t76'
EVIDENCE=ROOT/'docs/evidence/t76_frag1030'


def load(path,default=None):
    return json.loads(Path(path).read_text(encoding='utf-8')) if Path(path).is_file() else default


def save(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_bytes((json.dumps(value,ensure_ascii=False,indent=2)+'\n').encode('utf-8'))


def replace_tail(path,title,text):
    source=path.read_text(encoding='utf-8')
    marker='\n## '+title+'\n'
    if marker in source:source=source[:source.index(marker)]
    path.write_bytes((source.rstrip()+'\n'+marker+'\n'+text.rstrip()+'\n').encode('utf-8'))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-terminal',action='store_true')
    parser.add_argument('--commit-guard',type=Path)
    args=parser.parse_args()
    if args.commit_guard:
        guard=load(args.commit_guard)
        branch=subprocess.check_output(['git','branch','--show-current'],cwd=ROOT,text=True).strip()
        if branch!='t76':raise RuntimeError('Unexpected branch; no source/doc overwrite or automatic commit')
        head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
        if head!=guard['head']:raise RuntimeError('HEAD changed; no source/doc overwrite or automatic commit')
        for relative,expected in {**guard.get('readonly',{}),**guard['files']}.items():
            if hashlib.sha256((ROOT/relative).read_bytes()).hexdigest()!=expected:
                raise RuntimeError('Task input changed; preserving current work: '+relative)
        expected_evidence={p for p in guard['files'] if p.startswith('docs/evidence/t76_frag1030/')}
        actual_evidence={p.relative_to(ROOT).as_posix() for p in EVIDENCE.rglob('*') if p.is_file()}
        if actual_evidence!=expected_evidence:
            raise RuntimeError('Evidence inventory changed; preserving files outside the recorded task snapshot')
        if subprocess.run(['git','diff','--cached','--quiet'],cwd=ROOT).returncode:
            raise RuntimeError('Index has unrelated staged changes; preserving index')
    EVIDENCE.mkdir(parents=True,exist_ok=True)
    timestamp=datetime.now(timezone(timedelta(hours=8))).strftime('%Y-%m-%d %H:%M:%S')
    primary=load(ROOT/'out/t76_fallback_parallel/summary.json',{})
    net=load(ROOT/'out/t76_vqm_parallel/summary.json',{})
    trial=load(OUT/'trial_gate.json',{})
    search_paths=sorted((OUT/'search_source/out/t76_search/tb_t76_mixed_search').glob('*/summary.json'))
    search_done=bool(search_paths)
    if not search_paths:search_paths=sorted((OUT/'search_source/out/t76_search/tb_t76_mixed_search').glob('*/progress.json'))
    search=load(search_paths[-1],{}) if search_paths else {}
    if search_paths and not search_done:
        active=load(search_paths[-1].parent/'active_job.json',{})
        search['active_child']=active
    save(EVIDENCE/'mixed_search.json',search)
    terminal=bool(primary.get('Finished') and net.get('Finished'))
    if args.require_terminal and not terminal:raise RuntimeError('Finite simulation queues are still active; no final acceptance')
    candidate_compile=load(ROOT/'out/t76_latest_source_compile.json',{})
    if candidate_compile:
        save(EVIDENCE/'candidate_source_compile.json',candidate_compile)
        for name in ('vlog.log','iverilog.log','tool_metrics.json'):
            source=Path(candidate_compile['folder'])/name
            if source.is_file():shutil.copy2(source,EVIDENCE/('candidate_'+name))
    perf_checks={}
    for label in ('baseline','actual'):
        receipts=sorted((ROOT/'out/t76_perf_check'/label).glob('*/summary.json'))
        receipt=load(receipts[-1],{}) if receipts else {}
        perf_checks[label]=receipt
        if receipt:
            save(EVIDENCE/('performance_'+label+'_current_checker.json'),receipt)
            captures=Path(receipt['folder'])/'captures'
            for name in ('check_summary.json','performance_metrics.json','perf_metrics.json'):
                if (captures/name).is_file():
                    shutil.copy2(captures/name,EVIDENCE/('performance_'+label+'_'+name))
    for name in ('build_launch.json','source_compat_edits.json','vqm_comparison.json',
        'vqm_difference_excerpt.json','candidate_abort.json','parallel_launch.json',
        'fallback_parallel_launch.json','vqm_parallel_launch.json','line2_equivalence.json',
        'smoke_validation.json','t75_sources.json','resource_slot_checks.json','trial_gate.json',
        'trial_build_launch.json','trial_vqm_binding.json','vqm_structure.json','packing_difference.json',
        'priority_pauses.json','critical_tx_launch.json','critical_main_launch.json','critical_net_launch.json',
        'bag2_source_manifest.json','bag_protocol_refinement.json'):
        if (OUT/name).is_file():shutil.copy2(OUT/name,EVIDENCE/name)
    if (OUT/'resource_actual.json').is_file():shutil.copy2(OUT/'resource_actual.json',EVIDENCE/'resource_actual.json')
    scans=scan(OUT/'t75_sources.json');save(EVIDENCE/'t75_xz_scan.json',scans)
    save(EVIDENCE/'primary_queue.json',primary);save(EVIDENCE/'netlist_queue.json',net)
    live=[]
    for queue in (primary,net):
        for row in queue.get('Active',[]):
            identity=row['Process'];entry=dict(worker=identity,kind=row['kind'],index=row['id'])
            try:
                worker=psutil.Process(identity['pid'])
                if worker.create_time()!=identity['created']:raise RuntimeError('Worker PID identity changed')
                entry['processes']=[dict(pid=p.pid,created=p.create_time(),name=p.name(),
                    cwd=p.cwd(),command=p.cmdline(),status=p.status()) for p in worker.children(recursive=True)
                    if p.name().lower() in ('vsim.exe','vsimk.exe','vlog.exe')]
            except psutil.NoSuchProcess:entry['note']='Original worker exited during this read-only snapshot'
            live.append(entry)
    save(EVIDENCE/'live_processes.json',dict(sampled_at=timestamp,workers=live))
    for run in net.get('Runs',[]):
        if run.get('Kind')!='VQM76' or not run.get('Folder'):continue
        folder=Path(run['Folder']);dest=EVIDENCE/('net_case_'+str(run['Index']));dest.mkdir(exist_ok=True)
        for name in ('summary.json','tool_metrics.json','official_inputs.tcl','official_compile.log',
                     'simulation.log','official_transcript.log','window.txt'):
            if (folder/name).is_file():shutil.copy2(folder/name,dest/name)
    app={name:load(ROOT/'out'/('t76_line2_latest_'+name+'.json'),{}) for name in
         ('baseline_default','isolated_default','isolated_small')}
    save(EVIDENCE/'application_entries.json',app)
    compat=load(OUT/'vqm_comparison.json',{})
    equivalence=load(OUT/'line2_equivalence.json',{})
    line2=all(r.get('passed') is True for r in app.values()) and equivalence.get('all_equal') is True
    rows=[];burst_rows=[];statistics=[];metric_rows={0:[],1:[],2:[]};long_coverage=[];throughput=[];diagnostics=[]
    collected=list(primary.get('Runs',[]))
    final=search.get('final_run')
    if final:
        collected.append(dict(Test='tb_t76_load',Index='mixed_profile',Folder=final['folder'],
            Param='VL_COUNT='+str(final['vls'])+',MIXED=1,DURATION=12500000',
            Status='PASS' if final['status']=='PASS' else 'FAIL'))
    for run in collected:
        if run['Test']!='tb_t76_load':continue
        folder=Path(run['Folder']) if run.get('Folder') else None
        stats=None;equal=False
        if folder and (folder/'window.txt').is_file():
            stats=analyse(folder,partial=run['Status']!='PASS')
            subprocess.run(['E:/2026_Embedded_FPGA/setup_pack/bin/Passkey/bin/tclsh.exe',
                str(ROOT/'sim/t76_stats.tcl'),str(folder)],check=True,timeout=180,cwd=ROOT)
            equal=(folder/'t76_python.tsv').read_bytes()==(folder/'t76_tcl.tsv').read_bytes()
            dest=EVIDENCE/('case_'+str(run['Index']));dest.mkdir(exist_ok=True)
            for name in ('t76_stats.json','t76_python.tsv','t76_tcl.tsv','window.txt','summary.json','simulation.log'):
                if (folder/name).is_file():shutil.copy2(folder/name,dest/name)
            with gzip.open(dest/'public_samples.json.gz','wb') as stream:stream.write((folder/'t76_samples.json').read_bytes())
            for source in (0,1):
                for kind in ('bag','budget'):
                    p=folder/f't76_{kind}_{source}.json'
                    if p.is_file():shutil.copy2(p,dest/p.name)
            statistics.append(dict(index=run['Index'],folder=str(folder),independent_equal=equal,
                partial=stats['partial'],bag_burst=stats['bag_burst'],vls=stats['declared_vls'],mixed=stats['mixed'],
                window_ms=stats['window_ms'],status=run['Status'],groups=len(stats['groups']),issues=stats['issues'],
                formula_invalid_groups=sum(not r['formula_precondition'] for r in stats['groups'] if r['length']<=1471),
                jitter_100us_failures=sum(r['formula_precondition'] and r['official_jitter_cycles']>=12500
                    for r in stats['groups'] if r['length']<=1471),
                internal_50us_failures=sum(r['formula_precondition'] and r['official_jitter_cycles']>6250
                    for r in stats['groups'] if r['length']<=1471)))
            values=dict(line.split('\t') for line in (folder/'t76_python.tsv').read_text(encoding='ascii').splitlines())
            for source in range(2 if stats['duplex'] else 1):
                throughput.append([run['Index'],int(not stats['partial']),source,
                    stats['window_ms'],
                    int(values[f'{source}/total/inject_bytes'])*1000/stats['window_cycles'],
                    int(values[f'{source}/total/receive_bytes'])*1000/stats['window_cycles']])
            for group in stats['groups']:
                prefix=f"{group['source']}/{group['vl']}/{group['length']}"
                rate=lambda suffix:int(values[prefix+'/'+suffix])*1000/stats['window_cycles']
                mode=2 if group['length']>1471 else int(bool(stats['bag_burst']))
                metric_rows[mode].append([
                    run['Index'],group['policy'],int(not stats['partial']),group['source'],group['vlid'],group['length'],group['samples'],
                    stats['window_ms'],group['first_frame_minimum']*.008,group['observed_minimum']*.008,group['maximum']*.008,
                    group['bag_deduction']*.008 if mode!=2 else 'NA',group['official_jitter_us'] if mode!=2 and group['formula_precondition'] else 'NA',int(group['formula_precondition']) if mode!=2 else 'NA',
                    rate('inject_bytes'),rate('receive_bytes'),group['first_sample']['tx_first'],group['first_sample']['rx_last'],
                    group['worst_sample']['tx_first'],group['worst_sample']['rx_last'],group['note']])
                if mode!=2 and (not group['formula_precondition'] or group['official_jitter_cycles']>=12500):
                    first=group['first_sample'];worst=group['worst_sample']
                    comparison=first if stats['bag_burst'] else group['minimum_sample']
                    decomposition={}
                    if comparison['gmii_first'] is not None and worst['gmii_first'] is not None:
                        pre=(worst['gmii_first']-worst['tx_first'])-(comparison['gmii_first']-comparison['tx_first'])
                        post=(worst['rx_last']-worst['gmii_first'])-(comparison['rx_last']-comparison['gmii_first'])
                        assert pre+post-group['bag_deduction']==group['official_jitter_cycles']
                        decomposition=dict(input_to_first_gmii_delta_cycles=pre,first_gmii_to_rx_last_delta_cycles=post,
                            pre_wire_after_nominal_BAG_cycles=pre-group['bag_deduction'])
                    diagnostics.append(dict(case=run['Index'],source=group['source'],vlid=group['vlid'],length=group['length'],
                        formula_valid=group['formula_precondition'],signed_formula_us=group['official_jitter_us'],
                        first_sample=first,comparison_sample=comparison,worst_sample=worst,public_decomposition=decomposition,
                        finding='Public input-to-wire and wire-to-delivery deltas are exact. Attribution to an internal queue or scheduler requires more evidence; no internal measurement substitutes for public timing.'))
            if stats['mixed']==1:
                for source in (0,1):
                    for length in (1472,3000,8192):
                        completed=sum(g['samples'] for g in stats['groups'] if g['source']==source and g['length']==length)
                        long_coverage.append(dict(case=run['Index'],source=source,payload=length,
                            complete_messages=completed,full_100ms_pass=not stats['partial'],
                            status=('COMPLETE_BYTE_MATCH' if not stats['partial'] else 'PREFIX_BYTE_MATCH_ONLY') if completed else 'NOT_DELIVERED_BEFORE_ABORT'))
        row=f"| {run['Index']} | `{run['Param']}` | {run['Status']} | {'一致' if equal else '待完成/不一致'} | `{run.get('Folder')}` |"
        (burst_rows if stats and stats['bag_burst'] else rows).append(row)
    save(EVIDENCE/'statistics_crosscheck.json',statistics)
    save(EVIDENCE/'performance_diagnostics.json',diagnostics)
    columns=['case','policy','complete_window','source','VLID','payload_bytes','samples','planned_window_ms',
        'first_frame_latency_us','observed_min_latency_us','max_latency_us','BAG_deduction_us','jitter_us','formula_valid',
        'inject_mbps','receive_mbps','first_tx_cycle','first_rx_last_cycle','worst_tx_cycle','worst_rx_last_cycle','note']
    for mode,name in ((0,'periodic_metrics.tsv'),(1,'bag_wait_metrics.tsv'),(2,'long_message_metrics.tsv')):
        text='\t'.join(columns)+'\n'+''.join('\t'.join(f'{x:.6f}' if isinstance(x,float) else str(x) for x in row)+'\n' for row in metric_rows[mode])
        (EVIDENCE/name).write_bytes(text.encode('utf-8'))
    save(EVIDENCE/'long_message_coverage.json',long_coverage)
    (EVIDENCE/'total_throughput.tsv').write_bytes(('case\tcomplete_window\tsource\tplanned_window_ms\tinject_mbps\treceive_mbps\n'+
        ''.join('\t'.join(f'{x:.6f}' if isinstance(x,float) else str(x) for x in row)+'\n' for row in throughput)).encode('ascii'))
    required_ids={0,2,3,4,5,16,'mixed_profile'}
    required_stats=[r for r in statistics if r['index'] in required_ids]
    line34={r['index'] for r in required_stats}==required_ids and all(r['status']=='PASS' and not r['partial'] and r['window_ms']>=100
        and r['independent_equal'] and not r['issues'] and r['formula_invalid_groups']==0
        and r['jitter_100us_failures']==0 for r in required_stats)
    vqm=[r for r in net.get('Runs',[]) if r.get('Kind')=='VQM76']
    t75_final=all(r['status'] in ('PASS_NO_XZ','PASS_PREFIX_NO_XZ') for r in scans['runs'] if r['test']!='tb_elinx')
    t75_elinx=next(r for r in scans['runs'] if r['test']=='tb_elinx').get('t75_passed') is True
    line5={r['Index'] for r in vqm}=={3,5} and all(r['Status']=='PASS' for r in vqm) and t75_final and t75_elinx
    perf=[r for r in primary.get('Runs',[]) if r['Test']=='tb_sys_perf']
    save(EVIDENCE/'performance_actual_rerun.json',dict(runs=perf,pending=not perf,
        current_checker=perf_checks,simulation_replayed_for_recheck=False,
        definition='public tx_data first to public rx_data; periodic max-min without BAG deduction; BAG+1 retained'))
    trial_text='兼容候选的试布线尚无最终收据；不把候选编译通过当成原样源码修复交付。'
    if trial:
        m=trial['native_measurements'];sc=m['synthesized_timing']['clocks'][0];rc=m['routed_timing']['clocks'][0];cl=trial['clusters']
        trial_text=(f"按 22:40 的覆盖决定完成一次带原 tiles_1030.edc 的试布线。结论 **{trial['status']}**。"
            f"综合 setup/hold `{sc['setup_worst_slack']:+d}/{sc['hold_worst_slack']:+d} ps`，setup 失败 `{sc['setup_fail_ends']}/{sc['setup_total_ends']}`；"
            f"布线 `{rc['setup_worst_slack']:+d}/{rc['hold_worst_slack']:+d} ps`，setup 失败 `{rc['setup_fail_ends']}/{rc['setup_total_ends']}`，hold 失败 `{rc['hold_fail_ends']}/{rc['hold_total_ends']}`。"
            f"原锁定 {cl['expected']} 个、保留 {cl['retained']} 个、缺失 {cl['missing']} 个、新增 {cl['extra']} 个、偏移 {cl['moved']} 个。"
            "172 个 P0 管脚的原生落位、封装脚、方向逐项不变。原生工具报告 stratix_clb10685 锁定目标不存在；该 CRIT 和失败时序均保留。"
            "未使用 --no-tiles，未重新优化锁定，未重试；RTL 已恢复 e4573d22，未提交这批 RTL。详见 trial_gate.json。"
            "VQM 图的 65255 个功能单元记录经双射核对仅为网名/实例名重编号；但打包资源增加一个 CLB，不能把逻辑图等价当成布局/时序等价。分类和绑定分别见 vqm_structure.json、trial_vqm_binding.json。")
    mix_text='混合规格仍在搜索/100 ms 确认中，尚不声明新的最大并发值。'
    if search:
        probes=', '.join(str(r['vls'])+':'+r['status'] for r in search.get('probes',[]))
        mix_text+=' 已完成搜索点：'+probes+'。'
    mixed_stat=next((r for r in statistics if r['index']=='mixed_profile'),None)
    mixed_verified=search.get('declared_mixed_vls') is not None and mixed_stat and mixed_stat['independent_equal'] and not mixed_stat['issues']
    if mixed_verified:
        n=search['declared_mixed_vls'];limit=search['maximum_observed_passing_vls'];hi=search['adjacent_failing_vls']
        mix_text=(f"混合最大声明为 **{n} TX / {n} RX VL**；81 VL 全长短消息规格保持不变。固定激励的二分相邻边界为 {limit} VL 通过 20 ms、{hi} VL 失败，"
            f"取 {n} VL 留出 {(1-n/limit)*100:.1f}% 余量，随后 100 ms 功能与逐字节交付通过，两套统计一致，TX 页上界不超过 256。"
            "此边界是按既定二分法、固定激励及其单调性假设得到，不冒称穷举所有 VL 数。性能门槛另见统计表，原 81 VL 混合溢出继续列为限制。")
        replace_tail(ROOT/'docs/ARCH.md','T76 混合负载声明（搜索确认）',mix_text+
            f'\n\n其中 {n-3} 条为周期短消息，末三条分别承载 1472/3000/8192 字节长消息；BAG 均为 1 ms，长消息分别每 2/3/6 ms 注入。'
            '每条 VL 先覆盖一次 1471 字节最大单帧。该配置与 81 VL 纯短消息配置择一使用，不叠加；默认 21 VL 文件不变。详见 evidence/t76_frag1030/mixed_search.json 及混合统计表。')
        replace_tail(ROOT/'README.md','T76 混合负载声明',mix_text+
            '\n\n[完整规格](docs/ARCH.md#t76-混合负载声明搜索确认)；[证据与各门槛](docs/evidence/t76_frag1030/summary.md)。')
    result=dict(timestamp=timestamp,terminal=terminal,accepted=False,
        step0='TRIAL_'+trial.get('status','PENDING')+'; RTL baseline restored after failed route trial',
        line1='CONFIRMED',line2=line2,line3_line4=line34,line5=line5,
        class_b='NOT_RUN: section-4 prerequisite RTL commit was not made',
        statistics=statistics,primary_active=primary.get('Active'),primary_pending=primary.get('Pending'),
        netlist_active=net.get('Active'),netlist_pending=net.get('Pending'),
        full_t75_elinx_acceptance=t75_elinx,mixed_search_complete=search_done,
        mixed_declared_vls=search.get('declared_mixed_vls') if mixed_verified else None,
        known_81vl_mixed_failure='Retained as a limitation outside the new mixed profile, not erased',
        BAG_acceptance_case=16,BAG_fixed_order_case=14)
    # Keep source-compatibility, functional/performance and netlist gates separate.
    save(EVIDENCE/'summary.json',result)
    text=f'''# T76 执行记录

更新：{timestamp}。状态：**未验收**；有限作业队列{'均已结束' if terminal else '仍有运行或排队项目'}。

## 第 0 步与规格

原样兼容候选在 ModelSim/Icarus 下编译无错误、无警告；最初 VQM 严格字节门槛未满足，之后按明确覆盖决定执行一次试布线。旧 VQM SHA-256 `{compat.get('old_sha256')}`。{trial_text} 源码前端原样修复未交付；当前验证继续使用 T75 仿真副本兼容方式。

本线程已明确确认：81 TX / 81 RX VL，每 VL BAG=1 ms、Lmax=1471，消息≤8192 字节，TX 256 页、RX 16 个重组上下文。完整预算和默认 21 VL 子集见 `../../ARCH.md`。

## 线 2

配置隔离及实际应用入口：{'PASS' if line2 else 'PENDING/FAIL'}。默认 84 消息、两消息小场景及原测试台冻结基线均使用实际 `.do` 入口。14 份外部应用、事件、GMII 记录逐字节等价：`line2_equivalence.json`。`tb_elinx`、`tb_net_services`、`tb_frag1030_net` 和其既有共用端点保持原样；T75 工作区只读。

## 线 3、4

**81 VL 混合场景已出现 RX 溢出，作为限制原样保留。** 首次失败在仿真时间 3604444 ns，接收端 `ev_a=0x80`、`ev_b=0x01`、`ev_app=0`；第 450556 拍，负载 epoch=68006，负载开始后 382550 拍（3.0604 ms）。未修 RTL，81 VL 全长短消息声明不变。按后续决定混合规格另行确定：{mix_text} 最小复现、输入哈希和首个事件见 `failure_reproduction.md`、`case_1/` 及 `primary_queue.json`。故障成因与仅有的公开端口证据分开记录，不把推断当成已证明的内部原因。

公开测点为输入 VLID 首字节至输出最后一字节，另记输出首字节。Python/Tcl 分别解析原始记录，按 VL 和载荷分组；不读取彼此的统计输出。BAG 的 +1 拍样本保留。按本线程补充决定，周期注入表采用最大−最小，并注明“无样本含 BAG 等待，未减 BAG”；独立的背靠背测量表采用全程最大−首帧时延−BAG。后者还必须证明每条 VL 的第二条消息在前一帧 BAG 到期之前输入完毕、实际帧间隔不小于 BAG、平均每 VL 不超过每 BAG 一帧；页池以公开输入首字节预留整条消息的页、最后一个 GMII 分片结束后才归还的保守上界核对。长消息完成时延单列，不套单帧 2 ms 门槛。

周期注入场景，逐 VL / 载荷数值见 [周期统计表](periodic_metrics.tsv)：

| 序号 | 场景 | HDL/完整性 | 两套统计 | 原始输出目录 |
|---|---|---|---|---|
'''+ '\n'.join(rows)+'''

BAG 等待场景（每 VL 每 2 ms 连续两条最大载荷消息，长期平均仍为每 BAG 一帧），逐 VL 数值见 [BAG 等待统计表](bag_wait_metrics.tsv)：

固定输入顺序的场景 14 已通过 100 ms 完整性；每方向 4050 对均证明第二条等待 BAG，保守页占用 147/256，但只有 42/162 组满足最大−首帧>BAG。其余组不能计为抖动通过。场景 16 保留同样 81 VL、每轮两条、每 2 ms 到期、100 ms 窗口及统计公式，只让每三个相邻 VL 在相同到期时刻轮换输入顺序，覆盖顺序造成的排队差异；原场景和周期场景不变。场景 16 必须独立满足全部组公式、页池及 <100 µs 门槛，结果未出前不预称通过。详见 `bag_protocol_refinement.json`。

| 序号 | 场景 | HDL/完整性 | 两套统计 | 原始输出目录 |
|---|---|---|---|---|
'''+ ('\n'.join(burst_rows) if burst_rows else '| 待完成 | `BAG_BURST=1` | 运行或排队 | 待完成 | 见 primary_queue.json |')+f'''

长消息完成时延单独见 [长消息统计表](long_message_metrics.tsv)，三种长度的已交付数量与未完成边界见 `long_message_coverage.json`。各 VL 的吞吐在对应统计表，按方向的总吞吐见 [总吞吐表](total_throughput.tsv)；接收吞吐只统计窗口内的应用载荷，窗口后排空交付另由完整性检查保证。项目内部 50 µs 线独立计数在 `statistics_crosscheck.json` 的 `internal_50us_failures`，不替代官方 <100 µs 门槛。越过 100 µs 或 BAG 测量协议未满足的组，首帧/最坏样本、公开输入至线上起始及线上起始至交付的差分均保存在 `performance_diagnostics.json`；公式无效时表内抖动记 NA，带符号算式原值保留在诊断，不能计为性能通过。

表内 PASS 只表示 HDL 自检及完整性交付。T76 性能验收还要求 100 ms、周期及 BAG 场景覆盖 81 VL、混合覆盖独立声明 VL 数、全部分组公式成立、抖动 <100 µs 以及独立统计一致；当前总门槛为 {'PASS' if line34 else '未通过/未完成'}。

## 线 5 与未完成边界

官方网表窗口：{'PASS' if line5 else '未完成/未通过'}。三个 RTL 配对参考已保留；未开跑的独立单 VL 网表 smoke 合并进 TX/RX 的官方 .do 入口，避免重复初始化。TX 已立即占核启动，RX 在 T75 首次释放核后优先于其余载荷组。每个 VQM 作业最长 24 小时；按最新优先级决定，T76 自身网表最多 3 个，全机 ModelSim 总槽位≤10、计算核≤6（含 T75 与试布线预留），挂起内核不计计算核。两窗口都使用旧 VQM，不因候选试布线或提交重启。TX/RX 均含 81 VL、至少 1 ms 输入窗口、重复同 VL 帧及一条 1472 字节两片长消息；只有逐字节等于同激励 RTL 参考且全公开输出 X/Z 监视通过，才算该窗口通过。RTL 接收端以独立顶层模块名编译，电路内容不变。

完整初始化保留，未强制未初始化 RAM、未改提交 RTL 或 MAC。每个窗口的实际耗时、PID/创建时刻/截止、工作集峰值见队列和各运行 `tool_metrics.json`。≤4 小时是目标，不能预称达到。官方 `.vo` 替换为综合 `.vqm` 的可复现入口见 `../../../sim/run_t76_post_synth.do` 和 `official_reproduction.md`。

T75 的输出扫描见 `t75_xz_scan.json`；运行中文件仅为无 X/Z 前缀，不能算最终扫描。`tb_elinx` 无捕获文件，不补造扫描结论。原 T75 的三项最终成功和 frag1030 的第 199578 拍 PASS-PREFIX 仍要以其原始收据核对；本任务未停止、重跑或写入它们。B 类映射/仿真受“第 0 步 RTL 提交后”前提约束，本次未运行。

所有新产物和本地提交均限定在本工作区；未 push、未合并、未 amend。任务未整体完成时不把中间步骤列为最终验收。

本任务的两个有限队列都登记了一次性结束回调 `tools/t76_closeout.py`。先结束的队列只退出；最后结束的队列核对两份终态、分支、HEAD、文件哈希和空暂存区后，归集证据并创建本地证据提交。回调不启动仿真、不建定时任务、不触发代理续接；输入变化或验证错误时保留现场并失败退出。结果收据位于 `out/t76/closeout.json` 和 `out/t76/closeout_commit.json`，执行日志为 `out/t76/closeout.log`。
'''
    (EVIDENCE/'summary.md').write_bytes(text.encode('utf-8'))
    replace_tail(ROOT/'docs/FACTS.md','T76 当前执行状态',
        f'更新：{timestamp}。规格已确认，配置隔离及 14 份外部记录等价验证'+('通过' if line2 else '待完成')+
        '。兼容候选试布线 setup=-7664 ps / 1426 失败端点，RTL 已回退；81 VL 混合溢出保留。'+
        ('混合独立声明 63 VL，边界 70 通过/71 溢出，留 10% 余量的 100 ms 确认已通过。' if mixed_verified else '混合规格另行二分及 100 ms 确认。')+
        '81 VL 纯短消息规格不变。T76 未验收。'+
        '[实际门槛、运行状态和证据](evidence/t76_frag1030/summary.md)。')
    replace_tail(ROOT/'docs/FACTS_DETAIL.md','T76 门槛与证据',
        f'更新：{timestamp}。以 [T76 执行记录](evidence/t76_frag1030/summary.md) 和 `summary.json` 为准。'+
        '功能、自检、性能公式前提、独立统计、官方网表、T75 前缀和最终结果分别列示；计划窗口不等于实际完成窗口。'+
        '源码兼容候选已按覆盖决定试布线并失败回退；逻辑图重编号、打包/簇差异及实际时序分开记录，不以候选编译或逻辑图等价替代布局/时序验收。')
    print(json.dumps(dict(terminal=terminal,line2=line2,line34=line34,line5=line5,accepted=False),ensure_ascii=False))
    if args.commit_guard:
        paths=list(guard['files'])+[str(p.relative_to(ROOT)).replace('\\','/') for p in EVIDENCE.rglob('*') if p.is_file()]
        paths=sorted(set(paths))
        subprocess.run(['git','add','--pathspec-from-file=-','--pathspec-file-nul'],
            input=('\0'.join(paths)+'\0').encode('utf-8'),cwd=ROOT,check=True)
        staged=subprocess.check_output(['git','diff','--cached','--name-only','-z'],cwd=ROOT).decode('utf-8').split('\0')
        if any(p and p not in paths for p in staged):raise RuntimeError('Unexpected staged path; not committing')
        # Retain authentic Windows tool receipts and source CRLF bytes.
        subprocess.run(['git','-c','core.whitespace=blank-at-eol,blank-at-eof,space-before-tab,cr-at-eol',
            'diff','--cached','--check'],cwd=ROOT,check=True)
        subprocess.run(['git','commit','-m','test(t76): record bounded load and official-netlist evidence'],cwd=ROOT,check=True)
        commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
        save(OUT/'closeout_commit.json',dict(commit=commit,timestamp=timestamp,accepted=False))
        print('T76 LOCAL COMMIT '+commit)


if __name__=='__main__':main()
