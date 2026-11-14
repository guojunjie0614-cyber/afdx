# 证据目录索引

交付总览见 [frag1030_delivery/summary.md](frag1030_delivery/summary.md)。当前满负载并发规格为 63 TX / 63 RX VL，表项配置容量为 128 TX / 4096 RX VL。功能、性能、网表对照与静态时序分别以对应子目录的实测记录为依据。

| 目录或文件组 | 说明内容 | 对应版本 | 日期 | 定位说明 |
|---|---|---|---|---|
| [frag1030_delivery/](frag1030_delivery/summary.md) | 源码快速回归、配置隔离、评委基线长用例、官方 VQM 窗口对照与锁定布线时序汇总 | 分片交付版 | 11-04 | 交付验收总入口 |
| [vl63_full_load/](vl63_full_load/summary.md) | 63 VL 七场景满负载（P1–P1471、B1、B2）、逐字节完整性、双统计一致性、覆盖率汇总（58 份 UCDB）与 eLinx 界面行为仿真截图 | 分片交付版 | 11-04 | 63 VL 满负载与覆盖率主依据 |
| [frag_load/](frag_load/summary.md) | 负载注入边界探索：63 VL 混合负载 100 ms 验证、81 VL 溢出压力边界及公开应用口时戳统计详情 | 分片交付版 | 11-03 至 11-04 | 负载边界与混合场景依据；81 VL 仅作超规格压力参考 |
| [route_sta/](route_sta/summary.md) | 双工具编译兼容（`MODEL_TECH`）、综合输入等价核对、`NUM_PARALLEL_PROCESSORS=1` 排查与锁定布线两次独立复现（+29 ps / +604 ps） | 分片交付版 | 11-03 至 11-04 | 综合与锁定布线时序依据 |
| [vqm_compat/](vqm_compat/summary.md) | 分片版全套 RTL 回归、官方 VQM 对照窗口与分片前缀（199,578 拍）记录，及旧零残差检查器差异说明 | 分片交付版 | 11-03 至 11-04 | 全表 RTL 与前缀网表对照依据 |
| [mac_results.json](mac_results.json)、[mac_official_resources.json](mac_official_resources.json)、[mac_self_resources.json](mac_self_resources.json)、[mac_official_stress.json](mac_official_stress.json)、[mac_self_rtl.json](mac_self_rtl.json)、[mac_self_net.json](mac_self_net.json)、[mac_bad_crc.json](mac_bad_crc.json) | 自研精简 MAC 与官方生成 MAC IP 的资源占用、端到端时延、千兆测速及错误帧专项对照 | 分片前基线 | 10-11 | 设计取舍依据（供 `FACTS.md` 附录引用） |
| [vo_functional.json](vo_functional.json)、[vo_ram.json](vo_ram.json)、[vo_ram_bits.json](vo_ram_bits.json) | 厂商 `.vo` 网表与 RAM 仿真模型位序映射差异及最小复现 | 分片前基线 | 10-10 | 网表格式选型依据 |
| [performance.json](performance.json) | 早期定长性能检查原始输出 | 分片前历史 | 10-26 | 历史基线存档，供测试报告附录核对 |
| [perf_r97.json](perf_r97.json)、[rtc.json](rtc.json)、[capacity.log](capacity.log)、[snmp.log](snmp.log) | 早期性能（核心 `afdx_es` 变长循环 9.992 µs）、RTC、容量与 SNMP 原始日志 | 分片前历史 | 10-28 | 历史基线存档，供测试报告附录核对 |
