# AFDX 端系统补充数据

当前结果对应 2026-10-23 冻结 RTL `f60aaacd`。

本轮回归、评委、资源和布线后全量时序按当前证据更新；历史异常注入与独立实验保留原日期和原始数字，旧源码行号只作为归档定位。汇总见 [sim/reference](../sim/reference/)，测量边界见 [事实清单](FACTS.md)；证据摘要见 [manifest.json](evidence/manifest.json)。

## 逐项回归与评委入口

下表按 [sim/tests.txt](../sim/tests.txt) 排列；说明来自各测试平台开头的注释，数字取 [regression.json](../sim/reference/regression.json) 的 `Runs[].Checks/CheckItems/Status`。独立项为“—”表示该汇总没有单独项数，不能据此断言没有独立检查。

| 测试名及非默认参数 | 测什么 | 自检项数 | 独立核对项数 | 结果 |
|---|---|---|---|---|
| [tb_ram_sdp](../tb/tb_ram_sdp.v) | 核对不同存储器配置的写入、同步读取和读使能。 | 20764 | — | PASS |
| [tb_mac_tx](../tb/tb_mac_tx.v) | 核对以太网组帧、帧间隔和上游缺字节处理。 | 264649 | — | PASS |
| [tb_mac_rx](../tb/tb_mac_rx.v) | 核对正常帧、错误分类、去校验值和帧边界。 | 105303 | — | PASS |
| [tb_mac_loop](../tb/tb_mac_loop.v) | 发送端接回接收端，核对不同帧长与双网内容。 | 1385254 | — | PASS |
| [tb_tx_basic](../tb/tb_tx_basic.v) | 核对不同消息长度的分页存储、协议头与双网发送。 | 662057 | 7605 | PASS |
| [tb_tx_basic](../tb/tb_tx_basic.v) `TX_PAGE_AW=5,TX_OFF_AW=11` | 核对不同消息长度的分页存储、协议头与双网发送。 | 661637 | 7605 | PASS |
| [tb_tx_bag](../tb/tb_tx_bag.v) | 核对带宽间隔、计数回绕和发送间隔变化。 | 14054172 | 14591 | PASS |
| [tb_tx_multi](../tb/tb_tx_multi.v) | 核对多条虚拟链路的队列、轮询与网络选择。 | 14438577 | 56211 | PASS |
| [tb_tx_drop](../tb/tb_tx_drop.v) | 核对禁用、队满、超长、无空闲页及失败后的页回收。 | 30267258 | 4642 | PASS |
| [tb_tx_net](../tb/tb_tx_net.v) | 用固定输入核对发送内容和事件，供网表对照。 | 219315 | 229 | PASS |
| [tb_rx_basic](../tb/tb_rx_basic.v) | 核对接收映射、不同消息长度、用户数据与端口。 | 9960369 | 123855 | PASS |
| [tb_rx_fault](../tb/tb_rx_fault.v) | 损坏校验值、长度、报头和配置，核对拒绝原因。 | 576923 | 890 | PASS |
| [tb_rx_icrm](../tb/tb_rx_icrm.v) | 核对序号规则、回绕和两网到达时间差边界。 | 4635284 | 1274 | PASS |
| [tb_rx_load](../tb/tb_rx_load.v) | 大量虚拟链路接收时，核对序号隔离和冗余去重。 | 6406189 | 19180 | PASS |
| [tb_rx_ovf_ring](../tb/tb_rx_ovf_ring.v) `RX_RING_AW=9` | 缩小字节缓存，核对溢出回退和后续接收恢复。 | 422837 | 99 | PASS |
| [tb_rx_ovf_dq](../tb/tb_rx_ovf_dq.v) `RX_DQ_AW=1` | 缩小交付队列，核对队满丢帧和释放后恢复。 | 373852 | 57 | PASS |
| [tb_rx_net](../tb/tb_rx_net.v) | 用固定正常及异常输入核对接收输出，供网表对照。 | 374111 | 110 | PASS |
| [tb_sys_basic](../tb/tb_sys_basic.v) | 两个完整端系统互发消息，核对交付与事件。 | 5156252 | 2896 | PASS |
| [tb_sys_fault](../tb/tb_sys_fault.v) | 在线路上丢帧、重放及损坏字节，核对检测和恢复。 | 47120962 | 8726 | PASS |
| [tb_sys_delay](../tb/tb_sys_delay.v) | 改变两网延迟，核对交付、去重和端到端时延。 | 15482118 | 3763 | PASS |
| [tb_sys_load](../tb/tb_sys_load.v) | 多链路同时传输，核对交付、发送间隔和配置隔离。 | 216848087 | 116677 | PASS |
| [tb_sys_cfg](../tb/tb_sys_cfg.v) | 核对配置写握手、读延迟和计数采样时刻。 | 21170537 | 714342 | PASS |
| [tb_sys_reset](../tb/tb_sys_reset.v) | 传输途中复位，核对旧残帧不混入新交付。 | 10992598 | 3682 | PASS |
| [tb_sys_ovf](../tb/tb_sys_ovf.v) `RX_RING_AW=9` | 完整系统接收缓存溢出时，核对丢弃、计数和恢复。 | 9681664 | 1488 | PASS |
| [tb_sys_net](../tb/tb_sys_net.v) | 通过顶层执行配置、正常及异常传输，供网表对照。 | 2944308 | 1265 | PASS |
| [tb_sys_perf](../tb/tb_sys_perf.v) | 测量吞吐、发送与接收时延、端到端时延和抖动。 | 756655064 | 1212916 | PASS |
| [tb_sys_rtc](../tb/tb_sys_rtc.v) | 核对空载及有流量时的时钟同步、秒边界和交付。 | 10675857 | 1811 | PASS |
| [tb_sys_snmp](../tb/tb_sys_snmp.v) | 核对查询、团体名和编码边界，并比较配置口读值。 | 37611 | 926 | PASS |
| [tb_sys_snmp_settrap](../tb/tb_sys_snmp_settrap.v) | 核对设置、非法写入拒绝、启动和认证失败通知。 | 8563 | 188 | PASS |
| [tb_sys_615a](../tb/tb_sys_615a.v) | 核对加载卸载、文件内容、校验错误和丢包重试。 | 44098 | 752 | PASS |
| [tb_gbe_burst](../tb/tb_gbe_burst.v) `COUNT=77` | 同时提交多链路消息，测量排队时间并逐字节查重。 | 643552 | — | PASS |
| [tb_gbe_burst](../tb/tb_gbe_burst.v) `COUNT=81` | 同时提交多链路消息，测量排队时间并逐字节查重。 | 673500 | — | PASS |
| [tb_rm_phase](../tb/tb_rm_phase.v) | 跨粗计时边界并交换处理顺序，核对去重和老化。 | 353130 | — | PASS |
| [tb_rtc_recovery](../tb/tb_rtc_recovery.v) | 丢弃同步回应并交换使能顺序，核对重发恢复。 | 28 | — | PASS |
| [tb_rtc_originate](../tb/tb_rtc_originate.v) | 错误或过期的请求时间不得校时，合法回应仍能同步。 | 34 | — | PASS |
| [tb_judge_capacity](../tb/tb_judge_capacity.v) | 配置全部收发链路，逐字节核对双网只交付一次。 | 49924 | — | PASS |
| [tb_judge_snmp](../tb/tb_judge_snmp.v) | 解码查询、设置和通知，核对字段与配置口读值。 | 699 | — | PASS |
| [tb_elinx](../tb/tb_elinx.v) | 由界面入口运行双端双网互发，核对字节、端口和去重。 | 9238 | — | PASS |
| [tb_sys_perf_var](../tb/tb_sys_perf_var.v) | 变长帧、多虚拟链路并发、吞吐与分段时延检查。 | 1402134183 | 1573773 | PASS |

纯 ModelSim 入口记录见 [judge_result.txt](../sim/reference/judge_result.txt)。CE1 回归 39/39 通过、评委 8/8 通过；CE2 回归 39/39 通过、评委 8/8 通过。

| 入口用例 | 测试平台与目的 | 自检项数 | 独立核对项数 | 结果 |
|---|---|---|---|---|
| `services` | tb_net_services：用户收发、网络管理、时钟同步和文件加载卸载。 | 1124 | — | PASS |
| `capacity` | tb_judge_capacity：每端发送 128 条、配置接收 4096 条虚拟链路。 | 49924 | — | PASS |
| `snmp` | tb_judge_snmp：查询、设置和通知的报文字段与读回值。 | 699 | — | PASS |
| `burst77` | tb_gbe_burst：77 条虚拟链路同时提交消息。 | 643552 | — | PASS |
| `burst81` | tb_gbe_burst：81 条虚拟链路同时提交消息。 | 673500 | — | PASS |
| `rtc` | tb_sys_rtc：空载及有流量时的同步误差。 | 10675857 | — | PASS |
| `performance` | tb_sys_perf：吞吐、分段时延和抖动。 | 756655064 | — | PASS |
| `perf_var` | tb_sys_perf_var：变长帧与多虚拟链路、吞吐和分段时延。 | 1402134183 | — | PASS |

### 本轮代码覆盖率

本轮 CE2 完整 39 项覆盖率回归统计 24 个 RTL 模块，按 `sbceft` 插桩，测试平台不计入。统计按真实设计单元的已覆盖／总统计项合计，百分比按工具习惯截断；状态机合计为状态加转换。

| 覆盖类别 | 已覆盖 / 总数 | 百分比 |
|---|---|---|
| 语句 | 14314 / 15877 | 90.15% |
| 分支 | 8188 / 9642 | 84.92% |
| 条件 | 1029 / 1511 | 68.10% |
| 表达式 | 3264 / 4325 | 75.46% |
| 状态机，含状态和转换 | 248 / 418 | 59.33% |
| 状态 | 110 / 110 | 100.00% |
| 转换 | 138 / 308 | 44.80% |
| 翻转 | 47317 / 59698 | 79.26% |

逐模块数字和原始报告见 `sim/reference/coverage/`；未覆盖项保持原统计范围，不沿用旧版源码行号或未重新核对的原因说明。

## 综合资源占比与模块分工

当前官方综合用量见下表及本轮 `t43_timing.json`；归档界面报告仍保留于 [gui_resources.rpt](evidence/gui_resources.rpt)；EQ6HL130/CSG484_H 的器件总量取 [device_capacity.rpt](evidence/device_capacity.rpt) 各行斜线后的数。这里只借用器件容量，不把其中的布局后用量混进综合结果。比例按“综合用量 ÷ 总量”计算，四舍五入到小数点后两位。

| 资源 | 当前官方综合用量 | 器件总量 | 占比 |
|---|---|---|---|
| 查找表（Lookup Table，LUT） | 38297 | 136160 | 28.13% |
| 触发器（Flip-Flop，FF） | 19947 | 136160 | 14.65% |
| 可配置逻辑块（Configurable Logic Block，CLB） | 5049 | 13616 | 37.08% |
| 存储块（Memory） | 361 | 1200 | 30.08% |
| 数字信号处理单元（Digital Signal Processing，DSP） | 0 | 48 | 0.00% |
| 锁相环（Phase-Locked Loop，PLL） | 0 | 8 | 0.00% |
| 用户引脚 | 259 | 339 | 76.40% |

以下分模块数据是 2026-10-15 归档，模块边界与当前 24 个 RTL 模块不同，不作为本轮分模块资源。数据取 [gui_hierarchy.rpt](evidence/gui_hierarchy.rpt) 的 `Resource Utilization by Entity` 表（第 366–458 行）。同类模块的实例合并，数字包含子模块，父子行不可相加。存储单位是有效位数，不是物理块数；存储器包装模块的数已包含在调用它的模块中。
“逻辑单元”含仅使用寄存器的单元；“功能 LUT”由 `LUT-Only LCs + LUT/Register LCs` 计算。它与工具总体 `Total LUTs` 的统计口径不同。

| 模块类型 | 实例数 | 逻辑单元 | 功能 LUT | FF | 存储位数 |
|---|---:|---:|---:|---:|---:|
| `AFDX_top` | 1 | 32846 | 26268 | 13869 | 2421632 |
| `afdx_615a` | 1 | 7171 | 6276 | 1358 | 102400 |
| `afdx_cfg` | 1 | 1954 | 1702 | 1076 | 0 |
| `afdx_crc32_d8` | 4 | 90 | 90 | 0 | 0 |
| `afdx_mac_rx` | 2 | 371 | 355 | 222 | 0 |
| `afdx_mac_tx` | 1 | 597 | 597 | 155 | 0 |
| `afdx_ntp_fraction` | 3 | 1000 | 800 | 405 | 0 |
| `afdx_ram_sdp` | 19 | 1241 | 684 | 885 | 2421632 |
| `afdx_rtc` | 1 | 4573 | 3826 | 2190 | 0 |
| `afdx_rx_core` | 1 | 8814 | 5966 | 4964 | 1208320 |
| `afdx_rx_deliver` | 1 | 1975 | 1963 | 481 | 0 |
| `afdx_rx_engine` | 1 | 1127 | 944 | 489 | 0 |
| `afdx_rx_parse` | 2 | 2466 | 2224 | 1220 | 0 |
| `afdx_snmp` | 1 | 4463 | 3550 | 1261 | 4096 |
| `afdx_svc` | 1 | 120 | 120 | 7 | 0 |
| `afdx_timebase` | 1 | 33 | 33 | 33 | 0 |
| `afdx_tx_buf` | 1 | 493 | 359 | 257 | 0 |
| `afdx_tx_builder` | 1 | 2091 | 1884 | 962 | 0 |
| `afdx_tx_core` | 1 | 5677 | 4754 | 2975 | 1106816 |
| `afdx_tx_engine` | 1 | 1790 | 1460 | 1029 | 0 |
| `afdx_tx_free` | 1 | 206 | 181 | 126 | 2048 |

命令行入口与界面均使用官方分析综合、VQM 导出、装箱和综合后时序流程，资源按同一装箱报告统计。命令行报告和时序库位置取 `out/latest_AFDX_top.json` 的 `resources_report/timing_database`，复现见事实清单第三节；分模块表中的逻辑单元和功能 LUT 仍按上方层次报告的定义统计，不与总体 `Total LUTs` 混用。

## 各工况的时延细分

2026-10-23 的实测数据见 [perf_r97.json](evidence/perf_r97.json) 的 `main_table`。定义见[事实清单](FACTS.md#时延与抖动定义)；所有时延及极差单位为 µs，吞吐为 Mbps。首/末分别为应用交付首/末字节，L_app 包含链路。各列最大值可来自不同帧；逐帧才满足分段加和。

| 工况 | 方向 | 吞吐 | L_gmii | L_tx | L_rx首/末 | L_app首/末 | J_app（VL:min帧→max帧） | J_gmii | 发送间隔偏差 |
|---|---|---:|---:|---:|---|---|---|---:|---:|
| gbe77_d0 | es1_to_es2 | 906.136 | 0.000 | 0.304 | 12.360/24.120 | 12.664/24.424 | 0.008 (25:1180→2335) | 0.000 | 0.000 |
| gbe77_d0 | es2_to_es1 | 906.136 | 0.000 | 0.304 | 12.360/24.120 | 12.664/24.424 | 0.008 (23:718→949) | 0.000 | 0.000 |
| gbe77_d257 | es1_to_es2 | 906.136 | 2.056 | 0.304 | 12.360/24.120 | 14.720/26.480 | 0.008 (42:2968→3430) | 0.000 | 0.000 |
| gbe77_d257 | es2_to_es1 | 906.136 | 2.056 | 0.304 | 12.360/24.120 | 14.720/26.480 | 0.008 (1:2467→4007) | 0.000 | 0.000 |
| var_burst_d0 | es1_to_es2 | 57.794 | 0.000 | 26.616 | 12.352/24.112 | 36.184/36.312 | 0.000 (0:8561→8561) | 0.000 | 1.344 |
| var_burst_d0 | es2_to_es1 | 57.794 | 0.000 | 26.728 | 12.352/24.112 | 36.296/36.424 | 0.000 (0:8561→8561) | 0.000 | 0.000 |
| var_burst_d257 | es1_to_es2 | 57.794 | 2.056 | 21.024 | 12.352/24.112 | 34.776/34.824 | 0.008 (2:9763→10571) | 0.000 | 0.000 |
| var_burst_d257 | es2_to_es1 | 57.794 | 2.056 | 21.024 | 12.352/24.112 | 34.776/34.824 | 0.000 (0:9761→9761) | 0.000 | 0.000 |
| var_cycle_d0 | es1_to_es2 | 70.403 | 0.000 | 12.208 | 12.352/24.112 | 12.928/24.416 | 9.992 (25:2666→3026) | 0.000 | 6.192 |
| var_cycle_d0 | es2_to_es1 | 70.403 | 0.000 | 12.208 | 12.352/24.112 | 12.928/24.416 | 9.992 (25:2666→3026) | 0.000 | 6.192 |
| var_cycle_d257 | es1_to_es2 | 70.403 | 2.056 | 12.208 | 12.352/24.112 | 14.984/26.472 | 9.992 (25:3866→4226) | 0.000 | 6.192 |
| var_cycle_d257 | es2_to_es1 | 70.403 | 2.056 | 12.208 | 12.352/24.112 | 14.984/26.472 | 9.992 (25:3866→4226) | 0.000 | 6.192 |
| var_fixed_d0 | es1_to_es2 | 57.794 | 0.000 | 0.352 | 12.352/24.112 | 12.656/24.416 | 0.008 (21:262→382) | 0.000 | 0.000 |
| var_fixed_d0 | es2_to_es1 | 57.794 | 0.000 | 0.352 | 12.352/24.112 | 12.656/24.416 | 0.008 (1:242→426) | 0.000 | 0.000 |
| var_fixed_d257 | es1_to_es2 | 57.794 | 2.056 | 0.352 | 12.352/24.112 | 14.712/26.472 | 0.000 (0:1441→1441) | 0.000 | 0.000 |
| var_fixed_d257 | es2_to_es1 | 57.794 | 2.056 | 0.352 | 12.352/24.112 | 14.712/26.472 | 0.008 (3:1444→1836) | 0.000 | 0.000 |
| var_high_d0 | es1_to_es2 | 904.752 | 0.000 | 12.008 | 12.360/24.120 | 23.864/24.424 | 0.008 (50:5011→5891) | 0.000 | 0.000 |
| var_high_d0 | es2_to_es1 | 904.752 | 0.000 | 12.008 | 12.360/24.120 | 23.864/24.424 | 0.008 (33:4994→5794) | 0.000 | 0.000 |
| var_high_d257 | es1_to_es2 | 904.752 | 2.056 | 12.008 | 12.360/24.120 | 25.920/26.480 | 0.008 (15:6736→7936) | 0.000 | 0.000 |
| var_high_d257 | es2_to_es1 | 904.752 | 2.056 | 12.008 | 12.360/24.120 | 25.920/26.480 | 0.008 (2:6723→8163) | 0.000 | 0.000 |

A/B两网、逐载荷长度及各口径极差见 `证据/perf_r97.json:grouped_metrics`；键为工况/方向/网络/载荷长度/口径，数组列顺序见 `grouped_stat_order`，时间为整数拍，乘0.008转µs。未获接收的B副本没有应用交付，应用口径为NA；TX/GMII仍单独测量。零极差时min/max可为同一帧，不代表只有一个样本。

| Burst工况/方向 | 释放→首/末最大 µs | 释放口径首/末R97抖动 µs |
|---|---|---|
| var_burst_d0/es1_to_es2 | 173.528/173.656 | 0.000/0.000 |
| var_burst_d0/es2_to_es1 | 173.640/173.768 | 0.000/0.000 |
| var_burst_d257/es1_to_es2 | 174.464/174.592 | 0.008/0.008 |
| var_burst_d257/es2_to_es1 | 174.464/174.592 | 0.000/0.000 |

同拍是计划释放到主机待发队列；单应用口串行握手完成后才算M。上方主表为M→D，释放口径包含注入排队。出处为 `证据/perf_r97.json:main_table`、`burst_release_analysis`。
原旧值24.408 µs来自旧应用末字节、扣链路口径；54877a09增加接收映射读两拍后为24.424 µs。旧轻载均值未按新SFD边界重测，历史数据保留在 `证据/performance.json`，不挪用为当前分段数值。

## 综合后最慢路径


当前官方综合最慢路径取本轮 JSON 的 `timing.worst_setup_path`，以下仅为综合估算。

| 流程 | 模块与路径起点 → 终点 | 逻辑级数 | 逻辑延迟（ns） | 建立裕量（ns） |
|---|---|---|---|---|
| 官方综合 | `\afdx_615a:loader\|afdx_ram_sdp:load_ram\|altsyncram:memory_rtl_0\|altsyncram_h8c1:auto_generated\|altsyncram:ram_block1a0\|altsyncram_2c63:auto_generated\|ram_block1a10~I\|port_b_address_dff[0]/Q` → `\afdx_615a:loader\|afdx_ram_sdp:load_ram\|read_data[2]~I\|ff/D` | 2 | 3.097 | +4.459 |

### 本轮布线后全量时序

| 项目 | 当前官方结果 |
|---|---|
| 查找表（LUT） | 38297 |
| 触发器（FF） | 19947 |
| 可配置逻辑块（CLB） | 5049 |
| 存储器（Memory） | 361 |
| 用户引脚 | 259 |
| 综合后建立裕量／保持裕量 | +4.459 / -0.068 ns |
| 综合后最高频率估算 | 282.406 MHz |
| 布线后建立裕量／保持裕量 | -0.090 / +0.229 ns |
| 布线后最高频率估算 | 123.609 MHz |
| 布线后 setup 失败端点 | 1 / 50132 |
| 8 ns 路径数／最差 setup | 160894 / -0.090 ns |
| 16 ns 路径数／最差 setup | 50296 / +1.750 ns |
| 同沿 hold 路径数 | 211190 |

最差十条真实路径：

| 起点 → 终点 | 级数 | 逻辑 ns | 连线 ns | setup ns |
|---|---|---|---|---|
| `\cfg_regs\|cfg_ready_m~I\|ff/Q` → `\rtc\|load_ns[0]~I\|ff/ena` | 4 | 1.580 | 6.340 | -0.090 |
| `\rx_core\|ev_b[2]~I\|ff/Q` → `\cfg_regs\|count_b_len[30]~I\|ff/D` | 1 | 1.970 | 5.950 | +0.005 |
| `\rx_core\|ev_b[2]~I\|ff/Q` → `\cfg_regs\|count_b_len[31]~I\|ff/D` | 1 | 1.970 | 5.950 | +0.005 |
| `\cfg_regs\|tx_cfg_we~0_I\|ff/Q` → `\cfg_regs\|receive_bus[0].ready~I\|ff/D` | 2 | 1.042 | 6.846 | +0.037 |
| `\tx_core\|builder\|s_valid~I\|ff/Q` → `\tx_core\|mac\|fcs_a[23]~I\|ff/D` | 5 | 1.842 | 6.032 | +0.051 |
| `\snmp\|configured~I\|ff/Q` → `\snmp\|req_wa[0]~I\|ff/ena` | 5 | 1.820 | 5.949 | +0.061 |
| `\snmp\|configured~I\|ff/Q` → `\snmp\|rx_count[6]~I\|ff/ena` | 5 | 1.820 | 5.949 | +0.061 |
| `\snmp\|configured~I\|ff/Q` → `\snmp\|rx_count[8]~I\|ff/ena` | 5 | 1.820 | 5.949 | +0.061 |
| `\snmp\|configured~I\|ff/Q` → `\snmp\|req_wa[6]~I\|ff/ena` | 5 | 1.820 | 5.949 | +0.061 |
| `\snmp\|configured~I\|ff/Q` → `\snmp\|req_wa[7]~I\|ff/ena` | 5 | 1.820 | 5.949 | +0.061 |

本轮官方 VQM 的 `tb_net_services` 网表与同次 RTL 均通过 1124 项自检，错误均为 0；网表独立检查 65 项、错误 0，同激励 RTL 独立检查 59 项，网表另含 6 项精确记录对照；七份外部记录逐字节一致。网表仿真 7912.875 秒，同激励 RTL 23.813 秒；原网表 SHA-256 与本轮官方综合一致。

## 设计默认参数

下表按当前顶层默认例化计算；容量的 KiB 按 1024 字节换算。改测试参数后的容量不可套用此表。

| 参数或容量 | 默认数值与含义 | 源码出处 |
|---|---|---|
| 发送负载缓冲 | 256 页 × 512 字节 = 131072 字节（128 KiB），双网共用一份负载。 | `AFDX_top.v:7–9` 的 `TX_PAGE_AW=8/TX_OFF_AW=9`；`afdx_tx_core.v:45,162` 的 `PAGES/PAYLOAD_DEPTH/tx_payload` |
| 发送描述与链表 | 消息描述 256 项×44 位；消息链和页链分别 256 项×8 位；空闲页池 256 页。 | `afdx_tx_core.v:133–162`；`afdx_tx_free.v` 的 `PAGES` |
| 接收字节环 | A、B 网各 4096 字节（各 4 KiB）。 | `AFDX_top.v:10` 的 `RX_RING_AW=12`；`afdx_rx_core.v:174,183` |
| 接收描述队列 | 共用 32 项，每项 68 位；按 `2**RX_DQ_AW` 和 `RX_RING_AW+56` 计算。 | `AFDX_top.v:11`；`afdx_rx_core.v:66–88`；`afdx_rx_engine.v` 的 `DQ_DEPTH` |
| 虚拟链路容量 | 每端发送 128 条、接收 4096 条；接收映射表 65536 项×13 位。 | `afdx_tx_core.v:115,124`；`afdx_rx_core.v:145–163` |
| 复位后初始化 | 解除复位到观察到顶层就绪相隔 65538 拍，即 524.304 µs；记录 `R 5`、`I 65543`。 | `afdx_rx_core.v:112–125` 清 65536 项后收尾，`AFDX_top.v:273–275` 注册就绪；[fault_rx_events.txt](evidence/fault_rx_events.txt) 第 4、6 行；其 `G CLOCK_NS` 在 [fault_events.txt](evidence/fault_events.txt) |
| 工作节拍 | 共用 125 MHz 时钟，即每拍 8 ns；复位后每拍处理一个线路字节。 | `afdx_timebase.v` 的 `byte_en`；`AFDX_top.v:279–285`；`fault_events.txt` 的 `G CLOCK_NS 8` |
| 帧间隔 | 12 拍，即 96 ns；末帧之后首个空闲拍加后续 11 拍。 | `afdx_mac_tx.v:35,176–186` 的 `gap_left` |
| 调度前瞻 | `LOOKAHEAD=512` 拍，即 4.096 µs；它是调度参数，不是实测端到端时延。 | `AFDX_top.v:9`；`afdx_tx_engine.v` 的 `LOOKAHEAD` |
| 用户消息长度 | 每条最多 1471 字节，还受该链路配置的最大长度限制。 | `afdx_tx_buf.v:62,201` 的 `MAX_PAYLOAD` |
| 网络管理对象 | 简单网络管理协议（Simple Network Management Protocol，SNMP）共 36 个对象：2 个系统对象、34 个私有对象。 | `afdx_snmp.v:222–243,766` 的 `mib_arc/candidate` |
| 网络管理请求 | 请求缓存 256 字节，最多接收 256 字节；超过后不进入解析；每次处理 1 个变量绑定。 | `afdx_snmp.v:199–210,505–517` 的 `request_ram/rx_count/overflow`；报文解析状态机 |
| 数据加载存储 | 加载区 8192 字节（8 KiB），头文件区 2048 字节，加载请求区 512 字节；收发包缓存各 1024 字节。 | `afdx_615a.v:297–333` 的 `packet_rx/packet_tx/lur_ram/header_ram/load_ram` |
| 数据加载超时与重试 | 超时默认 250000000 拍（2 s），每次等待最多重发 1 次；初始请求另计。 | `afdx_615a.v:167,595–598,740–754` 的 `timeout_cycles/retry_limit/retries` |
| 数据加载默认协议 | 请求端口 59，协议文件版本 A4；不是完整文件无限重试。 | `afdx_615a.v:167,595,598` 的 `request_port/protocol_a4` |
| 实时时钟分辨率 | 实时时钟（Real-Time Clock，RTC）每拍增加 8 ns，默认同步周期 125000 拍（1 ms）；分辨率不等于同步精度。 | `afdx_rtc.v:60–64,233,298–302` 的 `period/nanoseconds` |

上述源码文件均在 [rtl](../rtl/)；初始化的拍数是当前记录的观察值，其余容量和时间换算由所列参数直接计算。

## 代码规模

统计所有已跟踪文本文件的物理行数，包含注释与空行，不算运行产物、PNG 图片和 `sim/reference/` 中的参考输出。`sim/` 包含固定向量及清单，因此该目录行数不等于脚本代码行数。以下命令在仓库根目录执行即可复算。

| 目录 | 文件数 | 物理行数 |
|---|---|---|
| `rtl/` | 24 | 12568 |
| `tb/` | 55 | 4287 |
| `tools/` | 27 | 5346 |
| `sim/` | 21 | 3591 |

```powershell
foreach ($dir in 'rtl','tb','tools','sim') {
  $files = @(git ls-files -- $dir ':(exclude)sim/reference/**' ':(exclude)*.png')
  $count = ($files | ForEach-Object { [IO.File]::ReadAllLines((Join-Path $PWD $_)).Length } | Measure-Object -Sum).Sum
  '{0}: files={1}, lines={2}' -f $dir,$files.Count,$count
}
```

## 异常注入与计数器读回

下表的 A/B 数值分别对应两网；“每端”表示两个端系统各自均读到该值，不能再合并成单端值。寄存器地址为十六进制，读回以 `sys_events.txt` 原记录的 `V` 行为准。
接收异常来源为 [fault_events.txt](evidence/fault_events.txt) 的 `A/J/R/P/V` 行及 [fault_checks.json](evidence/fault_checks.json) 的阶段统计；发送拒绝来源为 [load_commands.txt](evidence/load_commands.txt)、[load_tx_events.txt](evidence/load_tx_events.txt) 的 `M/E` 行、[load_events.txt](evidence/load_events.txt) 的 `V` 行和 [load_checks.json](evidence/load_checks.json)。地址对应见 `rtl/afdx_cfg.v`，独立计数核对见 `tools/sys_ref.py:273–288`。

| 出错情况 | 测试与实际注入数量 | 对应计数器读回 |
|---|---|---|
| 帧校验序列（Frame Check Sequence，FCS）错误 | `tb_sys_fault/fcs`：每端每网损坏 2 帧，共 8 帧。 | 每端 `0x49/0x51=2/2`，均从 0 增加到 2。 |
| 帧长错误 | `tb_sys_fault/len`：每端每网注入 1 帧，共 4 帧。 | 该阶段末每端 `0x4a/0x52=1/1`。 |
| IP 头校验错误 | `tb_sys_fault/ip_hdr`：每端每网注入 1 帧，共 4 帧。 | 每端报头错误 `0x4b/0x53=1/1`。 |
| UDP 报头错误 | `tb_sys_fault/udp_hdr`：每端每网注入 1 个校验和字段非零的帧，共 4 帧。 | 每端 `0x4b/0x53=2/2`，本阶段各增加 1。 |
| 未知虚拟链路 | `tb_sys_fault/unk`：每端每网注入 1 帧，共 4 帧。 | 每端 `0x4c/0x54=1/1`。 |
| 配置不允许该网 | `tb_sys_fault/cfg`：每端 2 条双网消息，各有 1 个 A 网和 1 个 B 网副本不允许，共 4 个被拒副本。 | 每端 `0x4d/0x55=1/1`。 |
| 同网序号重复 | `tb_sys_fault/duplicate`：四条单向线路各重放 1 帧，共 4 帧。 | 每端完整性错误 `0x4e/0x56=1/1`；这类同网重放先由序号检查拒绝。 |
| 序号不连续 | `tb_sys_fault/reorder`：四条线路各暂存并延后重放 1 帧，共 4 次乱序。 | 每端 `0x4e/0x56=2/2`，本阶段各增加 1。 |
| 双网冗余重复 | `tb_sys_load`：端2 收到端1的 922 组双网消息，共 1844 个副本，其中 922 个重复副本。 | 端2 `0x58=922`，交付 `0x59=922`；A/B 完好帧 `0x48/0x50=922/922`。 |
| 接收字节环溢出 | `tb_sys_ovf`：缓存缩到 512 字节，每端发送 513、1000、1471 字节消息各 1 条，双网各 3 个溢出帧。 | 每端 `0x4f/0x57=3/3`；[overflow_events.txt](evidence/overflow_events.txt)、[overflow_tx_events.txt](evidence/overflow_tx_events.txt)、[overflow_checks.json](evidence/overflow_checks.json)。 |
| 接收描述队列满 | `tb_rx_ovf_dq`：深度缩为 2，输入 8 帧，观察到 1 次 B 网队满及 2 次冗余丢弃。 | 配置口读回未测；核心事件 `b_ovf=1`，不是寄存器读回；[queue_overflow_checks.json](evidence/queue_overflow_checks.json)、[queue_overflow_events.txt](evidence/queue_overflow_events.txt)。 |
| 发送禁用 | `tb_sys_load/drops`：端1向禁用链路 125 提交 1 条消息。 | 端1 `0x41=1`（`drop_dis`）。 |
| 发送队列满 | `tb_sys_load/drops`：端1向队列限额为 0 的链路 127 提交 1 条消息。 | 端1 `0x42=1`（`drop_full`）。 |
| 发送消息超长 | `tb_sys_load/drops`：端1向最大长度为 1 的链路 126 提交 1 条 18 字节消息。 | 端1 `0x43=1`（`drop_long`）。 |
| 发送无空闲页 | `tb_sys_load/drops`：先用 85 条 1471 字节消息占用 255 页，再提交 1471、512、1 字节；前后两条失败，中间一条使用余下页成功。 | 端1 `0x44=2`（`drop_nopage`）；对应事件周期 1105337、1105873。 |

`tb_sys_fault/gdrop_a,gdrop_b` 另注入 10/13 个坏长度帧，端2最终长度错误读数变为 11/14；`0x5a/0x5b` 仍为 0。因此这两阶段证明的是长度拒绝，不能写成接收缓存溢出覆盖。以上异常的自动判定结果均在逐项回归表中。
