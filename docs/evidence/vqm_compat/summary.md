# 分片交付版全表 RTL 与官方 VQM 对照记录

本文汇总分片交付版全套 RTL 回归与官方 VQM 门级对照实测数据。其中 `tb_sys_perf` 按早期固定注入拍与严格零残差检查器计出 `702` 项差异，改为公开应用口实测口径后已全量通过，详见证 [performance_difference.md](performance_difference.md) 与 [frag1030_delivery/summary.md](../frag1030_delivery/summary.md)。

## 官方 VQM 与显式 RTL 配对对照

| 测试 | 类别 | 结果 | 自检数 | 外部对照项 | 仿真耗时 s |
|---|---|---|---:|---:|---:|
| `tb_elinx` | 官方 VQM | PASS | 9,238 | — | 52,312.469 |
| `tb_net_services` | 官方 VQM | PASS | 1,123 | 65 | 23,614.453 |
| `tb_frag1030_net` | 官方 VQM | PASS-PREFIX | — | 5 组字节比对 | 34,727.859 |
| `tb_net_services` | RTL 配对参考 | PASS | 1,123 | 59 | 10.344 |
| `tb_frag1030_net` | RTL 配对参考 | PASS | 33 | 9 | 42.313 |

- `tb_elinx` 按卡内规范使用公开端口独立自检；`tb_net_services` 全窗口外部记录与配对 RTL 参考逐字节相同；`tb_frag1030_net` 官方 VQM 运行至第 `199,578` 拍（含 1472 B 两帧分片重组与 A/B 各 6 帧、RX 4 条、发送记录 8 行与事件日志 5 组字节逐一核对），详见 [fragment_prefix.json](../frag1030_delivery/fragment_prefix.json) 与 [vqm_official.json](../frag1030_delivery/vqm_official.json)。
- RX/TX 两路独立端点的 1 ms 官方 VQM 对照窗口已完成并全量通过（各 161 checks），见 [vqm_windows.json](../frag1030_delivery/vqm_windows.json)。

## 全套 RTL 与参数分支测试记录

| 测试 | 类别 | 结果 | 检查数 | 外部对照项 | 仿真耗时 s |
|---|---|---|---:|---:|---:|
| `tb_ram_sdp` | RTL | PASS | 20,764 | — | 5.344 |
| `tb_mac_tx` | RTL | PASS | 264,649 | — | 6.750 |
| `tb_mac_rx` | RTL | PASS | 105,303 | — | 5.563 |
| `tb_mac_loop` | RTL | PASS | 1,385,254 | — | 5.422 |
| `tb_tx_basic` | RTL | PASS | 662,983 | 8,008 | 7.750 |
| `tb_tx_basic (TX_PAGE_AW=5, TX_OFF_AW=11)` | RTL | PASS | 662,557 | 8,008 | 7.547 |
| `tb_tx_bag` | RTL | PASS | 14,054,439 | 14,758 | 44.391 |
| `tb_tx_multi` | RTL | PASS | 14,440,385 | 57,904 | 50.610 |
| `tb_tx_drop` | RTL | PASS | 30,552,330 | 7,723 | 104.360 |
| `tb_tx_net` | RTL | PASS | 236,158 | 245 | 5.921 |
| `tb_rx_basic` | RTL | PASS | 9,960,369 | 123,855 | 26.094 |
| `tb_rx_fault` | RTL | PASS | 576,797 | 888 | 6.625 |
| `tb_rx_icrm` | RTL | PASS | 4,635,236 | 1,274 | 12.593 |
| `tb_rx_load` | RTL | PASS | 6,406,189 | 19,180 | 16.562 |
| `tb_rx_ovf_ring (RX_RING_AW=9)` | RTL | PASS | 422,837 | 99 | 5.078 |
| `tb_rx_ovf_dq (RX_DQ_AW=1)` | RTL | PASS | 373,852 | 57 | 5.703 |
| `tb_rx_net` | RTL | PASS | 374,111 | 110 | 5.750 |
| `tb_sys_basic` | RTL | PASS | 5,159,270 | 2,930 | 30.843 |
| `tb_sys_fault` | RTL | PASS | 42,129,011 | 9,064 | 208.281 |
| `tb_sys_delay` | RTL | PASS | 13,940,507 | 3,945 | 72.875 |
| `tb_sys_load` | RTL | PASS | 193,106,816 | 123,400 | 1,124.078 |
| `tb_sys_cfg` | RTL | PASS | 19,044,227 | 718,303 | 100.140 |
| `tb_sys_reset` | RTL | PASS | 10,182,209 | 3,876 | 48.328 |
| `tb_sys_ovf (RX_RING_AW=9)` | RTL | PASS | 8,886,303 | 1,562 | 43.657 |
| `tb_sys_net` | RTL | PASS | 2,793,425 | 1,315 | 18.656 |
| `tb_sys_perf` | RTL | 见上说明（旧零残差差异） | 683,408,635 | 1,325,290 | 4,496.625 |
| `tb_sys_rtc` | RTL | PASS | 10,675,841 | 1,811 | 937.937 |
| `tb_sys_snmp` | RTL | PASS | 37,611 | 926 | 142.500 |
| `tb_sys_snmp_settrap` | RTL | PASS | 8,563 | 188 | 119.844 |
| `tb_sys_615a` | RTL | PASS | 44,098 | 752 | 285.360 |
| `tb_gbe_burst (COUNT=77)` | RTL | PASS | 530,802 | — | 27.312 |
| `tb_gbe_burst (COUNT=81)` | RTL | PASS | 554,734 | — | 27.391 |
| `tb_rm_phase` | RTL | PASS | 353,130 | — | 60.328 |
| `tb_rtc_recovery` | RTL | PASS | 28 | — | 3.797 |
| `tb_rtc_originate` | RTL | PASS | 34 | — | 3.515 |
| `tb_judge_capacity` | RTL | PASS | 49,924 | — | 26.891 |
| `tb_judge_snmp` | RTL | PASS | 699 | — | 85.813 |
| `tb_elinx` | RTL | PASS | 9,238 | — | 24.406 |
| `tb_sys_perf_var` | RTL | PASS | 1,254,291,331 | 1,701,468 | 6,200.359 |
| `tb_top_wrap` | RTL | PASS | 12,284 | — | 12.891 |
| `tb_t65_queue_a` | RTL | PASS | 3,088 | 10 | 4.172 |
| `tb_t65_reset_app` | RTL | PASS | 204 | 42 | 17.593 |
| `tb_t65_reset_mac` | RTL | PASS | 204 | 45 | 17.797 |
| `tb_t65_reset_rx` | RTL | PASS | 204 | 44 | 17.562 |
| `tb_t65_rx_data` | RTL | PASS | 14,536,729 | 9,874 | 80.687 |
| `tb_t65_rx_desc` | RTL | PASS | 669 | 216 | 3.547 |
| `tb_t65_tx_desc` | RTL | PASS | 222,062 | 250 | 7.672 |
| `tb_t65_tx_hint` | RTL | PASS | 219,054 | 235 | 7.687 |
| `tb_t65_tx_init` | RTL | PASS | 198,841 | 14 | 7.406 |
| `tb_t65_tx_ready` | RTL | PASS | 221,142 | 239 | 7.672 |
| `tb_t65_tx_short_full` | RTL | PASS | 504,828 | 18 | 10.656 |
| `tb_t65_tx_short_init` | RTL | PASS | 498,847 | 17 | 10.672 |
| `tb_t65_tx_short_normal` | RTL | PASS | 499,054 | 17 | 11.766 |
| `tb_t65_tx_space` | RTL | PASS | 246,327 | 22 | 7.984 |
| `tb_t65_tx_space_edge` | RTL | PASS | 223,502 | 14 | 8.157 |
| `tb_t65_tx_unmapped` | RTL | PASS | 199,811 | 14 | 7.969 |
| `tb_cfg_local_ready` | RTL | PASS | 6,090 | — | 4.328 |
| `tb_context_pipeline` | RTL | PASS | 134 | — | 3.578 |
| `tb_reassembly_engine` | RTL | PASS | 39 | — | 3.875 |
| `tb_reassembly_limits` | RTL | PASS | 71 | — | 3.844 |
| `tb_reassembly_transactions` | RTL | PASS | 126 | — | 4.406 |
| `tb_service_pipeline` | RTL | PASS | 127 | — | 3.875 |
| `tb_rtc_banked` | RTL | PASS | 34 | — | 3.844 |
| `tb_fragmentation` | RTL | PASS | 33 | 9 | 59.735 |
| `tb_app_payload_pipeline` | RTL | PASS | 726,856 | — | 6.047 |
| `tb_tx_ingress_elastic` | RTL | PASS | 139,695 | — | 3.547 |
| `tb_tx_buffer_bounds` | RTL | PASS | 49,800 | — | 3.688 |

注：早期 `afdx_tx_buf.v:115` 含 `$fatal` 断言语句，采用单模块独立前端映射辅助网表时会被前端拒绝；实际整表交付流程以全顶层 `elinx/afdx_all.v` 官方 VQM 综合与 67 项全量直接 RTL 仿真为准，eLinx 行为仿真截图见 [elinx_gui_behav_pass.png](../vl63_full_load/elinx_gui_behav_pass.png)。
