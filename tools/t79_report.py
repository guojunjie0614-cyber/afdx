"""Render T79 receipts without starting simulations or changing the statistics."""
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
E=ROOT/'docs/evidence/t79_63vl'
CASES=[('P1',1),('P17',17),('P256',256),('P1024',1024),('P1471',1471),('B1',1471),('B2',1471)]

def main():
    receipt=json.loads((E/'run_receipt.json').read_text(encoding='utf-8'))
    rows={r['case']:r for r in receipt['runs']}
    text=['# T79：63 VL 满负载声明与验证','',
        f"运行状态：**{receipt['status']}**。开始：{receipt['started']}；最近终态：{receipt.get('finished','尚未结束')}。",
        '', '统一声明 **63 TX / 63 RX VL**，每 VL BAG=1 ms、Lmax=1471，A/B 冗余、双向同时运行；配置规模仍为 TX 128 / RX 4096。计划单向载荷 741.384 Mbit/s，含额外 VLID 输入为 742.392 Mbit/s；线路占用 63×1538/125000=77.5152%（约 77.5%）。声明变更不修改 RTL、VQM、约束或布局。',
        '', '## 七场景结果','',
        '每项 VL_COUNT=63、DURATION=12500000（100 ms）、DUPLEX=1、MIXED=0，CE_DIV=2。周期场景用最大−最小，无 BAG 等待、未减 BAG；B1/B2 用最大−首帧−BAG，保留带符号原值，公式不成立时不计抖动通过。端到端时延从输入 VLID 首字节至输出最后一字节，门槛沿用 T76 ≤2 ms。吞吐是 100 ms 窗口内交付应用载荷，两方向相加，不把 A/B 副本重复计数。',
        '', '| 场景/载荷 B | 状态 | HDL/完整性 | Python/Tcl | 最大抖动 µs / VLID / 方向 | 最大端到端 µs | 总吞吐 Mbit/s | 仿真用时 s / 场景用时 s |',
        '|---|---|---|---|---|---|---|---|']
    metrics=['case\tsource\tvlid\tlength\tsamples\tfirst_cycles\tmin_cycles\tmax_cycles\tbag_cycles\tsigned_jitter_cycles\tformula_valid\tjitter_us\tunder_100us']
    for name,length in CASES:
        row=rows.get(name,{})
        if 'groups' not in row:
            elapsed=f"{row.get('simulation_seconds','未完成')} / {row['seconds']:.3f}" if 'seconds' in row else '—'
            hdl='PASS/未独立核对' if row.get('hdl_result_lines') else '—'
            text.append(f"| {name}/{length} | {row.get('status','未启动')} | {hdl} | 未完成 | — | — | — | {elapsed} |")
            continue
        jitter=f"{row['maximum_jitter_us']:.3f}" if row['formula_invalid']==0 else 'NA（存在公式无效组）'
        text.append(f"| {name}/{length} | {row['status']} | {'PASS' if row['hdl_pass'] else 'FAIL'}/{'PASS' if row['integrity_pass'] else 'FAIL'} | {'一致' if row['statistics_equal'] else '不一致'} | {jitter} / 0x{row['worst_vlid']} / {row['worst_source']} | {row['maximum_latency_us']:.3f} | {sum(row['receive_mbps']):.6f} | {row['simulation_seconds']:.3f} / {row['seconds']:.3f} |")
        stats=json.loads((E/name/'t76_stats.json').read_text(encoding='utf-8'))
        for g in stats['groups']:
            metrics.append('\t'.join(map(str,[name,g['source'],g['vlid'],g['length'],g['samples'],
                g['first_frame_minimum'],g['observed_minimum'],g['maximum'],g['bag_deduction'],
                g['official_jitter_cycles'],int(g['formula_precondition']),
                f"{g['official_jitter_us']:.3f}" if g['formula_precondition'] else 'NA',g['under_100us']])))
    (E/'per_vl_metrics.tsv').write_text('\n'.join(metrics)+'\n',encoding='utf-8')
    text+=['','逐 VL 原值见 [per_vl_metrics.tsv](per_vl_metrics.tsv)；独立统计输出、HDL 日志、页池/BAG 消息对见对应场景目录。统计公式与 Python/Tcl 源码均保持 T76 原样。场景用时为启动至控制器确认结束，含接管识别延迟；实际仿真用时以 tool_metrics.json 为准。',
        '', '## 完整性、公式与预算','', '| 场景 | 分组数 | 公式无效组 | ≥100 µs 组 | 页池上界（两方向） | BAG 等待对/失败对（两方向） |',
        '|---|---|---|---|---|---|']
    for name,_ in CASES:
        row=rows.get(name,{})
        if 'groups' in row:
            text.append(f"| {name} | {row['groups']} | {row['formula_invalid']} | {row['jitter_failures']} | {row['page_upper_bounds']} / 256 | {row['bag_pairs']} / {row['bag_pair_failures']} |")
    text+=['','完整性包含逐消息序号、长度、计划周期覆盖、应用载荷逐字节相同、A/B 逐帧时戳/载荷一致、FCS/IP 校验、BAG 间隔、页池保守上界≤256。HDL 另核对交付与去重计数及公开端口 X/Z。BAG 场景逐对证明第二条输入完成早于第一帧+BAG，实际第二帧不早于 BAG 到期。',
        '', '## 原始输出与运行收据','', '[run_receipt.json](run_receipt.json) 保留命令、PID/创建时刻、截止、退出状态、原始目录、仿真用时和场景用时；各场景 tool_metrics.json 保留内核身份和峰值内存。前六项先启动，第七项等待空位；所有子进程继承最多六个逻辑 CPU 的亲和性。每项从首次启动起上限 10800 s，无重试、heartbeat、定时任务或续接。']
    for name,_ in CASES:
        row=rows.get(name,{})
        if 'folder' in row:text.append(f"- {name}：`{row['folder']}`")
    text+=['', '### 原样 RTL 的 ModelSim 诊断边界','',
        'T77/T78 原样 RTL 在 ModelSim 下存在 `$finish_and_return` 未定义和可选端口未连接警告。旧 t76_sim.py 把所有 Warning 视为失败，原 summary.json/退出码原样保留；T79 用与 tools/eda.py 相同的五条精确模式单独判定，完整警告仍在 simulation.log。未知 Warning、Error、Fatal、RAMCOLL、RX_ASSERT、HDL FAIL、输入哈希变化均不放行。t79_adjudication.json 单列 HDL、已知警告数与包装器状态，不把包装器 FAIL 改写为 PASS。接管队列控制器时保留原有仿真 PID、首次启动时刻和截止，未重跑。',
        '', '## 81 VL 行为不变的证明','',
        '选择任务卡允许的“代码路径不变”方法，未额外跑 81 VL smoke。相对起点 f4632d5c，tools/t76_sim.py 仅把 BAG_BURST=2 的拒绝条件由 VL_COUNT!=81 改为 VL_COUNT%3!=0；81 在 BAG_BURST=0/1/2 下均与原来一样不触发拒绝。其余运行代码逐字相同；tb_t76_load.v、t76_load_endpoint.v、全部 RTL、Python/Tcl 统计均逐字节未改。轮换函数 base=(vl/3)*3、rank=base+(vl-base+round)%3 原本就参数化，消息长度/到期时刻/相位/顺序算法均未改。哈希与自动核对见 [81vl_code_path_proof.json](81vl_code_path_proof.json)。T79 独立诊断不改变 HDL 激励或公开端口记录。',
        '', '## 混合场景复用','',
        '不重跑 mixed_profile。只读引用 T76 的 63 VL、100 ms 混合结果：HDL/逐字节完整性 PASS、两套统计一致、页池上界≤256。原始目录 `E:/2026_Embedded_FPGA/worktrees/active/c3_t76/out/t76/search_source/out/t76_sim/tb_t76_load/20261103_070501_935849`；[T76 汇总](../t76_frag1030/summary.md)、[统计交叉核对](../t76_frag1030/statistics_crosscheck.json)。短/长混合不额外叠加到纯短消息满负载；长消息按分片机会计费。',
        '', '## 超出声明的压力测试（81 VL 历史）','',
        'T76 周期注入最大抖动 3.368 µs；BAG 对齐撞车 case 16 的 10/162 组≥100 µs，最大 107.7 µs（VLID 0x0126）；81 VL 混合 RX 溢出。固定顺序 case 14 只有 42/162 组满足最大−首帧>BAG，其余组不计性能通过。上述数据作为超出当前 63 VL 声明的压力测试保留，不用于扩大当前声明。',
        '', '## eLinx 界面人工验证','',
        '11-04 提供的截图显示 `[RESULT] tb_elinx PASS checks=9238 errors=0`、Errors 0、Warnings 90、Elapsed 0:02:18，仿真时间 2557777 ns。截图中的系统任务诊断保留，不声称零警告；来源是任务卡提供的人工操作，本轮仅复制并目视核对，未重跑 GUI。',
        '', '[原始截图](elinx_gui_behav_pass.png) · [截图收据](elinx_gui_receipt.json)。界面 Loading... 的本机 socket 排障与备用 batch 命令已写入 README。',
        '', '## 待队友同步','',
        'docs/design/ 保持只读；以下五处已由上游转告，发现它们不再触发停止（按后续明确指令）。',
        '', '| 文件 | 行号 | 待同步内容 |','|---|---:|---|',
        '| docs/design/chapters/ch03.tex | 226 | 77/81 VL 双向满载基准及“完全覆盖满载无损调度需求” |',
        '| docs/design/chapters/ch03.tex | 143 | 最大可调度数 81、载荷率 953.208 Mbps |',
        '| docs/design/chapters/ch01.tex | 44 | 81 VL 极限吞吐率 |',
        '| docs/design/chapters/ch10.tex | 32 | 81 VL 极限容量 |',
        '| docs/design/AFDX端系统FPGA设计文档.tex | 191 | 摘要中的 81 VL 吞吐率 |',
        '', '## 文档与验收边界','',
        '本轮更新 README.md、docs/ARCH.md、docs/FACTS.md、docs/FACTS_DETAIL.md、docs/evidence/frag1030_delivery/summary.md，并新建本证据目录。docs/design/、docs/test/、rtl/、elinx/、sim/wave/png/、submission/、setup_pack/ 未改。不跑网表、不综合、不布线、不 push、不合并、不 amend。',
        '', '任一场景公式不成立或抖动≥100 µs 时停止本轮并保留其他场景已完成/中止边界；不能把声明下调、部分场景或 GUI PASS 当成七场景性能验收。']
    if receipt.get('error'):
        text+=['',f"本轮停止原因：**{receipt['error']}**。"]
        if (E/'B1/t76_stats.json').exists():
            stats=json.loads((E/'B1/t76_stats.json').read_text(encoding='utf-8'))
            bad=[g for g in stats['groups'] if not g['formula_precondition']]
            if bad:
                g=bad[0]
                invalid=['source\tvlid\tlength\tfirst_cycles\tmaximum_cycles\tspread_cycles\tbag_cycles\tsigned_jitter_us']
                for x in bad:
                    invalid.append('\t'.join(map(str,[x['source'],x['vlid'],x['length'],x['first_frame_minimum'],
                        x['maximum'],x['raw_spread_cycles'],x['bag_deduction'],x['official_jitter_us']])))
                (E/'formula_invalid_groups.tsv').write_text('\n'.join(invalid)+'\n',encoding='utf-8')
                text+=['','### B1 停止现象与原因','',
                    f"B1 的 HDL/完整性通过、Python/Tcl 一致，但 **{len(bad)}/126 组公式不成立**，详见 [无效组原值](formula_invalid_groups.tsv)。只有 VLID 0x0114、0x0115 的两个方向共 4 组满足前提，有效组中最大为 0.984 µs（0x0115）；不能把该子集最大值作为 B1 整体抖动通过。",
                    '', f"例：方向 {g['source']}、VLID 0x{g['vlid']}、1471 字节：首帧 {g['first_frame_minimum']} 拍（{g['first_frame_minimum']*.008:.3f} µs），全程最大 {g['maximum']} 拍（{g['maximum']*.008:.3f} µs）；最大−首帧={g['raw_spread_cycles']} 拍（{g['raw_spread_cycles']*.008:.3f} µs）≤125000 拍 BAG，减 BAG 后原值 {g['official_jitter_us']:.3f} µs，故该组记 NA。",
                    '', '该现象与“第二条确实等待 BAG”不矛盾：线上 BAG 从前一帧起点计时，而每条消息的端到端时延各从自己的输入首字节计时；背靠背第二条输入晚于首条，等待的是剩余 BAG，固定输入顺序也未保证全程最大与首帧的差值超过完整 BAG。统计前提额外要求最大−首帧>BAG，本次未满足；没有改公式、钳零或转用其他抖动口径。两方向各 3150 对均通过等待证明，页池上界均 144/256，最大端到端时延 1079.056 µs。',
                    '', '按停止指令未继续统计 P1471 或运行 B2：P1471 已留下 HDL PASS checks=12600 errors=0，但未完成 Python/Tcl 性能验收；B2 仅为中止前缀，无 HDL 终态。原始目录、输出哈希及中止身份见对应 stop_receipt.json；[停止确认](stop_confirmation.json)核对所有本任务进程已结束。']
    (E/'summary.md').write_text('\n'.join(text)+'\n',encoding='utf-8')

if __name__=='__main__':main()
