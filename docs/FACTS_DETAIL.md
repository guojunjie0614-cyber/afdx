# AFDX 端系统补充数据

## 当前交付状态

11-04 交付收尾的最终源码快速回归 63/63 PASS（52 项基础 + 11 项分支）；配置隔离 2/2 PASS，源码 `360cd0294e9ae129eef97fe37ae325187e13650c`。四个长用例引用分片版既有运行：tb_sys_perf 引用 11-03 满负载与分片负载验证中按公开应用口时戳统计的检查结果，其余引用 11-03 分片版 RTL 与官方 VQM 网表验证；与最终源码的关系由 11-04 ModelSim 兼容修正的 MODEL_TECH/兼容副本 ModelSim 等价及综合逐 token 保序相同证据绑定。11-03 满负载与分片负载验证的官方 VQM TX/RX 各 161 检查通过，与同激励 RTL 的 11 份记录各自逐字节相同。11-04 ModelSim 兼容修正后的端到端布线 setup +29 ps / hold +604 ps，setup/hold 各 0/96142 失败端点。旧 VQM `3cd8f5f8456c9881d083fe67dd7a60ed9c6779909ee1cb10dbf9367dc9729b6e` 与兼容修正后新 VQM `96d14e2f8ae99c72f3145f14a17f8606c16d98f7e039befe6359eb25c471e3b4` 分开绑定。

满负载规格为每端 63 TX / 63 RX VL（BAG=1 ms、Lmax=1471，线路占用约 77.5%）；可配置 TX 128 / RX 4096 条 VL。63 VL 七场景各连续 100 ms 通过：五项周期场景最大抖动 3.360 µs；BAG 等待场景 B2 最大 96.752 µs（0x0114、1471 B），全部分组 <100 µs；固定输入顺序的 B1 场景 HDL、完整性和双统计通过，BAG 等待抖动以轮换顺序的 B2 为判据。长短消息混合配置（3 条 VL 分别发送 1472、3000、8192 B，其余 60 条发送 1471 B）连续 100 ms 零丢失、逐字节一致。规格与网络规划要求见 [ARCH](ARCH.md#系统规格与网络规划)，原始记录见 [11-04 63 VL 满负载规格验证](evidence/t79_63vl/summary.md)；elinx 工程相对 a6181267 的一行源文件登记差异，以及检查数、耗时、输入哈希及体积见 [交付证据](evidence/frag1030_delivery/summary.md)。

### 压力测试与使用条件

- 压力测试（超出满负载规格）：81 VL 周期注入最大抖动 3.368 µs；81 VL 背靠背 BAG 等待场景（case 16）10/162 组抖动 ≥100 µs，最大 107.7 µs（VL 0x0126，两个方向）；81 VL 长短消息混合出现接收溢出，固定激励二分为 70 VL 通过 20 ms、71 VL 溢出，据此取 63 VL 规格（10% 余量）。
- 压力测试：63 VL 满负载下多条 VL 同时发送 8192 B（20 ms 窗口），2 条零丢失；3 条、4 条时接收载荷环溢出（ev_a[7]），出现丢失。网络规划要求同时发送 8192 B 消息的 VL 不超过 1 条。
- 8192 字节分片和故障恢复在 RTL 上验证；分片网表对照覆盖前 199,578 拍（含 1472 字节两帧重组），与 RTL 逐字节一致。
- eLinx Run Behavioral Simulation 于 11-04 人工验证：PASS checks=9238 errors=0，Elapsed 0:02:18，Warnings 90；截图与已知警告说明见 11-04 63 VL 满负载规格验证。
- eLinx 每次综合的 VQM 文本排列不同、功能结构相同，锁定布线后的时序相同（11-04 ModelSim 兼容修正后实测）。

## 逐项回归与评委入口

下表按 `sim/tests.txt` 顺序说明标准回归清单 56 项的测试内容。分片版新增测试及各项的自检数、独立核对数见 [交付回归记录](evidence/frag1030_delivery/regression.json)；评委入口 8/8 的完整输出见 [judge_result_frag1030.txt](../sim/reference/judge_result_frag1030.txt)。

| 测试名及非默认参数 | 测什么 |
|---|---|
| [tb_ram_sdp](../tb/tb_ram_sdp.v) | 核对不同存储器配置的写入、同步读取和读使能。 |
| [tb_mac_tx](../tb/tb_mac_tx.v) | 核对以太网组帧、帧间隔和上游缺字节处理。 |
| [tb_mac_rx](../tb/tb_mac_rx.v) | 核对正常帧、错误分类、去校验值和帧边界。 |
| [tb_mac_loop](../tb/tb_mac_loop.v) | 发送端接回接收端，核对不同帧长与双网内容。 |
| [tb_tx_basic](../tb/tb_tx_basic.v) | 核对不同消息长度的分页存储、协议头与双网发送。 |
| [tb_tx_basic](../tb/tb_tx_basic.v) `TX_PAGE_AW=5,TX_OFF_AW=11` | 核对不同消息长度的分页存储、协议头与双网发送。 |
| [tb_tx_bag](../tb/tb_tx_bag.v) | 核对带宽间隔、计数回绕和发送间隔变化。 |
| [tb_tx_multi](../tb/tb_tx_multi.v) | 核对多条虚拟链路的队列、轮询与网络选择。 |
| [tb_tx_drop](../tb/tb_tx_drop.v) | 核对禁用、队满、超长、无空闲页及失败后的页回收。 |
| [tb_tx_net](../tb/tb_tx_net.v) | 用固定输入核对发送内容和事件，供网表对照。 |
| [tb_rx_basic](../tb/tb_rx_basic.v) | 核对接收映射、不同消息长度、用户数据与端口。 |
| [tb_rx_fault](../tb/tb_rx_fault.v) | 损坏校验值、长度、报头和配置，核对拒绝原因。 |
| [tb_rx_icrm](../tb/tb_rx_icrm.v) | 核对序号规则、回绕和两网到达时间差边界。 |
| [tb_rx_load](../tb/tb_rx_load.v) | 大量虚拟链路接收时，核对序号隔离和冗余去重。 |
| [tb_rx_ovf_ring](../tb/tb_rx_ovf_ring.v) `RX_RING_AW=9` | 缩小字节缓存，核对溢出回退和后续接收恢复。 |
| [tb_rx_ovf_dq](../tb/tb_rx_ovf_dq.v) `RX_DQ_AW=1` | 缩小交付队列，核对队满丢帧和释放后恢复。 |
| [tb_rx_net](../tb/tb_rx_net.v) | 用固定正常及异常输入核对接收输出，供网表对照。 |
| [tb_sys_basic](../tb/tb_sys_basic.v) | 两个完整端系统互发消息，核对交付与事件。 |
| [tb_sys_fault](../tb/tb_sys_fault.v) | 在线路上丢帧、重放及损坏字节，核对检测和恢复。 |
| [tb_sys_delay](../tb/tb_sys_delay.v) | 改变两网延迟，核对交付、去重和端到端时延。 |
| [tb_sys_load](../tb/tb_sys_load.v) | 多链路同时传输，核对交付、发送间隔和配置隔离。 |
| [tb_sys_cfg](../tb/tb_sys_cfg.v) | 核对配置写握手、读延迟和计数采样时刻。 |
| [tb_sys_reset](../tb/tb_sys_reset.v) | 传输途中复位，核对旧残帧不混入新交付。 |
| [tb_sys_ovf](../tb/tb_sys_ovf.v) `RX_RING_AW=9` | 完整系统接收缓存溢出时，核对丢弃、计数和恢复。 |
| [tb_sys_net](../tb/tb_sys_net.v) | 通过顶层执行配置、正常及异常传输，供网表对照。 |
| [tb_sys_perf](../tb/tb_sys_perf.v) | 测量注入吞吐、R119 时延、R119-2 抖动和反压。 |
| [tb_sys_rtc](../tb/tb_sys_rtc.v) | 核对空载及有流量时的时钟同步、秒边界和交付。 |
| [tb_sys_snmp](../tb/tb_sys_snmp.v) | 核对查询、团体名和编码边界，并比较配置口读值。 |
| [tb_sys_snmp_settrap](../tb/tb_sys_snmp_settrap.v) | 核对设置、非法写入拒绝、启动和认证失败通知。 |
| [tb_sys_615a](../tb/tb_sys_615a.v) | 核对加载卸载、文件内容、校验错误和丢包重试。 |
| [tb_gbe_burst](../tb/tb_gbe_burst.v) `COUNT=77` | 同时提交多链路消息，测量排队时间并逐字节查重。 |
| [tb_gbe_burst](../tb/tb_gbe_burst.v) `COUNT=81` | 同时提交多链路消息，测量排队时间并逐字节查重。 |
| [tb_rm_phase](../tb/tb_rm_phase.v) | 跨粗计时边界并交换处理顺序，核对去重和老化。 |
| [tb_rtc_recovery](../tb/tb_rtc_recovery.v) | 丢弃同步回应并交换使能顺序，核对重发恢复。 |
| [tb_rtc_originate](../tb/tb_rtc_originate.v) | 错误或过期的请求时间不得校时，合法回应仍能同步。 |
| [tb_judge_capacity](../tb/tb_judge_capacity.v) | 配置全部收发链路，逐字节核对双网只交付一次。 |
| [tb_judge_snmp](../tb/tb_judge_snmp.v) | 解码查询、设置和通知，核对字段与配置口读值。 |
| [tb_elinx](../tb/tb_elinx.v) | 由界面入口运行双端双网互发，核对字节、端口和去重。 |
| [tb_sys_perf_var](../tb/tb_sys_perf_var.v) | 变长帧、多虚拟链路并发、注入吞吐与 R119 时延检查。 |
| [tb_top_wrap](../tb/tb_top_wrap.v) | 核对应用字节流封装、VLID 查找与整条消息交付。 |
| [tb_t65_queue_a](../tb/tb_t65_queue_a.v) | A 网交付队列满时整帧拒收、事件计数及释放后恢复。 |
| [tb_t65_reset_app](../tb/tb_t65_reset_app.v) | 应用 TX 查找状态复位，核对旧消息作废与双向恢复。 |
| [tb_t65_reset_mac](../tb/tb_t65_reset_mac.v) | MAC TX 前导状态复位，核对对端截断事件与恢复。 |
| [tb_t65_reset_rx](../tb/tb_t65_reset_rx.v) | RX 引擎 FRAME 状态复位，核对未交付旧帧作废与恢复。 |
| [tb_t65_rx_data](../tb/tb_t65_rx_data.v) | 模块级接收封装字节预留阈值、拒收及恢复。 |
| [tb_t65_rx_desc](../tb/tb_t65_rx_desc.v) | 模块级接收封装描述符预留阈值、拒收及恢复。 |
| [tb_t65_tx_desc](../tb/tb_t65_tx_desc.v) | 发送封装描述符耗尽、整条回滚及资源释放。 |
| [tb_t65_tx_hint](../tb/tb_t65_tx_hint.v) | ready 撤销但资源尚足时记录额外输入行为，并核对恢复。 |
| [tb_t65_tx_init](../tb/tb_t65_tx_init.v) | 初始化期间输入的事件、资源回收与后续恢复。 |
| [tb_t65_tx_ready](../tb/tb_t65_tx_ready.v) | 合法最大消息的 ready 准入提示与完整交付。 |
| [tb_t65_tx_short_full](../tb/tb_t65_tx_short_full.v) | 满队列时观察 1 字节输入，核对 2 字节空消息及恢复。 |
| [tb_t65_tx_short_init](../tb/tb_t65_tx_short_init.v) | 初始化时观察 1 字节输入，核对 2 字节空消息及恢复。 |
| [tb_t65_tx_short_normal](../tb/tb_t65_tx_short_normal.v) | 正常状态观察 1 字节输入，核对 2 字节空消息及恢复。 |
| [tb_t65_tx_space](../tb/tb_t65_tx_space.v) | 发送字节空间不足时整条回滚、事件及恢复。 |
| [tb_t65_tx_space_edge](../tb/tb_t65_tx_space_edge.v) | 发送字节空间边界下的接纳、拒收与恢复。 |
| [tb_t65_tx_unmapped](../tb/tb_t65_tx_unmapped.v) | 未命中 VLID 的整条拒收、事件及后续合法消息恢复。 |

### 代码覆盖率

#### 当前分片版覆盖率（11-04 交付引用）

11-03 在分片版 RTL `b3a60639` 上采集，58 份 UCDB、42 个 RTL 设计单元。交付 RTL = `b3a60639` + 11-04 ModelSim 兼容修正的 `MODEL_TECH` 声明前移分支，ModelSim 编译的电路等价；覆盖率引用该批采集结果。

| 覆盖类别 | 已覆盖 / 总数 | 未覆盖 | 汇总覆盖率 |
|---|---|---|---|
| 语句 | 12416 / 12824 | 408 | 96.8% |
| 分支 | 7230 / 7642 | 412 | 94.6% |
| 表达式 | 3242 / 3987 | 745 | 81.3% |
| FSM 状态 | 115 / 137 | 22 | 83.9% |
| 条件 | 1306 / 1766 | 460 | 74.0% |
| 翻转 | 59358 / 82546 | 23188 | 71.9% |
| FSM 跳转 | 141 / 375 | 234 | 37.6% |

按原始计数汇总后四舍五入到一位小数。原始数据、SHA256、58 个测试运行名和源码绑定见 [分片版覆盖率来源](evidence/t79_63vl/coverage_source.md)及 [原始 JSON](evidence/t79_63vl/coverage_frag1030.json)。这批覆盖率对应采集时的测试集合，11-04 新增的 63 VL 满负载规格验证见前文。

## 11-03 满负载与分片负载验证

更新：2026-11-04 06:37:27 的 [满负载与分片负载记录](evidence/t76_frag1030/summary.md) 和 [统计汇总](evidence/t76_frag1030/summary.json)保留当时结果。功能、自检、性能公式前提、独立统计、官方网表及 11-03 分片网表前缀分别列示；后续 TX/RX 网表窗口终态见 [交付核对](evidence/frag1030_delivery/vqm_windows.json)，当前 63 VL 规格结果见 [满负载验证](evidence/t79_63vl/summary.md)。源码兼容候选试布线失败后已回退；逻辑图重编号、打包/簇差异及实际时序分开记录。
