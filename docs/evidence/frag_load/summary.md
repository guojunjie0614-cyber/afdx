# 负载与混合压力边界记录

本文记录 81 VL 超规格压力探底、长短消息混合负载二分边界确定以及公开应用口时戳统计口径。后续最终 63 VL 满负载全套七场景验收见 [63 VL 验证汇总](../vl63_full_load/summary.md)，配置资源预算见 [ARCH.md](../../ARCH.md)。

## 1. 混合负载二分搜索与 81 VL 溢出边界

- **81 VL 混合溢出压力现象**：在 `81 VL` 满负载同时叠加长短消息混合的极限压力下，接收端于仿真时间 `3,604,444 ns`（第 `450,556` 拍，负载 `epoch = 68,006`，负载启动后 `382,550` 拍即 `3.0604 ms`）出现溢出标志 `ev_a = 0x80`、`ev_b = 0x01`、`ev_app = 0`。
- **混合负载二分定界**：在固定激励下用 `tools/run_load_search.py` 执行二分探底，20 ms 窗口内 `70 VL` 通过、`71 VL` 失败（详表见 [mixed_search.json](mixed_search.json)）；按留出约 10% 余量的原则将工程混合与满负载并发规格统一标定为 **63 TX / 63 RX VL**，并在 `100 ms` 长窗口下完成 `63 VL` 混合全量功能、逐字节完整性及 `<= 256` 页池预算验证（HDL/完整性通过、Python 与 Tcl 独立统计一致）。

## 2. 公开应用口时戳统计方法

- **测点定义**：自公开应用输入 `VLID` 首字节至接收端输出最后一字节，并单独记录输出首字节时戳；Python (`tools/run_load_sim.py`) 与 Tcl (`sim/load_stats.tcl`) 分别独立解析原始仿真记录按 VL 和载荷长度分组核算，交叉核对零偏差。
- **周期场景与 BAG 等待场景区分**：周期注入场景按 `最大 − 最小` 计抖动；背靠背连续发两帧场景（每 2 ms 发两帧最大载荷，长期平均仍 <= 每 BAG 一帧）按 `全程最大 − 首帧时延 − BAG` 计抖动，且要求每条 VL 第二条消息在前一帧 BAG 到期前输入完成、实际线上相邻帧间隔 >= BAG。
- **页池保守上界**：自应用输入首字节即预留整条消息所需 TX 页数，直至最后一个 GMII 分片线上传输结束才释放计入保守峰值，确认全场景均不超过 256 页。长消息（>1471 B）按整条消息完成时延单列，不直接套用单帧 2 ms 门槛。

## 3. 负载仿真与压测详表

### 周期与混合注入场景

逐 VL/载荷原始数据见 [periodic_metrics.tsv](periodic_metrics.tsv)，总吞吐见 [total_throughput.tsv](total_throughput.tsv)，汇总 JSON 见 [summary.json](summary.json)：

| 序号 | 场景配置 | HDL / 完整性 | 双统计一致 | 说明 |
|---|---|---|---|---|
| 0 | `GROUP_LENGTH=1471`（81 VL 压力） | PASS | 一致 | 周期最大抖动 `3.368 µs` |
| 1 | `GROUP_LENGTH=1471, MIXED=1`（81 VL 压力） | FAIL | 一致 | 3.0604 ms 触发 RX 溢出，确立 81 VL 混合上限 |
| 2 | `GROUP_LENGTH=1`（81 VL 压力） | PASS | 一致 | 短包极小载荷压力通过 |
| 3 | `GROUP_LENGTH=17`（81 VL 压力） | PASS | 一致 | 短包周期压力通过 |
| 4 | `GROUP_LENGTH=256`（81 VL 压力） | PASS | 一致 | 中包周期压力通过 |
| 5 | `GROUP_LENGTH=1024`（81 VL 压力） | PASS | 一致 | 大包周期压力通过 |
| mixed_profile | `VL_COUNT=63, MIXED=1, DURATION=12500000` | PASS | 一致 | 63 VL 100 ms 混合满载全量通过 |

### BAG 等待与长消息场景

逐 VL BAG 等待统计见 [bag_wait_metrics.tsv](bag_wait_metrics.tsv)，长消息完成时延与分片覆盖统计见 [long_message_metrics.tsv](long_message_metrics.tsv) 与 [long_message_coverage.json](long_message_coverage.json)：

| 序号 | 场景配置 | HDL / 完整性 | 双统计一致 | 实测现象与结论 |
|---|---|---|---|---|
| 14 | `GROUP_LENGTH=1471, BAG_BURST=1`（81 VL） | PASS | 一致 | 固定注入顺序，两方向各 4050 对均证明等待 BAG，页占用 `147/256`，因 `42/162` 组才跨越完整 BAG，转用轮换相位 B2/16 测试 |
| 16 | `GROUP_LENGTH=1471, BAG_BURST=2`（81 VL） | PASS | 一致 | 轮换相位 81 VL 超规格压力测试：`10/162` 组 `>= 100 µs`（最大 `107.7 µs`，VL `0x0126`）；同场景在 63 VL 规格下已全部收敛至 `96.752 µs` |

## 4. 网表窗对照与公开应用口复核

- TX 与 RX 独立端点的 1 ms 负载/分片官方 VQM 对照脚本入口见 [sim/run_load_post_synth.do](../../../sim/run_load_post_synth.do)，两窗口 22 份外部记录逐字节等价性核对见 [vqm_windows.json](../frag1030_delivery/vqm_windows.json)。
- 基于公开应用端口重核算后的 `tb_sys_perf` 检查器通过摘要见 [performance_actual_check_summary.json](performance_actual_check_summary.json)。
