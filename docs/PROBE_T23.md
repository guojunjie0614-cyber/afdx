# T23 注释、模板与评委入口走查

- 基线 `0b4d4b2a`；注释提交 `6cee516`，接口与入口提交 `e65fe55`；任务卡随第一次提交原样保存，状态行未改。
- 23 个 RTL 与 51 个测试文件补注释；第一提交仅新增494行注释，代码词法一致。顶层按模板排列八个wire端口，tx_ready仅改为内部同拍寄存器的assign输出；收尾更正地址注释，复综合网表排除生成日期后与已测网表逐字节一致。
- 走查副本：`out/t23/judge_baseline`、`entry_check`、`validation`；由 git archive 干净导出，完整验证冻结 115 个提交内输入文件。全部试验位于 out/t23。
- 入口缺口：原 do 仅五功能，指标入口依赖 Python；现补 `sim/run_judge.do` 和固定 72 项 RTC 向量，README 增加五条上手命令、网表步骤和指标输出定位，run.ps1 追加实测 METRIC 行。
- 在不含 Python 的 PATH 中，纯 ModelSim 四组自检全过；突发 77/81 VL 为 959.272/1008.488 µs，RTC 为 0/10788 ns。副本注入失败后正确打印 FAIL、退出 1；原五功能入口也实跑通过。
- eLinx 工程源表与 rtl 的 23 文件完全一致，路径为工程相对形式；干净副本按现有脚本综合成功，EPR 无需改动。GUI 点击未验证。
- RTL 回归 37/37：RESULT 合计 1186108152，独立检查 2305789；77 VL 两种链路工况均为 906.136 Mbps、最大端到端 24.408 µs、抖动 0，RTC 空载/满载 0/10788 ns，均未变化。
- 重新综合：逻辑单元 29954→29943（少11），未装箱RAM切片仍783，8 ns setup仍+2.749 ns、hold仍-0.068 ns。同路径受控原稿/仅注释/模板/重复原稿为29954/29943/29943/29954，寄存输出单元均13011：属注释后的工具映射变化，端口调整未再改变数量；仅未布局估算。
- 网表清单 8/8；最后仅跑一次整顶层五功能网表，1123 项自检、65 项独立核对通过，六份外部记录与同激励 RTL 逐字节一致。
- 复现：README 快速上手及 FLOW 网表入口；本次顺序、原始日志、输入摘要、逐项结果见 `out/t23/validation_status.json` 与 `out/t23/validation/out/`。未做 GUI 操作、布局布线或上板；未改 RTL 逻辑、测试逻辑和默认综合选项。

| 文件：注释行前→后 | 文件：注释行前→后 | 文件：注释行前→后 |
|---|---|---|
| `rtl/afdx_615a.v`：14→101 | `rtl/afdx_cfg.v`：8→20 | `rtl/afdx_crc32_d8.v`：4→7 |
| `rtl/afdx_gmii_rx.v`：10→17 | `rtl/afdx_gmii_tx.v`：10→18 | `rtl/afdx_mac_rx.v`：5→14 |
| `rtl/afdx_mac_tx.v`：5→18 | `rtl/afdx_ntp_fraction.v`：5→10 | `rtl/afdx_ram_sdp.v`：7→11 |
| `rtl/afdx_rtc.v`：11→28 | `rtl/afdx_rx_core.v`：5→15 | `rtl/afdx_rx_deliver.v`：6→14 |
| `rtl/afdx_rx_engine.v`：10→27 | `rtl/afdx_rx_parse.v`：9→22 | `rtl/afdx_snmp.v`：9→66 |
| `rtl/afdx_svc.v`：4→13 | `rtl/afdx_timebase.v`：4→8 | `rtl/AFDX_top.v`：6→26 |
| `rtl/afdx_tx_buf.v`：7→26 | `rtl/afdx_tx_builder.v`：11→24 | `rtl/afdx_tx_core.v`：4→16 |
| `rtl/afdx_tx_engine.v`：7→25 | `rtl/afdx_tx_free.v`：5→13 | `tb/lib/download_test_tasks.vh`：2→4 |
| `tb/lib/gmii_monitor.v`：1→3 | `tb/lib/line_driver.v`：0→2 | `tb/lib/line_monitor.v`：0→2 |
| `tb/lib/link_model.v`：5→7 | `tb/lib/load_test_endpoint.v`：1→3 | `tb/lib/mac_tx_suite.v`：0→2 |
| `tb/lib/rm_age_probe.v`：3→5 | `tb/lib/rtc_retry_suite.v`：2→4 | `tb/lib/rx_core_suite.v`：1→3 |
| `tb/lib/snmp_test_endpoint.v`：0→2 | `tb/lib/sys_endpoint.v`：4→6 | `tb/lib/sys_suite.v`：4→6 |
| `tb/lib/tx_core_suite.v`：2→4 | `tb/tb_gbe_burst.v`：1→3 | `tb/tb_gmii_rx.v`：6→8 |
| `tb/tb_gmii_tx.v`：2→4 | `tb/tb_mac_loop.v`：0→3 | `tb/tb_mac_rx.v`：1→4 |
| `tb/tb_mac_tx.v`：0→3 | `tb/tb_net_services.v`：1→3 | `tb/tb_probe_ram.v`：0→2 |
| `tb/tb_ram_sdp.v`：3→5 | `tb/tb_rm_phase.v`：3→5 | `tb/tb_rtc_originate.v`：0→2 |
| `tb/tb_rtc_recovery.v`：0→2 | `tb/tb_rx_basic.v`：0→3 | `tb/tb_rx_fault.v`：0→3 |
| `tb/tb_rx_icrm.v`：0→3 | `tb/tb_rx_load.v`：0→3 | `tb/tb_rx_net.v`：0→3 |
| `tb/tb_rx_ovf_dq.v`：0→3 | `tb/tb_rx_ovf_ring.v`：0→3 | `tb/tb_sys_615a.v`：2→5 |
| `tb/tb_sys_basic.v`：0→3 | `tb/tb_sys_cfg.v`：0→3 | `tb/tb_sys_delay.v`：0→3 |
| `tb/tb_sys_fault.v`：0→3 | `tb/tb_sys_load.v`：0→3 | `tb/tb_sys_net.v`：0→3 |
| `tb/tb_sys_ovf.v`：0→3 | `tb/tb_sys_perf.v`：0→3 | `tb/tb_sys_reset.v`：0→3 |
| `tb/tb_sys_rtc.v`：4→6 | `tb/tb_sys_snmp.v`：3→6 | `tb/tb_sys_snmp_settrap.v`：0→3 |
| `tb/tb_tx_bag.v`：0→3 | `tb/tb_tx_basic.v`：0→3 | `tb/tb_tx_drop.v`：0→3 |
| `tb/tb_tx_multi.v`：0→3 | `tb/tb_tx_net.v`：0→3 |  |
