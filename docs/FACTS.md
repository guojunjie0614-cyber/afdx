# AFDX 端系统事实清单

代码版本：`eb9499dc`。本页供设计文档和测试报告直接引用；功能覆盖以实测范围为准，不等于完整协议认证。
赛题来源：[选题指南](../spec/中科亿海微.pdf)正文第 2–4 页（PDF 第 4–6 页）；答疑来源：[问题汇总](../spec/FPGA创新大赛问题汇总1008.xlsx)的 Sheet1，R 表示工作表行号。
本次只核对已有源码、报告和日志，没有重新综合或运行长仿真。常规回归的 RTL 与当前版本一致，测试仅有注释及检查提示差异；专项历史实验另注明日期。
本页的 `证据/` 指 `out/facts/evidence/`：原始输出的逐字节副本及只读数据库查询结果，`manifest.json` 记录原位置和摘要。它不随 Git 分发；标准测试可用下列命令重建，专项实验的复现限制在对应条目说明。
命令均在仓库根目录的 PowerShell 执行；先按 [软件准备](../README.md#软件准备)配置工具路径和 Python 依赖。下表 `run <名称>` 表示 `powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test <名称>`。

## 一、需求对照

赛题评分比例为代码及仿真环境 40%、设计文档 20%、测试报告 20%、技术指标 20%（选题指南正文第 4 页）。
| 要求 | 已实现及实测结果 | 测试与复现 |
|---|---|---|
| ARINC 664 Part 7 通信 | UDP/IP 收发、虚拟链路配置、发送调度及双网传输；五功能自检共 1123 项、0 错误，范围见第七节。 | `run tb_net_services`；`证据/gui_services_summary.json:results`、`check`。 |
| 高完整性通信 | 检查帧校验、长度、序号，双网重复帧只交付一次；五功能记录含坏序号拒绝与正常副本去重，完整回归另含冗余跨刻度、逆序到达测试。 | `run tb_net_services`、`run tb_rm_phase`；`证据/gui_services_summary.json:check.checks`、`regression.json`。 |
| SNMP 网络管理 | Get/GetNext/Set/Trap 字段及配置口读回检查通过；专项自检 699 项、0 错误。 | `run tb_judge_snmp`；`证据/snmp.log` 的 `[RESULT]` 行。 |
| 615A 数据加卸载 | 文件加载到片内 RAM，再以 MEMORY.BIN 卸载；五功能中 16 字节逐字节一致，下载独立检查 41 项通过。 | `run tb_net_services`、`run tb_sys_615a`；`证据/gui_services_summary.json:check.download`。 |
| RTC 时钟同步 | 通过网络时间报文同步，支持丢回应重试，并检查回应是否回显本次请求时间戳（Originate）；空载/带载误差见下节。 | `run tb_sys_rtc`、`run tb_rtc_recovery`、`run tb_rtc_originate`；`证据/rtc.json`、`regression.json`。 |
| 传输速率 100 Mbps | 77 条发送虚拟链路时，每方向有效载荷吞吐 906.136 Mbps；两网副本不相加。 | `run tb_sys_perf`；`证据/judge_result.txt` 的 `JUDGE METRIC tb_sys_perf`。 |
| 帧格式 | 支持以太网帧、VLID、序号和最多 1471 字节消息；对应最大帧长 1518 字节，含 FCS，不含前导码。序号正常按 1–255 循环，复位首帧 0 按协议单独处理。 | `run tb_mac_tx`、`run tb_mac_rx`、`run tb_rx_icrm`；`证据/regression.json`，编码与检查见 `rtl/afdx_tx_builder.v`、`tools/afdx_ref.py`。 |
| 时延 <1–2 ms、抖动≤几十微秒 | 固定工况实测最大端到端时延 24.408 µs、发送抖动 0 µs；不宣称覆盖全部最坏情况。R60 明确 GMII 接口延时不超过 2 ms，未进一步定义抖动统计量。 | `run tb_sys_perf`；测量方法、争用反例见第二、五节。 |
| 128 条发送 / 4096 条接收虚拟链路 | 每端配置全部接收项，全部发送项各发一条消息；实际交付覆盖接收索引 0、4095 及中间 126 项，不是逐项发送遍历全部接收项。自检 49924 项通过。 | `run tb_judge_capacity`；`证据/capacity.log` 的 `[CAPACITY_SUMMARY]`、`[RESULT]`。 |

## 二、性能数字与测量方法

性能仿真共用理想 125 MHz 时钟，一拍 8 ns；GMII 每拍一字节。下面的吞吐以接收应用口完成去重后的有效载荷计算，不包括报文头、填充和冗余副本。
| 项目 | 数值及条件 | 日志定位 |
|---|---|---|
| 吞吐 | 77 条虚拟链路、每条 1471 字节、BAG=125000 拍（1 ms），双向同时发送；错开提交，预热两个 BAG，稳定测量 21 ms；链路延迟 0/257 拍两组均为每方向 906.136 Mbps。 | `证据/judge_result.txt`：`stage=gbe77_d0`、`stage=gbe77_d257`，`delivered_mbps=906.136`。 |
| 端到端时延 | 同一工况最大 24.408 µs；从应用提交末字节量到对端交付末字节，只扣设定的线路延迟，保留调度与排队等待。 | 同一 `JUDGE METRIC` 行的 `max_e2e_us=24.408`；计算见 `tools/perf_ref.py:measure`。 |
| 抖动 | 同一虚拟链路相邻帧发送起点间隔偏离 BAG 的最大值为 0 µs；仅指上述稳定、错开提交且无服务争用的窗口。 | 同一行 `jitter_us=0.000`；`证据/performance.json:reports.system.performance`。 |
| 容量 | 每端发送 128 条、接收配置 4096 条，接收交付抽测 128 个索引。容量测试为每条一次消息，不把它当作满容量吞吐测试。 | `证据/capacity.log`：`tx_vls_each=128 rx_configured_each=4096 rx_sampled_each=128 first=0 last=4095`。 |
| RTC 误差 | 空载最大 0 ns；普通用户流量及 77 条虚拟链路满载均为 10788 ns（10.788 µs）。经公开配置口读两端时钟后比较；共用理想时钟及对称链路，未测试晶振漂移。满载为 1471 字节、BAG=1 ms，预热后测量 21 ms。 | `证据/judge_result.txt`：`rtc_idle_max_ns=0 rtc_loaded_max_ns=10788 rtc_77vl_max_ns=10788`；`tb/tb_sys_rtc.v`、`证据/rtc.json`。 |

完整性能矩阵还测得 10 条虚拟链路 117.680 Mbps、81 条 953.208 Mbps；来源为 `证据/performance.json` 的 `throughput_d0`、`gbe81_d0`，对应延迟组也通过。复现均用 `run tb_sys_perf`，不是更换硬件接口速率。
项目检查器采用吞吐≥100 Mbps、时延≤2000 µs、抖动≤50 µs，同时核对固定基线。前两项依据 R58/R60；50 µs 是项目对“几十微秒”的检查取值，不能写成官方明确门限（`sim/judge_perf.tcl`）。R60 没有细化 GMII 的计时边界；引用本页时延时，应明确这里使用的是应用口起终点。

## 三、综合资源与时序

以下主结果来自 2026-10-12 的 eLinx 界面 Run Synthesis，器件为 EQ6HL130、封装 CSG484_H；R30 允许自行选择器件。这些是综合后估算，未计布线延迟。
| 流程 | 资源 | 时序及原始出处 |
|---|---|---|
| 界面 Run Synthesis（报告主表使用） | LUT 32847、FF 13869、CLB 4626、Memory 340、引脚 259。 | setup +2.522 ns、Fmax 182.548 MHz、hold −0.068 ns；`elinx/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem_utilization_synth.rpt` 与同目录 `AFDX_EndSystem.tan.pb`。 |
| 命令行综合（单独列示） | 29961 个逻辑单元、783 个未装箱 RAM 切片；不与上行 Memory 数直接相减。 | setup +2.749 ns、Fmax 190.440 MHz、hold −0.068 ns；`out/synth/AFDX_top/20261012_141415_998117/summary.json`，复现 `powershell -NoProfile -ExecutionPolicy Bypass -File elinx/synth.ps1 -Top AFDX_top -Sta`。 |

界面时序库为 SQLite；只读查询 `elinx_intra_clock_summary` 中 `name=clk`：`period=8000`、`setup_worst_slack=2522`、`hold_worst_slack=-68`，时间单位 ps；Fmax 字段单位 MHz。查询副本见 `证据/gui_timing.json`。
界面先运行 Analysis & Synthesis 并选择 Speed，再交给后端；依据同目录 `AFDX_EndSystem.map.rpt` 的 Settings 和 `AFDX_EndSystem.flow.rpt` 的执行阶段。命令行直接由 `tools/eda.py:synth` 调用 `eLinx_synthesis.exe`，没有这个额外前端。两条流程的映射和统计口径不同，不要求资源数字相同。
hold 仍为负，且未给完整外部 I/O 延迟预算；上述 Fmax 不能当作上板频率或物理时序签核。

## 四、仿真入口与已跑结果

环境记录为 eLinx 3.0.7、ModelSim SE-64 2020.4、Windows PowerShell 5.1；Python 入口另需 `psutil`、`pyasn1==0.4.8`。软件与许可证不随工程分发。
| 入口 | 操作 | 实跑结果与耗时 |
|---|---|---|
| eLinx 界面行为仿真 | 打开 `elinx/AFDX_EndSystem.epr`，设置 ModelSim 路径；Simulation Sources 确认 `tb_elinx`，点 Run Behavioral Simulation。 | `[RESULT] tb_elinx PASS checks=9238 errors=0`；设计内时间 2557089 ns。`证据/gui_behavior.log` 的会话耗时 00:02:47 可能包含界面停留，未单独记录纯仿真耗时。 |
| 纯 ModelSim 评委入口 | Transcript 中进入仓库根目录，`do sim/run_judge.do`；不需要 Python。 | `JUDGE ENTRY PASS cases=7 warnings=0 elapsed_s=627.787`；本次约 10.5 分钟，涵盖五功能、容量、SNMP、两种突发、RTC、性能。见 `证据/judge_result.txt`。 |
| 完整 RTL 回归 | `powershell -NoProfile -ExecutionPolicy Bypass -File sim/regress.ps1`。 | 38/38 通过，1202.078 秒；自检合计 1183249131、独立核对 2305780，见 `证据/regression.json`、`validation.json`。 |

综合后功能仿真有两套，均使用原厂单元模型，均不含布线延迟；不能用其中一套的资源表冒充另一套。
| 网表来源 | 仿真副本补全内容 | 已跑结果 |
|---|---|---|
| 界面 `elinx/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm` | `tools/adapt_gui_vqm.py` 按组件声明/模型补 427486 个输入，按原有进位连接补 3933 个 `cin_used=true`；不改已有连接、参数和 LUT 内容。 | `tb_elinx` 9238/0，7826.703 秒；五功能入口完整复跑 1123/0、独立检查 65/0，3121.109 秒，七份记录与同激励 RTL 逐字节相同。见 `证据/gui_elinx_summary.json`、`gui_services_summary.json`。 |
| 命令行 `out/synth/AFDX_top/<日期>/netlist.v` | `tools/fix_lut_mask.py` 把逗号分隔的 LUT 位值转成十六进制字面量，补算术进位使用参数及省略输入。 | 网表清单 8/8；完整五功能 1123/0、独立检查 65/0，六份记录与 RTL 一致，仿真 3323.563 秒。见 `证据/cli_validation.json`、`cli_services_summary.json`；被测网表位置保存在后者的 `inputs`。 |

“9238/0”等表示检查数/错误数。界面流程省略的数据输入按厂商声明置 1；命令行适配器把自身导出格式中的未接数据输入置 0，二者不能互换。两套都显式补使能及 RAM 掩码等默认输入，否则悬空值或未启用进位会使模型行为不同。依据为 `tools/adapt_gui_vqm.py`、`tools/fix_lut_mask.py` 及安装目录 `stratix_components.vhd:546–561`、`stratix_atoms.v:692–698,979,3114–3137`。
界面网表复现：先点 Run Synthesis，再执行下面任一命令；输出在 `out/gui_netlist/`，失败返回非零退出码。
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_gui_netlist.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_gui_netlist.ps1 -Test tb_net_services
```
命令行网表复现：先按 [FLOW 的网表入口](FLOW.md#网表入口)生成清单要求的各顶层网表，再运行；源码摘要有变化时需重新综合，不能绕过摘要检查。
```powershell
$deadline=(Get-Date).AddHours(5).ToString('o')
powershell -NoProfile -ExecutionPolicy Bypass -File sim/regress.ps1 -Netlist -Deadline $deadline
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_net_services -Deadline $deadline
$net=Join-Path ((Get-Content out/latest_AFDX_top.json -Raw|ConvertFrom-Json).folder) 'netlist.v'
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_net_services -Netlist $net -Deadline $deadline
```
上例五小时是运行预算，不是预计耗时。两套都只写仿真副本，不修改原网表或厂商模型；通过条件包括测试结果和独立检查，不能只看工具退出码。

## 五、报告必须主动说明的边界

- 布线后时序：2026-10-10 的独立实现记录为 setup −10.368 ns、Fmax 54.443 MHz，达不到 125 MHz；原数据库查询见 `证据/route_timing.json`，流程记录见 `route_default.json`。这是该次实现结果，当前提交没有重新布局布线。按 R46“综合后仿真即可”采用综合后功能仿真作为验收证据，不宣称布线后 125 MHz 已通过。
- 吞吐与赛题：R58 要求的是吞吐达到 100 Mbps，R59 要求时钟匹配接口速率，R61 说明 GMII 是 PHY 接口且 MII 可能达不到吞吐要求。本设计采用八位 GMII 和 125 MHz；906.136 Mbps 是固定工况下的有效载荷吞吐，不是把双网相加，也不代表已在实体接口上测量。
- 零抖动的限制：同拍释放的争用实验中，8/77 条虚拟链路、1471/17 字节、每组 24 轮，对共同理想释放时刻的最大偏差分别为 86.144/4.752/935.120/52.432 µs。该量包含同一线路的串行排队，不能与稳定窗口的相邻发送间隔抖动混用（`证据/contention.json`，2026-10-10）。
- 服务争用：77 条长消息叠加 RTC/SNMP/615A 时，两个方向同一虚拟链路的发送间隔分别为 125000–125258、125000–125312 拍，而非恒定 BAG。上述专项记录保留了逐虚拟链路数据；本页未把它们当作当前提交重跑结果，也未将独立实验驱动纳入标准回归；服务争用数字同样出自 `证据/contention.json` 的 `runs[-1].measurements.directions`。
- 突发排队：77/81 条虚拟链路同时提交后清空发送队列分别需 959.272/1008.488 µs；从应用末字节到对端末字节的最大值为 959.360/1452.576 µs。81 条的队列清空超过 1 ms，但这不是稳定窗口单条消息的 24.408 µs。来源为 `证据/judge_result.txt` 的两条 `JUDGE METRIC burst_vls`；复现 `run tb_gbe_burst -Param COUNT=77` 或 `COUNT=81`。

2026-10-11 自研 MAC 与生成的 TripleSpeedEthernet 配置独立对照如下；帧长含 FCS、不含前导码，每拍 8 ns，单口资源来自同器件装箱（pack）报告，不能直接乘实例数当作整机资源差额。
| 比较项 | 自研 MAC | 官方 IP 的这份配置 |
|---|---|---|
| 空闲发送延迟：首字节请求→首前导码 | 0 拍；先发前导码后接纳数据。 | 59 拍（472 ns）。 |
| 接收延迟：末 FCS→用户末字节 | 2 拍，输出剥离 FCS。 | 15 拍，输出保留 FCS。 |
| 单口 LUT/FF/Memory/CLB | 556/198/0/69。 | 1400/975/24/209。 |
| 四实例持续收发仿真速度 | RTL 186466 拍/秒；综合网表 584 拍/秒。 | 原始 `.vo` 198 拍/秒。 |

依据为 `证据/mac_results.json`、`mac_official_resources.json`、`mac_self_resources.json` 及三份测速摘要。官方配置的 118 帧（含连续 50 帧 1518 字节帧）在测试端先补 FCS 后逐字节通过；用户侧 FIFO 不是整个 IP 的缓存总量，网表还含收发数据 FIFO。两帧错误 FCS 仍被交付，错误信号未置位，见 `mac_bad_crc.json`。

结论仅针对这份生成配置，不推广到该 IP 的所有配置；当前设计保留自研 MAC，未测官方 IP 集成后的整机指标。专项实验代码和 IP 生成物不随仓库分发，重做对照需恢复同配置与激励。
`.vo` 导出缺陷：2026-10-10 的布局布线网表关闭 SDF 后仍有 12 项功能错误；发送状态 RAM 输入位序重排、输出位序未相应调整，与配套模型逐位读写不一致。独立最小 RAM 实验中，18 位写 `00100` 读回 `10000`；36 位写 `000000100` 读回 `100000000`，分别 237/239 项错误，RTL 同激励均 256 项通过。8/9/16/32 位对照通过（`证据/vo_functional.json`、`vo_ram.json`、`vo_ram_bits.json`）。
最小复现条件为深度 128、位宽 18/36 的单块同步 RAM，输入和输出各加寄存器；前若干地址依次写入只有一位为 1 的数据，再读回地址 8 观察上述差异；仿真采用原厂 `.vo` 与原厂 `elinx_atoms.v`，仅关闭 SDF；按 [官方教程](../ref/vqm文件和.vo文件生成与使用20230605.docx)导出，不能改连接或模型来制造通过。现有记录证明导出网表与源模型组合不等价，尚无厂商对责任环节的正式确认。官方 MAC 自带 `.vo` 使用另一组原语连接，能通过不代表上述导出问题消失。
顶层保留赛题八个端口的名称和方向；新增 B 网口用于冗余、`app_*` 用于应用消息、`cfg_*` 用于配置和读回、`ev_*` 用于观察错误。`tx_ready` 表示初始化完成，`rx_ready` 不参与线路背压；不能把它描述为可暂停的标准接收流。依据为 `rtl/AFDX_top.v:12–61`、选题模板正文第 3–4 页和 R61。

## 六、协议版本依据

- AFDX 使用仓库 `spec/ARINC_664P7.pdf` 的 2005 年原文（封面日期 2005-06-27）；未取得后续版本，不能宣称逐条符合后续版本。
- 数据加载使用 `spec/ARINC 615A-2002.pdf`，封面为 ARINC REPORT 615A-2、2002-05-10；协议文件采用 A4，同时识别 A3（`rtl/afdx_615a.v`）。
- SNMP v1/v2c 对照 [RFC 1157](https://www.rfc-editor.org/rfc/rfc1157.html) 与 [RFC 3416](https://www.rfc-editor.org/rfc/rfc3416.html)；RTC 使用 [SNTP，RFC 4330](https://www.rfc-editor.org/rfc/rfc4330.html)；TFTP 对照 [RFC 1350](https://www.rfc-editor.org/rfc/rfc1350.html)。
- R47 不限定协议版本，也不提供参考激励；R12/R48 要求参考协议规范。版本选择不等于自动免除尚未实现的协议功能。

## 七、未实现及未验证的范围

- 615A：信息操作、操作员定义卸载的后续传输、FIND、WAIT、ABORT、整文件重试、多文件加载，以及后续版本新增 TFTP 选项协商；已有介质定义卸载不能代替这些功能。
- SNMP：GetBulk、单请求多个变量、v1 格式 Trap；私有对象子树未换成正式分配的企业号，v2c 的 noSuchInstance 异常语义尚未完整覆盖。
- AFDX/IP：ICMP 回显、IP 分片重组、采样端口、Sub-VL 未实现；UDP 校验和发送为零，接收未按目的 IP 过滤。
- 异常边界：SNTP 尚不检查服务器 Stratum 和全零时间戳；TFTP ERROR 未核对来源端口，截断请求缺少完整长度拒绝。正常用例通过不能替代这些检查。
- 未完成整顶层完整性能矩阵的网表仿真，也未做实体硬件测量、独立晶振及非对称链路对时验证，也未完成当前版本布局布线时序签核。功能网表通过不能替代这些证据。
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
