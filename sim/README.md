# `sim/` 目录说明

根目录保留所有面向评委与开发者的直接执行入口及回归清单，内部 Tcl 辅助脚本归类于 `lib/`。

| 类别 | 路径 | 用途说明 |
| :--- | :--- | :--- |
| **ModelSim 直接入口** | `run_judge.do` | 评委批处理总入口（无需 Python，8 项系统级/性能用例） |
| | `run_app.do` | 顶层 VLID + 应用载荷流仿真入口（含长报文分片自动分支） |
| | `run_services.do` | 五项网络服务独立演示入口（Phase 1~6 汇总） |
| | `run_load_post_synth.do` | 门级网表（VQM）综合后 1 ms 负载对照复现入口 |
| **PowerShell 入口** | `run.ps1` | 单项 RTL/网表测试运行入口 |
| | `regress.ps1` | 批量 RTL / 网表回归脚本 |
| | `run_fragmentation.ps1` | 顶层包装与 IPv4 分片重组专项回归 |
| | `run_gui_netlist.ps1` | GUI 综合后 VQM 网表仿真入口 |
| **回归用例清单** | `tests.txt` | 标准 RTL 回归列表 |
| | `quick_tests.txt` | 快速 RTL 回归列表 |
| | `tests_netlist.txt` | 门级网表回归列表 |
| **子目录** | `lib/` | 内部 Tcl 辅助库（`judge_perf.tcl`、`r97_measure.tcl`、`perf_var_vectors.tcl`、`modelsim_compat.tcl`、`load_stats.tcl`） |
| | `vectors/` | 仿真输入激励与配置文件（`app/`、`judge/`、`net_services/`） |
| | `wave/` | 关键场景 ModelSim 波形脚本与原图（`png/`） |
| | `reference/` | 评委入口实测参考输出（`judge_result_frag1030.txt`） |
