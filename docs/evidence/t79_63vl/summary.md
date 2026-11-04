# T79：63 VL 满负载声明与验证

运行状态：**PASS**。开始：2026-11-04 11:50:38；最近终态：2026-11-04 12:14:22。

统一声明 **63 TX / 63 RX VL**，每 VL BAG=1 ms、Lmax=1471，A/B 冗余、双向同时运行；配置规模仍为 TX 128 / RX 4096。计划单向载荷 741.384 Mbit/s，含额外 VLID 输入为 742.392 Mbit/s；线路占用 63×1538/125000=77.5152%（约 77.5%）。声明变更不修改 RTL、VQM、约束或布局。

## 七场景结果

每项 VL_COUNT=63、DURATION=12500000（100 ms）、DUPLEX=1、MIXED=0，CE_DIV=2。周期场景用最大−最小，无 BAG 等待、未减 BAG；B1/B2 用最大−首帧−BAG，保留带符号原值，公式不成立时不计抖动通过。端到端时延从输入 VLID 首字节至输出最后一字节，门槛沿用 T76 ≤2 ms。吞吐是 100 ms 窗口内交付应用载荷，两方向相加，不把 A/B 副本重复计数。

| 场景/载荷 B | 状态 | HDL/完整性 | Python/Tcl | 最大抖动 µs / VLID / 方向 | 最大端到端 µs | 总吞吐 Mbit/s | 仿真用时 s / 场景用时 s |
|---|---|---|---|---|---|---|---|
| P1/1 | PASS | PASS/PASS | 一致 | 2.016 / 0x0104 / 0 | 38.440 | 1.008000 | 740.265 / 1023.069 |
| P17/17 | PASS | PASS/PASS | 一致 | 3.360 / 0x0104 / 0 | 34.600 | 17.136000 | 751.485 / 1024.570 |
| P256/256 | PASS | PASS/PASS | 一致 | 0.016 / 0x010E / 0 | 41.360 | 258.048000 | 905.047 / 1025.585 |
| P1024/1024 | PASS | PASS/PASS | 一致 | 0.008 / 0x0100 / 0 | 65.984 | 1032.192000 | 1394.547 / 1396.251 |
| P1471/1471 | PASS | PASS/PASS | 一致 | 0.016 / 0x0100 / 0 | 80.336 | 1482.768000 | 1418.594 / 1420.489 |
| B1/1471 | PASS（不作抖动判据） | PASS/PASS | 一致 | NA（存在公式无效组） / 0x0115 / 0 | 1079.056 | 1477.415360 | 1649.360 / 1652.150 |
| B2/1471 | PASS | PASS/PASS | 一致 | 96.752 / 0x0114 / 0 | 1175.432 | 1477.119360 | 1411.610 / 1412.867 |

逐 VL 原值见 [per_vl_metrics.tsv](per_vl_metrics.tsv)；独立统计输出、HDL 日志、页池/BAG 消息对见对应场景目录。统计公式保持 T76 原样；Python 仅为 MIXED=3 扩展预期序列检查，Tcl 源码保持原样。场景用时为启动至控制器确认结束，含接管识别延迟；实际仿真用时以 tool_metrics.json 为准。

## 完整性、公式与预算

| 场景 | 分组数 | 公式无效组 | ≥100 µs 组 | 页池上界（两方向） | BAG 等待对/失败对（两方向） |
|---|---|---|---|---|---|
| P1 | 126 | 0 | 0 | [57, 57] / 256 | [0, 0] / [0, 0] |
| P17 | 126 | 0 | 0 | [51, 51] / 256 | [0, 0] / [0, 0] |
| P256 | 126 | 0 | 0 | [16, 16] / 256 | [0, 0] / [0, 0] |
| P1024 | 126 | 0 | 0 | [14, 14] / 256 | [0, 0] / [0, 0] |
| P1471 | 126 | 0 | 0 | [18, 18] / 256 | [0, 0] / [0, 0] |
| B1 | 126 | 122 | 0 | [144, 144] / 256 | [3150, 3150] / [0, 0] |
| B2 | 126 | 0 | 0 | [156, 156] / 256 | [3150, 3150] / [0, 0] |

完整性包含逐消息序号、长度、计划周期覆盖、应用载荷逐字节相同、A/B 逐帧时戳/载荷一致、FCS/IP 校验、BAG 间隔、页池保守上界≤256。HDL 另核对交付与去重计数及公开端口 X/Z。BAG 场景逐对证明第二条输入完成早于第一帧+BAG，实际第二帧不早于 BAG 到期。

## 原始输出与运行收据

[run_receipt.json](run_receipt.json) 保留命令、PID/创建时刻、截止、退出状态、原始目录、仿真用时和场景用时；各场景 tool_metrics.json 保留内核身份和峰值内存。前六项先启动，第七项等待空位；所有子进程继承最多六个逻辑 CPU 的亲和性。每次授权运行上限 10800 s；P1471/B2 按后续明确授权在新目录补跑一次，初次记录保留。没有隐式重试、heartbeat、定时任务或续接。
- P1：`E:\2026_Embedded_FPGA\worktrees\active\c3_t79\out\t76_sim\tb_t76_load\20261103_191938_500768`
- P17：`E:\2026_Embedded_FPGA\worktrees\active\c3_t79\out\t76_sim\tb_t76_load\20261103_191939_542797`
- P256：`E:\2026_Embedded_FPGA\worktrees\active\c3_t79\out\t76_sim\tb_t76_load\20261103_191940_599960`
- P1024：`E:\2026_Embedded_FPGA\worktrees\active\c3_t79\out\t76_sim\tb_t76_load\20261103_191941_710230`
- P1471：`E:\2026_Embedded_FPGA\worktrees\active\c3_t79\out\t76_sim\tb_t76_load\20261103_195038_790879`
- B1：`E:\2026_Embedded_FPGA\worktrees\active\c3_t79\out\t76_sim\tb_t76_load\20261103_191943_886128`
- B2：`E:\2026_Embedded_FPGA\worktrees\active\c3_t79\out\t76_sim\tb_t76_load\20261103_195039_803119`

### 原样 RTL 的 ModelSim 诊断边界

T77/T78 原样 RTL 在 ModelSim 下存在 `$finish_and_return` 未定义和可选端口未连接警告。旧 t76_sim.py 把所有 Warning 视为失败，原 summary.json/退出码原样保留；T79 用与 tools/eda.py 相同的五条精确模式单独判定，完整警告仍在 simulation.log。未知 Warning、Error、Fatal、RAMCOLL、RX_ASSERT、HDL FAIL、输入哈希变化均不放行。t79_adjudication.json 单列 HDL、已知警告数与包装器状态，不把包装器 FAIL 改写为 PASS。接管队列控制器时保留原有仿真 PID、首次启动时刻和截止，未重跑。

## 81 VL 行为不变的证明

选择任务卡允许的“代码路径不变”方法，未额外跑 81 VL smoke。基础七场景的运行版本相对起点 f4632d5c，仅把 BAG_BURST=2 的拒绝条件由 VL_COUNT!=81 改为 VL_COUNT%3!=0；81 在 BAG_BURST=0/1/2 下均与原来一样不触发拒绝，其余运行代码及测试台原样。初次核对见 [81vl_code_path_proof.json](81vl_code_path_proof.json)。随后追加 MIXED=3：新消息长度分支只在 MIXED=3 生效，LONG_COUNT 在 MIXED=0/1/2 下未使用，原七字段 window.txt 输出和全部到期/序号/相位/轮换逻辑不变；Python 新的预期覆盖分支也仅对 MIXED=3 生效，统计公式和 Tcl 未改。旧模式的参数集合和命令也保持不变，历史 RTL/VQM 参考仍可精确匹配，见 [legacy_parameter_proof.json](legacy_parameter_proof.json)。新改动逐项精确逆变换核对及旧路径不变说明见 [mixed3_code_path_proof.json](mixed3_code_path_proof.json)，正式文件接纳见 [mixed3_adoption.json](mixed3_adoption.json)。全部 RTL 始终逐字节不变，独立诊断不改变激励或公开端口记录。

## 混合场景复用

不重跑 mixed_profile。只读引用 T76 的 63 VL、100 ms 混合结果：HDL/逐字节完整性 PASS、两套统计一致、页池上界≤256。原始目录 `E:/2026_Embedded_FPGA/worktrees/active/c3_t76/out/t76/search_source/out/t76_sim/tb_t76_load/20261103_070501_935849`；[T76 汇总](../t76_frag1030/summary.md)、[统计交叉核对](../t76_frag1030/statistics_crosscheck.json)。短/长混合不额外叠加到纯短消息满负载；长消息按分片机会计费。

## 超出声明的压力测试（81 VL 历史）

T76 周期注入最大抖动 3.368 µs；BAG 对齐撞车 case 16 的 10/162 组≥100 µs，最大 107.7 µs（VLID 0x0126）；81 VL 混合 RX 溢出。固定顺序 case 14 只有 42/162 组满足最大−首帧>BAG，其余组不计性能通过。上述数据作为超出当前 63 VL 声明的压力测试保留，不用于扩大当前声明。

## eLinx 界面人工验证

11-04 提供的截图显示 `[RESULT] tb_elinx PASS checks=9238 errors=0`、Errors 0、Warnings 90、Elapsed 0:02:18，仿真时间 2557777 ns。截图中的系统任务诊断保留，不声称零警告；来源是任务卡提供的人工操作，本轮仅复制并目视核对，未重跑 GUI。

[原始截图](elinx_gui_behav_pass.png) · [截图收据](elinx_gui_receipt.json)。界面 Loading... 的本机 socket 排障与备用 batch 命令已写入 README。

## 待队友同步

docs/design/ 保持只读；以下五处已由上游转告，发现它们不再触发停止（按后续明确指令）。

| 文件 | 行号 | 待同步内容 |
|---|---:|---|
| docs/design/chapters/ch03.tex | 226 | 77/81 VL 双向满载基准及“完全覆盖满载无损调度需求” |
| docs/design/chapters/ch03.tex | 143 | 最大可调度数 81、载荷率 953.208 Mbps |
| docs/design/chapters/ch01.tex | 44 | 81 VL 极限吞吐率 |
| docs/design/chapters/ch10.tex | 32 | 81 VL 极限容量 |
| docs/design/AFDX端系统FPGA设计文档.tex | 191 | 摘要中的 81 VL 吞吐率 |

## 文档与验收边界

本轮更新 README.md、docs/ARCH.md、docs/FACTS.md、docs/FACTS_DETAIL.md、docs/evidence/frag1030_delivery/summary.md，并新建本证据目录。docs/design/、docs/test/、rtl/、elinx/、submission/、setup_pack/ 未改。sim/wave/png/ 的 14 张 PNG 按追加授权更新并单独提交 686aeed，来源 12858ddf，提交正文列出逐文件 SHA256；tb_elinx.png 为 11-04 界面截图。不跑网表、不综合、不布线、不 push、不合并、不 amend。

按最新裁定：B1 的 HDL/完整性/双统计为 PASS，公式前提不成立的组保留带符号值，不作抖动判据，BAG 等待抖动由 B2 承担。仅在 B2 或周期场景出现≥100 µs 组、B2 公式不成立、或 HDL/完整性失败时停止回报。

### B1：通过完整性，不作抖动判据

B1 的 HDL/完整性/双统计 **PASS**；按最新裁定不作抖动判据， **122/126 组公式不成立**，详见 [无效组原值](formula_invalid_groups.tsv)。只有 VLID 0x0114、0x0115 的两个方向共 4 组满足前提，有效组中最大为 0.984 µs（0x0115）；该子集最大值不作为抖动验收判据；判据由 B2 承担。

例：方向 0、VLID 0x0100、1471 字节：首帧 6073 拍（48.584 µs），全程最大 129600 拍（1036.800 µs）；最大−首帧=123527 拍（988.216 µs）≤125000 拍 BAG，减 BAG 后原值 -11.784 µs，故该组记 NA。

该现象与“第二条确实等待 BAG”不矛盾：线上 BAG 从前一帧起点计时，而每条消息的端到端时延各从自己的输入首字节计时；背靠背第二条输入晚于首条，等待的是剩余 BAG，固定输入顺序也未保证全程最大与首帧的差值超过完整 BAG。这是与 T76 case 14 相同的固定顺序测量现象；带符号值为负不代表抖动超标。按最新裁定 B1 不作抖动判据，B2 承担该判据；没有改公式、钳零或转用其他抖动口径。两方向各 3150 对均通过等待证明，页池上界均 144/256，最大端到端时延 1079.056 µs。

此前按旧停止条件结束的 P1471/B2 记录保存在 stopped_initial/，初次队列见 initial_run_receipt.json。随后按明确授权，同参数、新目录重新启动 P1471/B2，各 3 小时上限；当前结果以上表和 run_receipt.json 为准。旧停止记录不覆盖新运行状态。

## 多条 VL 同时发送 8192 B 的边界测试

追加授权测试 MIXED=3、VL_COUNT=63、GROUP_LENGTH=1471、DUPLEX=1。末 LONG_COUNT 条 VL 在 sequence>0 后发送 8192 B，其余发送 1471 B；首轮全部 VL 先发送一次 1471 B。每条 8192 B 消息占六帧发送机会，同 VL 到期时刻至少间隔 6 ms，沿用既有按片计费调度。公开接口依次串行注入，同一批 VL 的计划到期时刻相同。

该项已按最终指令暂停，不再启动新作业。暂停前 N=2/3/4 的 20 ms 局部试验结果原样保留；100 ms 任务此前已取消，仅保留前缀，6/8 未运行。三项 20 ms 实际用时均低于 30 分钟，无超时，但不据此完成专项验收或写并发规格限制。失败不影响基础七场景，不修改 RTL。

边界队列：**已暂停、未完成（PAUSED_INCOMPLETE）**。**已验证单条 VL 发 8192 B（63 VL 混合场景）；多条 VL 并发长消息未验证**。以下仅归档暂停前的局部试验，不作规格限制。运行身份与暂停核对见 [边界收据](long_concurrent/run_receipt.json)、[暂停收据](long_concurrent/pause_receipt.json)。

| N | 窗口 ms | 结果 | HDL/完整性 | 双统计 | 短消息最大抖动 µs / VLID | 短消息最大端到端 µs | 8192 B 最大完成时延 µs | 仿真用时 s |
|---|---|---|---|---|---|---|---|---|
| 2 | 20 | PASS | PASS/PASS | 一致 | 0.016 / 0x0119 | 80.328 | 5219.288 | 334.281 |
| 3 | 20 | HDL_FAIL | FAIL/FAIL | — | — | — | — | 121.312 |
| 4 | 20 | HDL_FAIL | FAIL/FAIL | — | — | — | — | 121.563 |

首次失败 N3_20ms：端点 1、第 950089 拍、仿真 7600708 ns；ev_a=0x80、ev_b=0x01、ev_app=0x0。

首次失败 N4_20ms：端点 1、第 952002 拍、仿真 7616012 ns；ev_a=0x80、ev_b=0x01、ev_app=0x0。

N2_100ms：CANCELLED_BY_SCOPE_REDUCTION，按范围压缩指令中止，经过 920.423 s，不作 100 ms 验收；前缀及进程取消收据见 long_concurrent/N2_100ms/cancellation.json。

验收核对 HDL、逐字节完整性交付、Python/Tcl 逐字段一致、短消息分组抖动 <100 µs、短消息原 2 ms 门槛和页池上界。8192 B 只单列整条消息完成时延，不套单帧抖动或 2 ms 门槛。原始失败保留，未重试或修 RTL。新模式的旧路径不变证明见 [mixed3_code_path_proof.json](mixed3_code_path_proof.json)。
