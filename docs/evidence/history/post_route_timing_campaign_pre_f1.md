# T57 布线后时序与终验

交付源码 T57 `f1393d44`，master 合并 `8ef6f0cd`；PRES_FAC_MULT=1.45，唯一时钟 125 MHz（8 ns），CE_DIV=2，无单元坐标约束。

官方综合、布局布线和全量报告来自 `t57_timing.json:source_files`；界面工程的资源报告和布线数据库与命令行结果一致。界面综合时序数据库未留存，`gui_synthesis_timing.pb`、`gui_timing.json` 使用同源命令行综合产物，不表示重新操作过界面。

| 项目 | 实测 |
|---|---|
| LUT / FF / CLB / Memory / Pins / DSP / PLL | 33799 / 17086 / 4331 / 366 / 257 / 0 / 0 |
| setup | +0.011 ns（含 0.30 ns 不确定度；按 8 ns 为 +0.311 ns） |
| hold | +0.229 ns |
| setup / hold 失败端点 | 各 0 / 46325 |
| 8 ns 单周期组 | 147349 条，最差 +0.011 ns |
| 16 ns 多周期组 | 50296 条，最差 +1.580 ns |
| 同沿 hold | 197645 条，无失败 |
| 最差路径 | `rx_core/parse_b/position[7]/Q` → `rx_core/parse_b/vlid[6]/ena`；5 级、扇出 16，总 7.519 ns（逻辑 2.020、连线 5.499） |
| 约束检查 | 2755 寄存器、51992 内部弧，不合格寄存器和未覆盖弧均 0 |
| 终验 | CE1、CE2、CE2 覆盖率各 39/39；CE2 评委 8/8，errors=0、warnings=0；网表与 RTL 各 1124 检查、0 错误，7 份外部记录一致；check_wrapper 5/5 |

8 ns 路径数沿用原单周期组口径，不包含 50296 条多周期路径；两组相加为 197645。界面默认报告只列最差 100 条路径，全量计数取官方完整导出的数据库。`device_capacity.rpt` 原生 `Min Slack=1e+30` 与 `EndPoints=26701` 是资源报告中的占位/阶段值，时序只采用 `route_timing.json` 和 `t57_timing.json`。

综合警告共 7 条，原因见 `../FACTS.md`；不能与仿真 0 警告混同。setup 余量为 11 ps；当前结论限于内部静态时序及已列仿真，未完成完整外部 I/O 延迟预算或上板测量。历史专项实验保留原始证据，不作为本版终验。
