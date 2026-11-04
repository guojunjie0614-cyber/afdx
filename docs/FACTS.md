# AFDX 端系统事实清单

## T78 当前交付状态

最终源码快速回归 63/63 PASS（52 项基础 + 11 项分支）；配置隔离 2/2 PASS，源码 `360cd0294e9ae129eef97fe37ae325187e13650c`。四个长用例按批准的快速范围引用历史：tb_sys_perf 引用 T76 修正检查器，其余引用 T75；与最终源码的关系由 T77 MODEL_TECH/兼容副本 ModelSim 等价及综合逐 token 保序相同证据绑定。已启动长例保留原进程，已完成的结果附录入证据，不等待其余长例。T76 官方 VQM TX/RX 各 161 检查通过，与同激励 RTL 的 11 份记录各自逐字节相同。T77 端到端布线 setup +29 ps / hold +604 ps，setup/hold 各 0/96142 失败端点。旧 VQM `3cd8f5f8456c9881d083fe67dd7a60ed9c6779909ee1cb10dbf9367dc9729b6e` 与 T77 新 VQM `96d14e2f8ae99c72f3145f14a17f8606c16d98f7e039befe6359eb25c471e3b4` 分开绑定。

T79 已统一下调满负载声明为 63 TX / 63 RX VL（BAG=1 ms、Lmax=1471，线路占用约 77.5%）；配置规模仍为 TX 128 / RX 4096。63 VL 七场景性能正在验证，见 [T79 证据](evidence/t79_63vl/summary.md)。81 VL 数据属于超出声明的压力测试。elinx 相对 a6181267 的 T76 已有一行源登记差异保留，验收未闭合。详细检查数、耗时、输入哈希及体积见 [交付证据](evidence/frag1030_delivery/summary.md)。

### 限制与未完成项

- 超出声明的压力测试：81 VL 背靠背 BAG 等待场景（case 16）：10/162 组抖动 ≥ 100 µs，最大 107.7 µs（VL 0x0126，两个方向）。周期注入场景最大 3.368 µs。已按决定统一下调声明到 63 TX / 63 RX VL；上述 81 VL 数据保留为超出声明的压力测试，63 VL 验证结果见 T79 证据。
- 超出声明的压力测试：81 VL 长短消息混合会溢出；63 VL 混合复用 T76 的 100 ms 结果（固定激励搜索 70 通过、71 溢出）。
- 8192 字节分片和故障恢复只在 RTL 上验证；分片网表证据是截断到第 199,578 拍的比对（含 1472 字节两帧重组）。
- eLinx Run Behavioral Simulation 已于 11-04 人工验证：PASS checks=9238 errors=0，Elapsed 0:02:18，Warnings 90；截图与已知警告说明见 T79 证据。
- eLinx 每次综合的 VQM 文本排列不同，但结构相同，锁定布线的时序相同（T77 实测）。

## 历史验证基线

以下旧轮次数字保留其原始源码和验收边界；当前交付数字以上述 T78 证据为准。

> 版本边界（2026-11-02）：本页以下测量为 F1/T65 历史结果。当前分片开发分支修改了 RTL，旧功能、性能及正时序证据不覆盖当前版本。最新要求来自 [1030 答疑](sources/FPGA创新大赛问题汇总1030.xlsx) R138/R139；当前实现与新测量以仓库根目录硬件契约和本轮输出为准。

当前 F1 的 RTL 与 r5 A `18d1606c` 零差异；原 V1/V2 验证提交为 `t63@92ab7d7e`，F1b 在 `67d2e618` 基础上仅修正宏内测试观测。**V1 功能终验通过**：模块及整顶层网表清单 8/8 PASS，`tb_sys_net` 自检与独立核对通过；V2 时序复核通过；界面复跑通过（与 CLI 产物逐项比对 PASS，`.place`、`.route` 逐字节相同）。器件 EQ6HL130、封装 CSG484_H，主时钟 125 MHz（8.000 ns），CE_DIV=2。采用 PRES 1.30 和固定布局后，全部 53,882 个端点 setup/hold 均为 0 失败，最差余量为 +0.016 / +0.229 ns；setup 已含 0.30 ns 时钟不确定度。原始精度为 +16 / +229 ps，门槛按原始精度判定。

补充的逐项测试、资源、时延、参数和异常覆盖见 [补充数据](FACTS_DETAIL.md)。
本页分别记录当前性能实测与带日期的历史终验；RTL 源码共 29 个文件，标准回归清单 40 项，评委入口 8 用例。当前完成状态以第三、四节的本轮实测为准；带日期的历史专项实验保留原记录。功能覆盖以实际测试范围为准，不等于完整协议认证。
赛题来源：[选题指南](sources/中科亿海微.pdf)正文第 2–4 页（PDF 第 4–6 页）；答疑来源：[问题汇总 1026 版](sources/FPGA创新大赛问题汇总1026.xlsx)的 Sheet1，R 表示工作表行号。1026 版在 1022 版之后新增 R113–R126：其中 R119/R123/R125 改时延口径，R119-2 改抖动口径，R120 规定 100 Mbps 测法、128 条 VL 和 `tx_data`/`rx_data` 数据含义，R122 说明资源不计分，R124/R126 说明顶层激励只需注入 VLID 和应用数据。
性能与变长帧数据采用本次 F1 完整窗口记录；Tcl/Python 在同一批文件上分别比较 1784、20576、2572 个字段，差异为 0。CE2 回归 40/40、评委 8/8 通过。历史专项实验保留原日期，当前功能与时序证据为 `证据/t63_f1_final.json`。
本页的 `参考/` 指 [`sim/reference/`](../sim/reference/)，`证据/` 指 [`docs/evidence/`](evidence/)：原始输出的副本及只读数据库查询结果，`manifest.json` 记录每份文件的原位置和 SHA-256 摘要；文件里的绝对路径是生成时那台机器上的路径，不在本仓库。标准测试可用下列命令重建，专项实验的复现限制在对应条目说明。
命令均在仓库根目录的 PowerShell 执行；先按 [软件准备](../README.md#软件准备)配置工具路径和 Python 依赖。下表 `run <名称>` 表示 `powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test <名称>`。

## 一、需求对照

赛题评分比例为代码及仿真环境 40%、设计文档 20%、测试报告 20%、技术指标 20%（选题指南正文第 4 页）。
| 要求 | 已实现及实测结果 | 测试与复现 |
|---|---|---|
| ARINC 664 Part 7 通信 | UDP/IP 收发、虚拟链路配置、发送调度及双网传输；本轮同激励 RTL 五功能自检 1122 项、0 错误。网表对照状态见第四节。 | `tb_net_services`；`证据/t63_f1_functional.json:services_netlist`。 |
| 高完整性通信 | 检查帧校验、长度、序号，双网重复帧只交付一次；五功能记录含坏序号拒绝与正常副本去重，完整回归另含冗余跨刻度、逆序到达测试。 | `run tb_net_services`、`run tb_rm_phase`；`证据/t63_f1_services_summary.json:check.checks`、`参考/regression.json`。 |
| SNMP 网络管理 | Get/GetNext/Set/Trap 字段及配置口读回检查通过；专项自检 699 项、0 错误。 | `run tb_judge_snmp`；`证据/snmp.log` 的 `[RESULT]` 行。 |
| 615A 数据加卸载 | 文件加载到片内 RAM，再以 MEMORY.BIN 卸载；五功能中 16 字节逐字节一致，下载独立检查 41 项通过。 | `run tb_net_services`、`run tb_sys_615a`；`证据/t63_f1_services_summary.json:check.download`。 |
| RTC 时钟同步 | 通过网络时间报文同步，支持丢回应重试，并检查回应是否回显本次请求时间戳（Originate）；空载/带载误差见下节。 | `run tb_sys_rtc`、`run tb_rtc_recovery`、`run tb_rtc_originate`；`证据/rtc.json`、`参考/regression.json`。 |
| 传输速率 100 Mbps | R120-1 在发送注入口统计有效载荷。gbe77 / var_high 各方向最小注入率 906.136/904.752 Mbps，接收应用口去重交付的对应最小值 906.136/904.752 Mbps；A/B 副本不叠加。 | `run tb_sys_perf`、`run tb_sys_perf_var`、`do sim/run_app.do`；`证据/perf_r97.json:main_table`。 |
| 帧格式 | 支持以太网帧、VLID、序号和最多 1471 字节消息；对应最大帧长 1518 字节，含 FCS，不含前导码。序号正常按 1–255 循环，复位首帧 0 按协议单独处理。 | `run tb_mac_tx`、`run tb_mac_rx`、`run tb_rx_icrm`；`参考/regression.json`，编码与检查见 `rtl/afdx_tx_builder.v`、`tools/afdx_ref.py`。 |
| 时延与抖动 | R119 按应用首字节 valid 到对端交付末字节计算。gbe77 的主时延最大 48.288/50.344 µs（链路 0/257 拍），20 个性能窗口最大 63.576 µs，同 VL 同帧长抖动最大 19.536 µs；默认应用激励的主时延／抖动最大 60.584/15.200 µs。 | 定义、工况和边界见第二、五节；`证据/perf_r97.json:main_table`、`application_entry`、`jitter_r119_top`、`policy`。 |
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

R120-1 的吞吐在发送注入口统计：窗口内握手成功的有效载荷字节数除以窗口时长，A/B 副本不叠加。注入落后门限为 1471 拍。仅 var_burst 按 max(计划释放拍，上一条消息最后输入字节后 1 拍) 起算，排除主机串行注入排队；其他工况按计划释放拍起算。原始计划释放偏差另存 raw_lag_max_cycles。窗口、反压、丢帧和重复计数见 `证据/perf_r97.json`。

| 工况 | 注入 Mbps | 主时延最大 µs | 首字节时延最大 µs | 抖动最大 µs（VL/帧长） |
|---|---:|---:|---:|---|
| gbe77_d0 | 906.136 | 48.288 | 36.512 | 0.008（5/1471） |
| gbe77_d257 | 906.136 | 50.344 | 38.568 | 0.008（51/1471） |
| var_burst_d0 | 57.794 | 61.520 | 49.760 | 0.008（0/1） |
| var_burst_d257 | 57.794 | 63.576 | 51.816 | 0.000（0/1） |
| var_cycle_d0 | 70.403 | 48.280 | 36.504 | 19.536（25/256） |
| var_cycle_d257 | 70.403 | 50.336 | 38.560 | 19.536（25/256） |
| var_fixed_d0 | 57.794 | 48.280 | 36.504 | 0.008（13/1024） |
| var_fixed_d257 | 57.794 | 50.336 | 38.560 | 0.008（28/1024） |
| var_high_d0 | 904.752 | 48.288 | 36.512 | 0.008（41/1471） |
| var_high_d257 | 904.752 | 50.344 | 38.568 | 0.008（15/1471） |

gbe77 的主时延最大 48.288/50.344 µs（链路 0/257 拍），20 个窗口的最大值为 63.576 µs。R119-2 抖动最大 19.536 µs，位于 var_cycle_d0、es1_to_es2、VL25、256 字节，帧 2666→3266。var_burst 的计划释放→首/末字节最大 185.760/185.888 µs，释放口径抖动最大 0.008 µs。释放口径包含主机串行注入排队，与从首字节 valid 起算的主口径分开报告。逐方向原值见 `证据/perf_r97.json:main_table/jitter_r119_top/burst_release_analysis`。

### 应用激励入口（R124、R126）

`sim/run_app.do` 默认激励为 84 条消息、21 条 VL，载荷覆盖 1/17/256/1024/1471 字节，窗口为相对激励起点的 1–4 ms。本轮注入 210.440 Mbps，L_entry_last / L_entry_first 最大 60.584 / 48.808 µs，同 VL、同帧长抖动最大 15.200 µs（VL18 / 256 字节）；反压 0 拍、最长连续 0 拍，相对计划释放拍的注入落后最大 1351 拍，丢帧/重复/溢出均为 0，`APP ENTRY PASS`。小激励的五条消息已逐条核对通过；它未设稳定吞吐窗口，速率只报告。两种激励的原始汇总见 `sim/reference/app_result.json`。Tcl/Python 在同一默认激励记录上逐字段一致，来源为 `证据/perf_r97.json:application_entry/equivalence`。

### 变长帧与多虚拟链路工况

| 工况 | VL数 / BAG | UDP载荷字节 | 提交方式 |
|---|---|---|---|
| var_fixed | 32；1/2/4/8 ms各8条 | 1、17、256、1024、1471；每VL固定一种 | 错开 |
| var_cycle | 32；1/2/4/8 ms各8条 | 同一VL按上述五种长度循环 | 错开 |
| var_high | 80；1 ms | 前4条为1、17、256、1024，其余76条为1471 | 错开 |
| var_burst | 同var_fixed | 同var_fixed | 同拍释放到主机队列，单口串行握手 |

载荷1/17字节对应最小64字节以太网帧，256/1024字节为中间长度，1471字节对应最大1518字节帧；帧长含FCS、不含前导码。全部工况覆盖链路延迟0/257拍、双向、A/B开启。fixed/cycle/burst预热16 ms、窗口64 ms；high预热2 ms、窗口20 ms，每VL窗口至少8帧；同一批记录上 Tcl 与 Python 两份统计的 20576（perf_var）/1784（perf）个字段逐一相等，差异为 0（`证据/perf_r97.json:equivalence`）。
复现：`run tb_sys_perf_var`；纯 ModelSim 在仓库根目录执行 `set ::env(AFDX_JUDGE_CASE) perf_var` 后 `vsim -batch -do "do sim/run_judge.do; quit -f"`，取消筛选用 `unset ::env(AFDX_JUDGE_CASE)`。旧定长工况用 `run tb_sys_perf`。
新工况仅 var_high 检查注入 ≥100 Mbps；fixed/cycle/burst 的给定负载低于该值，注入只报告，不能据此判性能失败。全部帧（含预热）检查 L_entry_last ≤2000 µs，同时核对恰好一次交付、无丢包、冗余副本拒绝与错误计数。R119-2 未给出抖动数值上限；本轮逐项报告，并按项目检查线 50 µs 判定，该检查线不是官方门限（`证据/perf_r97.json:policy`、`validation`）。旧兼容字段 `jitter_us` 仍指发送间隔偏差，不能当作 R119-2 抖动。
var_cycle 的发送间隔偏差为 12.336 µs；gbe77、var_fixed、var_high、var_burst 均为 0.000 µs；旧 L_gmii 抖动均为 0.000 µs（`证据/perf_r97.json:main_table`）。gbe77 的注入落后按本轮 `inject/lag_max` 原值报告；释放口径只作为兼容字段。

| 其它项目 | 数值及条件 | 日志定位 |
|---|---|---|
| 容量 | 每端发送 128 条、接收配置 4096 条，接收交付抽测 128 个索引。容量测试为每条一次消息，不把它当作满容量吞吐测试。 | `证据/capacity.log`：`tx_vls_each=128 rx_configured_each=4096 rx_sampled_each=128 first=0 last=4095`。 |
| RTC 误差 | 空载最大 0 ns，普通用户流量最大 0 ns，77 条 VL 满载最大 0 ns；共用理想时钟和对称链路，经公开配置口读回比较，未测试晶振漂移或硬件误差。 | `证据/rtc.json` 的 idle_max_ns / loaded_max_ns / gbe_max_ns；`参考/judge_result.txt` 的 RTC 指标。 |

完整旧性能矩阵还记录 10 条虚拟链路 117.680 Mbps、81 条 953.208 Mbps；这是历史补充数据，来源为 `证据/performance.json` 的 `throughput_d0`、`gbe81_d0`，不替代上述当前时延口径。

## 三、综合资源与时序

当前 F1 的 RTL 与 r5 A `18d1606c` 零差异；原 V1/V2 验证提交为 `t63@92ab7d7e`，F1b 在 `67d2e618` 基础上仅修正宏内测试观测。**V1 功能终验通过**：模块及整顶层网表清单 8/8 PASS，`tb_sys_net` 自检与独立核对通过；V2 时序复核通过；界面复跑通过（与 CLI 产物逐项比对 PASS，`.place`、`.route` 逐字节相同）。器件 EQ6HL130、封装 CSG484_H，主时钟 125 MHz（8.000 ns），CE_DIV=2。采用 PRES 1.30 和固定布局后，全部 53,882 个端点 setup/hold 均为 0 失败，最差余量为 +0.016 / +0.229 ns；setup 已含 0.30 ns 时钟不确定度。原始精度为 +16 / +229 ps，门槛按原始精度判定。

`elinx/constraints.edc` 包含 PRES 1.30、172 条 P0 管脚语句和 5,540 条簇位置语句；固定布局来自 C0 布局加局部手工微调。**改 RTL 会使布局失效**，必须重新生成并验证位置约束。界面工程登记 `physical_only.edc` 与 `timing_only.sdc`，两者拼接与完整 EDC 一致；物理语句经 Tcl `source`，纯时序部分经 `read_sdc`，0.30 ns uncertainty 与已批准多周期约束保持不变。eLinx 界面会对登记的每个约束文件生成 `read_sdc`，并对 `.edc` 另加 `source`，因此 `physical_only.edc` 也会交给 SDC 解析器；解析器对其中约 5,700 条 PRES、管脚和簇位置语句逐条报 `invalid command`，这是预期现象，这些语句已由 `source` 生效，界面结果与 CLI 逐字节一致。

| 项目 | 当前官方结果 |
|---|---:|
| 查找表（LUT） | 39895 / 136160（29.30%） |
| 触发器（FF） | 20885 / 136160（15.34%） |
| 可配置逻辑块（CLB） | 5136 / 13616（37.72%） |
| 存储器（M4K） | 404 / 1200（33.67%） |
| 用户引脚 | 172 / 339（50.74%） |
| DSP / PLL | 0 / 0 |
| 综合后建立裕量／保持裕量 | +4.148 / -0.068 ns（未布局布线） |
| 布线后建立裕量／保持裕量 | +0.016 / +0.229 ns |
| 布线后 setup / hold 失败端点 | 0 / 53882；0 / 53882 |
| 8 ns 单周期路径数／最差 setup | 181000 / +0.016 ns |
| 16 ns 多周期路径数／最差 setup | 50296 / +0.268 ns |
| 同沿 hold 路径数 | 231296 |

约束审查：2755 个引擎寄存器、51992 条内部寄存器连接，invalid/uncovered 均为 0。本轮完整时序路径与原始数值见 `证据/t63_f1_timing.json`；`.place` 和官方资源报告均随证据保存。

F1 的界面复跑已完成，产物比对 PASS，记录见 [界面比对](evidence/t63_f1_gui_compare.json)；操作步骤见 [F1 界面复跑](T63_F1_GUI.md)。

综合估算、布线后静态时序和 RTL 性能采用各自原始证据；没有上板测量，也没有完整外部 I/O 延迟预算。

### 综合警告说明

本轮官方综合保留 8 条警告，原始编号和完整消息见 [F1 综合警告](evidence/t63_f1_synthesis_warnings.json)。各仿真诊断单独记录；已通过入口的 0 Error/FAIL/RAMCOLL 不替代综合诊断，仿真通过状态见 F1b 补验。

| 编号 | 数量 | 原始消息 |
|---|---:|---|
| 10230 | 1 | Verilog HDL assignment warning at afdx_615a_engine.v(2179): truncated value with size 32 to match size of target (11) |
| 276020 | 4 | Inferred RAM node "afdx_app_tx:application_tx\|afdx_app_read:reader\|bytes_rtl_0" from synchronous design logic.  Pass-through logic has been added to match the read-during-write behavior of the original design. |
| 276026 | 2 | Inferred RAM node "afdx_es:es\|afdx_615a:loader\|afdx_ram_sdp:load_ram\|memory_rtl_0" from synchronous design logic.  The RAM node maps into an M-RAM that powers up into an unknown state |
| 21074 | 1 | Design contains 1 input pin(s) that do not drive logic |

## 四、仿真入口与已跑结果

| 入口 | 当前结果 | 证据 |
|---|---|---|
| CE2 标准回归 | 56/56 PASS；自检 2334495386；原 40 项独立核对 4091874，新增 16 项独立核对 2246 | [T65b 验收](T65b_REGRESS.md)、[56 项汇总](evidence/t65b_regress/regression_summary.txt) |
| 评委入口 | 8/8 PASS；Error/FAIL/RAMCOLL=0 | `参考/judge_result.txt` |
| 应用默认与小激励 | 2/2 APP ENTRY PASS | `参考/app_result.json` |
| check_wrapper | 5/5 PASS | `证据/t63_f1_functional.json:wrapper` |
| 模块及整顶层网表清单 | 8/8 PASS；tb_sys_net 经 F1b 补验通过；官方 Quartus CLI VQM | `参考/netlist.json` |
| 官方 VQM 五功能 | 1122 项自检 PASS；七份记录与同激励 RTL 一致 | `证据/t63_f1_services_summary.json` |

56 项标准回归于 2026-10-30 09:56:18 至 11:36:57 完成，耗时 6038.613 秒；Error/Fatal/Warning/FAIL/RAMCOLL 均为 0。原 40 项 Checks、CheckItems 与 F1/T64 逐项一致，新增 16 项的自检及独立核对计数与 T65 逐项一致。挂接反例中 TB 仍 PASS，独立核对检出 4 个错误，入口正确返回失败。本次验收配置为 CE_DIV=2。

其余入口的原始验证来自 `92ab7d7e`；F1b 仅补验宏内观测受影响的 `tb_sys_net`，其余入口按有效预处理逐字节一致及依赖关系复用。各入口 Error/FAIL/RAMCOLL 均为 0。模块网表的旧 `eLinx_synthesis.exe` 入口在 ABC 阶段崩溃（0xC0000409）；本轮保留失败日志，全部八项改用官方 Quartus 分析、VQM 导出及原厂模型执行，未修改安装目录或系统配置。

F1b 已修正 `SYS_TOP_NETLIST` 下的公开输入消息观测和双网接收来源观测。RTL＋宏及同一 F1 V2 官方 VQM 的 `tb_sys_net` 均通过 2,792,645 项自检、0 错误，独立核对 88/88（含 16 项固定检查和 72 项帧级检查）；Error/Fatal/Warning/FAIL/RAMCOLL 均为 0。仅宏内显式跳过以私有核心末次握手为起点的两项 96 拍时限检查，保留结果对应、容量、顺序、原主机/排空期限和外部逐字节核对。无宏 CE1/CE2 的有效预处理 HDL 逐字节一致；原始预处理输出的行号指令和空白行单独保留。原始失败、超时和控制脚本错误保留于 [前序失败证据](evidence/t63_f1_sys_net_failure.json)，本次通过证据及边界见 [F1b 补验](evidence/t63_f1b_sys_net_pass.json)。

评委数值基线对应批准的 r5 A RTL：其 VLID 比较比旧 `21c11f8` 基线多两级流水，主时延和首字节时延各增加 16 ns。四个时延常数由两次独立 RTL 记录及同批 Tcl/Python 1,784 个字段核对更新，吞吐、时延和抖动需求门限未改；诊断见 `证据/t63_f1_judge_baseline.json`。

本次 F1 官方重建 VQM 与同次 RTL 的 `tb_net_services` 均通过 1122 项自检，Error/FAIL/RAMCOLL 均为 0；网表独立检查 65 项，七份外部记录逐字节一致。网表使用本卡 V2 的 VQM，不含布线延迟；证据见 `evidence/t63_f1_functional.json` 的 `services_netlist`。

复现官方 VQM 五功能：先执行 `elinx/synth.ps1`，再把 `out/latest_AFDX_top.json` 的 `netlist` 传给 `sim/run_gui_netlist.ps1 -Test tb_net_services -Netlist <VQM路径>`。默认五小时是预算，不是预计耗时；需检查测试、独立检查和七份记录，不能只看退出码。

### 代码覆盖率

#### T65 合并覆盖率与定向补测

T65 的 16 项新增测试补测了 A 网队列满及恢复、应用收发封装资源边界，以及 RX 引擎、MAC TX、应用 TX 三个登记状态的复位恢复；正向测试和独立核对全部通过。登记目标中，A01 的 26 项、A02 的 2 项、G3 的 3 项均有 UCDB 命中证据，合计 31 项；G3 备选 T64-0906 未注入。32 个仿真反例和 32 个离线捕获破坏反例均被检出。详见 [T65 补测报告](T65_GAP_TESTS.md)与[目标命中记录](evidence/t65_gap_tests/target_hits.json)。

当前合并统计复用 T64 的 40 份成功 UCDB，加入 T65 的 16 份正式 UCDB，共 56 次尝试、29 个 RTL 设计单元；失败及反例未纳入。以下数字来自 [T65 合并统计](evidence/t65_gap_tests/coverage.json)，百分比按计数截断到两位。T65b 的 56 项普通回归不带覆盖率，未生成新的覆盖率批次。

| 覆盖类别 | 已覆盖 / 总数 | 百分比 |
|---|---|---|
| 语句 | 7760 / 7866 | 98.65% |
| 分支 | 4354 / 4495 | 96.86% |
| 条件 | 893 / 1001 | 89.21% |
| 表达式 | 1788 / 2059 | 86.83% |
| 已识别状态 | 127 / 127 | 100.00% |
| 已识别转换 | 159 / 338 | 47.04% |
| 翻转 | 46008 / 59950 | 76.74% |

**合并统计与 T64 有 9 组设计单元/指标的分母不同，根因尚未证明；接受该结果作为当前集合的统计，不计算同口径增幅，也不据百分比下降判定功能退化。** 原始分母保留，未增加排除项，差异见 [分母核对](evidence/t65_gap_tests/denominators.json)。状态 100% 仅限工具识别集合；接收封装压力为模块级，复位只覆盖登记的三个精确状态，1 字节输入仅观察，不代表全部资源组合或复位边均已覆盖。

新增 16 项已由 T65b 并入 `sim/tests.txt`，独立检查器纳入正式入口，验收见 [T65b 报告](T65b_REGRESS.md)。`tools/t64_coverage.py` 专用于原 40 项冻结集合，当前 56 项清单会触发其预期集合校验失败；保留该工具及历史证据，不把此失败计为功能失败。

#### T64 冻结覆盖率基线

T64 冻结覆盖率基线：冻结提交 `e5cd8150`，CE_DIV=2，40 项完整 RTL 回归、29 个 RTL 设计单元、40 份 UCDB，按 `sbceft` 插桩，测试平台不计入。40/40 PASS，Error/Fatal/Warning/FAIL/RAMCOLL 均为零；普通回归复用 40 项，补跑 0 项，Checks、CheckItems 及 491 个确定性产物一致。详细来源与复用边界见 [T64 覆盖率报告](T64_F1_COVERAGE.md)。

| 覆盖类别 | 已覆盖 / 总数 | 百分比 |
|---|---|---|
| 语句 | 7754 / 7864 | 98.60% |
| 分支 | 4344 / 4491 | 96.72% |
| 条件 | 882 / 1001 | 88.11% |
| 表达式 | 1767 / 2027 | 87.17% |
| 状态机，含状态和转换 | 282 / 465 | 60.64% |
| 已识别状态 | 127 / 127 | 100.00% |
| 已识别转换 | 155 / 338 | 45.85% |
| 翻转 | 44903 / 57890 | 77.56% |

百分比按各设计单元已覆盖项数／总项数汇总并截断到两位。状态 100% 仅限工具识别集合，两个服务引擎的主 `state` 未被识别，不能据此宣称全部状态机控制路径已验证。完整未覆盖索引包含 13,806 个 bin，其中 10,578 个尚不能判断原因或可达性；未增加排除项。原始报告、逐模块统计和缺口分析见 [T64 证据](evidence/t64_f1_coverage/coverage.json)及 [未覆盖项分析](evidence/t64_f1_coverage/gap_analysis.md)。

T64 串行覆盖率回归实际耗时 17,896.286 秒（约 4 小时 58 分），含冻结、对照和合并报告的原生批次耗时 18,093.625 秒（约 5 小时 2 分）。历史 T57 的 39 项、24 模块覆盖率保留在 `sim/reference/coverage/`，源码与统计分母不同，不能将两次总百分比差直接解释为验证进退。

## 五、报告必须主动说明的边界

- 布线后时序：F1 setup +0.016 ns（含 0.30 ns uncertainty）、hold +0.229 ns、0/53,882 失败端点，多周期最差 +0.268 ns。界面复跑结果相同；不以上板实测或完整 I/O 签核表述。
- 吞吐与赛题：R120-1 规定在 `tx_data` 接口上单位时间内多 VL 注入的有效载荷字节数达到 100 Mbps、系统稳定且不丢帧/不溢出；A/B 副本在接收端只计一次，需要千兆 GMII。R59 要求时钟匹配接口速率，R61 说明 GMII 是 PHY 接口。本设计采用八位 GMII 和 125 MHz；gbe77 注入 906.136 Mbps，不是把双网相加，也不代表已在实体接口上测量。
- 时延口径：R119-1 把端到端时延改为从首字节应用输入到对端交付该数据，本设计主指标 L_entry_last 已包含首字节握手前的反压和 BAG 等待；旧 GMII SFD→SFD（R97-1）和“应用末字节提交”口径只作兼容字段，不能混用或与旧报告数字直接比较（`证据/perf_r97.json:definitions`）。
- 历史释放偏差的限制：同拍释放的争用实验中，8/77 条虚拟链路、1471/17 字节、每组 24 轮，对共同理想释放时刻的最大偏差分别为 86.144/4.752/935.120/52.432 µs。该量包含同一线路的串行排队，这不是 R119-2 的同 VL 同时延极差，也不能与发送间隔偏差混用（`证据/contention.json`，2026-10-10）。
- 服务争用：77 条长消息叠加 RTC/SNMP/615A 时，两个方向同一虚拟链路的发送间隔分别为 125000–125258、125000–125312 拍，而非恒定 BAG。上述专项记录保留了逐虚拟链路数据；本页未把它们当作当前提交重跑结果，也未将独立实验驱动纳入标准回归；服务争用数字同样出自 `证据/contention.json` 的 `runs[-1].measurements.directions`。
- 突发排队：77/81 条 VL 的当前原始指标见 `参考/judge_result.txt` 的 `JUDGE METRIC burst_vls`；稳定窗口主时延与整批队列排空时间分别统计，不互相替代。

顶层按 R120-3、R124、R126 提供“VLID 高字节、低字节、载荷”的应用输入与输出；PDF 模板 tx_data 的方向与 R120-3 相反，当前设计按后者。A/B GMII 单独引出，保留 cfg/ev，并新增整条丢弃事件 ev_app；不再引出 app_*。R110、R49、R95-2、R62、R120-2 的接口与配置依据见 [ARCH](ARCH.md#13-顶层端口与消息接口)。rx_ready 不使用，tx_ready 是最大消息开始许可；R122 说明资源占用不作为评分项。仿真和静态时序不代表上板测量。

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
- 未完成整顶层完整性能矩阵的网表仿真，也未做实体硬件测量、独立晶振及非对称链路对时验证；F1 已完成 125 MHz 全部内部路径的布线后时序验证（setup/hold 均 0 失败），但没有完整外部 I/O 时延预算。功能网表通过不能替代上述未测范围。
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
