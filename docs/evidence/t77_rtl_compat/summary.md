> 当前状态：本记录的 ModelSim 兼容修正与端到端布线结果已用于分片交付版；eLinx Run Behavioral Simulation 后于 11-04 人工验证通过，见 [截图与说明](../t79_63vl/summary.md#elinx-界面人工验证)。当前满负载规格为 63 VL，见 [交付汇总](../frag1030_delivery/summary.md)。下文保留 11-03 至 11-04 的原始记录。

# T77 v2 执行报告

命令行兼容验收 **PASS**：21 处声明已加 `MODEL_TECH` 分支，综合输入文本等价、实际综合入口核对、双工具编译、五项直接 RTL 仿真与检查数通过。最终端到端构建：**PASS**；eLinx 行为仿真界面路径：**未验证**。最终结论以各门槛独立实测为准。

报告时间：2026-11-04 01:39:02。工作区 `c3_t77`，分支 `t77`，从 `d3cffda5afe894393d59bd605955f95a2d70d846` 继续；本报告随最终本地提交保存。总截止为 2026-11-04 05:26:50。

## 实现与文本等价

- 仅修改指定 7 份 RTL 的 21 条声明。位宽、属性、初始化表达式和电路逻辑不变；带初始化 wire 仅在 ModelSim 分支拆成提前声明与原位置连续赋值。`$fatal` / `$finish_and_return` 保留原样。
- ModelSim 自动定义 `MODEL_TECH`；非 ModelSim 分支保留原声明位置。Python 与 Tcl 仿真入口默认直接编译 RTL，验收显式设置 `AFDX_MODELSIM_DECL_ORDER=0`、`AFDX_CE_DIV=2`。
- `iverilog -g2001 -E`，命令行不定义任何宏；保留 Icarus 内建宏，未定义 `MODEL_TECH`。逐 token 保序比较，并独立核对去空行后的原始字节。7 份文件各自相同，完整 `elinx/afdx_all.v` 展开后的 99,689 个 token 也完全相同；没有 token 排序或名称归一化。
- 35 份原始输入字节绑定到指定基准的冻结源码；未改动的 27 份 RTL 和综合入口逐字节保持不变。详见 `v2_original_source_binding.json`、`v2_source_edits.json`、`v2_text_equivalence.json`；可复核脚本为 `v2_source_check.py`。
- `quartus_map` 原生 Source Files Read 表中 34 份用户 RTL 与预处理证明的清单及哈希完全一致；QSF 仅列一个 `afdx_all.v`，分析日志确认该入口的 42 个设计单元。其余读入均为安装目录厂商库或本次 db 自动生成文件，无未核对入口，见 `v2_synthesis_inputs.json`。

## 编译、直接 RTL 仿真与警告

ModelSim `vlog -vlog01compat`、Icarus `iverilog -g2001 -s AFDX_top` 整顶层编译均成功，0 错误、0 警告。`v2_compilation.json` 保存 PID、创建时刻、命令、预算与日志。未手动定义 `MODEL_TECH`。

| 测试 | 结果 | 自检数 | 独立核对项 | 原生警告 | 仿真秒数 | 开始 | 结束 |
|---|---|---:|---:|---:|---:|---|---|
| tb_elinx | PASS | 9238 | — | 84 | 18.578 | 2026-11-04 00:33:41 | 2026-11-04 00:34:01 |
| tb_fragmentation | PASS | 33 | 9 | 84 | 45.657 | 2026-11-04 00:34:01 | 2026-11-04 00:34:49 |
| tb_sys_basic | PASS | 5159270 | 2930 | 80 | 18.937 | 2026-11-04 00:34:50 | 2026-11-04 00:35:11 |
| tb_rx_basic | PASS | 9960369 | 123855 | 40 | 14.359 | 2026-11-04 00:35:11 | 2026-11-04 00:35:39 |
| tb_tx_basic | PASS | 662983 | 8008 | 0 | 4.625 | 2026-11-04 00:35:39 | 2026-11-04 00:35:47 |

全部检查数及独立核对项与 T75 相同，Error/Fatal/RAMCOLL/RX_ASSERT/未知警告均为 0。五项均直接编译 34 份 RTL，无兼容副本、无网表替换。详情见 `v2_simulation_acceptance.json`，逐项日志、完整输入哈希与进程收据在 `v2_raw/sim/`。

首轮 `tb_elinx` 自检 PASS 9,238 项，但旧运行器因 84 条警告返回 FAIL，原始失败记录完整保留在 `v2_raw/initial_tb_elinx_warning_rejection/`。随后只在仿真入口识别已知诊断并完整记录：未定义 `$finish_and_return`（vsim-PLI-3003），以及 `raw_write_data`、`next_limit` 两个默认模式不读取的可选输入未连接警告。未抑制日志或修改 RTL 断言。出现任何 `[RX_ASSERT]` 消息仍判失败；Error/Fatal/RAMCOLL 和未知警告也仍判失败。7 项离线夹具验证这些判定，不构成功能仿真证据。

这五项没有触发上述断言；不证明未定义的 `$finish_and_return` 被触发后能够终止仿真。yosys 辅助网表兼容不在本次范围。编译、仿真、综合的每条警告及上下文见 `v2_warnings.json`；官方综合 64 条警告未抑制。

Tcl 原生入口验证默认值与显式 0 都返回同一组 34 份原 RTL，见 `v2_raw/tcl_entry/`。eLinx 的 ModelSim 安装路径已只读核对；界面行为仿真的实际状态、隔离工程和进程证据见 `v2_gui_simulation.json`。未重跑完整评委入口。

界面验证未完成：窗口工具两次 launch_app 超时，按快捷方式工作目录启动也未获得 eLinx 窗口，系统同时出现 SmartScreen 进程。没有操作安全界面。已核实身份并取消本任务阻塞的启动控制器，未触碰安全进程或 T75/T76；已请用户手动打开隔离工程后继续。这一项保留未验证，不能以 CLI 通过替代。

## 综合不确定性

| VQM | SHA256 |
|---|---|
| baseline | `3cd8f5f8456c9881d083fe67dd7a60ed9c6779909ee1cb10dbf9367dc9729b6e` |
| v1_original | `e9e1734c570b8344c3666e02ebf1152dd45bd7a74e801d93c73de3a1126839b4` |
| v2_guarded | `53cdae1284079171cc3d0554bd32e51a7ad8c7b1f1afaf8e6e6ffafea2affd23` |
| gui_original | `0219980118e6d6932f9a56c065840cc1bd4c5ba2209f0b607ea4719fd45e1a4f` |
| e2e_processors_1 | `96d14e2f8ae99c72f3145f14a17f8606c16d98f7e039befe6359eb25c471e3b4` |

逐项比较见 `v2_final_vqm_comparison.json`。所有文件均为 115,027,164 bytes；去掉注释行后的排序行集合相同。逐个核对 65,255 个同名单元（62,274 个 lcell、2,981 个 RAM 段）的类型、全部功能参数及带顺序的端口 token，并核对 134 条赋值与顶层端口声明，名称映射为恒等映射。排序仅用于差异分类，未替代主要的源码 token 等价门槛。

GUI 的 `02199801…` 与基准 `3cd8f5f8…` 去掉整行 // 注释后仍有 2,739 个对应行位置不同，保序比较不相同；与 v1 的 `e9e1734c…` 也有 2,739 处。基准/v1/v2 初次综合两两均为 2,729 处。这些差异是文本排列，未找到名字、功能参数或连接变化。见 `v2_gui_ordered_comparison.json`、`v2_gui_structure.json`。

三次历史 QSF 除输入/输出路径及 GUI 工程创建时间外，功能设置逐行相同；默认 QDF 完全相同，QPF 仅有注释和日期元数据差别。三次均启用 Parallel Synthesis、seed=1，允许最多 6 个处理器，但原生统计的平均使用数 1.00、最大使用数 1。GUI/基准/v1 的原生墙钟耗时分别为 15:27、17:52、04:20；没有足够的历史全机负载采样，不能把耗时差或特定排列变化归因于负载。设置、路径、CPU 统计和原始日志摘录见 `v2_synthesis_environment.json`。

最可能的环节是 VQM 导出时未固定的等价节点枚举/序列化顺序；这是基于差异仅在排列且逻辑记录相同的推断，尚未定位到具体内部容器或路径/进程地址因素。证据不支持将原因直接定为并行处理器数量。

按追加要求，在唯一一次端到端构建的隔离 QSF 副本设置 `NUM_PARALLEL_PROCESSORS=1`；原生报告确认 Maximum allowed=1。导出 VQM 为 `96d14e2f…`，与基准的保序非注释行仍有 2,729 处不同；本次探测没有恢复基准顺序，不能宣称该设置已使输出固定。见 `v2_single_processor_ordered.json`。没有再开额外综合重试来寻找相同哈希。

初次 v2 官方 map/export：2026-11-04 00:33:41 至 2026-11-04 00:38:00。后续用户批准 R1，并以改动后源码完整构建取代固定 VQM 的 R2；总预算放宽为 5 小时。R2 在工具启动前取消，见 `v2_route_R2.json`。旧串行控制器在 R1 后被已有收据门槛阻止，不是 R1 原生流程失败。

### R1 与最终端到端验收

R1 使用官方 `run_pack.tcl` 的 `udm_parse_vqm` 导入 v1 原样网表 `e9e1734c…`，重新原生打包、综合后时序、锁定布线，未重新综合或复用旧 ECP。最终端到端流程调用未经修改的 `build_1030.main()`，参数为 `--route --pres 1.30`，仅在运行副本新增上述单处理器设置；从改动后 RTL 重新综合并使用新网表完成全部流程。两条流程均使用新输出目录、默认全部锁定及 P0，未传 `--no-tiles`、未改锁定或重新优化；R1 完成后才启动端到端构建。综合预算 1,800 秒，路由预算 3,600 秒。

| 测试 | 原生布线完成 | 本项门槛通过 | 保留/预期锁定簇 | 缺失/新增/偏移 | setup ps | hold ps | setup 失败/总数 | hold 失败/总数 | P0 |
|---|---|---|---|---|---:|---:|---|---|---|
| R1 | True | True | 11044/11044 | 0/0/0 | 29 | 604 | 0/96142 | 0/96142 | True |
| E2E | True | True | 11044/11044 | 0/0/0 | 29 | 604 | 0/96142 | 0/96142 | True |

| 流程 | 开始 | 结束 | 墙钟秒数 | LUT / FF | CLB / Memory | Pins / DSP / PLL |
|---|---|---|---:|---|---|---|
| R1 | 2026-11-04 00:46:27 | 2026-11-04 00:56:37 | 610.25 | 62274 / 35597 | 10230 / 814 | 172 / 0 / 0 |
| E2E | 2026-11-04 01:01:41 | 2026-11-04 01:16:40 | 898.5 | 62274 / 35597 | 10230 / 814 | 172 / 0 / 0 |

R1 精确复现基准；改动后源码的完整端到端流程也通过正时序、零失败端点、锁定与 P0 门槛。本轮未出现两条路径一正一负的情况。

时序按数据库原始 ps 精度判定，未用四舍五入值放宽门槛。锁定计数只含 CLB/M4K，P0 的 172 个 I/O pad 单独核对；`v2_placement_xyz.json` 独立核对全部 X/Y/Z，并确认 R1、端到端与基准的 `.place` 逐字节相同。初版采集器把 I/O pad 也计入簇集合，收尾已从同一原生 `.place` 只读重算；初版收据与实际执行的采集脚本留在 `v2_raw/`，没有因此重跑 EDA。

每项的 VQM 哈希、资源、原始时序字段、落位/P0 明细、错误、PID/创建时刻/命令/预算、开始结束及输入不变性见 `v2_route_R1.json`、`v2_end_to_end.json`。原生流程日志、`.place`、时序与资源报告在 `v2_raw/R1/`、`v2_raw/E2E/`。大体积检查点与布线产物保留在相应 `out/t77_route/` 和 `out/build1030/`，未纳入 Git。

### 交付需要的文件与步骤

1. 携带本提交的完整源码、工程和脚本；若携带已验证网表，则为每份 VQM 一并携带其 SHA256、匹配的检查点、锁定、布线及原生时序证据。基准旧时序与本次新网表的时序分别绑定，不混用。
2. 携带同提交的工程及脚本，特别是 `elinx/AFDX_EndSystem.epr`、`elinx/AFDX_EndSystem_assignment_defaults.qdf`、`elinx/constraints_t62.json`（P0）、`elinx/timing_only.sdc`、`elinx/tiles_1030.edc`；保留本报告和完整 `tools/`、本证据目录中的运行脚本及其 Python 依赖。
3. 使用与本机相同的 eLinx 3.0.7 / EQ6HL130 / CSG484_H 安装组件。R1 启动时记录原生 pack、综合时序和 route 脚本哈希；端到端收尾再次读取并确认三份安装脚本与 R1 相同。`constraints.edc` 与 `imple_constraints.edc` 在隔离输出目录按上述不变输入生成，前者包含 8 ns / 0.30 ns、P0 和 PRES，后者再添加全部锁定。
4. 在工程根目录设置仿真 `AFDX_MODELSIM_DECL_ORDER=0`，eLinx 行为仿真顶层为 `tb_elinx`。从源码重建使用 `tools/build_1030.py --route --pres 1.30`；本次单处理器探测的完整封装和唯一执行收据为 `v2_end_to_end.py`、`v2_end_to_end.json`。已有 VQM 的直接官方打包/布线路径见 `v2_route.py --label <新标签> --vqm <路径> --sha256 <完整哈希> --deadline <本次截止>`，无需原始综合数据库。
5. 核对新输出自身 VQM 哈希、默认锁定的全部落位与 0 偏移、172 个 P0 管脚，以及数据库原始精度 setup > 0、hold >= 0、setup/hold 均 0 失败端点。数值是否精确回到 +29/+604 ps 在上表另行报告。若不满足，只保留结果并停止，不放宽锁定或另行优化。

原有时序证据绑定基准 VQM；本次改动后源码的端到端结果独立绑定其新网表与相应布线输出。上述单机试验不等于跨安装或跨机器的普遍确定性证明。未实际创建或修改交付包。

## 资源、边界与历史

- 有记录的工具启动前采样：可用内存最小 8.637 GiB，E 盘最小 36.131 GiB；资源与进程身份详见各 runner 收据。最多 1 个本任务 eLinx、1 个本任务 ModelSim；v2 综合、R1、最终端到端构建串行，五项仿真自身串行。
- T75/T76 工作区只读，未结束或挂起其进程。收尾 PID/创建时刻核对见 `status.json`；记录的本任务工具均已退出。未写禁止目录、eLinx 设置或 `~/.codex/`；未派子代理、heartbeat、定时任务、定时续接、push、合并或 amend。
- `v1_summary.md`、`v1_status.json`、`v1_execution_context.json`、`v1_manifest.json` 保留 d3cffda5 上的 v1 停止现场，原综合和编译失败日志未覆盖。本轮可从 `status.json`、本报告、`manifest.json` 进入。

Skills used：`windows-toolbox` 用于 Windows 命令、路径、进程身份和原始产物核对；`computer-use` 用于界面启动诊断及隔离工程验证。

Subagents used：无。
