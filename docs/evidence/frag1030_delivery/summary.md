# frag1030 交付收尾证据

更新：2026-11-04 08:56:26。T78 执行完成；验收存在未闭合项：elinx 基准差异和既有性能限制，不能标整体无条件通过。

| 分块 | 结果 / 检查数 | 用时 | 源码与 VQM 绑定 |
|---|---|---|---|
| RTL 快速回归 | 63/63 PASS（52 项基础 + 11 项分支）；配置隔离 2/2 PASS；逐项 HDL/外部检查数见 [回归收据](regression.json)、[差异说明](regression_differences.json) | 整轮 813.637 s，目标 30 分钟，上限 1 小时；逐项见收据 | `360cd0294e9ae129eef97fe37ae325187e13650c`；原样 RTL，VQM 不适用 |
| 官方 VQM | T75 tb_elinx 9238、tb_net_services 1123；分片 PASS-PREFIX 5 组 / 32 行；T76 TX/RX 各 161 检查，11 份记录逐字节相同 | T75 完整窗口 52312.469 / 23614.453 s，分片前缀 34727.859 s；T76 26897.997 / 27020.43 s | 证据提交 `451b91c4` / `afd47721`；旧 VQM `3cd8f5f8456c9881d083fe67dd7a60ed9c6779909ee1cb10dbf9367dc9729b6e`；冻结输入哈希见各收据 |
| 满负载性能 | 未通过：case 16 的 10/162 组 ≥100 µs，最大 107.7 µs；周期最大 3.368 µs；81 VL 混合溢出；63 VL 混合 100 ms 完整性通过 | 100 ms 仿真窗口；运行耗时见 [T76 队列](../t76_frag1030/primary_queue.json) | `afd47721` 保存冻结源码及统计；RTL，VQM 不适用 |
| 时序 | PASS：setup +29 ps，hold +604 ps，setup/hold 各 0/96142 失败；含 0.30 ns 不确定度；11044 簇、172 P0 不变 | 端到端 898.5 s | `fe40d1fb` 保存 T77 构建输入；VQM `96d14e2f8ae99c72f3145f14a17f8606c16d98f7e039befe6359eb25c471e3b4`；[原始数值](timing.json) |

[T75 证据](../t75_frag1030/summary.md) · [T76 证据](../t76_frag1030/summary.md) · [T77 证据](../t77_rtl_compat/summary.md)。历史提交号用于定位保存冻结输入的证据，实际输入以原始收据内 SHA256 清单绑定；未将后续报告提交冒称为运行时 HEAD。

快速版覆盖清单为 `sim/t78_quick_tests.txt` 的 52 项和 `par_regress.py DEFAULT_BRANCH` 的 11 项，另加默认 84 消息和两消息配置隔离实际入口。排除 tb_sys_perf_var、tb_sys_perf、tb_sys_load、tb_sys_rtc；tb_sys_perf_var、tb_sys_load、tb_sys_rtc 引用 T75 FinalRTL，tb_sys_perf 引用 T76 performance_actual_rerun（HDL 683408635、独立 1357450），均为 PASS。[长用例收据](long_references.json)保留逐项检查数、用时和运行目录。T77 的 MODEL_TECH 分支对 ModelSim 与兼容副本等价，非 ModelSim 综合入口逐 token 保序相同，见其文本等价与直接 RTL 验收证据；引用历史长例不冒称在最终源码重跑完成。最初四项都已开跑，tb_sys_load/tb_sys_rtc 已完成并附录入本轮收据；tb_sys_perf_var/tb_sys_perf 继续原进程与四小时原截止，不中断、不重启、不等待。其最终结果由原 `out/t78_regression/summary.json` 自动记录；本提交保留收尾时快照。

T76 原摘要的“网表窗口未完成”已过时；[本轮只读核对](vqm_windows.json)确认两窗口终态、[RESULT]、仿真结束时间、进程用时及 22 份文件的两侧 SHA256/行数。未重跑网表仿真。8192 字节及故障恢复网表覆盖仍不成立。T75 [终态摘录](t75_official.json)、[分片前缀](fragment_prefix.json)保留覆盖边界。

合并顺序：fe40d1fb 后 451b91c4，均无冲突。RTL 精确为 7 文件 +89 行。`elinx/` 相对 a6181267 多出 T76 已有的 `sim_1` 配置模块登记一行，因此该条验收 FAIL；相对 afd47721 无改动，未自行回退。见 [合并核验](merge_verification.json)。声明保持：81 TX/RX VL 用于单帧周期场景；长短消息混合独立声明 63 TX/RX VL。ARCH 规格表未改。

## 限制与未完成项

- 81 VL 背靠背 BAG 等待场景（case 16）：10/162 组抖动 ≥ 100 µs，最大 107.7 µs（VL 0x0126，两个方向）。周期注入场景最大 3.368 µs。声明是否下调到 63 VL 待用户决定。
- 81 VL 长短消息混合会溢出；混合场景的声明是 63 VL（70 通过、71 溢出）。
- 8192 字节分片和故障恢复只在 RTL 上验证；分片网表证据是截断到第 199,578 拍的比对（含 1472 字节两帧重组）。
- eLinx 界面里点 Run Behavioral Simulation 还没有人工验证；命令行 ModelSim 已通过。
- eLinx 每次综合的 VQM 文本排列不同，但结构相同，锁定布线的时序相同（T77 实测）。

## 复核入口

[原始 RTL RESULT 和输入哈希](regression_native.json)、[配置隔离实际入口](configuration_cases.json)、[slack](slack.rpt)、[route status](route_status.rpt)、[placed utilization](utilization_placed.rpt)。[提交包体积报告](package_size.md)列出测量提交、总大小、最大 20 文件及所有超过 5 MB 的跟踪文件。没有新增超过 5 MB 的文件。
