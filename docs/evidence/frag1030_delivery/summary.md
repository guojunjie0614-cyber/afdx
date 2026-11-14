# frag1030 交付汇总

本文汇总分片交付版的源码快速回归、官方 VQM 对照、63 VL 满负载验证及锁定布线时序结果。七场景详表与 eLinx 界面行为仿真截图见 [63 VL 验证汇总](../vl63_full_load/summary.md)。

| 验证分块 | 结果 / 检查数 | 用时 / 窗口 | 输入与绑定依据 |
|---|---|---|---|
| RTL 快速回归 | `63/63 PASS`（52 项基础 + 11 项分支）；配置隔离 `2/2 PASS`；逐项 HDL/外部检查数见 [regression.json](regression.json)、[regression_differences.json](regression_differences.json) | 整轮 `813.637 s`（目标 30 min） | 交付版 RTL 源码 |
| 官方 VQM 对照 | `tb_elinx` `9,238` checks PASS；`tb_net_services` `1,123` checks PASS；`tb_frag1030_net` 分片前缀 `PASS-PREFIX`（199,578 拍，5 组/32 行逐字节一致）；TX/RX 负载窗口各 `161` checks PASS（22 份输出逐字节等价） | `tb_elinx` `52,312.469 s`；`tb_net_services` `23,614.453 s`；`tb_frag1030_net` 前缀 `34,727.859 s`；TX/RX 负载窗口 `26,897.997 s` / `27,020.430 s` | VQM 对照记录 [vqm_official.json](vqm_official.json)、[fragment_prefix.json](fragment_prefix.json)、[vqm_windows.json](vqm_windows.json) |
| 超出声明的 81 VL 压力测试 | 81 VL 背靠背 BAG 等待（case 16）：`10/162` 组 `>= 100 µs`，最大 `107.7 µs`；周期场景最大 `3.368 µs`；81 VL 混合场景 RX 溢出；63 VL 混合 100 ms 全量通过 | `100 ms` 仿真窗口 | RTL 仿真（不作当前 63 VL 规格限制），详见 [负载边界记录](../frag_load/summary.md) |
| 布局布线与静态时序 | `PASS`：Worst Setup `+29 ps`（`+0.029 ns`），Worst Hold `+604 ps`（`+0.604 ns`），setup/hold 各 `0/96,142` 失败端点；含 `0.30 ns` 时钟不确定度；`11,044/11,044` 锁定簇、`172` 个 P0 引脚 | 端到端完整构建 `898.5 s` | 最终 VQM SHA256 `96d14e2f8ae99c72f3145f14a17f8606c16d98f7e039befe6359eb25c471e3b4`，见 [timing.json](timing.json)、[slack.rpt](slack.rpt) |

## 回归与评委长用例覆盖

- 快速回归清单见 [quick_tests.txt](../../../sim/quick_tests.txt) 的 52 项基础用例与 `tools/par_regress.py` 的 11 项参数化分支用例，另加默认 84 消息与两消息配置隔离入口（见 [configuration_cases.json](configuration_cases.json)）。
- 4 项超长系统级性能/负载用例（`tb_sys_load`、`tb_sys_rtc`、`tb_sys_perf`、`tb_sys_perf_var`）与 4 项快速评委用例汇总于 [judge_result_frag1030.txt](../../../sim/reference/judge_result_frag1030.txt)（8 项全通过，合计 `1,949,513,089` 次逐拍/逐字节断言检查、`0` 错误、总耗时 `8,322.663 s` ≈ 2.31 h）；详细逐项记录保留于 [long_references.json](long_references.json)。
- TX/RX 官方 VQM 窗口核对结果见 [vqm_windows.json](vqm_windows.json)，确认两窗口 `[RESULT]`、仿真结束时刻、进程耗时及 22 份输出文件的 SHA256/行数与 RTL 参考逐字节相同。分片官方 VQM 摘录与前缀边界见 [vqm_official.json](vqm_official.json)、[fragment_prefix.json](fragment_prefix.json)。

## 63 VL 满负载规格与已验证边界

- **当前满负载并发声明**：**63 TX / 63 RX VL**，每 VL `BAG = 1 ms`、`Lmax = 1471 B`，单向计划载荷 `741.384 Mbit/s`，千兆线路占用率 `77.5%`；配置表容量仍为 `128 TX / 4096 RX VL`。
- **七场景实测**：在 [63 VL 验证汇总](../vl63_full_load/summary.md) 中，P1/P17/P256/P1024/P1471 五项周期场景最大抖动 `3.360 µs`；背靠背 B2 场景最大抖动 `96.752 µs`（VL `0x0114`、`1471 B`），HDL/逐字节完整性/Python-Tcl 双统计全数通过；B1 固定顺序下有 `122/126` 组因首帧未跨完整 BAG 不满足统计前提（记 `NA`），其 3,150 对/方向 BAG 间隔均实测通过，抖动判据由 B2 承担。
- **混合与长消息边界**：已验证单条 VL 在 63 VL 满负载混合工况下发送 `8192 B` 长消息（`100 ms` 无损交付）；多条 VL 并发持续发送 `8192 B` 仅验证至 `N = 2`（20 ms 窗口 PASS），`N = 3/4` 会触发应用侧满载反压上限，不列入并发规格保证，见 [limitations.md](limitations.md)。

## 复核入口

- [acceptance.json](acceptance.json) · [final_input_integrity.json](final_input_integrity.json) · [configuration_cases.json](configuration_cases.json)
- [slack.rpt](slack.rpt) · [route_status.rpt](route_status.rpt) · [utilization_placed.rpt](utilization_placed.rpt)
- 分目录详表：[63 VL 验证](../vl63_full_load/summary.md) · [负载与 81 VL 压力边界](../frag_load/summary.md) · [布线与 STA 复现](../route_sta/summary.md) · [全表 RTL 与 VQM 兼容](../vqm_compat/summary.md)
