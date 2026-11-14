> 当前状态：本记录中的分片版 RTL 与官方 VQM 验证已用于交付；旧性能检查器的失败后来由按公开应用口时戳统计的检查结果通过，见 [交付长用例收据](../frag1030_delivery/long_references.json)及 [性能差异说明](performance_difference.md)。当前满负载规格为 63 VL，见 [交付汇总](../frag1030_delivery/summary.md)。下文保留 11-03 至 11-04 的原始记录。

# T75 frag1030 验证结果

更新：2026-11-04 06:18:32。执行：COMPLETE；验收：REVISED_SCOPE_COMPLETE_WITH_LIMITATIONS。

最终 RTL 已通过 66/67 项；完整官方 VQM 已通过 2/2 项；分片前缀状态为 PASS-PREFIX。
RUNNING 和 QUEUED 不计为 PASS；执行结束与验收通过分别报告。

## 正式官方 VQM 与显式配对参考

| 测试 | 类别 | 结果 | 检查数 | 外部项 | 仿真秒数 | 开始 | 结束 | 输出目录 |
|---|---|---|---:|---:|---:|---|---|---|
| tb_elinx | A | PASS | 9238 | — | 52312.469 | 2026-11-03 15:33:51 | 2026-11-04 06:06:08 | out/gui_netlist/tb_elinx_gui/20261102_233351_107710 |
| tb_net_services | A | PASS | 1123 | 65 | 23614.453 | 2026-11-03 16:07:08 | 2026-11-03 22:41:09 | out/t75/candidate1_source/out/gui_netlist/tb_net_services_gui/20261103_000708_762471 |
| tb_frag1030_net | A | PASS-PREFIX | — | 5 | 34727.859 | 2026-11-03 16:07:41 | 2026-11-04 01:46:54 | out/t75/candidate1_source/out/gui_netlist/tb_frag1030_net_gui/20261103_000741_186882 |
| tb_net_services | RTL reference | PASS | 1123 | 59 | 10.344 | 2026-11-03 16:06:55 | 2026-11-03 16:07:08 | out/t75/candidate1_source/out/gui_netlist/tb_net_services_rtl/20261103_000655_481368 |
| tb_frag1030_net | RTL reference | PASS | 33 | 9 | 42.313 | 2026-11-03 16:06:56 | 2026-11-03 16:07:41 | out/t75/candidate1_source/out/gui_netlist/tb_frag1030_net_rtl/20261103_000656_614198 |

网表记录必须与本次调用显式返回的 RTL 参考逐字节相同。tb_elinx 按卡内规定使用独立公开端口自检。

按 11-03 21:30 获批调整，tb_elinx 和 tb_net_services 运行完整版；分片只验证至 199578 拍的前缀，结果标 PASS-PREFIX。A/B 各 6 帧、RX 4 条、全部 8 行发送记录及截止前事件逐字节比对。8192 字节和故障恢复已在 RTL 验证，相应 VQM 覆盖留待 T76。详见 plan_adjustment.md。

前缀的外部项数按五组文件字节比较计；有意中断时没有最终 HDL RESULT，不借用 RTL 的 33 项数值。原 GUI 非零退出及独立 PASS-PREFIX 收据分别保留。

## 最终 RTL 全表与分支测试

| 测试 | 类别 | 结果 | 检查数 | 外部项 | 仿真秒数 | 开始 | 结束 | 输出目录 |
|---|---|---|---:|---:|---:|---|---|---|
| tb_ram_sdp | RTL | PASS | 20764 | — | 5.344 | 2026-11-03 17:24:51 | 2026-11-03 17:24:58 | out/t75/candidate2_source/out/sim/tb_ram_sdp/20261103_012451_330445 |
| tb_mac_tx | RTL | PASS | 264649 | — | 6.75 | 2026-11-03 17:25:02 | 2026-11-03 17:25:12 | out/t75/candidate2_source/out/sim/tb_mac_tx/20261103_012502_045494 |
| tb_mac_rx | RTL | PASS | 105303 | — | 5.563 | 2026-11-03 17:25:16 | 2026-11-03 17:25:24 | out/t75/candidate2_source/out/sim/tb_mac_rx/20261103_012516_533131 |
| tb_mac_loop | RTL | PASS | 1385254 | — | 5.422 | 2026-11-03 17:25:28 | 2026-11-03 17:25:39 | out/t75/candidate2_source/out/sim/tb_mac_loop/20261103_012528_495110 |
| tb_tx_basic | RTL | PASS | 662983 | 8008 | 7.75 | 2026-11-03 17:25:43 | 2026-11-03 17:25:55 | out/t75/candidate2_source/out/sim/tb_tx_basic/20261103_012543_893727 |
| tb_tx_basic TX_PAGE_AW=5,TX_OFF_AW=11 | RTL | PASS | 662557 | 8008 | 7.547 | 2026-11-03 17:25:56 | 2026-11-03 17:26:07 | out/t75/candidate2_source/out/sim/tb_tx_basic/20261103_012556_152865 |
| tb_tx_bag | RTL | PASS | 14054439 | 14758 | 44.391 | 2026-11-03 17:26:09 | 2026-11-03 17:26:57 | out/t75/candidate2_source/out/sim/tb_tx_bag/20261103_012609_618812 |
| tb_tx_multi | RTL | PASS | 14440385 | 57904 | 50.61 | 2026-11-03 17:26:58 | 2026-11-03 17:27:54 | out/t75/candidate2_source/out/sim/tb_tx_multi/20261103_012658_825065 |
| tb_tx_drop | RTL | PASS | 30552330 | 7723 | 104.36 | 2026-11-03 17:27:52 | 2026-11-03 17:29:39 | out/t75/candidate2_source/out/sim/tb_tx_drop/20261103_012752_122733 |
| tb_tx_net | RTL | PASS | 236158 | 245 | 5.921 | 2026-11-03 17:27:55 | 2026-11-03 17:28:05 | out/t75/candidate2_source/out/sim/tb_tx_net/20261103_012755_656552 |
| tb_rx_basic | RTL | PASS | 9960369 | 123855 | 26.094 | 2026-11-03 17:28:08 | 2026-11-03 17:28:55 | out/t75/candidate2_source/out/sim/tb_rx_basic/20261103_012808_374327 |
| tb_rx_fault | RTL | PASS | 576797 | 888 | 6.625 | 2026-11-03 17:28:56 | 2026-11-03 17:29:06 | out/t75/candidate2_source/out/sim/tb_rx_fault/20261103_012856_522866 |
| tb_rx_icrm | RTL | PASS | 4635236 | 1274 | 12.593 | 2026-11-03 17:29:07 | 2026-11-03 17:29:23 | out/t75/candidate2_source/out/sim/tb_rx_icrm/20261103_012907_677611 |
| tb_rx_load | RTL | PASS | 6406189 | 19180 | 16.562 | 2026-11-03 17:29:24 | 2026-11-03 17:29:46 | out/t75/candidate2_source/out/sim/tb_rx_load/20261103_012924_563084 |
| tb_rx_ovf_ring RX_RING_AW=9 | RTL | PASS | 422837 | 99 | 5.078 | 2026-11-03 17:29:41 | 2026-11-03 17:29:49 | out/t75/candidate2_source/out/sim/tb_rx_ovf_ring/20261103_012941_792557 |
| tb_rx_ovf_dq RX_DQ_AW=1 | RTL | PASS | 373852 | 57 | 5.703 | 2026-11-03 17:29:48 | 2026-11-03 17:29:57 | out/t75/candidate2_source/out/sim/tb_rx_ovf_dq/20261103_012948_351430 |
| tb_rx_net | RTL | PASS | 374111 | 110 | 5.75 | 2026-11-03 17:29:51 | 2026-11-03 17:30:00 | out/t75/candidate2_source/out/sim/tb_rx_net/20261103_012951_624931 |
| tb_sys_basic | RTL | PASS | 5159270 | 2930 | 30.843 | 2026-11-03 17:29:58 | 2026-11-03 17:30:33 | out/t75/candidate2_source/out/sim/tb_sys_basic/20261103_012958_825240 |
| tb_sys_fault | RTL | PASS | 42129011 | 9064 | 208.281 | 2026-11-03 17:30:02 | 2026-11-03 17:33:34 | out/t75/candidate2_source/out/sim/tb_sys_fault/20261103_013002_659774 |
| tb_sys_delay | RTL | PASS | 13940507 | 3945 | 72.875 | 2026-11-03 17:30:35 | 2026-11-03 17:31:51 | out/t75/candidate2_source/out/sim/tb_sys_delay/20261103_013035_452940 |
| tb_sys_load | RTL | PASS | 193106816 | 123400 | 1124.078 | 2026-11-03 17:05:25 | 2026-11-03 17:24:18 | out/t75/candidate2_source/out/sim/tb_sys_load/20261103_010525_607641 |
| tb_sys_cfg | RTL | PASS | 19044227 | 718303 | 100.14 | 2026-11-03 17:31:53 | 2026-11-03 17:33:40 | out/t75/candidate2_source/out/sim/tb_sys_cfg/20261103_013153_340113 |
| tb_sys_reset | RTL | PASS | 10182209 | 3876 | 48.328 | 2026-11-03 17:33:36 | 2026-11-03 17:34:28 | out/t75/candidate2_source/out/sim/tb_sys_reset/20261103_013336_445494 |
| tb_sys_ovf RX_RING_AW=9 | RTL | PASS | 8886303 | 1562 | 43.657 | 2026-11-03 17:33:41 | 2026-11-03 17:34:28 | out/t75/candidate2_source/out/sim/tb_sys_ovf/20261103_013341_865310 |
| tb_sys_net | RTL | PASS | 2793425 | 1315 | 18.656 | 2026-11-03 17:22:38 | 2026-11-03 17:23:00 | out/t75/candidate2_source/out/sim/tb_sys_net/20261103_012238_838112 |
| tb_sys_perf | RTL | FAIL | 683408635 | 1325290 | 4496.625 | 2026-11-03 17:05:24 | 2026-11-03 18:23:41 | out/t75/candidate2_source/out/sim/tb_sys_perf/20261103_010524_288871 |
| tb_sys_rtc | RTL | PASS | 10675841 | 1811 | 937.937 | 2026-11-03 17:05:27 | 2026-11-03 17:21:08 | out/t75/candidate2_source/out/sim/tb_sys_rtc/20261103_010527_366422 |
| tb_sys_snmp | RTL | PASS | 37611 | 926 | 142.5 | 2026-11-03 17:34:29 | 2026-11-03 17:36:54 | out/t75/candidate2_source/out/sim/tb_sys_snmp/20261103_013429_232257 |
| tb_sys_snmp_settrap | RTL | PASS | 8563 | 188 | 119.844 | 2026-11-03 17:34:30 | 2026-11-03 17:36:33 | out/t75/candidate2_source/out/sim/tb_sys_snmp_settrap/20261103_013430_856130 |
| tb_sys_615a | RTL | PASS | 44098 | 752 | 285.36 | 2026-11-03 17:23:01 | 2026-11-03 17:27:50 | out/t75/candidate2_source/out/sim/tb_sys_615a/20261103_012301_636423 |
| tb_gbe_burst COUNT=77 | RTL | PASS | 530802 | — | 27.312 | 2026-11-03 17:21:36 | 2026-11-03 17:22:05 | out/t75/candidate2_source/out/sim/tb_gbe_burst/20261103_012136_757873 |
| tb_gbe_burst COUNT=81 | RTL | PASS | 554734 | — | 27.391 | 2026-11-03 17:22:07 | 2026-11-03 17:22:36 | out/t75/candidate2_source/out/sim/tb_gbe_burst/20261103_012207_653147 |
| tb_rm_phase | RTL | PASS | 353130 | — | 60.328 | 2026-11-03 17:36:35 | 2026-11-03 17:37:37 | out/t75/candidate2_source/out/sim/tb_rm_phase/20261103_013635_486203 |
| tb_rtc_recovery | RTL | PASS | 28 | — | 3.797 | 2026-11-03 17:36:55 | 2026-11-03 17:37:00 | out/t75/candidate2_source/out/sim/tb_rtc_recovery/20261103_013655_493299 |
| tb_rtc_originate | RTL | PASS | 34 | — | 3.515 | 2026-11-03 17:37:01 | 2026-11-03 17:37:06 | out/t75/candidate2_source/out/sim/tb_rtc_originate/20261103_013701_673208 |
| tb_judge_capacity | RTL | PASS | 49924 | — | 26.891 | 2026-11-03 17:24:20 | 2026-11-03 17:24:48 | out/t75/candidate2_source/out/sim/tb_judge_capacity/20261103_012420_022460 |
| tb_judge_snmp | RTL | PASS | 699 | — | 85.813 | 2026-11-03 17:37:07 | 2026-11-03 17:38:35 | out/t75/candidate2_source/out/sim/tb_judge_snmp/20261103_013707_760150 |
| tb_elinx | RTL | PASS | 9238 | — | 24.406 | 2026-11-03 17:21:09 | 2026-11-03 17:21:35 | out/t75/candidate2_source/out/sim/tb_elinx/20261103_012109_521849 |
| tb_sys_perf_var | RTL | PASS | 1254291331 | 1701468 | 6200.359 | 2026-11-03 17:05:22 | 2026-11-03 18:53:15 | out/t75/candidate2_source/out/sim/tb_sys_perf_var/20261103_010522_873463 |
| tb_top_wrap | RTL | PASS | 12284 | — | 12.891 | 2026-11-03 17:37:38 | 2026-11-03 17:37:52 | out/t75/candidate2_source/out/sim/tb_top_wrap/20261103_013738_240490 |
| tb_t65_queue_a | RTL | PASS | 3088 | 10 | 4.172 | 2026-11-03 17:37:53 | 2026-11-03 17:37:59 | out/t75/candidate2_source/out/sim/tb_t65_queue_a/20261103_013753_325379 |
| tb_t65_reset_app | RTL | PASS | 204 | 42 | 17.593 | 2026-11-03 17:38:01 | 2026-11-03 17:38:20 | out/t75/candidate2_source/out/sim/tb_t65_reset_app/20261103_013801_059734 |
| tb_t65_reset_mac | RTL | PASS | 204 | 45 | 17.797 | 2026-11-03 17:38:22 | 2026-11-03 17:38:42 | out/t75/candidate2_source/out/sim/tb_t65_reset_mac/20261103_013822_627859 |
| tb_t65_reset_rx | RTL | PASS | 204 | 44 | 17.562 | 2026-11-03 17:38:36 | 2026-11-03 17:38:56 | out/t75/candidate2_source/out/sim/tb_t65_reset_rx/20261103_013836_894300 |
| tb_t65_rx_data | RTL | PASS | 14536729 | 9874 | 80.687 | 2026-11-03 17:38:44 | 2026-11-03 17:40:08 | out/t75/candidate2_source/out/sim/tb_t65_rx_data/20261103_013844_374150 |
| tb_t65_rx_desc | RTL | PASS | 669 | 216 | 3.547 | 2026-11-03 17:38:58 | 2026-11-03 17:39:03 | out/t75/candidate2_source/out/sim/tb_t65_rx_desc/20261103_013858_160848 |
| tb_t65_tx_desc | RTL | PASS | 222062 | 250 | 7.672 | 2026-11-03 17:39:04 | 2026-11-03 17:39:13 | out/t75/candidate2_source/out/sim/tb_t65_tx_desc/20261103_013904_215367 |
| tb_t65_tx_hint | RTL | PASS | 219054 | 235 | 7.687 | 2026-11-03 17:39:15 | 2026-11-03 17:39:24 | out/t75/candidate2_source/out/sim/tb_t65_tx_hint/20261103_013915_073375 |
| tb_t65_tx_init | RTL | PASS | 198841 | 14 | 7.406 | 2026-11-03 17:39:25 | 2026-11-03 17:39:35 | out/t75/candidate2_source/out/sim/tb_t65_tx_init/20261103_013925_943058 |
| tb_t65_tx_ready | RTL | PASS | 221142 | 239 | 7.672 | 2026-11-03 17:39:36 | 2026-11-03 17:39:46 | out/t75/candidate2_source/out/sim/tb_t65_tx_ready/20261103_013936_432164 |
| tb_t65_tx_short_full | RTL | PASS | 504828 | 18 | 10.656 | 2026-11-03 17:39:46 | 2026-11-03 17:39:59 | out/t75/candidate2_source/out/sim/tb_t65_tx_short_full/20261103_013946_800844 |
| tb_t65_tx_short_init | RTL | PASS | 498847 | 17 | 10.672 | 2026-11-03 17:40:00 | 2026-11-03 17:40:13 | out/t75/candidate2_source/out/sim/tb_t65_tx_short_init/20261103_014000_654447 |
| tb_t65_tx_short_normal | RTL | PASS | 499054 | 17 | 11.766 | 2026-11-03 17:40:09 | 2026-11-03 17:40:23 | out/t75/candidate2_source/out/sim/tb_t65_tx_short_normal/20261103_014009_921662 |
| tb_t65_tx_space | RTL | PASS | 246327 | 22 | 7.984 | 2026-11-03 17:40:15 | 2026-11-03 17:40:25 | out/t75/candidate2_source/out/sim/tb_t65_tx_space/20261103_014015_079003 |
| tb_t65_tx_space_edge | RTL | PASS | 223502 | 14 | 8.157 | 2026-11-03 17:40:26 | 2026-11-03 17:40:36 | out/t75/candidate2_source/out/sim/tb_t65_tx_space_edge/20261103_014026_496152 |
| tb_t65_tx_unmapped | RTL | PASS | 199811 | 14 | 7.969 | 2026-11-03 17:40:28 | 2026-11-03 17:40:38 | out/t75/candidate2_source/out/sim/tb_t65_tx_unmapped/20261103_014028_007661 |
| tb_cfg_local_ready | RTL | PASS | 6090 | — | 4.328 | 2026-11-03 17:40:37 | 2026-11-03 17:40:43 | out/t75/candidate2_source/out/sim/tb_cfg_local_ready/20261103_014037_382872 |
| tb_context_pipeline | RTL | PASS | 134 | — | 3.578 | 2026-11-03 17:40:40 | 2026-11-03 17:40:45 | out/t75/candidate2_source/out/sim/tb_context_pipeline/20261103_014040_333063 |
| tb_reassembly_engine | RTL | PASS | 39 | — | 3.875 | 2026-11-03 17:40:44 | 2026-11-03 17:40:50 | out/t75/candidate2_source/out/sim/tb_reassembly_engine/20261103_014044_848600 |
| tb_reassembly_limits | RTL | PASS | 71 | — | 3.844 | 2026-11-03 17:40:46 | 2026-11-03 17:40:51 | out/t75/candidate2_source/out/sim/tb_reassembly_limits/20261103_014046_352697 |
| tb_reassembly_transactions | RTL | PASS | 126 | — | 4.406 | 2026-11-03 17:40:51 | 2026-11-03 17:40:57 | out/t75/candidate2_source/out/sim/tb_reassembly_transactions/20261103_014051_094520 |
| tb_service_pipeline | RTL | PASS | 127 | — | 3.875 | 2026-11-03 17:40:52 | 2026-11-03 17:40:58 | out/t75/candidate2_source/out/sim/tb_service_pipeline/20261103_014052_736780 |
| tb_rtc_banked | RTL | PASS | 34 | — | 3.844 | 2026-11-03 17:40:59 | 2026-11-03 17:41:04 | out/t75/candidate2_source/out/sim/tb_rtc_banked/20261103_014059_124028 |
| tb_fragmentation | RTL | PASS | 33 | 9 | 59.735 | 2026-11-03 17:41:00 | 2026-11-03 17:42:03 | out/t75/candidate2_source/out/sim/tb_fragmentation/20261103_014100_684750 |
| tb_app_payload_pipeline | RTL | PASS | 726856 | — | 6.047 | 2026-11-03 17:41:05 | 2026-11-03 17:41:13 | out/t75/candidate2_source/out/sim/tb_app_payload_pipeline/20261103_014105_430109 |
| tb_tx_ingress_elastic | RTL | PASS | 139695 | — | 3.547 | 2026-11-03 17:41:14 | 2026-11-03 17:41:19 | out/t75/candidate2_source/out/sim/tb_tx_ingress_elastic/20261103_014114_826160 |
| tb_tx_buffer_bounds | RTL | PASS | 49800 | — | 3.688 | 2026-11-03 17:41:21 | 2026-11-03 17:41:26 | out/t75/candidate2_source/out/sim/tb_tx_buffer_bounds/20261103_014121_204654 |

## B 类辅助结果

| 测试 | 类别 | 结果 | 检查数 | 外部项 | 仿真秒数 | 开始 | 结束 | 输出目录 |
|---|---|---|---:|---:|---:|---|---|---|
| tb_mac_tx afdx_mac_tx | B | BLOCKED | — | — | — | — | — | — |
| tb_mac_rx afdx_mac_rx | B | BLOCKED | — | — | — | — | — | — |
| tb_mac_loop afdx_timebase,afdx_mac_tx,afdx_mac_rx | B | BLOCKED | — | — | — | — | — | — |
| tb_probe_ram probe_p1_2048x8 | B | BLOCKED | — | — | — | — | — | — |
| tb_probe_ram probe_p2_array | B | BLOCKED | — | — | — | — | — | — |
| tb_tx_net afdx_tx_core | B | BLOCKED | — | — | — | — | — | — |
| tb_rx_net afdx_rx_core | B | BLOCKED | — | — | — | — | — | — |
| tb_sys_net AFDX_top | B | BLOCKED | — | — | — | — | — | — |

B 类八份所需映射均已尝试；当前失败原因为整份源文件前端读取时遇到 afdx_tx_buf.v:115 的 $fatal。未用官方 VQM 代替 B 类结果。具体映射输出如下：

- AFDX_top: FAIL；out/synth/AFDX_top/20261102_233746_354083；mapping: exit=1 reason=None; E:\2026_Embedded_FPGA\worktrees\active\c3_frag1030\out\synth\AFDX_top\20261102_233746_354083\mapping.log
- afdx_tx_core: FAIL；out/synth/afdx_tx_core/20261102_233747_451790；mapping: exit=1 reason=None; E:\2026_Embedded_FPGA\worktrees\active\c3_frag1030\out\synth\afdx_tx_core\20261102_233747_451790\mapping.log
- afdx_rx_core: FAIL；out/synth/afdx_rx_core/20261102_233748_552811；mapping: exit=1 reason=None; E:\2026_Embedded_FPGA\worktrees\active\c3_frag1030\out\synth\afdx_rx_core\20261102_233748_552811\mapping.log
- afdx_mac_tx: FAIL；out/synth/afdx_mac_tx/20261102_234226_130672；mapping: exit=1 reason=None; E:\2026_Embedded_FPGA\worktrees\active\c3_frag1030\out\synth\afdx_mac_tx\20261102_234226_130672\mapping.log
- afdx_mac_rx: FAIL；out/synth/afdx_mac_rx/20261102_234227_223865；mapping: exit=1 reason=None; E:\2026_Embedded_FPGA\worktrees\active\c3_frag1030\out\synth\afdx_mac_rx\20261102_234227_223865\mapping.log
- afdx_timebase: FAIL；out/synth/afdx_timebase/20261102_234228_325948；mapping: exit=1 reason=None; E:\2026_Embedded_FPGA\worktrees\active\c3_frag1030\out\synth\afdx_timebase\20261102_234228_325948\mapping.log
- probe_p1_2048x8: FAIL；out/synth/probe_p1_2048x8/20261102_234229_479745；mapping: exit=1 reason=None; E:\2026_Embedded_FPGA\worktrees\active\c3_frag1030\out\synth\probe_p1_2048x8\20261102_234229_479745\mapping.log
- probe_p2_array: FAIL；out/synth/probe_p2_array/20261102_234230_597957；mapping: exit=1 reason=None; E:\2026_Embedded_FPGA\worktrees\active\c3_frag1030\out\synth\probe_p2_array\20261102_234230_597957\mapping.log

## 输入冻结、变更与边界

- VQM 比较见 vqm_sha256.json；正式运行的 original.vqm 与布线输入相同。
- 运行、PID、创建时间、原始截止及全部历史尝试见 out/t75/baseline_run/summary.json 和 out/t75/all_attempts.json。
- 最初原样 56 项编译失败保留；随后冻结旧判据基线与最终新判据运行分列，未覆盖失败。
- 最终整表冻结源为 out/t75/candidate2_source；输入清单为 out/t75/final_source_manifest.json；RTL 工具预算显式配置为 28800 秒。
- 官方入口与最终整表的测试平台字节、34 份 RTL 一致性，以及同次 RTL/网表激励向量哈希见 official_source_compatibility.json。
- 仿真源码兼容只在 out/ 副本执行，保留所有断言；每份副本有精确逆变换收据。
- 首次 A 调用已结束；四份共享测试库已按哈希核对后恢复为最终整表实际测试的版本，与 candidate2_source 和 Git 中的已提交版本一致。收据见 out/t75/root_library_pins.json 和 final_integrity.json。
- 冻结快照共 203 个文件：201 份源/辅助文件和 2 份 Python 缓存，全部保持原哈希；根目录源文件比较排除缓存。交付工具相对快照的预算/准入/默认截止差异见 out/t75/tool_delta_after_freeze.patch；所有 A 类实际使用显式截止。
- 卡内 b3a60639 对比要求与指定 a6181267 起点的继承 physical_only.edc 差异单独列出；本任务不更改 RTL、网表或时序约束。
- 13 项资源边界检查见 resource_slot_checks.json；前缀比较器的 12 项夹具自检见 prefix_checker_selftest.json，夹具不构成 VQM 证据。
- 变更依据见 test_changes.md；缺陷和环境分类见 defects.md；网表峰值见 peak_memory.json；旧性能门槛差异见 performance_difference.md，统计未修改。

## 未通过项

- tb_sys_perf: check: exit=1 reason=None; E:\2026_Embedded_FPGA\worktrees\active\c3_frag1030\out\t75\candidate2_source\out\sim\tb_sys_perf\20261103_010524_288871\check.log
