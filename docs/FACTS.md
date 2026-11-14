# AFDX 端系统事实清单

## 当前交付状态

11-04 交付收尾的最终源码快速回归 63/63 PASS（52 项基础 + 11 项分支）；配置隔离 2/2 PASS，源码 `360cd0294e9ae129eef97fe37ae325187e13650c`。四个长用例引用分片版既有运行：tb_sys_perf 引用 11-03 满负载与分片负载验证中按公开应用口时戳统计的检查结果，其余引用 11-03 分片版 RTL 与官方 VQM 网表验证；与最终源码的关系由 11-04 ModelSim 兼容修正的 MODEL_TECH/兼容副本 ModelSim 等价及综合逐 token 保序相同证据绑定。11-03 满负载与分片负载验证的官方 VQM TX/RX 各 161 检查通过，与同激励 RTL 的 11 份记录各自逐字节相同。11-04 ModelSim 兼容修正后的端到端布线 setup +29 ps / hold +604 ps，setup/hold 各 0/96142 失败端点。旧 VQM `3cd8f5f8456c9881d083fe67dd7a60ed9c6779909ee1cb10dbf9367dc9729b6e` 与兼容修正后新 VQM `96d14e2f8ae99c72f3145f14a17f8606c16d98f7e039befe6359eb25c471e3b4` 分开绑定。

满负载规格为每端 63 TX / 63 RX VL（BAG=1 ms、Lmax=1471，线路占用约 77.5%）；可配置 TX 128 / RX 4096 条 VL。63 VL 七场景各连续 100 ms 通过：五项周期场景最大抖动 3.360 µs；BAG 等待场景 B2 最大 96.752 µs（0x0114、1471 B），全部分组 <100 µs；固定输入顺序的 B1 场景 HDL、完整性和双统计通过，BAG 等待抖动以轮换顺序的 B2 为判据。长短消息混合配置（3 条 VL 分别发送 1472、3000、8192 B，其余 60 条发送 1471 B）连续 100 ms 零丢失、逐字节一致。规格与网络规划要求见 [ARCH](ARCH.md#系统规格与网络规划)，原始记录见 [11-04 63 VL 满负载规格验证](evidence/t79_63vl/summary.md)；elinx 工程相对 a6181267 的一行源文件登记差异，以及检查数、耗时、输入哈希及体积见 [交付证据](evidence/frag1030_delivery/summary.md)。

### 压力测试与使用条件

- 压力测试（超出满负载规格）：81 VL 周期注入最大抖动 3.368 µs；81 VL 背靠背 BAG 等待场景（case 16）10/162 组抖动 ≥100 µs，最大 107.7 µs（VL 0x0126，两个方向）；81 VL 长短消息混合出现接收溢出，固定激励二分为 70 VL 通过 20 ms、71 VL 溢出，据此取 63 VL 规格（10% 余量）。
- 压力测试：63 VL 满负载下多条 VL 同时发送 8192 B（20 ms 窗口），2 条零丢失；3 条、4 条时接收载荷环溢出（ev_a[7]），出现丢失。网络规划要求同时发送 8192 B 消息的 VL 不超过 1 条。
- 8192 字节分片和故障恢复在 RTL 上验证；分片网表对照覆盖前 199,578 拍（含 1472 字节两帧重组），与 RTL 逐字节一致。
- eLinx Run Behavioral Simulation 于 11-04 人工验证：PASS checks=9238 errors=0，Elapsed 0:02:18，Warnings 90；截图与已知警告说明见 [11-04 63 VL 满负载规格验证](evidence/t79_63vl/summary.md#elinx-界面人工验证)。
- eLinx 每次综合的 VQM 文本排列不同、功能结构相同，锁定布线后的时序相同（11-04 ModelSim 兼容修正后实测）。

## 来源与约定

赛题来源：[选题指南](sources/中科亿海微.pdf)正文第 2–4 页（PDF 第 4–6 页）；答疑来源：[问题汇总 1030 版](sources/FPGA创新大赛问题汇总1030.xlsx)的 Sheet1，R 表示工作表行号。该版保留 R113–R126：其中 R119/R123/R125 改时延口径，R119-2 改抖动口径，R120 规定 100 Mbps 测法、128 条 VL 和 `tx_data`/`rx_data` 数据含义，R122 说明资源不计分，R124/R126 说明顶层激励只需注入 VLID 和应用数据。

1030 版新增条目中，R138 允许自定义激励格式并说明规则，要求支持分片；系统配置须在非顶层激励文件中完成，顶层激励只注入应用数据。R139 给出抖动≈最大时延−最小时延−BAG 配置值，满负载下不出现三位数（µs）以上的抖动即可；吞吐测试在系统正常规格配置下完成，不统一指定组合；通过 eLinx 调用 ModelSim，需要综合后仿真，器件综合即可，测试报告应包含完整仿真测试记录。R140 说明其余功能在演示和测试报告中给出结果，评测结合代码、仿真和报告综合评估，不需要为此额外引出端口。R141 说明其他文档随代码打包上传。

当前交付依据与历史记录的区分见 [证据目录索引](evidence/README.md)。
本页的 `参考/` 指 [`sim/reference/`](../sim/reference/)，`证据/` 指 [`docs/evidence/`](evidence/)。测试清单与覆盖率见 [补充数据](FACTS_DETAIL.md)。

## 一、需求对照

赛题评分比例为代码及仿真环境 40%、设计文档 20%、测试报告 20%、技术指标 20%（选题指南正文第 4 页）。
逐项功能与技术指标的符合性结论见[测试报告](test/AFDX端系统FPGA测试报告.pdf)的符合性总表，实测数值见 [README](../README.md) 第 5 节。

## 二、性能数字与测量方法

性能仿真共用理想 125 MHz 时钟，一拍 8 ns；GMII 每拍一字节。R95-1 要求千兆 GMII；R120-1 规定吞吐在发送注入口（`tx_data` 一侧）按单位时间内多 VL 注入的有效载荷字节数统计，A/B 副本与头部不计（[分片版评委入口结果](../sim/reference/judge_result_frag1030.txt)的 `JUDGE METRIC` 中 `inject_mbps`）。

### 时延与抖动定义（R119、R120）

R119-1 把端到端时延改为“任意 VL 的首个 `tx_data` 数据输入到 `rx_data` 接收该数据的时长”，R123、R125 给出相同表述。本设计在应用发送口记录消息首字节第一次 `valid` 为高的拍 S，在接收应用口记录交付首字节拍 D 和末字节拍 D+n−1；主指标 L_entry_last = D+n−1−S，同时报告 L_entry_first = D−S。首字节握手前的反压和 BAG 等待都计入。来源：R119-1、[perf_r97.json](evidence/perf_r97.json)的 `definitions`（分片前 10-28 的输出，测量定义与当前代码一致）；定义代码为 [perf_ref.py](../tools/perf_ref.py)的 `measure_r97()`（含 VLID 首字节与载荷起点的换算）。

| 名称 | 起点 | 终点 | 说明 |
|---|---|---|---|
| L_entry_last | 应用发送口消息首字节第一次 `valid` | 接收应用口交付该消息末字节 | 端到端时延主指标，门限 2000 µs |
| L_entry_first | 同上 | 接收应用口交付首字节 | 同时报告的对照口径 |
| L_gmii（legacy） | 发送端 GMII TX 同帧 SFD | 接收端 GMII RX 同帧 SFD | R97-1 旧定义，**已被 R119 取代** |
| L_tx（legacy） | 应用末字节握手 M | 发送端 GMII TX 同帧 SFD | 兼容字段 |
| L_rx / L_rx_last（legacy） | 接收端 GMII RX 同帧 SFD | 交付首/末字节 | 兼容字段 |
| L_app / L_app_last（legacy） | M | 交付首/末字节 | 旧主指标，保留为补充 |
| L_release_app / L_release_app_last（legacy） | 主机计划释放拍 | 交付首/末字节 | 含单应用口串行注入排队 |

R97 原文使用“发送端 GMII 输入”“接收端 GMII 输出”；本直连仿真按上表 TX/RX 边界测量，L_gmii 等于链路模型延迟 0.000 或 2.056 µs，反映的是链路模型本身。这些 GMII 与末字节口径作为兼容字段保留，主指标为 L_entry_last。
R119-2 的抖动是同一 VL、**帧长相同**的多帧 L_entry_last 最大值减最小值，再取所有组的最大值，并给出所在 VL、帧长和两帧编号；它包含 ARINC 664 的 BAG 抖动。旧 R97-2 的“同一 VL 多帧”不区分帧长，已被 R119-2 取代；原“相邻发送起点间隔偏离 BAG”称为发送间隔偏差（`tx_interval_jitter`），与 R119-2 抖动分开报告。来源：R119-2、[perf_r97.json](evidence/perf_r97.json)的 `definitions`（分片前 10-28 的输出，测量定义与当前代码一致）；定义代码为 [perf_ref.py](../tools/perf_ref.py)的 `measure_r97()` / `stats_len()`。[分片版评委入口结果](../sim/reference/judge_result_frag1030.txt)分别输出 `jitter_r119_us`、`jitter_vl`、`jitter_len` 和发送间隔偏差。63 VL 满负载按 R139 的测量分组与结果见 [满负载验证](evidence/t79_63vl/summary.md)。

R120-1 的吞吐在发送注入口统计：窗口内握手成功的有效载荷字节数除以窗口时长，A/B 副本不叠加。注入落后门限为 1471 拍。仅 var_burst 按 max(计划释放拍，上一条消息最后输入字节后 1 拍) 起算，排除主机串行注入排队；其他工况按计划释放拍起算。原始计划释放偏差另存 raw_lag_max_cycles。窗口与原始偏差定义见 [当前测量代码](../tools/perf_ref.py)的 `measure_r97()`；反压、丢帧和重复计数见 [分片版评委入口结果](../sim/reference/judge_result_frag1030.txt)的 `stall_cycles`、`stall_maxrun`、`dropped`、`duplicate`、`overflow`。

各工况的实测数值见 [README](../README.md) 第 5 节、[11-04 63 VL 满负载规格验证](evidence/t79_63vl/summary.md) 和 [交付证据](evidence/frag1030_delivery/summary.md)。

### 变长帧与多虚拟链路工况

| 工况 | VL数 / BAG | UDP载荷字节 | 提交方式 |
|---|---|---|---|
| var_fixed | 32；1/2/4/8 ms各8条 | 1、17、256、1024、1471；每VL固定一种 | 错开 |
| var_cycle | 32；1/2/4/8 ms各8条 | 同一VL按上述五种长度循环 | 错开 |
| var_high | 80；1 ms | 前4条为1、17、256、1024，其余76条为1471 | 错开 |
| var_burst | 同var_fixed | 同var_fixed | 同拍释放到主机队列，单口串行握手 |

载荷1/17字节对应最小64字节以太网帧，256/1024字节为中间长度，1471字节对应最大1518字节帧；帧长含FCS、不含前导码。全部工况覆盖链路延迟0/257拍、双向、A/B开启。fixed/cycle/burst预热16 ms、窗口64 ms；high预热2 ms、窗口20 ms，每VL窗口至少8帧。
复现：`run tb_sys_perf_var`；纯 ModelSim 在仓库根目录执行 `set ::env(AFDX_JUDGE_CASE) perf_var` 后 `vsim -batch -do "do sim/run_judge.do; quit -f"`，取消筛选用 `unset ::env(AFDX_JUDGE_CASE)`。旧定长工况用 `run tb_sys_perf`。

## 三、综合资源与时序

分片交付版的资源、布线后时序和固定布局见 [1030 实现记录](1030_IMPLEMENTATION.md)；原始报告见 [交付证据](evidence/frag1030_delivery/summary.md) 目录下的 `timing.json`、`slack.rpt` 和 `utilization_placed.rpt`。

## 四、仿真入口与已跑结果

逐项回归结果见 `证据/frag1030_delivery/regression.json`，评委入口 8/8 的完整输出见 `参考/judge_result_frag1030.txt`，官方 VQM 网表对照见 `证据/frag1030_delivery/t75_official.json`。

### 代码覆盖率

#### 当前分片版覆盖率（11-04 交付引用）

11-03 在分片版 RTL `b3a60639` 上采集，58 份 UCDB、42 个 RTL 设计单元。交付 RTL = `b3a60639` + 11-04 ModelSim 兼容修正的 `MODEL_TECH` 声明前移分支，ModelSim 编译的电路等价；覆盖率直接引用、未重跑。

| 覆盖类别 | 已覆盖 / 总数 | 未覆盖 | 汇总覆盖率 |
|---|---|---|---|
| 语句 | 12416 / 12824 | 408 | 96.8% |
| 分支 | 7230 / 7642 | 412 | 94.6% |
| 表达式 | 3242 / 3987 | 745 | 81.3% |
| FSM 状态 | 115 / 137 | 22 | 83.9% |
| 条件 | 1306 / 1766 | 460 | 74.0% |
| 翻转 | 59358 / 82546 | 23188 | 71.9% |
| FSM 跳转 | 141 / 375 | 234 | 37.6% |

按原始计数汇总后四舍五入到一位小数。原始数据、SHA256、58 个测试运行名和源码绑定见 [分片版覆盖率来源](evidence/t79_63vl/coverage_source.md)及 [原始 JSON](evidence/t79_63vl/coverage_frag1030.json)。统计范围为上述 58 次运行。

## 五、测量与使用条件

- 吞吐与赛题：R120-1 规定在 `tx_data` 接口上单位时间内多 VL 注入的有效载荷字节数达到 100 Mbps、系统稳定且不丢帧/不溢出；A/B 副本在接收端只计一次，需要千兆 GMII。R59 要求时钟匹配接口速率，R61 说明 GMII 是 PHY 接口。本设计采用八位 GMII 和 125 MHz；gbe77 注入 906.136 Mbps 为单份业务载荷（A/B 副本不叠加），在 RTL 仿真中测得，见 [分片版评委入口结果](../sim/reference/judge_result_frag1030.txt)的 `inject_mbps`。
- 时延口径：R119-1 把端到端时延改为从首字节应用输入到对端交付该数据，本设计主指标 L_entry_last 已包含首字节握手前的反压和 BAG 等待；旧 GMII SFD→SFD（R97-1）和“应用末字节提交”口径作为兼容字段，与主指标分别报告（[perf_r97.json](evidence/perf_r97.json)的 `definitions`：分片前 10-28 的输出，测量定义与当前代码一致；当前 [perf_ref.py](../tools/perf_ref.py)的 `measure_r97()`）。

顶层按 R120-3、R124、R126 提供“VLID 高字节、低字节、载荷”的应用输入与输出；PDF 模板 tx_data 的方向与 R120-3 相反，当前设计按后者。A/B GMII 单独引出，保留 cfg/ev，并新增整条丢弃事件 ev_app；不再引出 app_*。R110、R49、R95-2、R62、R120-2 的接口与配置依据见 [ARCH](ARCH.md#13-顶层端口与消息接口)。rx_ready 不使用，tx_ready 是最大消息开始许可；R122 说明资源占用不作为评分项。按 R112 以仿真截图和演示视频代替开发板实测。

## 六、协议版本依据

- AFDX 依据 ARINC 664 Part 7 的 2005 年原文（封面日期 2005-06-27）。
- 数据加载依据 ARINC REPORT 615A-2（封面日期 2002-05-10）；协议文件采用 A4，同时识别 A3（`rtl/afdx_615a.v`）。
- 两份 ARINC 规范原文有版权，不随仓库分发。
- SNMP v1/v2c 对照 [RFC 1157](https://www.rfc-editor.org/rfc/rfc1157.html) 与 [RFC 3416](https://www.rfc-editor.org/rfc/rfc3416.html)；RTC 使用 [SNTP，RFC 4330](https://www.rfc-editor.org/rfc/rfc4330.html)；TFTP 对照 [RFC 1350](https://www.rfc-editor.org/rfc/rfc1350.html)。
- R47 不限定协议版本，也不提供参考激励；R12/R48 要求参考协议规范。

## 七、功能范围与使用条件

- 615A 本版本范围之外：信息操作、操作员定义卸载的后续传输、FIND、WAIT、ABORT、整文件重试、多文件加载，以及后续版本新增 TFTP 选项协商。
- SNMP 本版本范围之外：GetBulk、单请求多个变量、v1 格式 Trap、v2c noSuchInstance 的完整异常语义；私有对象子树使用演示企业号。
- AFDX/IP：单条消息最长 8192 字节，发送端 IPv4 分片、接收端 16 个上下文重组；UDP 校验和发送为零，接收按 VLID 查表、不按目的 IP 过滤。本版本范围之外：ICMP 回显、采样端口、Sub-VL。
- 异常检查：已覆盖的异常见测试报告。可继续增加的检查：SNTP 服务器 Stratum 和全零时间戳、TFTP ERROR 来源端口、截断请求的完整长度拒绝。
- 发送缓存容量：128 条发送虚拟链路为配置容量。发送缓存共 256 页 × 512 字节，一条 1471 字节消息占 3 页，最多同时容纳 85 条最长消息；`tb_sys_load/drops` 中第 86 条因无空闲页被拒收并计入 `drop_nopage`。满负载规格 63 VL 最长单帧静态占 189 页；77、81 条链路的压力测试分别占 231、243 页。
- 验证方式：功能和性能为 RTL 仿真测量；综合后功能以官方 VQM 零延迟网表仿真验证；分片版已完成 125 MHz 全部内部路径的布线后时序验证（setup/hold 均 0 失败），外部 I/O 时序随板级设计约束。RTC 对时在共用理想时钟、对称链路下测量。
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

以下实验在开发期间各跑一次，用来决定“自研 MAC 还是用官方 IP”“综合后网表用哪种格式仿真”“是否追求布线后时序”。它们是方案选择的依据，写报告时可引用并注明日期；当前代码的验收结果见第三、四节。

**自研 MAC 与官方 MAC IP 对照（2026-10-11）。** R95-2建议直接调用 `Tri_Mode_Ethernet_Mac` IP并例化两次；R111补充说明MAC IP无强制使用要求。本设计采用自研MAC，理由和实测数据见下表。 自研 MAC 与 eLinx 生成的 TripleSpeedEthernet 配置独立对照如下；帧长含 FCS、不含前导码，每拍 8 ns，单口资源来自同器件装箱（pack）报告，整机资源以整机装箱报告为准。
| 比较项 | 自研 MAC | 官方 IP 的这份配置 |
|---|---|---|
| 空闲发送延迟：首字节请求→首前导码 | 0 拍；先发前导码后接纳数据。 | 59 拍（472 ns）。 |
| 接收延迟：末 FCS→用户末字节 | 2 拍，输出剥离 FCS。 | 15 拍，输出保留 FCS。 |
| 单口 LUT/FF/Memory/CLB | 556/198/0/69。 | 1400/975/24/209。 |
| 四实例持续收发仿真速度 | RTL 186466 拍/秒；综合网表 584 拍/秒。 | 原始 `.vo` 198 拍/秒。 |

依据为 `证据/mac_results.json`、`mac_official_resources.json`、`mac_self_resources.json` 及三份测速摘要。官方配置的 118 帧（含连续 50 帧 1518 字节帧）在测试端先补 FCS 后逐字节通过；除用户侧 FIFO 外，网表还含收发数据 FIFO。两帧错误 FCS 仍被交付，错误信号未置位，见 `mac_bad_crc.json`。

结论针对这份生成配置；当前设计采用自研 MAC，整机指标均以自研 MAC 测得。专项实验代码和 IP 生成物不随仓库分发，重做对照需恢复同配置与激励。

**`.vo` 导出缺陷（2026-10-10）。** 布局布线网表关闭 SDF 后仍有 12 项功能错误；发送状态 RAM 输入位序重排、输出位序未相应调整，与配套模型逐位读写不一致。独立最小 RAM 实验中，18 位写 `00100` 读回 `10000`；36 位写 `000000100` 读回 `100000000`，分别 237/239 项错误，RTL 同激励均 256 项通过。8/9/16/32 位对照通过（`证据/vo_functional.json`、`vo_ram.json`、`vo_ram_bits.json`）。
最小复现条件为深度 128、位宽 18/36 的单块同步 RAM，输入和输出各加寄存器；前若干地址依次写入只有一位为 1 的数据，再读回地址 8 观察上述差异；仿真采用原厂 `.vo` 与原厂 `elinx_atoms.v`，仅关闭 SDF；按官方教程《vqm文件和.vo文件生成与使用》（2023-06-05，不随仓库分发）导出，不能改连接或模型来制造通过。现有记录证明导出网表与源模型组合不等价，尚无厂商对责任环节的正式确认。官方 MAC 自带 `.vo` 使用另一组原语连接，能通过不代表上述导出问题消失。
