# AFDX 端系统补充数据

当前 F1 的 RTL 与 r5 A `18d1606c` 零差异；原 V1/V2 验证提交为 `t63@92ab7d7e`，F1b 在 `67d2e618` 基础上仅修正宏内测试观测。**V1 功能终验通过**：模块及整顶层网表清单 8/8 PASS，`tb_sys_net` 自检与独立核对通过；V2 时序复核通过，真实 GUI 待用户复跑。器件 EQ6HL130、封装 CSG484_H，主时钟 125 MHz（8.000 ns），CE_DIV=2。采用 PRES 1.30 和固定布局后，全部 53,882 个端点 setup/hold 均为 0 失败，最差余量为 +0.016 / +0.229 ns；setup 已含 0.30 ns 时钟不确定度。原始精度为 +16 / +229 ps，门槛按原始精度判定。

本轮回归、评委、资源和布线后全量时序按当前证据更新；历史异常注入与独立实验保留原日期和原始数字，旧源码行号只作为归档定位。汇总见 [sim/reference](../sim/reference/)，测量边界见 [事实清单](FACTS.md)；证据摘要见 [manifest.json](evidence/manifest.json)。

## 逐项回归与评委入口

下表为本次 F1 的 CE2 完整回归，按 `sim/tests.txt` 的原始顺序列出，计数与 `sim/reference/regression.json` 一致。独立项为“—”表示汇总没有单独项数；覆盖率历史记录另列，不作为 F1 覆盖率。

| 测试名及非默认参数 | 测什么 | 自检项数 | 独立核对项数 | 结果 |
|---|---|---:|---:|---|
| [tb_ram_sdp](../tb/tb_ram_sdp.v) | 核对不同存储器配置的写入、同步读取和读使能。 | 20764 | — | PASS |
| [tb_mac_tx](../tb/tb_mac_tx.v) | 核对以太网组帧、帧间隔和上游缺字节处理。 | 264649 | — | PASS |
| [tb_mac_rx](../tb/tb_mac_rx.v) | 核对正常帧、错误分类、去校验值和帧边界。 | 105303 | — | PASS |
| [tb_mac_loop](../tb/tb_mac_loop.v) | 发送端接回接收端，核对不同帧长与双网内容。 | 1385254 | — | PASS |
| [tb_tx_basic](../tb/tb_tx_basic.v) | 核对不同消息长度的分页存储、协议头与双网发送。 | 662156 | 7606 | PASS |
| [tb_tx_basic](../tb/tb_tx_basic.v) `TX_PAGE_AW=5,TX_OFF_AW=11` | 核对不同消息长度的分页存储、协议头与双网发送。 | 661736 | 7606 | PASS |
| [tb_tx_bag](../tb/tb_tx_bag.v) | 核对带宽间隔、计数回绕和发送间隔变化。 | 14054199 | 14592 | PASS |
| [tb_tx_multi](../tb/tb_tx_multi.v) | 核对多条虚拟链路的队列、轮询与网络选择。 | 14438572 | 56224 | PASS |
| [tb_tx_drop](../tb/tb_tx_drop.v) | 核对禁用、队满、超长、无空闲页及失败后的页回收。 | 30267272 | 4643 | PASS |
| [tb_tx_net](../tb/tb_tx_net.v) | 用固定输入核对发送内容和事件，供网表对照。 | 219323 | 230 | PASS |
| [tb_rx_basic](../tb/tb_rx_basic.v) | 核对接收映射、不同消息长度、用户数据与端口。 | 9960369 | 123855 | PASS |
| [tb_rx_fault](../tb/tb_rx_fault.v) | 损坏校验值、长度、报头和配置，核对拒绝原因。 | 576923 | 890 | PASS |
| [tb_rx_icrm](../tb/tb_rx_icrm.v) | 核对序号规则、回绕和两网到达时间差边界。 | 4635284 | 1274 | PASS |
| [tb_rx_load](../tb/tb_rx_load.v) | 大量虚拟链路接收时，核对序号隔离和冗余去重。 | 6406189 | 19180 | PASS |
| [tb_rx_ovf_ring](../tb/tb_rx_ovf_ring.v) `RX_RING_AW=9` | 缩小字节缓存，核对溢出回退和后续接收恢复。 | 422837 | 99 | PASS |
| [tb_rx_ovf_dq](../tb/tb_rx_ovf_dq.v) `RX_DQ_AW=1` | 缩小交付队列，核对队满丢帧和释放后恢复。 | 373852 | 57 | PASS |
| [tb_rx_net](../tb/tb_rx_net.v) | 用固定正常及异常输入核对接收输出，供网表对照。 | 374111 | 110 | PASS |
| [tb_sys_basic](../tb/tb_sys_basic.v) | 两个完整端系统互发消息，核对交付与事件。 | 5156222 | 2898 | PASS |
| [tb_sys_fault](../tb/tb_sys_fault.v) | 在线路上丢帧、重放及损坏字节，核对检测和恢复。 | 42097787 | 9008 | PASS |
| [tb_sys_delay](../tb/tb_sys_delay.v) | 改变两网延迟，核对交付、去重和端到端时延。 | 13938621 | 3915 | PASS |
| [tb_sys_load](../tb/tb_sys_load.v) | 多链路同时传输，核对交付、发送间隔和配置隔离。 | 193108134 | 122284 | PASS |
| [tb_sys_cfg](../tb/tb_sys_cfg.v) | 核对配置写握手、读延迟和计数采样时刻。 | 19020433 | 717644 | PASS |
| [tb_sys_reset](../tb/tb_sys_reset.v) | 传输途中复位，核对旧残帧不混入新交付。 | 10177297 | 3844 | PASS |
| [tb_sys_ovf](../tb/tb_sys_ovf.v) `RX_RING_AW=9` | 完整系统接收缓存溢出时，核对丢弃、计数和恢复。 | 8881779 | 1550 | PASS |
| [tb_sys_net](../tb/tb_sys_net.v) | 通过顶层执行配置、正常及异常传输，供网表对照。 | 2792795 | 1307 | PASS |
| [tb_sys_perf](../tb/tb_sys_perf.v) | 测量注入吞吐、R119 时延、R119-2 抖动和反压。 | 683383807 | 1309214 | PASS |
| [tb_sys_rtc](../tb/tb_sys_rtc.v) | 核对空载及有流量时的时钟同步、秒边界和交付。 | 10675841 | 1811 | PASS |
| [tb_sys_snmp](../tb/tb_sys_snmp.v) | 核对查询、团体名和编码边界，并比较配置口读值。 | 37611 | 926 | PASS |
| [tb_sys_snmp_settrap](../tb/tb_sys_snmp_settrap.v) | 核对设置、非法写入拒绝、启动和认证失败通知。 | 8563 | 188 | PASS |
| [tb_sys_615a](../tb/tb_sys_615a.v) | 核对加载卸载、文件内容、校验错误和丢包重试。 | 44098 | 752 | PASS |
| [tb_gbe_burst](../tb/tb_gbe_burst.v) `COUNT=77` | 同时提交多链路消息，测量排队时间并逐字节查重。 | 530765 | — | PASS |
| [tb_gbe_burst](../tb/tb_gbe_burst.v) `COUNT=81` | 同时提交多链路消息，测量排队时间并逐字节查重。 | 554697 | — | PASS |
| [tb_rm_phase](../tb/tb_rm_phase.v) | 跨粗计时边界并交换处理顺序，核对去重和老化。 | 353130 | — | PASS |
| [tb_rtc_recovery](../tb/tb_rtc_recovery.v) | 丢弃同步回应并交换使能顺序，核对重发恢复。 | 28 | — | PASS |
| [tb_rtc_originate](../tb/tb_rtc_originate.v) | 错误或过期的请求时间不得校时，合法回应仍能同步。 | 34 | — | PASS |
| [tb_judge_capacity](../tb/tb_judge_capacity.v) | 配置全部收发链路，逐字节核对双网只交付一次。 | 49924 | — | PASS |
| [tb_judge_snmp](../tb/tb_judge_snmp.v) | 解码查询、设置和通知，核对字段与配置口读值。 | 699 | — | PASS |
| [tb_elinx](../tb/tb_elinx.v) | 由界面入口运行双端双网互发，核对字节、端口和去重。 | 9238 | — | PASS |
| [tb_sys_perf_var](../tb/tb_sys_perf_var.v) | 变长帧、多虚拟链路并发、注入吞吐与 R119 时延检查。 | 1254269621 | 1680167 | PASS |
| [tb_top_wrap](../tb/tb_top_wrap.v) | 核对应用字节流封装、VLID 查找与整条消息交付。 | 12284 | — | PASS |

本次 CE2 40/40、评委 8/8 通过，原始输出见 [judge_result.txt](../sim/reference/judge_result.txt)。

| 入口用例 | 自检项数 | 结果 |
|---|---:|---|
| services | 1122 | PASS |
| capacity | 49924 | PASS |
| snmp | 699 | PASS |
| burst77 | 530765 | PASS |
| burst81 | 554697 | PASS |
| rtc | 10675841 | PASS |
| performance | 683383807 | PASS |
| perf_var | 1254269621 | PASS |

F1b 已修正 `SYS_TOP_NETLIST` 下的公开输入消息观测和双网接收来源观测。RTL＋宏及同一 F1 V2 官方 VQM 的 `tb_sys_net` 均通过 2,792,645 项自检、0 错误，独立核对 88/88（含 16 项固定检查和 72 项帧级检查）；Error/Fatal/Warning/FAIL/RAMCOLL 均为 0。仅宏内显式跳过以私有核心末次握手为起点的两项 96 拍时限检查，保留结果对应、容量、顺序、原主机/排空期限和外部逐字节核对。无宏 CE1/CE2 的有效预处理 HDL 逐字节一致；原始预处理输出的行号指令和空白行单独保留。原始失败、超时和控制脚本错误保留于 [前序失败证据](evidence/t63_f1_sys_net_failure.json)，本次通过证据及边界见 [F1b 补验](evidence/t63_f1b_sys_net_pass.json)。

### 历史代码覆盖率（T57）

以下为 T57 的历史覆盖率记录：CE2 39 项用例、24 个 RTL 文件、39 个 UCDB，按 `sbceft` 插桩，测试平台不计入。F1 本轮未重跑覆盖率，不能将该表作为当前 29 个 RTL 文件的覆盖率结果。各统计类别的口径和原始报告保持原记录。

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

## 综合资源占比与模块分工

当前官方综合来自 F1 源重建；用量和占比由 [F1 资源报告](evidence/t63_f1_synthesis_resources.rpt) 计算，完整布局及约束一致性见 [F1 时序证据](evidence/t63_f1_timing.json)。

| 项目 | 当前官方结果 |
|---|---:|
| 查找表（LUT） | 39895 / 136160（29.30%） |
| 触发器（FF） | 20885 / 136160（15.34%） |
| 可配置逻辑块（CLB） | 5136 / 13616（37.72%） |
| 存储器（M4K） | 404 / 1200（33.67%） |
| 用户引脚 | 172 / 339（50.74%） |
| DSP / PLL | 0 / 0 |

以下分模块数据是 2026-10-15 归档，模块边界与当前 29 个 RTL 文件不同，不作为本轮分模块资源。数据取 [历史层次报告](evidence/history/gui_hierarchy_20261015.rpt) 的 `Resource Utilization by Entity` 表（第 366–458 行）。同类模块的实例合并，数字包含子模块，父子行不可相加。存储单位是有效位数，不是物理块数；存储器包装模块的数已包含在调用它的模块中。
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

以下为本次 F1 同一版本的完整窗口测量；Tcl/Python 的 1784（定长）、20576（变长）、2572（默认应用）个字段均一致。时间单位 µs，吞吐单位 Mbps。

| 工况 | 方向 | 注入 | 主时延首/末 | 抖动（VL/帧长，帧号） | 反压拍/最长 | 落后拍 | L_gmii | L_tx | L_rx首/末 | L_app首/末 |
|---|---|---:|---|---|---:|---:|---:|---:|---|---|
| gbe77_d0 | es1_to_es2 | 906.136 | 36.512/48.288 | 0.008（5/1471，1160→2392） | 0/0 | 2 | 0.000 | 12.312 | 12.440/24.200 | 24.752/36.512 |
| gbe77_d0 | es2_to_es1 | 906.136 | 36.512/48.288 | 0.008（3/1471，698→1006） | 0/0 | 2 | 0.000 | 12.312 | 12.440/24.200 | 24.752/36.512 |
| gbe77_d257 | es1_to_es2 | 906.136 | 38.568/50.344 | 0.008（51/1471，2977→4132） | 0/0 | 2 | 2.056 | 12.312 | 12.440/24.200 | 26.808/38.568 |
| gbe77_d257 | es2_to_es1 | 906.136 | 38.568/50.344 | 0.008（49/1471，2515→2746） | 0/0 | 2 | 2.056 | 12.312 | 12.440/24.200 | 26.808/38.568 |
| var_burst_d0 | es1_to_es2 | 57.794 | 49.760/61.520 | 0.000（0/1，8561→8561） | 0/0 | 2 | 0.000 | 38.320 | 12.432/24.192 | 49.752/49.760 |
| var_burst_d0 | es2_to_es1 | 57.794 | 49.760/61.520 | 0.008（0/1，8561→9161） | 0/0 | 2 | 0.000 | 38.320 | 12.432/24.192 | 49.752/49.760 |
| var_burst_d257 | es1_to_es2 | 57.794 | 51.816/63.576 | 0.000（0/1，9761→9761） | 0/0 | 2 | 2.056 | 38.320 | 12.432/24.192 | 51.808/51.816 |
| var_burst_d257 | es2_to_es1 | 57.794 | 51.816/63.576 | 0.000（0/1，9761→9761） | 0/0 | 2 | 2.056 | 38.320 | 12.432/24.192 | 51.808/51.816 |
| var_cycle_d0 | es1_to_es2 | 70.403 | 36.504/48.280 | 19.536（25/256，2666→3266） | 0/0 | 2 | 0.000 | 24.072 | 12.432/24.192 | 24.872/36.504 |
| var_cycle_d0 | es2_to_es1 | 70.403 | 36.504/48.280 | 19.536（25/256，2666→3266） | 0/0 | 2 | 0.000 | 24.072 | 12.432/24.192 | 24.872/36.504 |
| var_cycle_d257 | es1_to_es2 | 70.403 | 38.560/50.336 | 19.536（25/256，3866→4466） | 0/0 | 2 | 2.056 | 24.072 | 12.432/24.192 | 26.928/38.560 |
| var_cycle_d257 | es2_to_es1 | 70.403 | 38.560/50.336 | 19.536（25/256，3866→4466） | 0/0 | 2 | 2.056 | 24.072 | 12.432/24.192 | 26.928/38.560 |
| var_fixed_d0 | es1_to_es2 | 57.794 | 36.504/48.280 | 0.000（0/1，241→241） | 0/0 | 2 | 0.000 | 12.312 | 12.432/24.192 | 24.744/36.504 |
| var_fixed_d0 | es2_to_es1 | 57.794 | 36.504/48.280 | 0.008（13/1024，254→1134） | 0/0 | 2 | 0.000 | 12.312 | 12.432/24.192 | 24.744/36.504 |
| var_fixed_d257 | es1_to_es2 | 57.794 | 38.560/50.336 | 0.000（0/1，1441→1441） | 0/0 | 2 | 2.056 | 12.312 | 12.432/24.192 | 26.800/38.560 |
| var_fixed_d257 | es2_to_es1 | 57.794 | 38.560/50.336 | 0.008（28/1024，1469→2189） | 0/0 | 2 | 2.056 | 12.312 | 12.432/24.192 | 26.800/38.560 |
| var_high_d0 | es1_to_es2 | 904.752 | 36.512/48.288 | 0.008（41/1471，5002→6202） | 0/0 | 2 | 0.000 | 23.872 | 12.440/24.200 | 35.808/36.512 |
| var_high_d0 | es2_to_es1 | 904.752 | 36.512/48.288 | 0.008（71/1471，5032→6472） | 0/0 | 2 | 0.000 | 23.872 | 12.440/24.200 | 35.808/36.512 |
| var_high_d257 | es1_to_es2 | 904.752 | 38.568/50.344 | 0.008（15/1471，6736→6896） | 0/0 | 2 | 2.056 | 23.872 | 12.440/24.200 | 37.864/38.568 |
| var_high_d257 | es2_to_es1 | 904.752 | 38.568/50.344 | 0.008（45/1471，6766→7166） | 0/0 | 2 | 2.056 | 23.872 | 12.440/24.200 | 37.864/38.568 |

gbe77 的主时延最大 48.288/50.344 µs（链路 0/257 拍），20 个窗口的最大值为 63.576 µs。R119-2 抖动最大 19.536 µs，位于 var_cycle_d0、es1_to_es2、VL25、256 字节，帧 2666→3266。var_burst 的计划释放→首/末字节最大 185.760/185.888 µs，释放口径抖动最大 0.008 µs。释放口径包含主机串行注入排队，与从首字节 valid 起算的主口径分开报告。逐方向原值见 `证据/perf_r97.json:main_table/jitter_r119_top/burst_release_analysis`。

`sim/run_app.do` 默认激励为 84 条消息、21 条 VL，载荷覆盖 1/17/256/1024/1471 字节，窗口为相对激励起点的 1–4 ms。本轮注入 210.440 Mbps，L_entry_last / L_entry_first 最大 60.584 / 48.808 µs，同 VL、同帧长抖动最大 15.200 µs（VL18 / 256 字节）；反压 0 拍、最长连续 0 拍，相对计划释放拍的注入落后最大 1351 拍，丢帧/重复/溢出均为 0，`APP ENTRY PASS`。小激励的五条消息已逐条核对通过；它未设稳定吞吐窗口，速率只报告。两种激励的原始汇总见 `sim/reference/app_result.json`。Tcl/Python 在同一默认激励记录上逐字段一致，来源为 `证据/perf_r97.json:application_entry/equivalence`。

原始值及 A/B、逐载荷分组见 `证据/perf_r97.json`。注入落后仅在 var_burst 扣除主机串行排队，其他工况相对计划释放；`raw_lag_max_cycles` 保留原始计划偏差。

## 综合后最慢路径

以下为本轮未布局布线的综合估算，不能代替布线后签核。

| 起点 → 终点 | 级数 | 逻辑 ns | setup ns |
|---|---:|---:|---:|
| `\afdx_es:es\|afdx_615a:loader\|afdx_ram_sdp:denial_ram\|altsyncram:memory_rtl_0\|altsyncram_1bd1:auto_generated\|ram_block1a0~I\|port_b_address_dff[0]/Q` → `\afdx_es:es\|afdx_615a:loader\|afdx_mgmt_tx:sender\|bytes_rtl_0_bypass[7]~I\|ff/D` | 2 | 3.108 | +4.148 |

### 本轮布线后全量时序

当前 F1 的 RTL 与 r5 A `18d1606c` 零差异；原 V1/V2 验证提交为 `t63@92ab7d7e`，F1b 在 `67d2e618` 基础上仅修正宏内测试观测。**V1 功能终验通过**：模块及整顶层网表清单 8/8 PASS，`tb_sys_net` 自检与独立核对通过；V2 时序复核通过，真实 GUI 待用户复跑。器件 EQ6HL130、封装 CSG484_H，主时钟 125 MHz（8.000 ns），CE_DIV=2。采用 PRES 1.30 和固定布局后，全部 53,882 个端点 setup/hold 均为 0 失败，最差余量为 +0.016 / +0.229 ns；setup 已含 0.30 ns 时钟不确定度。原始精度为 +16 / +229 ps，门槛按原始精度判定。

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

`elinx/constraints.edc` 包含 PRES 1.30、172 条 P0 管脚语句和 5,540 条簇位置语句；固定布局来自 C0 布局加局部手工微调。**改 RTL 会使布局失效**，必须重新生成并验证位置约束。界面工程登记 `physical_only.edc` 与 `timing_only.sdc`，两者拼接与完整 EDC 一致；物理语句经 Tcl `source`，纯时序部分经 `read_sdc`，0.30 ns uncertainty 与已批准多周期约束保持不变。

最差十条原生路径，取自本轮全量 SQLite 时序库：

| 起点 → 终点 | 级数 | 逻辑 ns | 连线 ns | setup ns |
|---|---:|---:|---:|---:|
| `\es\|rtc\|rx_packet[140]~I\|ff/Q` → `\es\|rtc\|reply_frac_match~I\|ff/D` | 4 | 1.573 | 6.036 | +0.016 |
| `\es\|cfg_regs\|cfg_ready~I\|ff/Q` → `\es\|cfg_regs\|user_id[8]~I\|ff/ena` | 4 | 1.650 | 5.859 | +0.021 |
| `\es\|cfg_regs\|cfg_ready~I\|ff/Q` → `\es\|cfg_regs\|user_id[9]~I\|ff/ena` | 4 | 1.650 | 5.859 | +0.021 |
| `\es\|rx_core\|map_group_data[80]~I\|ff/Q` → `\es\|rx_core\|map_q_r[2]~I\|ff/D` | 3 | 1.473 | 6.129 | +0.023 |
| `\es\|rx_core\|init_done~I\|ff/Q` → `\es\|rx_core\|engine\|op_idx[8]~I\|ff/D` | 3 | 1.403 | 6.196 | +0.026 |
| `\es\|rx_core\|init_done~I\|ff/Q` → `\es\|rx_core\|engine\|state_ra[8]~I\|ff/D` | 3 | 1.403 | 6.196 | +0.026 |
| `\es\|cfg_regs\|receive_bus[0].bank_ready_q~I\|ff/Q` → `\es\|cfg_regs\|receive_bus[0].address[1]~I\|ff/ena` | 2 | 0.950 | 6.553 | +0.027 |
| `\es\|cfg_regs\|receive_bus[0].bank_ready_q~I\|ff/Q` → `\es\|cfg_regs\|receive_bus[0].address[8]~I\|ff/ena` | 2 | 0.950 | 6.553 | +0.027 |
| `\es\|cfg_regs\|receive_bus[0].bank_ready_q~I\|ff/Q` → `\es\|cfg_regs\|receive_bus[0].address[15]~I\|ff/ena` | 2 | 0.950 | 6.553 | +0.027 |
| `\es\|cfg_regs\|receive_bus[0].bank_ready_q~I\|ff/Q` → `\es\|cfg_regs\|receive_bus[0].address[7]~I\|ff/ena` | 2 | 0.950 | 6.553 | +0.027 |

本次 F1 官方重建 VQM 与同次 RTL 的 `tb_net_services` 均通过 1122 项自检，Error/FAIL/RAMCOLL 均为 0；网表独立检查 65 项，七份外部记录逐字节一致。网表使用本卡 V2 的 VQM，不含布线延迟；证据见 `evidence/t63_f1_functional.json` 的 `services_netlist`。

## 设计默认参数

下表按当前顶层默认例化计算；容量的 KiB 按 1024 字节换算。改测试参数后的容量不可套用此表。

| 参数或容量 | 默认数值与含义 | 源码出处 |
|---|---|---|
| 发送负载缓冲 | 256 页 × 512 字节 = 131072 字节（128 KiB），双网共用一份负载。 | `AFDX_top.v` 的默认参数 `TX_PAGE_AW=8/TX_OFF_AW=9`；`afdx_tx_core.v:45,162` 的 `PAGES/PAYLOAD_DEPTH/tx_payload` |
| 发送描述与链表 | 消息描述 256 项×44 位；消息链和页链分别 256 项×8 位；空闲页池 256 页。 | `afdx_tx_core.v:133–162`；`afdx_tx_free.v` 的 `PAGES` |
| 接收字节环 | A、B 网各 4096 字节（各 4 KiB）。 | `AFDX_top.v` 的默认参数 `RX_RING_AW=12`；`afdx_rx_core.v:174,183` |
| 接收描述队列 | 共用 32 项，每项 68 位；按 `2**RX_DQ_AW` 和 `RX_RING_AW+56` 计算。 | `AFDX_top.v` 的默认参数及核心例化；`afdx_rx_core.v:66–88`；`afdx_rx_engine.v` 的 `DQ_DEPTH` |
| 虚拟链路容量 | 每端发送 128 条、接收 4096 条；接收映射表 65536 项×13 位。 | `afdx_tx_core.v:115,124`；`afdx_rx_core.v:145–163` |
| 复位后初始化 | 本轮 R→I 标记间隔 65540 拍，即 524.320 µs；R=5，I=65545。 | [F1 初始化观测](evidence/t63_f1_initialization.json)，原始 tb_sys_fault 日志。 |
| 工作节拍 | 共用 125 MHz 时钟，即每拍 8 ns；复位后每拍处理一个线路字节。 | `afdx_timebase.v` 的 `byte_en`；`AFDX_top.v` 的默认参数及核心例化；`fault_events.txt` 的 `G CLOCK_NS 8` |
| 帧间隔 | 12 拍，即 96 ns；末帧之后首个空闲拍加后续 11 拍。 | `afdx_mac_tx.v:35,176–186` 的 `gap_left` |
| 调度前瞻 | `LOOKAHEAD=512` 拍，即 4.096 µs；它是调度参数，不是实测端到端时延。 | `AFDX_top.v` 的默认参数及核心例化；`afdx_tx_engine.v` 的 `LOOKAHEAD` |
| 用户消息长度 | 每条最多 1471 字节，还受该链路配置的最大长度限制。 | `afdx_tx_buf.v:62,201` 的 `MAX_PAYLOAD` |
| 网络管理对象 | 简单网络管理协议（Simple Network Management Protocol，SNMP）共 36 个对象：2 个系统对象、34 个私有对象。 | `afdx_snmp.v:222–243,766` 的 `mib_arc/candidate` |
| 网络管理请求 | 请求缓存 256 字节，最多接收 256 字节；超过后不进入解析；每次处理 1 个变量绑定。 | `afdx_snmp.v:199–210,505–517` 的 `request_ram/rx_count/overflow`；报文解析状态机 |
| 数据加载存储 | 加载区 8192 字节（8 KiB），头文件区 2048 字节，加载请求区 512 字节；收发包缓存各 1024 字节。 | `afdx_615a.v:297–333` 的 `packet_rx/packet_tx/lur_ram/header_ram/load_ram` |
| 数据加载超时与重试 | 超时默认 250000000 拍（2 s），每次等待最多重发 1 次；初始请求另计。 | `afdx_615a.v:167,595–598,740–754` 的 `timeout_cycles/retry_limit/retries` |
| 数据加载默认协议 | 请求端口 59，协议文件版本 A4；不是完整文件无限重试。 | `afdx_615a.v:167,595,598` 的 `request_port/protocol_a4` |
| 实时时钟分辨率 | 实时时钟（Real-Time Clock，RTC）每拍增加 8 ns，默认同步周期 125000 拍（1 ms）；分辨率不等于同步精度。 | `afdx_rtc.v:60–64,233,298–302` 的 `period/nanoseconds` |

上述源码文件均在 [rtl](../rtl/)；初始化的拍数是当前记录的观察值，其余容量和时间换算由所列参数直接计算。

## 代码规模

按当前已跟踪文本统计，包含注释、空行；不含 `sim/reference/` 和 PNG。工具目录还计入本次新增的 GUI 比对脚本。

| 目录 | 文件数 | 物理行数 |
|---|---:|---:|
| `rtl/` | 29 | 13030 |
| `tb/` | 58 | 4813 |
| `tools/` | 62 | 11379 |
| `sim/` | 26 | 4220 |

## 异常注入与计数器读回

以下为历史专项注入记录，保留原始数字与日期；当前 F1 终验另见本页首表及 `证据/t63_f1_functional.json`。下表的 A/B 数值分别对应两网；“每端”表示两个端系统各自均读到该值，不能再合并成单端值。寄存器地址为十六进制，读回以 `sys_events.txt` 原记录的 `V` 行为准。
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
