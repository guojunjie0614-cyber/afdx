# 2026-11-03 分片版本验证结果归档

归档日期：2026-11-04。目标分支：`feature/fragmentation-timing-1030`。

**本轮已按用户要求停止。原报告回归已完成针对性适配、补测和证据核对；新增混合负载及全长报文负载存在真实交付丢失，网表验证尚未闭环，不能宣称全部通过。** 本次归档只整理既有结果，没有重新运行仿真、检查器、综合或布线。

验证对象为 1030 分片版本，125 MHz、`AFDX_CE_DIV=2`，应用消息最大 8192 B。基准提交为 `b3a60639d2e67b0e102afce7aabd352a813c0f98`；随本次提交保留测试夹具、检查器和执行工具的改动，未修改 `rtl/`、`hardware_spec.yaml` 或 `hardware_contract.yaml`。设计行为以规格及硬件契约为准，历史报告数字不自动成为当前验收阈值。

## 已完成的验证

| 项目 | 实际结果 | 主要归档证据 |
|---|---|---|
| 原报告 native 回归 | 57 个正向用例配置均已有接受的成功证据。原始批次 50 PASS / 7 FAIL 原样保留；其中旧接口/端口警告通过针对性替换用例解决，纯来源变更项单独严格核对。 | [原始批次](out/report_native/20261103_175508_682036/summary.json)、[最终收集及替换说明](out/report/native_coverage_collection/20261103_213045_224126/summary.json) |
| Native 覆盖率 | 58 个正向 UCDB（57 个配置 + 五服务额外用例），42 个实际 RTL design unit；合并检查通过。未宣称全覆盖或签核。 | [覆盖率与分母](out/report/native_coverage_collection/20261103_213045_224126/coverage.json)、[输入绑定](out/report/native_coverage_collection/20261103_213045_224126/inputs.json) |
| ModelSim judge | 8 项实际用例通过、零警告；执行范围为分段 7+1。原中断及末项来源校验 FAIL 均保留，由单独审查解释接受原因。 | [8 项审查](out/report_judge_review/20261103_212119_438097/summary.json) |
| T65 正向与负向控制 | 16 个正向夹具通过；32 个真实 HDL 变异及检查器失败传播验证完成。原始编译失败没有计入成功检出。离线检查器的 32 项破坏控制单独留档。 | [Native 控制](out/report_controls/native_consolidated.json)、[离线控制](out/report_controls/20261103_175738_200812/summary.json) |
| 固定/可变性能 | 原窗口及负载保留；native 固定和可变用例实际通过 HDL/独立检查，可变项来源标记的接受说明另列于最终收集。 | [固定 native](out/sim/tb_sys_perf/20261103_175508_684130/summary.json)、[可变 native 原始记录](out/sim/tb_sys_perf_var/20261103_175508_683841/summary.json) |
| gbe77_d100 | 实际补跑并重新检查同一捕获；双向各 906.136 Mbps，1771/1771 条，最大应用完成延迟 49.4 us。原先误报记录保留。 | [同捕获复核](out/perf_d100/recheck_20261103_183222_342250/d100_summary.json) |
| RM04 PSN/RM | 按明确重建的等价实验完成，169270 项独立检查、33846 帧、2688 个矩阵点。历史原始源缺失，未声称逐字重现历史实验。 | [实际运行](out/open_verilator/20261103_183202_203088/summary.json) |
| 应用 Tcl 入口 | 默认及长报文入口实际执行成功；长报文原始完成时间保留，不套用普通单帧 2 ms 限值。 | [默认](out/report_entry/app_default/20261103_185707_507931/summary.json)、[长报文](out/report_entry/app_long/20261103_185735_592511/summary.json) |
| 波形及服务 GUI | 6 个实际 native GUI 场景、13 张已检查截图；截图位于各场景 `captures/`，仅接受的截图纳入归档。 | [GUI 汇总及截图路径](out/report_wave/current_gui_consolidated.json) |
| 已有布线时序绑定 | 复用并核对 34 项源/约束/数据库身份，96142 端点、319181 路径、零失败；setup +0.029 ns、hold +0.604 ns。未重新综合或布线。 | [绑定结果](out/report_profile/routed_binding.json) |

覆盖率的实际计数如下；未覆盖清单及合并 UCDB 以 gzip 保留。

| 指标 | 已覆盖 / 总数 | 百分比 |
|---|---:|---:|
| Statements | 12416 / 12824 | 96.818465% |
| Branches | 7230 / 7642 | 94.608741% |
| Conditions | 1306 / 1766 | 73.952435% |
| Expressions | 3242 / 3987 | 81.314271% |
| FSM States | 115 / 137 | 83.941606% |
| FSM Transitions | 141 / 375 | 37.600000% |
| Toggles | 59358 / 82546 | 71.908996% |

## 新增 FAQ 测试

| 场景 | 当前结论 | 主要证据 |
|---|---|---|
| A：128 VL、每条 1471 B、2 ms 周期 | **PASS**。8192/8192 条交付；100 ms 测量窗 6400/6400 条、753.152 Mbps。原始应用延迟 48.576..48.600 us。覆盖全部 128 VL 的配置最大短报文。 | [HDL 日志](out/faq_supplement/20261103_212917_739291/load/short128/simulation.log)、[独立检查](out/faq_supplement/20261103_212917_739291/load/short128/checks/20261103_213251_049028/summary.json) |
| B：124 短 VL + 4 个 8192 B 长 VL | **FAIL，4011/4032 条，缺 21 条。** 全部输入及 A/B 每网 4352 帧均正确，目的端未完整交付。成功短报文的同 VL/长度抖动最坏 68.360 us，小于 100 us，但未达到项目内部 50 us 目标；缺失消息仍使功能验收失败。 | [原始 FAIL](out/faq_supplement/20261103_212917_739291/load/mixed128/simulation.log)、[联合诊断](out/faq_load_diagnostic/20261103_220059_973210/combined_failure_analysis.json) |
| C：128 VL、每条 8192 B、64 ms 周期 | **FAIL，256/312 条，缺 56 条。** 全部输入按计划完成，A/B 各 1872 帧可重建 312 条完整消息。已排除输入截断及固定 128 ms 看门狗假设。 | [原始 FAIL](out/faq_supplement/20261103_212917_739291/load/long128/simulation.log)、[联合诊断](out/faq_load_diagnostic/20261103_220059_973210/combined_failure_analysis.json) |
| 异常 VL 与健康 VL 并存 | **PASS**。20 条精确交付，79 项独立检查，故障上下文期间 12 条健康交付；健康流 GMII EOF 到应用完成最大 2466 拍（19.728 us）。此量不是应用输入起算的 2 ms 延迟。 | [实际结果](out/faq_supplement/20261103_212917_739291/fault/run_summary.json) |
| 首帧及后续帧抖动分析 | 已有真实捕获的离线统计完成。16076 条匹配消息，162 条真实首帧、15914 条后续消息；712 个阶段内重复组最坏 0.024 us，170 个跨阶段重复组最坏 2.080 us。单样本首帧组未给出抖动通过结论。 | [统计结果](out/faq_jitter/20261103_205626_826706/summary.json) |
| 最小分片 GLS 的 RTL 对照 | **RTL PASS**：2 VL、1472/64/17 B，3 条交付、每网 4 帧，602354 项 HDL 检查、零错误。VQM 对照尚未完成。 | [RTL 汇总](out/faq_gls/rtl/20261103_205418_274519/summary.json)、[公开捕获检查](out/faq_gls/rtl/20261103_205418_274519/check_summary.json) |

A/B/C 的公开输入、A/B 帧、应用输出和事件捕获均保留，较大文件以 `.gz` 存储。`queue.json` 的进程返回码与 HDL 结果应一并阅读：Verilator 进程正常退出也可能输出 HDL FAIL，不能据进程返回 0 判断功能通过。

## RX 内部诊断的结论与边界

默认每网原始 RX 暂存环只有 4096 B（`RX_RING_AW=12`），与 32768 B 的应用环是不同资源。长报文在 `D_OUTPUT` 期间使重组下游 `ready=0`，可能阻塞原始环排空。帧接纳需要为整个 payload 留出空间；环占用不必达到 4096 B 才会拒收。

最初仅凭公开合并事件位 `0x80` 将暂存溢出视为确定原因，证据不足，因为该位同时合并 parser、engine 和 reassembly 拒绝。修正后的[联合诊断](out/faq_load_diagnostic/20261103_220059_973210/combined_failure_analysis.json)保留这一纠正；较早的强确定性诊断也保留为历史记录，不能作为全部失败的最终解释。

后续只观察内部信号的 native 诊断获得了以下具体证据，未 force/驱动 DUT，未修改 canonical RTL：

- B 首个缺失消息：cycle 721450，VL 0122 / ID 00A1，A/B parser 均报 `80`；已占 2943 B，待收 1471 B，总计 4414 B > 4096 B，同时 `D_OUTPUT`、`ready=0`、DQ=4。该首次失败的 parser 容量拒收已有直接观察支持。
- C 的 index 2/3：offset 5888 的分片出现 parser 容量拒收；后续 offset 7360 虽 parser 通过，但重组上下文只到 5888，连续偏移检查 `bounds_ok=0`，随后 engine 报 `80`。这解释了这些具体消息的缺片与连续偏移拒绝链。
- B180/C20 的原始 HDL 分别为 179/180 和 18/20 交付失败。运行期间诊断 runner 增加了未知事件统计/校验，触发来源身份 FAIL。**原标记完整保留，尚未完成针对每个快照的独立来源复核，因此不能把这两个诊断条目重标为接受成功。** 归档同时保留当时的 wrapper/runner 快照。
- C40 的采集成功且无来源漂移，但功能结果仍是 **33/40 交付 FAIL**。停止时尚未完成 index 38 的上下文占用分析，未证实后续全部失败都来自 16 个重组槽耗尽。

对应目录：[B180](out/faq_rx_trace_queue/20261103_221319_550979/mixed128/)、[C20](out/faq_rx_trace_queue/20261103_221319_550979/long128/)、[C40](out/faq_rx_trace_context/20261103_222215_278495/)。内部 trace 以 `rx_internal_trace.txt.gz` 保留。

**尚未实施硬件修复。** 增大原始 RX 环或解耦输出/排空都需要后续设计决策；任何 RTL 修改也会使现有源绑定 VQM/时序证据需要相应更新。没有通过降低负载、放宽阈值或忽略丢失消息让原测试变成 PASS。

## 网表及历史材料的未完成项

- NET01、NET02 都被内存保护终止（`memory_guard`、exit 15），没有有效 gate PASS。NET02 的 RTL 对照 1123 项通过仅证明其 RTL 部分。见[批次](out/netlist_verification/20261103_175259_142693/batch.json)、[NET01](out/netlist_verification/20261103_175259_142693/NET01.log)、[NET02](out/netlist_verification/20261103_175259_142693/NET02.log)。
- 最小 FAQ gate 原队列等待期间即被可用内存保护停止；随后的小重试在准备来源检查阶段失败，报 `Prepared input changed: ... tools/gui_netlist.py`，**尚未进入 gate 仿真**。见[重试原始日志](faq-gate-retry.log)。未通过刷新来源身份掩盖失败。
- 补充的 8 个历史模块网表缺少原文件，顶层 VQM 不能替代独立模块/probe。历史 MAC 与官方 IP 的面积比较也缺少完整原始生成材料，均不宣称当前重现成功。
- eLinx GUI 菜单没有产生可验证的 ModelSim 子进程；已有 CLI/native/GUI 波形证据分别保留。没有把菜单自动化当作额外的强制数值验收项。

## 归档使用方式

[manifest.json](manifest.json)逐项记录原工程相对路径、归档路径、原始及归档字节数、SHA256 和压缩方式。校验值只用于确认拷贝完整性，未建立新的验收基线。

本目录的 `out/...` 镜像对应原工程的 `out/...`。原 JSON/日志内容保持不变，内部绝对路径指向当时 Windows 工作机；这些路径不是要求克隆者拥有同一用户目录。查找实际随库文件时使用 manifest 的 `archived` 字段。`.gz` 可用标准 gzip 工具或 Python `gzip` 解压；解压后的 UCDB 可供 ModelSim/vcover 查看，全部 58 个接受输入 UCDB 及合并 UCDB 均保留。

归档包含关键汇总、原始通过/失败/来源漂移标记、诊断 trace、FAQ 公开捕获、相关 UCDB、13 张接受截图及复制完整性清单。未包含工具安装目录、许可证或凭据、私人 FAQ 工作簿及工作表导出、仿真可执行文件、WLF/编译工作库、115 MB 厂商 VQM，以及较早大性能回归的全部原始逐字节捕获。这些大件仍保留在原工作区，未删除。相关测试工具源代码与本归档在同一提交中保留，单凭本归档不能替代重新执行所需的 EDA 工具及厂商库。
