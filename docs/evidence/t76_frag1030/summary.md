# T76 执行记录

更新：2026-11-04 06:37:27。状态：**未验收**；有限作业队列均已结束。

## 第 0 步与规格

原样兼容候选在 ModelSim/Icarus 下编译无错误、无警告；最初 VQM 严格字节门槛未满足，之后按明确覆盖决定执行一次试布线。旧 VQM SHA-256 `3cd8f5f8456c9881d083fe67dd7a60ed9c6779909ee1cb10dbf9367dc9729b6e`。按 22:40 的覆盖决定完成一次带原 tiles_1030.edc 的试布线。结论 **FAIL**。综合 setup/hold `+4148/+192 ps`，setup 失败 `0/164745`；布线 `-7664/+604 ps`，setup 失败 `1426/96142`，hold 失败 `0/96142`。原锁定 11044 个、保留 11043 个、缺失 1 个、新增 2 个、偏移 0 个。172 个 P0 管脚的原生落位、封装脚、方向逐项不变。原生工具报告 stratix_clb10685 锁定目标不存在；该 CRIT 和失败时序均保留。未使用 --no-tiles，未重新优化锁定，未重试；RTL 已恢复 e4573d22，未提交这批 RTL。详见 trial_gate.json。VQM 图的 65255 个功能单元记录经双射核对仅为网名/实例名重编号；但打包资源增加一个 CLB，不能把逻辑图等价当成布局/时序等价。分类和绑定分别见 vqm_structure.json、trial_vqm_binding.json。 源码前端原样修复未交付；当前验证继续使用 T75 仿真副本兼容方式。

本线程已明确确认：81 TX / 81 RX VL，每 VL BAG=1 ms、Lmax=1471，消息≤8192 字节，TX 256 页、RX 16 个重组上下文。完整预算和默认 21 VL 子集见 `../../ARCH.md`。

## 线 2

配置隔离及实际应用入口：PASS。默认 84 消息、两消息小场景及原测试台冻结基线均使用实际 `.do` 入口。14 份外部应用、事件、GMII 记录逐字节等价：`line2_equivalence.json`。`tb_elinx`、`tb_net_services`、`tb_frag1030_net` 和其既有共用端点保持原样；T75 工作区只读。

## 线 3、4

**81 VL 混合场景已出现 RX 溢出，作为限制原样保留。** 首次失败在仿真时间 3604444 ns，接收端 `ev_a=0x80`、`ev_b=0x01`、`ev_app=0`；第 450556 拍，负载 epoch=68006，负载开始后 382550 拍（3.0604 ms）。未修 RTL，81 VL 全长短消息声明不变。按后续决定混合规格另行确定：混合最大声明为 **63 TX / 63 RX VL**；81 VL 全长短消息规格保持不变。固定激励的二分相邻边界为 70 VL 通过 20 ms、71 VL 失败，取 63 VL 留出 10.0% 余量，随后 100 ms 功能与逐字节交付通过，两套统计一致，TX 页上界不超过 256。此边界是按既定二分法、固定激励及其单调性假设得到，不冒称穷举所有 VL 数。性能门槛另见统计表，原 81 VL 混合溢出继续列为限制。 最小复现、输入哈希和首个事件见 `failure_reproduction.md`、`case_1/` 及 `primary_queue.json`。故障成因与仅有的公开端口证据分开记录，不把推断当成已证明的内部原因。

公开测点为输入 VLID 首字节至输出最后一字节，另记输出首字节。Python/Tcl 分别解析原始记录，按 VL 和载荷分组；不读取彼此的统计输出。BAG 的 +1 拍样本保留。按本线程补充决定，周期注入表采用最大−最小，并注明“无样本含 BAG 等待，未减 BAG”；独立的背靠背测量表采用全程最大−首帧时延−BAG。后者还必须证明每条 VL 的第二条消息在前一帧 BAG 到期之前输入完毕、实际帧间隔不小于 BAG、平均每 VL 不超过每 BAG 一帧；页池以公开输入首字节预留整条消息的页、最后一个 GMII 分片结束后才归还的保守上界核对。长消息完成时延单列，不套单帧 2 ms 门槛。

周期注入场景，逐 VL / 载荷数值见 [周期统计表](periodic_metrics.tsv)：

| 序号 | 场景 | HDL/完整性 | 两套统计 | 原始输出目录 |
|---|---|---|---|---|
| 0 | `GROUP_LENGTH=1471` | PASS | 一致 | `E:\2026_Embedded_FPGA\worktrees\active\c3_t76\out\t76\fallback_source\out\t76_sim\tb_t76_load\20261103_054633_707838` |
| 1 | `GROUP_LENGTH=1471,MIXED=1` | FAIL | 一致 | `E:\2026_Embedded_FPGA\worktrees\active\c3_t76\out\t76\fallback_source\out\t76_sim\tb_t76_load\20261103_054634_869671` |
| 2 | `GROUP_LENGTH=1` | PASS | 一致 | `E:\2026_Embedded_FPGA\worktrees\active\c3_t76\out\t76\fallback_source\out\t76_sim\tb_t76_load\20261103_061703_896445` |
| 3 | `GROUP_LENGTH=17` | PASS | 一致 | `E:\2026_Embedded_FPGA\worktrees\active\c3_t76\out\t76\fallback_source\out\t76_sim\tb_t76_load\20261103_061705_106406` |
| 4 | `GROUP_LENGTH=256` | PASS | 一致 | `E:\2026_Embedded_FPGA\worktrees\active\c3_t76\out\t76\fallback_source\out\t76_sim\tb_t76_load\20261103_062700_522137` |
| 5 | `GROUP_LENGTH=1024` | PASS | 一致 | `E:\2026_Embedded_FPGA\worktrees\active\c3_t76\out\t76\fallback_source\out\t76_sim\tb_t76_load\20261103_070029_744614` |
| mixed_profile | `VL_COUNT=63,MIXED=1,DURATION=12500000` | PASS | 一致 | `E:\2026_Embedded_FPGA\worktrees\active\c3_t76\out\t76\search_source\out\t76_sim\tb_t76_load\20261103_070501_935849` |

BAG 等待场景（每 VL 每 2 ms 连续两条最大载荷消息，长期平均仍为每 BAG 一帧），逐 VL 数值见 [BAG 等待统计表](bag_wait_metrics.tsv)：

固定输入顺序的场景 14 已通过 100 ms 完整性；每方向 4050 对均证明第二条等待 BAG，保守页占用 147/256，但只有 42/162 组满足最大−首帧>BAG。其余组不能计为抖动通过。场景 16 保留同样 81 VL、每轮两条、每 2 ms 到期、100 ms 窗口及统计公式，只让每三个相邻 VL 在相同到期时刻轮换输入顺序，覆盖顺序造成的排队差异；原场景和周期场景不变。场景 16 必须独立满足全部组公式、页池及 <100 µs 门槛，结果未出前不预称通过。详见 `bag_protocol_refinement.json`。

| 序号 | 场景 | HDL/完整性 | 两套统计 | 原始输出目录 |
|---|---|---|---|---|
| 14 | `GROUP_LENGTH=1471,BAG_BURST=1` | PASS | 一致 | `E:\2026_Embedded_FPGA\worktrees\active\c3_t76\out\t76\bag_source\out\t76_sim\tb_t76_load\20261103_062645_586079` |
| 16 | `GROUP_LENGTH=1471,BAG_BURST=2` | PASS | 一致 | `E:\2026_Embedded_FPGA\worktrees\active\c3_t76\out\t76\bag2_source\out\t76_sim\tb_t76_load\20261103_075234_348460` |

长消息完成时延单独见 [长消息统计表](long_message_metrics.tsv)，三种长度的已交付数量与未完成边界见 `long_message_coverage.json`。各 VL 的吞吐在对应统计表，按方向的总吞吐见 [总吞吐表](total_throughput.tsv)；接收吞吐只统计窗口内的应用载荷，窗口后排空交付另由完整性检查保证。项目内部 50 µs 线独立计数在 `statistics_crosscheck.json` 的 `internal_50us_failures`，不替代官方 <100 µs 门槛。越过 100 µs 或 BAG 测量协议未满足的组，首帧/最坏样本、公开输入至线上起始及线上起始至交付的差分均保存在 `performance_diagnostics.json`；公式无效时表内抖动记 NA，带符号算式原值保留在诊断，不能计为性能通过。

表内 PASS 只表示 HDL 自检及完整性交付。T76 性能验收还要求 100 ms、周期及 BAG 场景覆盖 81 VL、混合覆盖独立声明 VL 数、全部分组公式成立、抖动 <100 µs 以及独立统计一致；当前总门槛为 未通过/未完成。

## 线 5 与未完成边界

官方网表窗口：未完成/未通过。三个 RTL 配对参考已保留；未开跑的独立单 VL 网表 smoke 合并进 TX/RX 的官方 .do 入口，避免重复初始化。TX 已立即占核启动，RX 在 T75 首次释放核后优先于其余载荷组。每个 VQM 作业最长 24 小时；按最新优先级决定，T76 自身网表最多 3 个，全机 ModelSim 总槽位≤10、计算核≤6（含 T75 与试布线预留），挂起内核不计计算核。两窗口都使用旧 VQM，不因候选试布线或提交重启。TX/RX 均含 81 VL、至少 1 ms 输入窗口、重复同 VL 帧及一条 1472 字节两片长消息；只有逐字节等于同激励 RTL 参考且全公开输出 X/Z 监视通过，才算该窗口通过。RTL 接收端以独立顶层模块名编译，电路内容不变。

完整初始化保留，未强制未初始化 RAM、未改提交 RTL 或 MAC。每个窗口的实际耗时、PID/创建时刻/截止、工作集峰值见队列和各运行 `tool_metrics.json`。≤4 小时是目标，不能预称达到。官方 `.vo` 替换为综合 `.vqm` 的可复现入口见 `../../../sim/run_t76_post_synth.do` 和 `official_reproduction.md`。

T75 的输出扫描见 `t75_xz_scan.json`；运行中文件仅为无 X/Z 前缀，不能算最终扫描。`tb_elinx` 无捕获文件，不补造扫描结论。T75 的 `tb_elinx`、`tb_net_services` 原始终态和 frag1030 的第 199578 拍 PASS-PREFIX 仍要以各自原始收据核对；本任务未停止、重跑或写入它们。B 类映射/仿真受“第 0 步 RTL 提交后”前提约束，本次未运行。

所有新产物和本地提交均限定在本工作区；未 push、未合并、未 amend。任务未整体完成时不把中间步骤列为最终验收。

本任务的两个有限队列都登记了一次性结束回调 `tools/t76_closeout.py`。先结束的队列只退出；最后结束的队列核对两份终态、分支、HEAD、文件哈希和空暂存区后，归集证据并创建本地证据提交。回调不启动仿真、不建定时任务、不触发代理续接；输入变化或验证错误时保留现场并失败退出。结果收据位于 `out/t76/closeout.json` 和 `out/t76/closeout_commit.json`，执行日志为 `out/t76/closeout.log`。
