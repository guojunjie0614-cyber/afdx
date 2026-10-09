# C3 T3 发送核心验证结果

基线：`3a09a4ee`，ARCH v0.3；默认种子 20261007。日志路径以下均相对 `out/`，各目录 `summary.json` 保存源码、测试平台及参考工具 SHA256。
表内 R 为 `[RESULT] checks/errors`，C 为 `[CHECK] items/errors/either`；所有行均 PASS。MAC 行的消息栏表示输入向量用例，RAM 无消息。

| 测试 | 消息/用例 | 帧 A/B | R | C | 日志目录 |
|---|---:|---:|---|---|---|
| tb_ram_sdp | 0 | 0/0 | 20764/0 | — | `sim/tb_ram_sdp/20261008_012643_633938` |
| tb_mac_tx | 72 | 45/45 | 1703516/0 | — | `sim/tb_mac_tx/20261008_012647_789613` |
| tb_mac_rx | 70 | 70 输入用例 | 409817/0 | — | `sim/tb_mac_rx/20261008_012652_460529` |
| tb_mac_loop | 224 | 112/123 | 7110567/0 | — | `sim/tb_mac_loop/20261008_012656_854573` |
| tb_tx_basic | 401 | 398/382 | 1122421/0 | 7986/0/0 | `sim/tb_tx_basic/20261008_012703_097059` |
| tb_tx_basic（5/11） | 401 | 398/382 | 1121417/0 | 7986/0/0 | `sim/tb_tx_basic/20261008_012708_847441` |
| tb_tx_bag | 2372 | 166/166 | 14081918/0 | 14757/0/0 | `sim/tb_tx_bag/20261008_012714_562426` |
| tb_tx_multi | 1698 | 1698/1698 | 14785644/0 | 43309/0/0 | `sim/tb_tx_multi/20261008_012729_643650` |
| tb_tx_drop | 251 | 220/220 | 30306384/0 | 4864/0/2 | `sim/tb_tx_drop/20261008_012747_606421` |
| tb_tx_net | 13 | 10/8 | 249085/0 | 240/0/1 | `sim/tb_tx_net/20261008_012815_028451` |
| tb_tx_net（网表） | 13 | 10/8 | 249085/0 | 240/0/1 | `net/tb_tx_net/20261008_012820_172927` |

| 100 MHz 未布线综合估算 | 逻辑单元 | RAM 切片 | setup/ns | hold/ns | 日志目录 |
|---|---:|---:|---:|---:|---|
| afdx_tx_core | 5620 | 291 | 5.719 | -0.068 | `synth/afdx_tx_core/20261008_011455_959955` |
| probe_tx_core | 5787 | 291 | 5.719 | -0.068 | `synth/probe_tx_core/20261008_011647_768345` |
七张表切片数：cfg 32、state 63、desc 44、mnext 8、pnext 8、free 8、payload 128；无额外 RAM。两次估算 Fmax 均 233.590 MHz。
afdx_tx_core 最差 setup：`\afdx_ram_sdp:tx_payload|memory:rtl_mem15477|altsyncram_ak71:auto_gen0_1|ram_block1a80|port_b_address_dff[0]/Q` → `c3_native_cell_1092|ff/D`。
probe_tx_core 最差 setup：`\afdx_tx_core:core|afdx_ram_sdp:tx_payload|memory:rtl_mem15495|altsyncram_ak71:auto_gen0_1|ram_block1a245|port_b_address_dff[0]/Q` → `c3_native_cell_1107|ff/D`。
hold −0.068 ns 未判通过；估算走线延迟为零，不是布线后签核。按 T2 结论，布局布线与 hold 证实留到 T6。
网表测试为 122829 周期；`events.txt`、`dump_a.txt`、`dump_b.txt` 与上表 RTL 行逐字节相同（3/3），大小及 SHA256 见 `t3_final_evidence.json`。
边界结果：精确 BAG、128 VL 突发、三 VL 轮询、1500 条混合消息均通过；页耗尽/无复位回填/复位后回填各接收 44 条（含开启 BAG 的首帧）。
参考工具：五测试同种子生成逐字节一致；九组破坏记录全部被拒绝，见 `t3_reference_audit_20261008_final/summary.json`。接收途中还页的合法不确定记录被接受，重复抓包及脉冲被拒绝，见 `t3_bounds_audit_20261008/summary.json`。
运行命令：`sim/regress.ps1 -Deadline 2026-10-08T05:38:15+08:00`；`elinx/synth.ps1 -Top afdx_tx_core -Sta`（包装改为 `probe_tx_core`）；`sim/run.ps1 -Test tb_tx_net -Netlist <核心网表>`。
T2 四项 RTL 已复跑；T2 网表未重复运行。安装目录日志 property 的前后 SHA256 相同。
本次执行截至 2026-10-08T01:36:39+08:00，耗时 58.40 分钟，未进入 T4。
