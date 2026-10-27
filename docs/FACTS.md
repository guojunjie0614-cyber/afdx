# AFDX 端系统事实清单

当前参考输出对应 2026-10-27 的 T59 实测；RTL 源码仍是 master `5a71a5ff`（本卡不改 `rtl/`、`elinx/`），测试、脚本和文档在分支 `t59`。资源与时序仍引用 2026-10-26 的 T57 `f1393d44`（master 合并 `8ef6f0cd`）。

补充的逐项测试、资源、时延、参数和异常覆盖见 [补充数据](FACTS_DETAIL.md)。
本页分别记录当前性能实测与带日期的历史终验；RTL 源码共 24 个模块，标准回归清单 39 项，评委入口 8 用例。当前完成状态以第三、四节的本轮实测为准；带日期的历史专项实验保留原记录。功能覆盖以实际测试范围为准，不等于完整协议认证。
赛题来源：[选题指南](sources/中科亿海微.pdf)正文第 2–4 页（PDF 第 4–6 页）；答疑来源：[问题汇总 1026 版](sources/FPGA创新大赛问题汇总1026.xlsx)的 Sheet1，R 表示工作表行号。1026 版在 1022 版之后新增 R113–R126：其中 R119/R123/R125 改时延口径，R119-2 改抖动口径，R120 规定 100 Mbps 测法、128 条 VL 和 `tx_data`/`rx_data` 数据含义，R122 说明资源不计分，R124/R126 说明顶层激励只需注入 VLID 和应用数据。
性能口径与变长帧结果采用 2026-10-27 的 T59 完整窗口实测；CE2 的 Tcl 与 Python 两份记录在同一批文件夹上逐字段一致，差异为 0（`证据/perf_r97.json:equivalence`）。CE2 回归 39/39、评委 8/8 通过；参考计数取本次运行结果。历史异常注入及第九节专项实验保留原日期、原始数字和测量范围；当前综合、布线及同版网表验证仍为第三节的 T57 结果。
本页的 `参考/` 指 [`sim/reference/`](../sim/reference/)，`证据/` 指 [`docs/evidence/`](evidence/)：原始输出的副本及只读数据库查询结果，`manifest.json` 记录每份文件的原位置和 SHA-256 摘要；文件里的绝对路径是生成时那台机器上的路径，不在本仓库。标准测试可用下列命令重建，专项实验的复现限制在对应条目说明。
命令均在仓库根目录的 PowerShell 执行；先按 [软件准备](../README.md#软件准备)配置工具路径和 Python 依赖。下表 `run <名称>` 表示 `powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test <名称>`。

## 一、需求对照

赛题评分比例为代码及仿真环境 40%、设计文档 20%、测试报告 20%、技术指标 20%（选题指南正文第 4 页）。
| 要求 | 已实现及实测结果 | 测试与复现 |
|---|---|---|
| ARINC 664 Part 7 通信 | UDP/IP 收发、虚拟链路配置、发送调度及双网传输；本轮同激励 RTL 五功能自检 1124 项、0 错误。网表对照状态见第四节。 | `tb_net_services`；`证据/manifest.json` 中 `file=t57_timing.json` 条目的 `terminal_results.netlist`。 |
| 高完整性通信 | 检查帧校验、长度、序号，双网重复帧只交付一次；五功能记录含坏序号拒绝与正常副本去重，完整回归另含冗余跨刻度、逆序到达测试。 | `run tb_net_services`、`run tb_rm_phase`；`证据/gui_services_summary.json:check.checks`、`参考/regression.json`。 |
| SNMP 网络管理 | Get/GetNext/Set/Trap 字段及配置口读回检查通过；专项自检 699 项、0 错误。 | `run tb_judge_snmp`；`证据/snmp.log` 的 `[RESULT]` 行。 |
| 615A 数据加卸载 | 文件加载到片内 RAM，再以 MEMORY.BIN 卸载；五功能中 16 字节逐字节一致，下载独立检查 41 项通过。 | `run tb_net_services`、`run tb_sys_615a`；`证据/gui_services_summary.json:check.download`。 |
| RTC 时钟同步 | 通过网络时间报文同步，支持丢回应重试，并检查回应是否回显本次请求时间戳（Originate）；空载/带载误差见下节。 | `run tb_sys_rtc`、`run tb_rtc_recovery`、`run tb_rtc_originate`；`证据/rtc.json`、`参考/regression.json`。 |
| 传输速率 100 Mbps | R120-1 在发送注入口按注入的有效载荷字节数统计。定长 gbe77 每方向注入 906.136 Mbps，混合帧长 var_high 注入 904.752 Mbps；接收应用口去重后分别为 906.136/904.752 Mbps，均不把 A/B 相加。 | `run tb_sys_perf`、`run tb_sys_perf_var`、`do sim/run_app.do`；`证据/perf_r97.json:main_table`。 |
| 帧格式 | 支持以太网帧、VLID、序号和最多 1471 字节消息；对应最大帧长 1518 字节，含 FCS，不含前导码。序号正常按 1–255 循环，复位首帧 0 按协议单独处理。 | `run tb_mac_tx`、`run tb_mac_rx`、`run tb_rx_icrm`；`参考/regression.json`，编码与检查见 `rtl/afdx_tx_builder.v`、`tools/afdx_ref.py`。 |
| 时延与抖动 | R119：任意 VL 首字节应用输入到对端交付该数据的时长 <1–2 ms（最坏情况）。本设计 gbe77 主时延 L_entry_last 最大 36.336/38.392 µs（链路 0/257 拍），全部工况最大 46.744 µs（var_burst，257 拍链路）；R119-2 抖动（同一 VL、同一帧长）最大 9.816 µs，位于 VL25、帧长 256 字节（帧 2666→3266）。 | 定义、工况和边界见第二、五节；`证据/perf_r97.json:main_table`、`jitter_r119_top`、`policy`。 |
| 128 条发送 / 4096 条接收虚拟链路 | 每端配置全部接收项，全部发送项各发一条消息；实际交付覆盖接收索引 0、4095 及中间 126 项，不是逐项发送遍历全部接收项。自检 49924 项通过。 | `run tb_judge_capacity`；`证据/capacity.log` 的 `[CAPACITY_SUMMARY]`、`[RESULT]`。 |

## 二、性能数字与测量方法

性能仿真共用理想 125 MHz 时钟，一拍 8 ns；GMII 每拍一字节。R95-1 要求千兆 GMII；R120-1 规定吞吐在发送注入口（`tx_data` 一侧）按单位时间内多 VL 注入的有效载荷字节数统计，A/B 副本与头部不计（`证据/perf_r97.json:main_table`）。

### 时延与抖动定义（R119、R120）

R119-1 把端到端时延改为“任意 VL 的首个 `tx_data` 数据输入到 `rx_data` 接收该数据的时长”，R123、R125 给出相同表述。本设计在应用发送口记录消息首字节第一次 `valid` 为高的拍 S，在接收应用口记录交付首字节拍 D 和末字节拍 D+n−1；主指标 L_entry_last = D+n−1−S，同时报告 L_entry_first = D−S。首字节握手前的反压和 BAG 等待都计入。来源：R119-1、`证据/perf_r97.json:definitions`。

| 名称 | 起点 | 终点 | 说明 |
|---|---|---|---|
| L_entry_last | 应用发送口消息首字节第一次 `valid` | 接收应用口交付该消息末字节 | 本卡主指标，门限 2000 µs |
| L_entry_first | 同上 | 接收应用口交付首字节 | 同时报告的对照口径 |
| L_gmii（legacy） | 发送端 GMII TX 同帧 SFD | 接收端 GMII RX 同帧 SFD | R97-1 旧定义，**已被 R119 取代** |
| L_tx（legacy） | 应用末字节握手 M | 发送端 GMII TX 同帧 SFD | 兼容字段 |
| L_rx / L_rx_last（legacy） | 接收端 GMII RX 同帧 SFD | 交付首/末字节 | 兼容字段 |
| L_app / L_app_last（legacy） | M | 交付首/末字节 | 旧主指标，保留为补充 |
| L_release_app / L_release_app_last（legacy） | 主机计划释放拍 | 交付首/末字节 | 含单应用口串行注入排队 |

R97 原文使用“发送端 GMII 输入”“接收端 GMII 输出”；本直连仿真按上表 TX/RX 边界测量，L_gmii 等于链路模型延迟 0.000 或 2.056 µs，不能把它当作端系统性能。这些 GMII 与末字节口径只作兼容字段保留，不再作为主指标。
R119-2 的抖动是同一 VL、**帧长相同**的多帧 L_entry_last 最大值减最小值，再取所有组的最大值，并给出所在 VL、帧长和两帧编号；它包含 ARINC 664 的 BAG 抖动。旧 R97-2 的“同一 VL 多帧”不区分帧长，已被 R119-2 取代；原“相邻发送起点间隔偏离 BAG”仍称发送间隔偏差（`tx_interval_jitter`），不是抖动。来源：R119-2、`证据/perf_r97.json:definitions`、`jitter_r119_top`。

R120-1 的吞吐在发送注入口统计：窗口内握手成功的有效载荷字节数 ÷ 窗口时长；同时报告 `app_tx_valid` 为高而 `app_tx_ready` 为低的拍数、最长连续反压拍数、相对计划释放的最大落后拍数，以及丢帧、重复交付、溢出和错误计数。窗口取各工况的稳定注入段（`F begin/end` 或应用入口的 `window.txt`），去掉开头预热和结尾排空；判定为注入 ≥100 Mbps、丢帧/溢出/重复为 0、落后不超过一条最大消息（1471 拍）。来源：R120-1、`证据/perf_r97.json:main_table`。

| 工况 | 注入 Mbps | 主时延最大 µs | 首字节时延最大 µs | 抖动最大 µs（VL/帧长） |
|---|---:|---:|---:|---|
| gbe77_d0 | 906.136 | 36.336 | 24.576 | 0.008（29/1471） |
| gbe77_d257 | 906.136 | 38.392 | 26.632 | 0.008（1/1471） |
| var_burst_d0 | 57.794 | 44.792 | 33.032 | 0.000（0/1） |
| var_burst_d257 | 57.794 | 46.744 | 34.984 | 0.008（3/1024） |
| var_cycle_d0 | 70.403 | 36.328 | 24.568 | 9.816（25/256） |
| var_cycle_d257 | 70.403 | 38.384 | 26.624 | 9.816（25/256） |
| var_fixed_d0 | 57.794 | 36.336 | 24.576 | 0.008（24/1471） |
| var_fixed_d257 | 57.794 | 38.384 | 26.624 | 0.008（3/1024） |
| var_high_d0 | 904.752 | 36.336 | 24.576 | 0.008（50/1471） |
| var_high_d257 | 904.752 | 38.392 | 26.632 | 0.008（15/1471） |

表中合并两方向取最大值；逐方向、两种时延口径、反压与落后拍见[时延细分](FACTS_DETAIL.md#各工况的时延细分)，原值为 `证据/perf_r97.json:main_table`。R119 主时延包含首字节握手前的反压和 BAG 等待：gbe77 的 36.336 µs 中约 11.8 µs 是 1471 字节逐拍输入，其余是发送与接收处理；旧 L_app_last 的 24.432 µs 仍作为兼容字段保留，不能和新主指标混用。
变长循环的最大 R119-2 抖动为 9.816 µs，定位在 VL25、帧长 256 字节，两帧编号 2666→3266；旧 9.992 µs 是不同帧长（256 B 与 1 B）之间的极差，已被 R119-2 的“帧长相同”口径取代（`证据/perf_r97.json:jitter_r119_top`）。
var_burst 的同拍提交指同拍进入测试主机待发队列，再按单一应用口握手串行注入。R119 主时延最大 46.744 µs；计划释放→首/末字节最大 174.464 / 174.592 µs，释放口径抖动最大 0.008 µs。差额主要是主机串行注入排队，R119 主口径从首字节 valid 起算，释放口径是最坏参考（`证据/perf_r97.json:main_table`、`burst_release_analysis`）。

### 应用激励入口（R124、R126）

`sim/run_app.do` 的默认激励有 84 条消息、21 条 VL，覆盖 1/17/256/1024/1471 字节，注入窗口取 1–4 ms。实测注入 **210.440 Mbps**，L_entry_last 最大 **552.000 µs**（首字节 540.240 µs），R119-2 抖动最大 **26.000 µs**（VL0/帧长 1471），窗口内反压 990 拍、最长连续 6 拍，注入落后计划最大 1375 拍（不超过一条 1471 拍最大消息），丢帧/重复/溢出均为 0，判定 PASS。手写小激励（3 条 VL、5 条消息，`sim/vectors/app/small_stimulus.txt`）的 `rx.txt` 逐条与输入一致，因没有窗口文件吞吐只报告。数据见 `证据/perf_r97.json:application_entry`，原始记录在 `out/app/<运行名>/`。

### 变长帧与多虚拟链路工况

| 工况 | VL数 / BAG | UDP载荷字节 | 提交方式 |
|---|---|---|---|
| var_fixed | 32；1/2/4/8 ms各8条 | 1、17、256、1024、1471；每VL固定一种 | 错开 |
| var_cycle | 32；1/2/4/8 ms各8条 | 同一VL按上述五种长度循环 | 错开 |
| var_high | 80；1 ms | 前4条为1、17、256、1024，其余76条为1471 | 错开 |
| var_burst | 同var_fixed | 同var_fixed | 同拍释放到主机队列，单口串行握手 |

载荷1/17字节对应最小64字节以太网帧，256/1024字节为中间长度，1471字节对应最大1518字节帧；帧长含FCS、不含前导码。全部工况覆盖链路延迟0/257拍、双向、A/B开启。fixed/cycle/burst预热16 ms、窗口64 ms；high预热2 ms、窗口20 ms，每VL窗口至少8帧；同一批记录上 Tcl 与 Python 两份统计的 20560（perf_var）/1780（perf）个字段逐一相等，差异为 0（`证据/perf_r97.json:equivalence`）。
复现：`run tb_sys_perf_var`；纯 ModelSim 在仓库根目录执行 `set ::env(AFDX_JUDGE_CASE) perf_var` 后 `vsim -batch -do "do sim/run_judge.do; quit -f"`，取消筛选用 `unset ::env(AFDX_JUDGE_CASE)`。旧定长工况用 `run tb_sys_perf`。
新工况仅 var_high 检查注入 ≥100 Mbps；fixed/cycle/burst 的给定负载低于该值，注入只报告，不能据此判性能失败。全部帧（含预热）检查 L_entry_last ≤2000 µs，同时核对恰好一次交付、无丢包、冗余副本拒绝与错误计数。R119-2 未给出抖动数值上限，抖动只报告，50 µs 是项目检查器的判定线，不是官方门限（`证据/perf_r97.json:policy`、`validation`）。旧兼容字段 `jitter_us` 仍指发送间隔偏差，不能当作 R119-2 抖动。
var_cycle 的发送间隔偏差为 6.192 µs；gbe77、var_fixed、var_high、var_burst 均为 0.000 µs；旧 L_gmii 抖动均为 0.000 µs（`证据/perf_r97.json:main_table`）。gbe77 已有独立计划释放记录，注入落后最大 1 拍；释放口径只作为兼容字段。

| 其它项目 | 数值及条件 | 日志定位 |
|---|---|---|
| 容量 | 每端发送 128 条、接收配置 4096 条，接收交付抽测 128 个索引。容量测试为每条一次消息，不把它当作满容量吞吐测试。 | `证据/capacity.log`：`tx_vls_each=128 rx_configured_each=4096 rx_sampled_each=128 first=0 last=4095`。 |
| RTC 误差 | 空载最大 0 ns；普通用户流量及 77 条虚拟链路满载均为 10788 ns（10.788 µs）。经公开配置口读两端时钟后比较；共用理想时钟及对称链路，未测试晶振漂移。满载为 1471 字节、BAG=1 ms，预热后测量 21 ms。 | `参考/judge_result.txt`：`rtc_idle_max_ns=0 rtc_loaded_max_ns=10788 rtc_77vl_max_ns=10788`；`tb/tb_sys_rtc.v`、`证据/rtc.json`。 |

完整旧性能矩阵还记录 10 条虚拟链路 117.680 Mbps、81 条 953.208 Mbps；这是历史补充数据，来源为 `证据/performance.json` 的 `throughput_d0`、`gbe81_d0`，不替代上述当前时延口径。

## 三、综合资源与时序

器件 EQ6HL130、封装 CSG484_H，唯一主时钟为 8 ns（125 MHz），顶层 `CE_DIV=2`；交付工程使用 PRES1.45，无单元坐标约束。时钟约束为 125 MHz（周期 8.000 ns）；为保留裕度，建立时间检查额外设置 0.30 ns 时钟不确定度（clock uncertainty），即每条路径须在 7.70 ns 内完成。已完成 T57 官方综合、布局布线及全量时序导出；实现后全部 46325 个端点满足要求：setup +0.011 ns（含 0.30 ns 不确定度；按 8 ns 为 +0.311 ns）、保持时间最差余量 +0.229 ns，0 个失败端点。多周期路径最差 +1.580 ns。

| 项目 | 当前官方结果 |
|---|---|
| 查找表（LUT） | 33799 / 136160（24.82%） |
| 触发器（FF） | 17086 / 136160（12.55%） |
| 可配置逻辑块（CLB） | 4331 / 13616（31.81%） |
| 存储器（Memory） | 366 / 1200（30.50%） |
| 用户引脚 | 257 / 339（75.81%） |
| DSP / PLL | 0 / 0 |
| 综合后建立裕量／保持裕量 | +4.148 / -0.068 ns |
| 综合后最高频率估算 | 不显示（设 0.30 ns 时钟不确定度） |
| 布线后建立裕量／保持裕量 | +0.011 / +0.229 ns |
| 布线后最高频率估算 | 不显示（设 0.30 ns 时钟不确定度） |
| 布线后 setup / hold 失败端点 | 0 / 46325；0 / 46325 |
| 8 ns 单周期路径数／最差 setup | 147349 / +0.011 ns |
| 16 ns 路径数／最差 setup | 50296 / +1.580 ns |
| 同沿 hold 路径数 | 197645 |

约束检查：2755 个引擎寄存器，不合格寄存器 0，遗漏内部连接 0；综合、实现及全量报告的约束审查均通过。
综合估算、布线后静态时序和 RTL 性能仿真采用不同证据口径；未设置完整外部 I/O 延迟预算，也没有上板测量。当前轻量时序证据为 `docs/evidence/t57_timing.json`，五线终验与参考输出来源登记在 `docs/evidence/manifest.json`。D3 `f60aaacd` 的历史资源为 LUT/FF 38297/19947；本版分别减少 4498（11.7%）和 2861（14.3%），历史原值保留在 `t43_timing.json`。

CE1/CE2 回归均 39/39 通过；CE2 覆盖率回归 39/39，产出 39 个 UCDB；CE2 评委入口 8/8 通过。
本轮同激励 RTL 五功能联测中，SNMP、上传、卸载分别为 1481、16689、48363 拍；这是相应用例的观察值。


T57 界面工程与官方命令行复跑的资源和布线时序逐项一致，查询结果见 `evidence/gui_timing.json`、`route_timing.json`；界面工程的综合时序数据库未留存，综合估算取同源命令行产物。

历史原始记录：2026-10-15 的命令行完整流程耗时 233.062 秒，八项资源与时序指标逐项等于当日界面结果，整个 `clk` 时钟摘要和最慢路径查询也一致。运行目录为 `out/synth/AFDX_top/20261015_091856_983349/`，各阶段退出码和耗时见 `tool_metrics.json`。

### 综合警告说明

T57 官方综合共 7 条警告，原始编号与消息见 [综合警告清单](evidence/t57_synthesis_warnings.json)。评委入口的“仿真 0 警告”仅描述 ModelSim 编译和运行日志，与“综合 7 条警告”是两回事。

| 编号与数量 | 对象、原因与适用条件 |
|---|---|
| 10230 ×1 | `afdx_615a_engine.v:2179` 的扫描位置运算从 32 位截成 11 位；件号长度限制在 64 字节以内、头缓冲区 2048 字节。合法且位于头缓冲区内的输入，其被截高位均为 0；此说明不把合法输入边界推广到任意畸形指针。 |
| 276026 ×2 | `load_ram`、`tx_payload` 映射到 M-RAM，上电内容未知。两块均先写后读：发送负载写满一页后才读该页，加载区由 `available_size` 保护，不依赖上电值。 |
| 276020 ×2 | SNMP、loader 两个 `afdx_mgmt_tx` 各有 8 字节队列；工具为同拍同址读写补直通逻辑。空队列不读，满队列不再发起写入来源的预取；在途读占用预留位置，因此有效同址读写不会发生。 |
| 21074 ×1、15610 ×1 | 同一未使用输入 `rx_ready` 的两条提示。该端口由赛题模板规定；官方答疑 R62 允许不用 ready，GMII 接收按当拍 valid 处理。 |

## 四、仿真入口与已跑结果

环境记录为 eLinx 3.0.7、ModelSim SE-64 2020.4、Windows PowerShell 5.1；Python 入口另需 `psutil`、`pyasn1==0.4.8`。软件与许可证不随工程分发。
| 入口 | 操作 | 实跑结果与耗时 |
|---|---|---|
| eLinx 界面行为仿真 | 打开 `elinx/AFDX_EndSystem.epr`，设置 ModelSim 路径；Simulation Sources 确认 `tb_elinx`，点 Run Behavioral Simulation。 | `[RESULT] tb_elinx PASS checks=9238 errors=0`；设计内时间 2557089 ns。界面中的这次运行在 2026-10-12（RTL 整理前），记录见 `证据/gui_behavior.log`，会话耗时 00:02:47 可能包含界面停留；同一测试平台在 2026-10-14 的完整回归中以脚本运行，结果同为 9238/0。 |
| 纯 ModelSim 评委入口 | 仓库根目录 `vsim -batch -do "do sim/run_judge.do; quit -f"`，无需 Python；`-batch` 绕开本地 vish/vsim 的 RPC 传输，`transcript` 也不可用。 | 本轮 T59 8/8 通过，`JUDGE ENTRY PASS cases=8 warnings=0 elapsed_s=5801.362 output_mib=1017.7`；见 `参考/judge_result.txt`。 |
| 完整 RTL 回归 | `sim/regress.ps1`；CE2 带 `-Coverage`。 | 本轮 T59 的 CE2 回归 39/39 通过（自检合计 2585512407、独立核对 3895481，来源为本轮逐项 `Checks/CheckItems`）；CE2 覆盖率回归 39/39、39 个 UCDB 仍为 T57 对同一 RTL 的记录，本卡未重跑覆盖率。 |

综合后功能仿真共用官方 VQM 入口，使用原厂单元模型，不含布线延迟。
| 网表来源 | 仿真副本补全内容 | 已跑结果 |
|---|---|---|
| 界面 `elinx/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm` | `tools/adapt_gui_vqm.py` 按组件声明/模型补省略输入，按原有进位连接补 `cin_used=true`；只写仿真副本。 | 2026-10-13 的 `tb_elinx` 为 9238/0，7826.703 秒；五功能为 1123/0、独立检查 65/0，3121.109 秒，七份记录与同激励 RTL 逐字节相同。见 `证据/gui_elinx_summary.json`、`history/gui_services_summary_20261013.json`；这是 RTL 整理前的记录，本次没有重跑 `tb_elinx`。 |
| 命令行官方综合，VQM 取本轮 JSON 的 `netlist` | 同一仿真适配与原厂单元模型，只写仿真副本。 | T57 官方 VQM 与同次 RTL 在 `tb_net_services` 中均通过 1124 项自检、0 错误；网表独立检查 65 项、同激励 RTL 独立检查 59 项，均 0 错误，七份外部记录逐字节一致。网表验证入口总耗时 7991.843 秒（含同激励 RTL、编译和独立检查），来源为 `docs/evidence/t57_timing.json` 的 `terminal_results.netlist`。 |

“9238/0”等表示检查数/错误数。补省略输入时按厂商声明取默认值，并补使能、RAM 掩码及进位使用参数；原有连接、参数和 LUT 内容不变，原网表和厂商模型不改。依据为 `tools/adapt_gui_vqm.py` 及安装目录 `stratix_components.vhd:546–561`、`stratix_atoms.v:692–698,979,3114–3137`。
界面网表复现：先点 Run Synthesis，再执行下面任一命令；输出在 `out/gui_netlist/`，失败返回非零退出码。
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_gui_netlist.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_gui_netlist.ps1 -Test tb_net_services
```
命令行网表复现：先按 [README 的“综合后网表仿真”](../README.md#综合后网表仿真)运行官方综合，再把它生成的 VQM 交给同一入口。
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File elinx/synth.ps1
$net=(Get-Content out/latest_AFDX_top.json -Raw|ConvertFrom-Json).netlist
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_gui_netlist.ps1 -Test tb_net_services -Netlist $net
```
入口默认五小时是运行预算，不是预计耗时。通过条件包括测试结果、独立检查和七份外部记录对照，不能只看工具退出码。

### 代码覆盖率

T57 对同一 RTL 的 CE2 完整 39 项覆盖率回归统计 24 个 RTL 模块，按 `sbceft` 插桩，测试平台不计入。统计按真实设计单元的已覆盖／总统计项合计，百分比按工具习惯截断；状态机合计为状态加转换。

| 覆盖类别 | 已覆盖 / 总数 | 百分比 |
|---|---|---|
| 语句 | 6973 / 7076 | 98.54% |
| 分支 | 3850 / 3987 | 96.56% |
| 条件 | 618 / 725 | 85.24% |
| 表达式 | 1708 / 1940 | 88.04% |
| 状态机，含状态和转换 | 248 / 418 | 59.33% |
| 状态 | 110 / 110 | 100.00% |
| 转换 | 138 / 308 | 44.80% |
| 翻转 | 41408 / 53786 | 76.98% |

逐模块数字和原始报告见 `sim/reference/coverage/`；未覆盖项保持原统计范围，不沿用旧版源码行号或未重新核对的原因说明。

## 五、报告必须主动说明的边界

- 布线后时序：已完成本轮官方布局布线和全量报告，setup +0.011 ns（含 0.30 ns 不确定度；按 8 ns 为 +0.311 ns）、hold +0.229 ns、失败端点 0、多周期最差 +1.580 ns。当前状态见第三节，不以上板实测或完整 I/O 签核表述。
- 吞吐与赛题：R120-1 规定在 `tx_data` 接口上单位时间内多 VL 注入的有效载荷字节数达到 100 Mbps、系统稳定且不丢帧/不溢出；A/B 副本在接收端只计一次，需要千兆 GMII。R59 要求时钟匹配接口速率，R61 说明 GMII 是 PHY 接口。本设计采用八位 GMII 和 125 MHz；gbe77 注入 906.136 Mbps，不是把双网相加，也不代表已在实体接口上测量。
- 时延口径：R119-1 把端到端时延改为从首字节应用输入到对端交付该数据，本设计主指标 L_entry_last 已包含首字节握手前的反压和 BAG 等待；旧 GMII SFD→SFD（R97-1）和“应用末字节提交”口径只作兼容字段，不能混用或与旧报告数字直接比较（`证据/perf_r97.json:definitions`）。
- 历史释放偏差的限制：同拍释放的争用实验中，8/77 条虚拟链路、1471/17 字节、每组 24 轮，对共同理想释放时刻的最大偏差分别为 86.144/4.752/935.120/52.432 µs。该量包含同一线路的串行排队，这不是 R119-2 的同 VL 同时延极差，也不能与发送间隔偏差混用（`证据/contention.json`，2026-10-10）。
- 服务争用：77 条长消息叠加 RTC/SNMP/615A 时，两个方向同一虚拟链路的发送间隔分别为 125000–125258、125000–125312 拍，而非恒定 BAG。上述专项记录保留了逐虚拟链路数据；本页未把它们当作当前提交重跑结果，也未将独立实验驱动纳入标准回归；服务争用数字同样出自 `证据/contention.json` 的 `runs[-1].measurements.directions`。
- 突发排队：77/81 条虚拟链路同时提交后清空发送队列分别需 959.288/1008.504 µs；从应用末字节到对端末字节的最大值为 959.376/1464.592 µs。81 条的队列清空超过 1 ms，但这不是稳定窗口单条消息的 36.336 µs 主时延（`证据/perf_r97.json:main_table`）。来源为 `参考/judge_result.txt` 的两条 `JUDGE METRIC burst_vls`；复现 `run tb_gbe_burst -Param COUNT=77` 或 `COUNT=81`。

顶层保留赛题八个端口的名称和方向；新增 B 网口用于冗余、`app_*` 用于应用消息、`cfg_*` 用于配置和读回、`ev_*` 用于观察错误。`tx_ready` 表示初始化完成，`rx_ready` 不参与线路背压；不能把它描述为可暂停的标准接收流。R110、R124、R126 说明评测时顶层激励文件只需注入 VLID 和应用数据，用于综合的 TOP 端口可以自定、但须完成到应用数据的封装；R120-3 进一步说明 `tx_data` 是送进端系统发送端的数据、`rx_data` 是接收端处理完的输出，数据流是包含 VLID 的原始有效载荷。本设计因此提供只读两个文本文件的评测封装 `sim/run_app.do`（VLID+应用数据，见 README 的“应用激励入口”），它不改变 `AFDX_top` 现有端口；R122 说明资源占用不作为评分项。实现依据为 `rtl/AFDX_top.v:13–67`，本次不改接口。R112 允许以仿真结果截图及仿真演示视频代替开发板照片和视频；本设计没有开发板实测，不将仿真指标写成硬件测量。

## 六、协议版本依据

- AFDX 依据 ARINC 664 Part 7 的 2005 年原文（封面日期 2005-06-27）；未取得后续版本，不能宣称逐条符合后续版本。
- 数据加载依据 ARINC REPORT 615A-2（封面日期 2002-05-10）；协议文件采用 A4，同时识别 A3（`rtl/afdx_615a.v`）。
- 两份 ARINC 规范原文有版权，不随仓库分发。
- SNMP v1/v2c 对照 [RFC 1157](https://www.rfc-editor.org/rfc/rfc1157.html) 与 [RFC 3416](https://www.rfc-editor.org/rfc/rfc3416.html)；RTC 使用 [SNTP，RFC 4330](https://www.rfc-editor.org/rfc/rfc4330.html)；TFTP 对照 [RFC 1350](https://www.rfc-editor.org/rfc/rfc1350.html)。
- R47 不限定协议版本，也不提供参考激励；R12/R48 要求参考协议规范。版本选择不等于自动免除尚未实现的协议功能。

## 七、未实现及未验证的范围

- 615A：信息操作、操作员定义卸载的后续传输、FIND、WAIT、ABORT、整文件重试、多文件加载，以及后续版本新增 TFTP 选项协商；已有介质定义卸载不能代替这些功能。
- SNMP：GetBulk、单请求多个变量、v1 格式 Trap；私有对象子树未换成正式分配的企业号，v2c 的 noSuchInstance 异常语义尚未完整覆盖。
- AFDX/IP：ICMP 回显、IP 分片重组、采样端口、Sub-VL 未实现；UDP 校验和发送为零，接收未按目的 IP 过滤。
- 异常边界：SNTP 尚不检查服务器 Stratum 和全零时间戳；TFTP ERROR 未核对来源端口，截断请求缺少完整长度拒绝。正常用例通过不能替代这些检查。
- 发送缓存容量：128 条发送虚拟链路是配置上限，不是同时排队的能力。发送缓存共 256 页 × 512 字节，一条 1471 字节消息占 3 页，最多同时容纳 85 条最长消息；`tb_sys_load/drops` 中第 86 条因无空闲页被拒收并计入 `drop_nopage`（见[补充数据](FACTS_DETAIL.md)异常注入表）。因此不能保证 128 条链路同时各排一条最长消息；77、81 条链路的满载测试分别占 231、243 页。
- 未完成整顶层完整性能矩阵的网表仿真，也未做实体硬件测量、独立晶振及非对称链路对时验证；T57 已完成 125 MHz 全量内部路径时序验证，但没有完整外部 I/O 时延预算。功能网表通过不能替代上述未测范围。
以上范围按 `rtl/afdx_615a.v`、`rtl/afdx_snmp.v`、`rtl/afdx_rtc.v`、`rtl/afdx_rx_parse.v` 的当前行为及标准回归清单核对。

## 八、术语表

| 缩写 | 中文与英文全称 |
|---|---|
| AFDX | 航空电子全双工交换式以太网，Avionics Full-Duplex Switched Ethernet。 |
| VL / VLID / BAG | 虚拟链路 Virtual Link；虚拟链路标识 Virtual Link Identifier；带宽分配间隔 Bandwidth Allocation Gap。 |
| MAC / PHY | 媒体访问控制 Media Access Control；物理层 Physical Layer。 |
| GMII / MII | 千兆媒体独立接口 Gigabit Media Independent Interface；媒体独立接口 Media Independent Interface。 |
| UDP / IP | 用户数据报协议 User Datagram Protocol；网际协议 Internet Protocol。 |
| FCS / CRC / IFG | 帧校验序列 Frame Check Sequence；循环冗余校验 Cyclic Redundancy Check；帧间隔 Inter-Frame Gap。 |
| RTC / SNTP / NTP | 实时时钟 Real-Time Clock；简单网络时间协议 Simple Network Time Protocol；网络时间协议 Network Time Protocol。 |
| SNMP / MIB / TFTP | 简单网络管理协议 Simple Network Management Protocol；管理信息库 Management Information Base；简单文件传输协议 Trivial File Transfer Protocol。 |
| RTL / FPGA / IP 核 | 寄存器传输级 Register-Transfer Level；现场可编程门阵列 Field-Programmable Gate Array；知识产权核 Intellectual Property Core（与网际协议 IP 区分）。 |
| LUT / FF / CLB | 查找表 Look-Up Table；触发器 Flip-Flop；可配置逻辑块 Configurable Logic Block。 |
| RAM / FIFO / SDF | 随机存取存储器 Random-Access Memory；先进先出队列 First-In First-Out；标准延迟格式 Standard Delay Format。 |
| I/O | 输入/输出，Input/Output。 |
| setup / hold / Fmax | 建立时间 / 保持时间（本页数值均为裕量）；Maximum Frequency，工具给出的最高频率估算。 |

## 九、附录：设计取舍依据的专项实验

以下实验在开发期间各跑一次，用来决定“自研 MAC 还是用官方 IP”“综合后网表用哪种格式仿真”“是否追求布线后时序”。它们不是当前代码的验收结果，写报告时可作为方案选择的依据引用，并注明日期。

**布线后时序（2026-10-10）。** 一次默认设置的布局布线得到 setup −10.368 ns、Fmax 54.443 MHz；原数据库查询见 `证据/history/route_timing_20261010.json`，流程记录见 `history/route_default_20261010.json`。当前版本已重新完成官方布局布线与全量时序，见第三节；上述数字仅保留为历史实验。

**同拍释放与服务争用（2026-10-10）。** 数据见第五节对应两条，来源 `证据/contention.json`。

**自研 MAC 与官方 MAC IP 对照（2026-10-11）。** R95-2建议直接调用 `Tri_Mode_Ethernet_Mac` IP并例化两次；R111补充说明MAC IP无强制使用要求。本设计保留自研MAC，理由和实测边界见下表。 自研 MAC 与 eLinx 生成的 TripleSpeedEthernet 配置独立对照如下；帧长含 FCS、不含前导码，每拍 8 ns，单口资源来自同器件装箱（pack）报告，不能直接乘实例数当作整机资源差额。
| 比较项 | 自研 MAC | 官方 IP 的这份配置 |
|---|---|---|
| 空闲发送延迟：首字节请求→首前导码 | 0 拍；先发前导码后接纳数据。 | 59 拍（472 ns）。 |
| 接收延迟：末 FCS→用户末字节 | 2 拍，输出剥离 FCS。 | 15 拍，输出保留 FCS。 |
| 单口 LUT/FF/Memory/CLB | 556/198/0/69。 | 1400/975/24/209。 |
| 四实例持续收发仿真速度 | RTL 186466 拍/秒；综合网表 584 拍/秒。 | 原始 `.vo` 198 拍/秒。 |

依据为 `证据/mac_results.json`、`mac_official_resources.json`、`mac_self_resources.json` 及三份测速摘要。官方配置的 118 帧（含连续 50 帧 1518 字节帧）在测试端先补 FCS 后逐字节通过；用户侧 FIFO 不是整个 IP 的缓存总量，网表还含收发数据 FIFO。两帧错误 FCS 仍被交付，错误信号未置位，见 `mac_bad_crc.json`。

结论仅针对这份生成配置，不推广到该 IP 的所有配置；当前设计保留自研 MAC，未测官方 IP 集成后的整机指标。专项实验代码和 IP 生成物不随仓库分发，重做对照需恢复同配置与激励。

**`.vo` 导出缺陷（2026-10-10）。** 布局布线网表关闭 SDF 后仍有 12 项功能错误；发送状态 RAM 输入位序重排、输出位序未相应调整，与配套模型逐位读写不一致。独立最小 RAM 实验中，18 位写 `00100` 读回 `10000`；36 位写 `000000100` 读回 `100000000`，分别 237/239 项错误，RTL 同激励均 256 项通过。8/9/16/32 位对照通过（`证据/vo_functional.json`、`vo_ram.json`、`vo_ram_bits.json`）。
最小复现条件为深度 128、位宽 18/36 的单块同步 RAM，输入和输出各加寄存器；前若干地址依次写入只有一位为 1 的数据，再读回地址 8 观察上述差异；仿真采用原厂 `.vo` 与原厂 `elinx_atoms.v`，仅关闭 SDF；按官方教程《vqm文件和.vo文件生成与使用》（2023-06-05，不随仓库分发）导出，不能改连接或模型来制造通过。现有记录证明导出网表与源模型组合不等价，尚无厂商对责任环节的正式确认。官方 MAC 自带 `.vo` 使用另一组原语连接，能通过不代表上述导出问题消失。
