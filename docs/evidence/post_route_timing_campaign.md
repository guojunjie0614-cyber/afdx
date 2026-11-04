# F1 历史：固定布局与时序

本文件记录分片前的 F1 版本，已被分片版取代；当前时序见 README“综合与布线结果”及 `../1030_IMPLEMENTATION.md`。

F1 使用 r5 A 网表与 PRES 1.30，172 条 P0 管脚及 5,540 条簇位置固定。官方源重建与全量时序复核为 setup +0.016 ns、hold +0.229 ns、0/53,882 失败端点，含 0.30 ns setup uncertainty。

布局来自 C0 加局部手工微调；改 RTL 会使布局失效。只有 PRES 1.30 是交付档；1.35 和 1.40 的已存记录仅作参考，不补扫。

V1 功能终验未通过：网表清单 7/8 PASS，tb_sys_net 因网表观察分支失败（103 项断言、独立核对 11 错误）；相同宏在未映射 RTL 上复现。其他必需功能入口已通过。证据见 `t63_f1_sys_net_failure.json`。此后 F1b 修正宏内观测，网表清单 8/8 PASS，见 `t63_f1b_sys_net_pass.json`。

功能终验与每项输入、产物摘要见 `t63_f1_functional.json`；时序、资源和前十路径见 `t63_f1_timing.json`。真实 GUI 复跑已完成，记录见 `t63_f1_gui_compare.json`，与 CLI 产物逐项比对通过（`.place`、`.route` 逐字节相同）。
