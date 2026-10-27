# RTL 覆盖率结果

ModelSim SE-64 2020.4 对 CE_DIV=2 的完整 39 项官方回归统计 `sbceft`，全部通过；测试平台未插桩。
`modules.csv` 每行一个 RTL 模块，共 24 个设计单元，清单来自这次源码中的模块声明，并逐一与工具报告核对。
`vcover_report.txt` 顺序拼接各设计单元的原始报告，仅统一 LF 换行；`merged.ucdb` 合并本轮所有测试数据库。
每个设计单元只统计一份源码。
总体按各模块已覆盖统计项数除以全部统计项数计算，百分比保留两位并按工具习惯截断。语句、分支、条件、表达式、状态、转移和翻转分别统计；FSM 合计为状态加转移。`N/A` 表示没有该类统计项。
本轮对应 T57 `f1393d44`（master 合并 `8ef6f0cd`）v02 终验；39 个 UCDB 取自 `c3_t57_v02_ce2cov/out/sim/`，其 SHA-256 登记在 `coverage_numbers.json:inputs` 和 `docs/evidence/manifest.json`，合并前后逐一核对。T58 仅运行 vcover merge/report，无重新仿真。数字和实际开始、结束时间见 `totals.json`，逐项计数见 `coverage_numbers.json`；与同源关闭覆盖率的 39 项回归按测试名及参数比较 Checks/CheckItems，缺省独立项按 0 计，`reference_counts_match` 见 `totals.json`。
