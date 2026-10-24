# RTL 覆盖率结果

ModelSim SE-64 2020.4 对 CE_DIV=2 的完整 39 项官方回归统计 `sbceft`，全部通过；测试平台未插桩。
`modules.csv` 每行一个 RTL 模块，共 24 个设计单元，清单来自这次源码中的模块声明，并逐一与工具报告核对。
`vcover_report.txt` 顺序拼接各设计单元的原始报告，仅统一 LF 换行；`merged.ucdb` 合并本轮所有测试数据库。
总体按各模块已覆盖统计项数除以全部统计项数计算，百分比保留两位并按工具习惯截断。语句、分支、条件、表达式、状态、转移和翻转分别统计；FSM 合计为状态加转移。`N/A` 表示没有该类统计项。
本轮对应冻结版 `83e5d5e8`；39 个 UCDB 的 SHA-256 与终验登记逐一相同。数字和实际开始、结束时间见 `totals.json`，逐项计数见 `coverage_numbers.json`；与同源关闭覆盖率的 39 项回归按测试名及参数比较 Checks/CheckItems，缺省独立项按 0 计，`reference_counts_match` 为 true。
