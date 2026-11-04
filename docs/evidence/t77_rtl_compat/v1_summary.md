# T77 v1 执行报告：原样重综合 VQM 不同，按卡停止

状态：`STOPPED_BY_CARD`。T77 兼容目标未完成；未形成可验收的 RTL 修改。

执行工作区为 `E:/2026_Embedded_FPGA/worktrees/active/c3_t77`，分支 `t77`，起点 `edbbd1fb541016da590d637e1f28dfecf02f2f2b`。依据任务卡第 1 步及停止条件“原样重综合就与基准不同”，本次在基线门槛失败后停止；未重试综合、未实现宏分支、未布线、未运行要求的五项仿真。

## 基线门槛

- 官方工具运行开始：2026-11-04 00:15:03；比较控制器结束：2026-11-04 00:21:16。
- 34 份 RTL 和 `elinx/afdx_all.v` 共 35 份文件，与指定基准构建的源码快照逐字节相同，详见 `original_source_comparison.json`。
- 官方入口由现有 `tools/build_1030.py` 的 `prepare()` 生成，执行 `quartus_map` 和 `quartus_cdb --vqm`，只到 `synth_1` 导出 VQM。未执行 pack、综合后时序或 route。入口和约束的对比见 `official_entry_comparison.json`。
- QSF 在仅重定位本次输出和源码快照路径后逐行相同；QPF、默认分配文件及两份约束逐字节相同。EPR 的唯一内容差异是本次继承的仿真文件集多列出 `tb/lib/afdx_sys_config.v`，综合运行配置相同；这不是本次修改，且该仿真文件不在官方综合的 QSF 中。
- `quartus_map`：成功，0 errors，约 262.750 秒；`quartus_cdb`：成功，0 errors / 0 warnings，约 7.610 秒。PID、创建时间、命令、输出目录和预算见 `baseline_tool_metrics.json`；综合总截止为 00:45:03。
- 启动时空闲内存约 10.015 GiB、E 盘约 39.650 GiB；本任务最多一个官方综合工具运行。

指定基准：

```text
E:/2026_Embedded_FPGA/worktrees/active/c3_frag1030/out/build1030/AFDX_top_1030/20261102_212626_064390/project/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm
SHA256 3cd8f5f8456c9881d083fe67dd7a60ed9c6779909ee1cb10dbf9367dc9729b6e
```

本次原样综合：

```text
E:/2026_Embedded_FPGA/worktrees/active/c3_t77/out/t77_synth/baseline_original/20261103_081503_980400/project/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm
SHA256 e9e1734c570b8344c3666e02ebf1152dd45bd7a74e801d93c73de3a1126839b4
```

两份文件均为 115,027,164 bytes。逐字节比较不相同；去掉左侧空白后以 `//` 开始的整行注释，再保持原有顺序逐行比较，仍不相同。两边各有 1,054,470 行非注释行，其中 2,729 个对应行位置不同。没有排序，也没有通过结构等价放宽验收。

第一处差异为原始第 71,712 行（去注释后第 71,695 行）。基准为 `application_rx` 下 RAM `bank[0] / slice[0]` 的 `decode_hha:rden_decode|eq_node` 声明；本次同位置为 `application_tx` 下 RAM `bank[4] / slice[1]` 的声明。完整路径、前十处逐行差异及两种 SHA256 见 `baseline_ordered_comparison.json`。

已确认的是原样重综合未满足任务卡的严格 VQM 门槛。没有继续判断全部差异是否仅为排列变化、是否功能等价，也没有确定变化的根因；这些判断均不能替代本卡规定的基线验收。

## ModelSim 前置探测

- 当前 eLinx 仿真设置 `ModelSimInstallPath` 指向 `E:/Verilog/ModelSim/setup_pack/win64`。本次只读取设置，没有启动 eLinx GUI 仿真，未改设置。
- `tools/eda.py sim` 使用该 ModelSim 的 `vlog.exe -vlog01compat` 和 `vsim.exe -batch`；当前默认启用 T75 兼容副本。若后续获准继续直接 RTL 验收，必须设置 `AFDX_MODELSIM_DECL_ORDER=0`。本次未修改这个入口。
- 未显式传入任何定义的宏探测文件，只在 `MODEL_TECH` 不存在时引入语法错误，实际编译成功，确认 ModelSim 自动定义该宏。
- `verror 2730` 的本机解释为找不到给定变量。原样 RTL 实测产生 38 个编译错误，其中 22 条 `vlog-2730`；保留原始失败日志，没有用副本变换隐藏结果。
- `-suppress 2730` 和 `-warning 2730` 均仍有 38 errors，并各报一条 `vlog-53`：`Cannot suppress or change severity level of message number 2730.` 因此两种选项都不可用。
- `-permissive` 仍有 23 errors / 15 warnings，也不能编译通过。全部诊断逐条保留在 `compiler_probes.json` 和 `probe_*.log`。
- 另一个隔离的微型工具探测编译、运行了一个未触发 `$finish_and_return` 的分支，0 errors / 0 warnings；它只说明该探测场景可运行，不证明断言被触发时的支持情况，也不构成任何要求的功能仿真验收。对应输入、日志和进程收据为 `system_task_probe_*`。

官方综合的 64 条原始 warning 行逐条列在 `warnings.json`，完整上下文见 `baseline_analysis.log`。没有抑制综合警告。

## 未执行与现场边界

- 兼容 RTL 改动：未执行，`rtl/` 与起点一致。
- 双工具最终编译验收：未执行；原样 ModelSim 前置编译失败，未运行本卡的 Icarus 编译验收。
- 锁定布局、PRES 1.30 布线、setup / hold、失败端点和 P0 管脚验收：未执行。任务卡中的 +0.029 / +0.604 ns 是预期基准，不能作为 T77 的实测结果。
- `tb_elinx`、`tb_fragmentation`、`tb_sys_basic`、`tb_rx_basic`、`tb_tx_basic`：未执行，检查数未验收。
- `README.md` 未修改，因为没有获得可用的新编译方法或通过兼容验收。
- T75、T76 工作区只读；没有结束或挂起其进程。收尾时所记录的 20 个原有进程均仍存在，详见 `status.json`。没有派子代理、heartbeat、定时任务、push、合并或 amend。
- 原比较控制器在生成差异摘录期间耗时较长，曾尝试检查其身份后仅停止该控制器；身份查询时它已自然退出，未执行任何 kill。官方综合和导出此前均已成功退出。最终顺序比较改为流式扫描，没有重新运行综合。

主报告与小体积原始日志保存在本目录；115 MB 的候选 VQM、冻结源码和运行库保留在上述 `out/t77_synth/`，未作为 Git 跟踪文件加入。`status.json` 为停止状态入口，`baseline_original.json` 为首次执行收据，`baseline_ordered_comparison.json` 为最终逐行比对收据。

后续须先处理“原样综合输出不满足严格基准一致性”的前置问题，再决定是否授权继续 T77。当前没有继续尝试替代方案。

Skills used：`windows-toolbox`，用于 Windows 命令、路径、工具产物和进程身份核对。

Subagents used：无。
