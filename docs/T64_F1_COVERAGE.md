# T64 F1 覆盖率回归与未覆盖项分析

## 验收结论

T64 第 1 至 8 节完成。冻结提交 `e5cd815020448820c2de7c587f288554defb74bc` 的 CE_DIV=2 标准清单 40 项带覆盖率回归全部 PASS，Error/Fatal/Warning/FAIL/RAMCOLL 均为零。旧 F1 普通回归 40 项均通过逐项复用核对，无需补跑；覆盖率开关前后 Checks、CheckItems 及 491 个确定性产物逐文件 SHA-256 一致。40 份成功尝试的 UCDB 均可读、测试身份正确，合并后包含精确的 40 个测试身份；29 个当前 RTL 设计单元全部纳入统计。

原有 538 个跟踪文件及冻结工具程序前后摘要一致。共有 2,711 条未覆盖索引，压缩位段展开后覆盖全部 13,806 个未覆盖 bin。分类和补测建议不改变原始分母，未知项没有被豁免。没有设置任意覆盖率通过线。

## 冻结来源与执行边界

- 工作目录：`E:/2026_Embedded_FPGA/worktrees/active/c3_t63`；分支 `t63`，启动时工作区干净。
- 卡片：`E:/2026_Embedded_FPGA/cards/T64_F1_coverage.md`；已完整读取并核对 T63 交接及适用规则。
- 当前清单：[sim/tests.txt](../sim/tests.txt)，40 项；同名不同参数独立计数。29 个 `.v` 文件实际声明 29 个模块，清单见 [coverage.json](evidence/t64_f1_coverage/coverage.json)。
- 配置：`AFDX_CE_DIV=2`、入口默认 `Seed=20261007`，原参数和完整测试窗口保留。20261007 是既有独立参考向量入口的种子；UCDB 自身原生 seed 字段为 0，与入口未额外设置 ModelSim 随机种子的行为一致，不混为同一种子。
- 工具：Python `E:/anaconda3/python.exe`，ModelSim SE-64 2020.4 Simulator/Compiler/Coverage Utility 2020.10；程序摘要、版本和环境记录见 [freeze.json](evidence/t64_f1_coverage/freeze.json)。
- 仅 RTL 以 `+cover=sbceft` 编译；TB 单独编译且没有 coverage 选项；仿真均为 `-batch -coverage`。编译宏、独立检查器与原入口一致。
- 没有修改 RTL、TB、既有 sim/tools、测试清单、种子、门限、参考模型、约束或全局设置。未综合、布局布线、跑网表、烧录、上板或进行完整协议认证；本报告不提供新的物理时序证据。
- 本次只新增 `tools/t64_coverage.py`、本报告及 `docs/evidence/t64_f1_coverage/`。`submission`、README、FACTS、两份正式报告及历史覆盖率均不更新；第 9 节留给父线程验收后处理。

## 运行入口、资源与实际耗时

调用既有串行 `sim/regress.ps1 -Coverage -Seed 20261007 -Deadline <启动后8小时>`，不采用并发仿真。新工具只负责冻结、复用核对、独立后台进程的整批截止、汇总和证据导出，没有替换既有编译、仿真或功能检查。串行入口使用标准 latest 指针，40 个数据库的来源按本批 summary 固定收集，未 glob 混入旧批次。

- 原生后台程序：北京时间 **2026-10-30T00:33:24+08:00 至 2026-10-30T05:34:57+08:00**，**18,093.625 s**（5 小时 1 分 33.625 秒，含冻结、回归、输出比较及 UCDB 合并/报告）。
- 标准覆盖率回归：北京时间 **2026-10-30T00:33:29+08:00 至 2026-10-30T05:31:45+08:00**，墙钟 **17,896.286 s**。
- 单项原生作业耗时之和（向量/编译/仿真/检查等）：17,876.512 s；单项仿真耗时之和：17,422.620 s。两者均不冒充整批墙钟。
- 硬截止：北京时间 **2026-10-30T08:33:28+08:00**，未触发。`tb_sys_perf` 仿真预算 9,000 s，`tb_sys_perf_var` 14,400 s，`tb_sys_load` 5,400 s，其余覆盖率仿真 3,600 s；编译沿用 120 s，其余阶段沿用现有预算，整批截止只会截短剩余预算。
- 本批最慢两项：`tb_sys_perf_var` 总原生作业 8,832.968 s、`tb_sys_perf` 5,056.969 s，均低于各自单项上限。40 项各有一次功能尝试，无失败、超时或重跑。
- 启动可用内存 14.230 GiB、E 盘空闲 110.292 GiB；运行记录最低可用内存 12.905 GiB、E 盘空闲 107.888 GiB。保留原入口较严的 5 GiB 内存下限，附加 8 GiB 磁盘下限。
- 启动时目标工作区无其他执行作业，旧 admission 无活动 lease；发现的用户 ModelSim GUI 位于 submission。当前批次串行占用一个仿真槽，未修改或关闭该 GUI，没有启动其他 EDA/仿真批次。全机 10 个 ModelSim 限额在启动核对时有充足余量。
- 唯一恢复入口：[out/t64/current.json](../out/t64/current.json)；原生程序 PID 9536，PID、启动时间、命令、子进程身份和状态见原始目录。后台程序脱离启动终端运行并自行等待、超时；没有 heartbeat、定时任务、模型续接或短时状态轮询。
- 原始日志时间为美国太平洋夏令时 UTC−7；本报告统一换算 UTC+8。最终分析与证据验收时间另见 acceptance.json。
- 离线缺口分析和首次完整证据终验于北京时间 **2026-10-30 05:55:50** 完成；从后台程序启动至此共 **19,346.335 s**（5 小时 22 分 26.335 秒）。该用时包含回归后的分析与整理，本地提交在终验后执行。

## 普通回归复用与开关对照

普通回归来源为 [sim/reference/regression.json](../sim/reference/regression.json)，`SourceCommit=92ab7d7ea0dd5ad3db443eb5b2d7aa7afd613516`，原始 40 项结果与其 summary 均保存。后续 F1b `9f9d0225` 修改两个 TB 库的网表观测宏分支，不能只因 RTL 一致就跳过依赖审查。

本次逐项核对“测试名＋排序后的参数＋CE_DIV＋种子”、原始命令、全部输入摘要、编译宏、向量及检查器。58 个 TB/include 当前文件与 F1b 保存快照逐字节相同，旧 F1 文件与其 baseline 快照逐字节相同；CE2 有效 HDL 两端 SHA-256 均为 `a88c844135f18bc97aa29a37372beddab4c6b5f5f46666a47db0d7c346d79b76`。该预处理证据仅去编译器行号指令与空白行，其余有效 HDL 不改。所有 RTL、向量生成、独立检查器、入口和清单仍一致。t62_runtime 的变化只涉及 registry 默认位置和可选环境守护，不改变仿真命令语义。

旧工具程序没有保存二进制摘要，因此不声称已经证明旧、今程序逐字节一致；已核对保存的 ModelSim 编译器版本、可执行路径，以及当前程序修改时间早于旧运行起点。当前工具二进制已在本批前后冻结和复核。逐项矩阵及此边界见 [reuse.json](evidence/t64_f1_coverage/reuse.json)。

40/40 可复用，补跑 0 项。27 项带独立检查器，共 **4,091,874 CheckItems**；13 项没有独立检查器，按 N/A 保留，未当成 0 分。全部测试共 **2,329,932,201 Checks**。491 个保存的确定性产物涵盖向量、原始帧/事件、PCAP、解码结果、check_summary 和 R97 输出，逐文件摘要全部一致；有些用例没有额外产物，表中给出 0，仍有 TB Checks 对照。详见 [comparison.json](evidence/t64_f1_coverage/comparison.json)。

|序号|用例|参数|Checks|CheckItems|比较产物|作业耗时 s|结果|
|---:|---|---|---:|---:|---:|---:|---|
|1|tb_ram_sdp|默认|20,764|N/A|0|4.297|PASS／一致|
|2|tb_mac_tx|默认|264,649|N/A|8|3.983|PASS／一致|
|3|tb_mac_rx|默认|105,303|N/A|4|3.704|PASS／一致|
|4|tb_mac_loop|默认|1,385,254|N/A|10|6.124|PASS／一致|
|5|tb_tx_basic|默认|662,156|7606|8|5.798|PASS／一致|
|6|tb_tx_basic|TX_PAGE_AW=5,TX_OFF_AW=11|661,736|7606|8|5.813|PASS／一致|
|7|tb_tx_bag|默认|14,054,199|14592|8|28.686|PASS／一致|
|8|tb_tx_multi|默认|14,438,572|56224|8|43.422|PASS／一致|
|9|tb_tx_drop|默认|30,267,272|4643|8|63.235|PASS／一致|
|10|tb_tx_net|默认|219,323|230|8|4.518|PASS／一致|
|11|tb_rx_basic|默认|9,960,369|123855|8|39.516|PASS／一致|
|12|tb_rx_fault|默认|576,923|890|8|5.562|PASS／一致|
|13|tb_rx_icrm|默认|4,635,284|1274|8|13.437|PASS／一致|
|14|tb_rx_load|默认|6,406,189|19180|8|18.765|PASS／一致|
|15|tb_rx_ovf_ring|RX_RING_AW=9|422,837|99|8|5.031|PASS／一致|
|16|tb_rx_ovf_dq|RX_DQ_AW=1|373,852|57|8|5.032|PASS／一致|
|17|tb_rx_net|默认|374,111|110|8|5.030|PASS／一致|
|18|tb_sys_basic|默认|5,156,222|2898|29|36.108|PASS／一致|
|19|tb_sys_fault|默认|42,097,787|9008|29|273.249|PASS／一致|
|20|tb_sys_delay|默认|13,938,621|3915|29|95.001|PASS／一致|
|21|tb_sys_load|默认|193,108,134|122284|29|1255.765|PASS／一致|
|22|tb_sys_cfg|默认|19,020,433|717644|29|136.406|PASS／一致|
|23|tb_sys_reset|默认|10,177,297|3844|29|68.561|PASS／一致|
|24|tb_sys_ovf|RX_RING_AW=9|8,881,779|1550|29|63.610|PASS／一致|
|25|tb_sys_net|默认|2,792,795|1307|29|24.484|PASS／一致|
|26|tb_sys_perf|默认|683,383,807|1309214|31|5056.969|PASS／一致|
|27|tb_sys_rtc|默认|10,675,841|1811|7|735.594|PASS／一致|
|28|tb_sys_snmp|默认|37,611|926|8|198.298|PASS／一致|
|29|tb_sys_snmp_settrap|默认|8,563|188|8|167.954|PASS／一致|
|30|tb_sys_615a|默认|44,098|752|43|337.124|PASS／一致|
|31|tb_gbe_burst|COUNT=77|530,765|N/A|2|31.562|PASS／一致|
|32|tb_gbe_burst|COUNT=81|554,697|N/A|2|32.329|PASS／一致|
|33|tb_rm_phase|默认|353,130|N/A|0|36.140|PASS／一致|
|34|tb_rtc_recovery|默认|28|N/A|0|3.704|PASS／一致|
|35|tb_rtc_originate|默认|34|N/A|0|4.234|PASS／一致|
|36|tb_judge_capacity|默认|49,924|N/A|0|33.235|PASS／一致|
|37|tb_judge_snmp|默认|699|N/A|0|133.874|PASS／一致|
|38|tb_elinx|默认|9,238|N/A|0|37.281|PASS／一致|
|39|tb_sys_perf_var|默认|1,254,269,621|1680167|32|8832.968|PASS／一致|
|40|tb_top_wrap|默认|12,284|N/A|0|20.109|PASS／一致|

40 项 Error、Fatal、Warning、FAIL、RAMCOLL 均为 0，独立检查器 errors 均为 0；每项诊断已登记在 comparison.json。

## UCDB 完整性与统计方法

仅以本批 [summary.json](../out/regress/coverage_20261029_093329_1383247/summary.json) 指向的 40 次成功尝试构造输入列表。每份独立数据库都通过同版 vcover testnames/report 读取，名称绑定测试及唯一目录；编译日志同时确认 RTL 插桩、TB 无插桩。合并命令使用 `vcover merge -checkinputs -ucdbchecks`，原始输出为 `All input files merged successfully`、Errors 0、Warnings 0。合并数据库测试集合与精确 40 项尝试集合相等。

合并 UCDB：`out/t64/20261029_093324_002975/merged.ucdb`，**3,411,724 bytes**，SHA-256 **`1B89C4C6C2B143203BB6A83CEE8837E8A72575266B5C49F8821DCF30F10609E0`**。40 份数据库摘要、大小、参数、来源见 [ucdb_inputs.json](evidence/t64_f1_coverage/ucdb_inputs.json)；独立 testnames 原文、合并诊断和合并 testnames 原文保存在 [raw/](evidence/t64_f1_coverage/raw/)。大数据库与完整仿真日志留在 out，未复制进仓库。

按当前源码模块集合导出 29 份 DU summary 和未覆盖详细报告，再核对合并数据库实际有覆盖统计的 DU 并集，精确相等；TB 未进入统计。每个源码设计单元只计一次，参数化实例在同一 DU 内由工具归并；不对模块百分比求平均。条件/表达式采用工具的 Focused Condition/Expression Coverage 输入项口径。N/A 表示总项数为 0。百分比以整数计算 `floor(covered*10000/total)/100`，截断保留两位；FSM 合计为状态＋转移。参数标签可能混合不同参数实例的局限在缺口分析 C03 明示。

|指标|已覆盖|总数|未覆盖|覆盖率|
|---|---:|---:|---:|---:|
|语句|7,754|7,864|110|98.60%|
|分支|4,344|4,491|147|96.72%|
|条件|882|1,001|119|88.11%|
|表达式|1,767|2,027|260|87.17%|
|FSM 状态|127|127|0|100.00%|
|FSM 转移|155|338|183|45.85%|
|翻转|44,903|57,890|12,987|77.56%|
|FSM 合计|282|465|183|60.64%|

## 逐模块覆盖率

下表为截断后的百分比。各模块、各指标的已覆盖数/总数完整保存在 [modules.csv](evidence/t64_f1_coverage/modules.csv) 和 [coverage.json](evidence/t64_f1_coverage/coverage.json)，并可逐一追溯到 [raw/](evidence/t64_f1_coverage/raw/) 的原始 summary。没有沿用 T57 的 24 模块白名单。

|设计单元|语句|分支|条件|表达式|状态|转移|翻转|
|---|---:|---:|---:|---:|---:|---:|---:|
|afdx_615a|100.00%|100.00%|74.19%|100.00%|N/A|N/A|59.13%|
|afdx_615a_engine|97.14%|94.31%|76.19%|81.58%|100.00%|29.62%|66.78%|
|afdx_app_map|100.00%|100.00%|N/A|N/A|N/A|N/A|78.12%|
|afdx_app_read|100.00%|100.00%|100.00%|100.00%|N/A|N/A|97.56%|
|afdx_app_rx|97.95%|93.54%|100.00%|55.55%|100.00%|60.00%|83.90%|
|afdx_app_tx|99.12%|98.22%|95.58%|72.22%|100.00%|55.00%|87.18%|
|afdx_cfg|100.00%|99.09%|75.60%|86.75%|N/A|N/A|64.97%|
|afdx_crc32_d8|100.00%|100.00%|N/A|N/A|N/A|N/A|50.00%|
|afdx_es|100.00%|100.00%|100.00%|75.67%|N/A|N/A|77.47%|
|afdx_mac_rx|100.00%|100.00%|100.00%|100.00%|100.00%|100.00%|99.67%|
|afdx_mac_tx|98.93%|93.15%|84.61%|76.92%|100.00%|88.88%|92.41%|
|afdx_mgmt_tx|100.00%|100.00%|100.00%|90.00%|N/A|N/A|79.31%|
|afdx_ntp_fraction|96.42%|95.83%|100.00%|N/A|100.00%|80.00%|99.12%|
|afdx_ram_sdp|50.00%|62.50%|0.00%|N/A|N/A|N/A|99.64%|
|afdx_rtc|96.65%|94.13%|65.62%|60.46%|100.00%|43.39%|69.72%|
|afdx_rx_core|100.00%|99.73%|100.00%|100.00%|N/A|N/A|98.81%|
|afdx_rx_deliver|98.55%|96.00%|85.71%|100.00%|100.00%|75.00%|100.00%|
|afdx_rx_engine|99.24%|98.17%|96.66%|98.52%|100.00%|75.00%|70.26%|
|afdx_rx_parse|100.00%|100.00%|97.43%|96.66%|100.00%|60.00%|93.27%|
|afdx_snmp|98.65%|93.06%|57.14%|100.00%|100.00%|83.33%|46.82%|
|afdx_snmp_engine|97.02%|93.73%|85.58%|84.35%|100.00%|26.36%|63.24%|
|afdx_svc|100.00%|100.00%|100.00%|67.69%|N/A|N/A|94.56%|
|afdx_timebase|100.00%|100.00%|N/A|N/A|N/A|N/A|86.27%|
|AFDX_top|100.00%|100.00%|N/A|62.50%|N/A|N/A|98.26%|
|afdx_tx_buf|98.62%|94.93%|81.25%|90.90%|100.00%|70.83%|100.00%|
|afdx_tx_builder|99.39%|98.07%|96.96%|95.00%|100.00%|80.00%|91.93%|
|afdx_tx_core|100.00%|100.00%|50.00%|100.00%|N/A|N/A|92.84%|
|afdx_tx_engine|99.23%|98.13%|87.50%|95.91%|100.00%|72.72%|92.74%|
|afdx_tx_free|98.38%|96.66%|83.33%|83.33%|100.00%|66.66%|99.09%|

## 未覆盖项与验证边界

完整索引 [uncovered_index.csv](evidence/t64_f1_coverage/uncovered_index.csv) 的每条记录具有模块、源码行、工具原文行、覆盖项、bin 数、分类及分析组；[gap_analysis.md](evidence/t64_f1_coverage/gap_analysis.md) 给出源码依据、触发条件、未知项与按风险排序的后续建议。[index_validation.json](evidence/t64_f1_coverage/index_validation.json) 对 29 个模块、7 类原始指标逐一证明索引未覆盖数与 summary 缺口相等。没有静默漏项；按源码字面补零边界拆分的翻转行保持 bin 数不变。

|分类|索引条目|未覆盖 bin|解释|
|---|---:|---:|---|
|A|275|2,240|实际可达但本批未覆盖|
|B|36|862|本批配置和明确假设下不可达|
|C|63|126|工具识别/插桩/统计局限，未豁免|
|U|2,337|10,578|尚不能判断|

- 状态转移优先项：61 条同步复位、16 条 RTC 中止未逐状态覆盖；SNMP part 的 54 条候选跨状态弧具有工具提取局限；加载辅助状态 35 条、RTC 再入 14 条、其余 3 条仍待关联可达性分析。
- 真正需要优先补测的是恢复后的数据完整性、应用缓存/描述符边界、A 网队列满及回收、重复数据块/丢 ACK/远端 ERROR/坏 CRC、SNMP 错误字段、RTC 进位。后续建议没有在本卡偷偷新增测试或放宽判据。
- **127/127 状态只代表工具识别集合。**两项服务引擎主 state 没有被工具识别；状态 100% 不能代替转移 45.85%，也不能声称协议全路径已验证。
- 显式常量、冗余状态位、静态求宽函数、CRC 循环变量、参数标签混合均保留原始分母。其余宽中间值、数据位域及状态关联缺口仍有未知，未作全量形式证明。
- T57 历史覆盖率仍在 `sim/reference/coverage/`，其源码、模块和分母不同；本报告没有把总百分比差解读为验证进退。
- 本批所有单项与必需 vcover merge/report 成功。可选的全 UCDB dump 进入重复实例部分后终止，只保留完整 DU 原生段（约 27 MB）用于为隐式分支补源码定位；终止 PID/启动时间/命令及原因在 out 中保存，不把这个中止当作必需 merge/report 的失败。帮助命令曾因本版不接受 `vcover help report` 而报错，已用 `report -help` 核实语法；未影响任何回归。索引初版拦下两个优化后无直接定位的状态高位，核实声明后补齐，未重跑仿真。

## 证据入口与验收结果

- [freeze.json](evidence/t64_f1_coverage/freeze.json)：冻结提交、538 个原文件、模块、清单、工具版本/摘要和启动前资源/进程。
- [reuse.json](evidence/t64_f1_coverage/reuse.json)、[comparison.json](evidence/t64_f1_coverage/comparison.json)：40 项普通复用矩阵和覆盖率开关对照。
- [ucdb_inputs.json](evidence/t64_f1_coverage/ucdb_inputs.json)、[collection.json](evidence/t64_f1_coverage/collection.json)：40 份数据库与合并结果。
- [coverage.json](evidence/t64_f1_coverage/coverage.json)、[modules.csv](evidence/t64_f1_coverage/modules.csv)、[raw/](evidence/t64_f1_coverage/raw/)：总体/逐模块计数及原始文本报告。
- [uncovered_index.csv](evidence/t64_f1_coverage/uncovered_index.csv)、[branch_uncovered_native.txt](evidence/t64_f1_coverage/branch_uncovered_native.txt)、[gap_analysis.md](evidence/t64_f1_coverage/gap_analysis.md)：完整索引与主要分析。
- [acceptance.json](evidence/t64_f1_coverage/acceptance.json)、[manifest.json](evidence/t64_f1_coverage/manifest.json)：终验状态及提交证据的路径、大小和 SHA-256 清单。
- 本机原始目录：[out/t64/20261029_093324_002975/](../out/t64/20261029_093324_002975/)；启动脚本快照 `launch_tool.py` 保留原运行工具摘要，当前工具在运行结束后新增了离线 publish/索引逻辑，未改变已完成的运行。复算执行 `E:/anaconda3/python.exe -B -X utf8 tools/t64_coverage.py publish`，依赖已保留的原始目录。`launch` 对已有唯一运行明确拒绝，恢复时先读 current.json 和 state.json，不重启整批。

本卡自动创建本地提交，提交对象仅为上述白名单新增文件；最终 commit 见交付回复及 Git 历史。未 push、merge、amend 或创建 PR。父线程依据本报告验收，再执行任务卡第 9 节。
