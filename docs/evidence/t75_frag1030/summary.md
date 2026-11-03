# T75 frag1030 验证证据

状态：执行中，尚未完成验收。起点 `a61812679eb784f0436e4569c3b37172f720abc1`。

任务依据：`cards/T75_frag1030_verify.md` v3。所有人工报告时间使用北京时间。

- 正式网表：`out/build1030/AFDX_top_1030/20261102_212626_064390/project/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm`。
- VQM SHA256：`3CD8F5F8456C9881D083FE67DD7A60ED9C6779909EE1CB10DBF9367DC9729B6E`。
- 输入和保护范围快照：`out/t75/preflight.json`、`out/t75/protected_start.json`。
- 原始基线和随后独立用例：`out/t75/baseline_run/summary.json`。最初 56 项保留原始编译失败；声明兼容之后的运行另列，不覆盖历史结果。
- 首轮原始测试输入：`out/t75/baseline_source/`。候选测试输入：`out/t75/candidate1_source/`。
- 源码兼容性收据：每次 `summary.json` 的 `modelsim_declaration_order`。只生成 `out/` 内仿真副本；精确逆变换验证保留原始声明、位宽、表达式和断言。原始 RTL 从未写入。
- 同名测试使用独立 `AFDX_LATEST_PREFIX`、工作库和输出目录。运行 PID、创建时间、硬截止和内存峰值保存在调度汇总及各次 `active_job.json` / `tool_metrics.json`。
- 首次官方网表运行的无关共享测试库已复制后，更新后的库保存在冻结候选中；运行入口的两个未实例化测试库暂时保留原始版本。相关收据见 `out/t75/frozen_candidate.json`。网表实例化测试和 RTL 均未改变。

资源门槛：全机最多 10 个 ModelSim 内核；启动前可用内存至少 4 GiB、E 盘至少 20 GiB；工具运行保留 3 GiB 内存保护。正常优先级。不启动 eLinx GUI，不修改界面工程运行目录。

注意：卡内要求相对 `b3a60639` 的 `rtl elinx` 差异为空，但指定起点 `a6181267` 已继承 `elinx/physical_only.edc` 的 5540 个旧锁到 11044 个新锁的替换。本任务分别核验起点差异和本任务新增差异，不撤回已指定的约束。

最终结果表、峰值及提交将在全部运行结束后补齐；当前文件不构成通过声明。
