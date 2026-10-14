# AFDX 端系统补充数据

源码统计基线为 `5019fb7a`；本页只整理已有源码、综合报告和仿真记录，没有重新综合或仿真。功能与测量边界见 [事实清单](FACTS.md)。下文“证据”均指 [evidence](evidence/)；新增原件的来源、字节数和 SHA-256 摘要见 [manifest.json](evidence/manifest.json)。时延均为仿真值，综合时序不含布线延迟。

## 逐项回归与评委入口

下表按 [sim/tests.txt](../sim/tests.txt) 排列；说明来自各测试平台开头的注释，数字取 [regression.json](evidence/regression.json) 的 `Runs[].Checks/CheckItems/Status`。独立项为“—”表示该汇总没有单独项数，不能据此断言没有独立检查。

| 测试名及非默认参数 | 测什么 | 自检项数 | 独立核对项数 | 结果 |
|---|---|---:|---:|---|
| [tb_ram_sdp](../tb/tb_ram_sdp.v) | 核对不同存储器配置的写入、同步读取和读使能。 | 20764 | — | PASS |
| [tb_mac_tx](../tb/tb_mac_tx.v) | 核对以太网组帧、帧间隔和上游缺字节处理。 | 264649 | — | PASS |
| [tb_mac_rx](../tb/tb_mac_rx.v) | 核对正常帧、错误分类、去校验值和帧边界。 | 105303 | — | PASS |
| [tb_mac_loop](../tb/tb_mac_loop.v) | 发送端接回接收端，核对不同帧长与双网内容。 | 1385254 | — | PASS |
| [tb_tx_basic](../tb/tb_tx_basic.v) | 核对不同消息长度的分页存储、协议头与双网发送。 | 662055 | 7605 | PASS |
| [tb_tx_basic](../tb/tb_tx_basic.v) `TX_PAGE_AW=5,TX_OFF_AW=11` | 核对不同消息长度的分页存储、协议头与双网发送。 | 661635 | 7605 | PASS |
| [tb_tx_bag](../tb/tb_tx_bag.v) | 核对带宽间隔、计数回绕和发送间隔变化。 | 14054170 | 14591 | PASS |
| [tb_tx_multi](../tb/tb_tx_multi.v) | 核对多条虚拟链路的队列、轮询与网络选择。 | 14438575 | 56211 | PASS |
| [tb_tx_drop](../tb/tb_tx_drop.v) | 核对禁用、队满、超长、无空闲页及失败后的页回收。 | 30267256 | 4642 | PASS |
| [tb_tx_net](../tb/tb_tx_net.v) | 用固定输入核对发送内容和事件，供网表对照。 | 219313 | 229 | PASS |
| [tb_rx_basic](../tb/tb_rx_basic.v) | 核对接收映射、不同消息长度、用户数据与端口。 | 9960369 | 123855 | PASS |
| [tb_rx_fault](../tb/tb_rx_fault.v) | 损坏校验值、长度、报头和配置，核对拒绝原因。 | 576923 | 890 | PASS |
| [tb_rx_icrm](../tb/tb_rx_icrm.v) | 核对序号规则、回绕和两网到达时间差边界。 | 4635288 | 1274 | PASS |
| [tb_rx_load](../tb/tb_rx_load.v) | 大量虚拟链路接收时，核对序号隔离和冗余去重。 | 6406189 | 19180 | PASS |
| [tb_rx_ovf_ring](../tb/tb_rx_ovf_ring.v) `RX_RING_AW=9` | 缩小字节缓存，核对溢出回退和后续接收恢复。 | 422837 | 99 | PASS |
| [tb_rx_ovf_dq](../tb/tb_rx_ovf_dq.v) `RX_DQ_AW=1` | 缩小交付队列，核对队满丢帧和释放后恢复。 | 373852 | 57 | PASS |
| [tb_rx_net](../tb/tb_rx_net.v) | 用固定正常及异常输入核对接收输出，供网表对照。 | 374111 | 110 | PASS |
| [tb_sys_basic](../tb/tb_sys_basic.v) | 两个完整端系统互发消息，核对交付与事件。 | 5155148 | 2896 | PASS |
| [tb_sys_fault](../tb/tb_sys_fault.v) | 在线路上丢帧、重放及损坏字节，核对检测和恢复。 | 47117674 | 8726 | PASS |
| [tb_sys_delay](../tb/tb_sys_delay.v) | 改变两网延迟，核对交付、去重和端到端时延。 | 15481734 | 3763 | PASS |
| [tb_sys_load](../tb/tb_sys_load.v) | 多链路同时传输，核对交付、发送间隔和配置隔离。 | 216810445 | 116677 | PASS |
| [tb_sys_cfg](../tb/tb_sys_cfg.v) | 核对配置写握手、读延迟和计数采样时刻。 | 21167623 | 714342 | PASS |
| [tb_sys_reset](../tb/tb_sys_reset.v) | 传输途中复位，核对旧残帧不混入新交付。 | 10991314 | 3682 | PASS |
| [tb_sys_ovf](../tb/tb_sys_ovf.v) `RX_RING_AW=9` | 完整系统接收缓存溢出时，核对丢弃、计数和恢复。 | 9681100 | 1488 | PASS |
| [tb_sys_net](../tb/tb_sys_net.v) | 通过顶层执行配置、正常及异常传输，供网表对照。 | 2943996 | 1265 | PASS |
| [tb_sys_perf](../tb/tb_sys_perf.v) | 测量吞吐、发送与接收时延、端到端时延和抖动。 | 756575324 | 1212916 | PASS |
| [tb_sys_rtc](../tb/tb_sys_rtc.v) | 核对空载及有流量时的时钟同步、秒边界和交付。 | 10675857 | 1811 | PASS |
| [tb_sys_snmp](../tb/tb_sys_snmp.v) | 核对查询、团体名和编码边界，并比较配置口读值。 | 37611 | 926 | PASS |
| [tb_sys_snmp_settrap](../tb/tb_sys_snmp_settrap.v) | 核对设置、非法写入拒绝、启动和认证失败通知。 | 8563 | 188 | PASS |
| [tb_sys_615a](../tb/tb_sys_615a.v) | 核对加载卸载、文件内容、校验错误和丢包重试。 | 44098 | 752 | PASS |
| [tb_gbe_burst](../tb/tb_gbe_burst.v) `COUNT=77` | 同时提交多链路消息，测量排队时间并逐字节查重。 | 643550 | — | PASS |
| [tb_gbe_burst](../tb/tb_gbe_burst.v) `COUNT=81` | 同时提交多链路消息，测量排队时间并逐字节查重。 | 673498 | — | PASS |
| [tb_rm_phase](../tb/tb_rm_phase.v) | 跨粗计时边界并交换处理顺序，核对去重和老化。 | 353130 | — | PASS |
| [tb_rtc_recovery](../tb/tb_rtc_recovery.v) | 丢弃同步回应并交换使能顺序，核对重发恢复。 | 28 | — | PASS |
| [tb_rtc_originate](../tb/tb_rtc_originate.v) | 错误或过期的请求时间不得校时，合法回应仍能同步。 | 34 | — | PASS |
| [tb_judge_capacity](../tb/tb_judge_capacity.v) | 配置全部收发链路，逐字节核对双网只交付一次。 | 49924 | — | PASS |
| [tb_judge_snmp](../tb/tb_judge_snmp.v) | 解码查询、设置和通知，核对字段与配置口读值。 | 699 | — | PASS |
| [tb_elinx](../tb/tb_elinx.v) | 由界面入口运行双端双网互发，核对字节、端口和去重。 | 9238 | — | PASS |

纯 ModelSim 入口 `do sim/run_judge.do` 的独立一次记录见 [judge_result.txt](evidence/judge_result.txt)：以下各例错误数和 Warning 数均为 0；该入口未单列独立核对项数，总结果为 `PASS cases=7`。

| 入口用例 | 测试平台与目的 | 自检项数 | 独立核对项数 | 结果 |
|---|---|---:|---:|---|
| `services` | tb_net_services：用户收发、网络管理、时钟同步和文件加载卸载。 | 1123 | — | PASS |
| `capacity` | tb_judge_capacity：每端发送 128 条、配置接收 4096 条虚拟链路。 | 49924 | — | PASS |
| `snmp` | tb_judge_snmp：查询、设置和通知的报文字段与读回值。 | 699 | — | PASS |
| `burst77` | tb_gbe_burst：77 条虚拟链路同时提交消息。 | 643550 | — | PASS |
| `burst81` | tb_gbe_burst：81 条虚拟链路同时提交消息。 | 673498 | — | PASS |
| `rtc` | tb_sys_rtc：空载及有流量时的同步误差。 | 10675857 | — | PASS |
| `performance` | tb_sys_perf：吞吐、时延和发送抖动。 | 756575324 | — | PASS |

## 综合资源占比与模块分工

界面综合的用量来自 [gui_resources.rpt](evidence/gui_resources.rpt)；EQ6HL130/CSG484_H 的器件总量取 [device_capacity.rpt](evidence/device_capacity.rpt) 各行斜线后的数。这里只借用器件容量，不把其中的布局后用量混进综合结果。比例按“综合用量 ÷ 总量”计算，四舍五入到小数点后两位。

| 资源 | 界面综合用量 | 器件总量 | 占比 |
|---|---:|---:|---:|
| 查找表（Lookup Table，LUT） | 32847 | 136160 | 24.12% |
| 触发器（Flip-Flop，FF） | 13869 | 136160 | 10.19% |
| 可配置逻辑块（Configurable Logic Block，CLB） | 4626 | 13616 | 33.97% |
| 存储块（Memory） | 340 | 1200 | 28.33% |
| 数字信号处理单元（Digital Signal Processing，DSP） | 0 | 48 | 0.00% |
| 锁相环（Phase-Locked Loop，PLL） | 0 | 8 | 0.00% |
| 用户引脚 | 259 | 339 | 76.40% |

分模块数据取 [gui_hierarchy.rpt](evidence/gui_hierarchy.rpt) 的 `Resource Utilization by Entity` 表（第 366–458 行）。同类模块的实例合并，数字包含子模块，父子行不可相加。存储单位是有效位数，不是物理块数；存储器包装模块的数已包含在调用它的模块中。
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

README 的命令行 LUT 29962 来自 [cli_resources.rpt](evidence/cli_resources.rpt) 的 `Total LUTs`；事实清单的 29961 来自 [cli_synthesis_summary.json](evidence/cli_synthesis_summary.json) 的 `lcells`。二者分别统计 LUT 和网表逻辑单元，不是笔误，不互相替换。

## 各工况的时延细分

数据来自 [performance.json](evidence/performance.json) 的 `reports.system.performance.<阶段>.directions.<方向>`；取 `T_tx`、`T_rx`、`T_e2e_link_removed` 的 `max_us/mean_us`。单位均为 µs，每格为“最大值 / 平均值”，均值保留六位小数。
发送侧从应用提交末字节量到线路首字节；接收侧从收到线路末字节量到应用交付末字节；端到端从提交末字节量到交付末字节，只扣设定的线路延迟。三列不能直接相加，线路串行发送时间仍在端到端一列内（[perf_ref.py](../tools/perf_ref.py) 第 87–106 行）。
`d0/d257` 表示线路延迟 0/257 拍，时钟周期 8 ns；`light` 为单链路轻载，`throughput/duplex` 为 10 条链路的单向/双向工况，`gbe77/gbe81` 为 77/81 条链路双向工况。重载各条消息为 1471 字节、带宽间隔 1 ms，预热后测量 21 ms；来源同上各方向的 `vls` 与 `measured_ms`，输入约束见 `perf_ref.py` 第 15–54 行。

| 阶段 | 方向 | 样本数 | 发送侧 最大 / 平均 | 接收侧 最大 / 平均 | 端到端 最大 / 平均 |
|---|---|---:|---:|---:|---:|
| `light_d0` | 端1→端2 | 40 | 0.296 / 0.257600 | 11.952 / 3.412800 | 24.400 / 7.356800 |
| `light_d0` | 端2→端1 | 40 | 0.296 / 0.257600 | 11.952 / 3.412800 | 24.400 / 7.356800 |
| `light_d257` | 端1→端2 | 40 | 0.296 / 0.257600 | 11.952 / 3.412800 | 24.400 / 7.356800 |
| `light_d257` | 端2→端1 | 40 | 0.296 / 0.257600 | 11.952 / 3.412800 | 24.400 / 7.356800 |
| `throughput_d0` | 端1→端2 | 210 | 0.248 / 0.248000 | 11.960 / 11.952038 | 24.408 / 24.400038 |
| `duplex_d0` | 端1→端2 | 210 | 0.248 / 0.248000 | 11.952 / 11.952000 | 24.400 / 24.400000 |
| `duplex_d0` | 端2→端1 | 210 | 0.248 / 0.248000 | 11.960 / 11.952038 | 24.408 / 24.400038 |
| `throughput_d257` | 端1→端2 | 210 | 0.248 / 0.248000 | 11.960 / 11.952038 | 24.408 / 24.400038 |
| `duplex_d257` | 端1→端2 | 210 | 0.248 / 0.248000 | 11.952 / 11.952000 | 24.400 / 24.400000 |
| `duplex_d257` | 端2→端1 | 210 | 0.248 / 0.248000 | 11.960 / 11.952038 | 24.408 / 24.400038 |
| `gbe77_d0` | 端1→端2 | 1617 | 0.248 / 0.248000 | 11.960 / 11.952005 | 24.408 / 24.400005 |
| `gbe77_d0` | 端2→端1 | 1617 | 0.248 / 0.248000 | 11.960 / 11.952010 | 24.408 / 24.400010 |
| `gbe77_d257` | 端1→端2 | 1617 | 0.248 / 0.248000 | 11.960 / 11.952010 | 24.408 / 24.400010 |
| `gbe77_d257` | 端2→端1 | 1617 | 0.248 / 0.248000 | 11.960 / 11.952010 | 24.408 / 24.400010 |
| `gbe81_d0` | 端1→端2 | 1701 | 0.248 / 0.248000 | 11.952 / 11.952000 | 24.400 / 24.400000 |
| `gbe81_d0` | 端2→端1 | 1701 | 0.248 / 0.248000 | 11.952 / 11.952000 | 24.400 / 24.400000 |
| `gbe81_d257` | 端1→端2 | 1701 | 0.248 / 0.248000 | 11.952 / 11.952000 | 24.400 / 24.400000 |
| `gbe81_d257` | 端2→端1 | 1701 | 0.248 / 0.248000 | 11.952 / 11.952000 | 24.400 / 24.400000 |

轻载按长度分组如下。两种线路延迟、两个方向的发送侧和端到端结果相同，每组各有 8 个样本；对应 `light_groups.<长度>`。该分组没有保存 `T_rx`，接收侧按长度的最大值和均值均为未测，不能用总体最大值相减补出。

| 用户消息字节数 | 发送侧 最大 / 平均（µs） | 接收侧 最大 / 平均 | 端到端 最大 / 平均（µs） |
|---|---:|---|---:|
| 1 | 0.296 / 0.296000 | 未测 / 未测 | 1.056 / 1.056000 |
| 17 | 0.248 / 0.248000 | 未测 / 未测 | 1.136 / 1.136000 |
| 18 | 0.248 / 0.248000 | 未测 / 未测 | 1.152 / 1.152000 |
| 511 | 0.248 / 0.248000 | 未测 / 未测 | 9.040 / 9.040000 |
| 1471 | 0.248 / 0.248000 | 未测 / 未测 | 24.400 / 24.400000 |

## 综合后最慢路径

在 [界面时序库](evidence/gui_synthesis_timing.pb) 和 [命令行时序库](evidence/cli_synthesis_timing.pb) 中以只读方式执行 SQL：`SELECT * FROM elinx_intra_clock_longest_sync_path_report ORDER BY slack, path_id LIMIT 1;`，按最小建立裕量选路径。延迟和裕量字段单位为 ps，表内换算为 ns。两条路径的 `net_delay` 均为 0，不能用来证明布线后能运行在该频率。

| 综合方式 | 模块与路径起点 → 终点 | 逻辑级数 | 逻辑延迟（ns） | 建立裕量（ns） |
|---|---|---:|---:|---:|
| 界面 | `afdx_615a:loader`；`name_pos[1]~I\|ff/Q` → `packet_type[1]~I\|ff/D` | 15 | 5.403 | +2.522 |
| 命令行 | `afdx_snmp:snmp`；`cursor[0]` → `state[1]` | 23 | 5.176 | +2.749 |

命令行库中的起终点为 `c3_native_cell_9490|ff/Q` 和 `c3_native_cell_10117|ff/D`；命令行综合网表里这两个单元的例化（摘录见 [cli_design_excerpt.txt](evidence/cli_design_excerpt.txt)）通过 `regout` 将其对应到上表寄存器。这是综合后的单元路径，不是源码行间的执行顺序。

## 设计默认参数

下表按当前顶层默认例化计算；容量的 KiB 按 1024 字节换算。改测试参数后的容量不可套用此表。

| 参数或容量 | 默认数值与含义 | 源码出处 |
|---|---|---|
| 发送负载缓冲 | 256 页 × 512 字节 = 131072 字节（128 KiB），双网共用一份负载。 | `AFDX_top.v:7–9` 的 `TX_PAGE_AW=8/TX_OFF_AW=9`；`afdx_tx_core.v:37,150` 的 `PAGES/PAYLOAD_DEPTH/tx_payload` |
| 发送描述与链表 | 消息描述 256 项×44 位；消息链和页链分别 256 项×8 位；空闲页池 256 页。 | `afdx_tx_core.v:122–150`；`afdx_tx_free.v` 的 `PAGES` |
| 接收字节环 | A、B 网各 4096 字节（各 4 KiB）。 | `AFDX_top.v:10` 的 `RX_RING_AW=12`；`afdx_rx_core.v:160,169` |
| 接收描述队列 | 共用 32 项，每项 68 位；按 `2**RX_DQ_AW` 和 `RX_RING_AW+56` 计算。 | `AFDX_top.v:11`；`afdx_rx_core.v:59–77`；`afdx_rx_engine.v` 的 `DQ_DEPTH` |
| 虚拟链路容量 | 每端发送 128 条、接收 4096 条；接收映射表 65536 项×13 位。 | `afdx_tx_core.v:104,113`；`afdx_rx_core.v:132–150` |
| 复位后初始化 | 解除复位到观察到顶层就绪相隔 65538 拍，即 524.304 µs；记录 `R 5`、`I 65543`。 | `afdx_rx_core.v:100–113` 清 65536 项后收尾，`AFDX_top.v:158–160` 注册就绪；[fault_rx_events.txt](evidence/fault_rx_events.txt) 第 4、6 行；其 `G CLOCK_NS` 在 [fault_events.txt](evidence/fault_events.txt) |
| 工作节拍 | 共用 125 MHz 时钟，即每拍 8 ns；复位后每拍处理一个线路字节。 | `afdx_timebase.v` 的 `byte_en`；`AFDX_top.v:163`；`fault_events.txt` 的 `G CLOCK_NS 8` |
| 帧间隔 | 12 拍，即 96 ns；末帧之后首个空闲拍加后续 11 拍。 | `afdx_mac_tx.v:155–165` 的 `gap_left` |
| 调度前瞻 | `LOOKAHEAD=512` 拍，即 4.096 µs；它是调度参数，不是实测端到端时延。 | `AFDX_top.v:9`；`afdx_tx_engine.v` 的 `LOOKAHEAD` |
| 用户消息长度 | 每条最多 1471 字节，还受该链路配置的最大长度限制。 | `afdx_tx_buf.v` 的长度检查 `1471` |
| 网络管理对象 | 简单网络管理协议（Simple Network Management Protocol，SNMP）共 36 个对象：2 个系统对象、34 个私有对象。 | `afdx_snmp.v:122–138,618` 的 `mib_arc/candidate` |
| 网络管理请求 | 请求缓存 256 字节，最多接收 256 字节；超过后不进入解析；每次处理 1 个变量绑定。 | `afdx_snmp.v:99–110,388–400` 的 `request_ram/rx_count/overflow`；报文解析状态机 |
| 数据加载存储 | 加载区 8192 字节（8 KiB），头文件区 2048 字节，加载请求区 512 字节；收发包缓存各 1024 字节。 | `afdx_615a.v:208–244` 的 `packet_rx/packet_tx/lur_ram/header_ram/load_ram` |
| 数据加载超时与重试 | 超时默认 250000000 拍（2 s），每次等待最多重发 1 次；初始请求另计。 | `afdx_615a.v:480–485,624–638` 的 `timeout_cycles/retry_limit/retries` |
| 数据加载默认协议 | 请求端口 59，协议文件版本 A4；不是完整文件无限重试。 | `afdx_615a.v:482,485` 的 `request_port/protocol_a4` |
| 实时时钟分辨率 | 实时时钟（Real-Time Clock，RTC）每拍增加 8 ns，默认同步周期 125000 拍（1 ms）；分辨率不等于同步精度。 | `afdx_rtc.v:191,255–259` 的 `period/nanoseconds` |

上述源码文件均在 [rtl](../rtl/)；初始化的拍数是当前记录的观察值，其余容量和时间换算由所列参数直接计算。

## 代码规模

统计所有已跟踪文本文件的物理行数，包含注释与空行，不算运行产物。`sim/` 包含固定向量及清单，因此该目录行数不等于脚本代码行数。以下命令在仓库根目录执行即可复算。

| 目录 | 文件数 | 物理行数 |
|---|---:|---:|
| `rtl/` | 21 | 6663 |
| `tb/` | 53 | 4090 |
| `tools/` | 21 | 4275 |
| `sim/` | 11 | 2740 |

```powershell
foreach ($dir in 'rtl','tb','tools','sim') {
  $files = @(git ls-files -- $dir)
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
