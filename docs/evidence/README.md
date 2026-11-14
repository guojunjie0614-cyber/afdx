# 证据目录索引

先看 [frag1030_delivery/summary.md](frag1030_delivery/summary.md)，再按下表查找具体测量及其覆盖范围。当前满负载规格为 63 TX / 63 RX VL；配置容量仍为 128 TX / 4096 RX VL。功能、性能、网表对照与时序分别以对应记录为依据。

| 目录或文件组 | 证明什么 | 对应 RTL | 日期 | 是否是当前交付依据 |
|---|---|---|---|---|
| [frag1030_delivery/](frag1030_delivery/summary.md) | 最终源码回归、配置隔离、历史长用例绑定、官方 VQM 对照及布线时序的汇总；列明工程登记差异与覆盖边界 | 分片交付版 | 11-04 | 是，交付总入口 |
| [t79_63vl/](t79_63vl/summary.md) | 63 VL 七场景满负载、逐字节完整性、双统计、周期与 BAG 等待抖动、eLinx 界面行为仿真；含暂停的并发长消息专项 | 分片交付版 | 11-04 | 是；暂停专项的局部结果不作并发规格依据 |
| [t76_frag1030/](t76_frag1030/summary.md) | 满负载与分片负载、63 VL 混合、81 VL 压力测试及公开应用口时戳统计；TX/RX VQM 终态见交付总入口 | 分片交付版；含未交付兼容候选的失败 | 11-03 至 11-04 | 是，按场景引用；81 VL 不作满负载规格 |
| [t77_rtl_compat/](t77_rtl_compat/summary.md) | ModelSim 声明兼容、综合输入等价、官方综合与锁定布线的两次独立复现 | 分片交付版；含第一版停止记录 | 11-03 至 11-04 | 是，以 v2 最终记录为准 |
| [t75_frag1030/](t75_frag1030/summary.md) | 分片版 RTL 回归、官方 VQM 完整窗口与分片前缀；保留旧性能检查器失败分类 | 分片交付版 | 11-03 至 11-04 | 是，按覆盖范围引用；性能以随后通过的记录为准 |
| [mac_results.json](mac_results.json)、[mac_official_resources.json](mac_official_resources.json)、[mac_self_resources.json](mac_self_resources.json)、[mac_official_stress.json](mac_official_stress.json)、[mac_self_rtl.json](mac_self_rtl.json)、[mac_self_net.json](mac_self_net.json)、[mac_bad_crc.json](mac_bad_crc.json) | 自研 MAC 与官方生成配置的资源、延迟、测速及错误帧专项对照，供 [FACTS 附录](../FACTS.md#九附录设计取舍依据的专项实验)引用 | 分片前历史 | 10-11 | 仅作设计取舍依据，不作当前整机验收 |
| [vo_functional.json](vo_functional.json)、[vo_ram.json](vo_ram.json)、[vo_ram_bits.json](vo_ram_bits.json) | 原厂 .vo 与配套 RAM 模型的位序差异及最小复现，供 FACTS 附录引用 | 分片前历史 | 10-10 | 仅作网表格式选择依据 |
| [performance.json](performance.json) | 旧定长性能检查输出；保留历史引用 | 分片前历史，提交 286fa1b6 | 10-26 | 否；测试报告附录仍引用此组历史证据，保留 |
| [perf_r97.json](perf_r97.json)、[rtc.json](rtc.json)、[capacity.log](capacity.log)、[snmp.log](snmp.log) | 旧性能、RTC、容量及 SNMP 原始结果；测试报告附录仍引用 | 分片前历史，提交 92ab7d7e | 10-28 | 否；保留以供核对旧报告 |
| [manifest.json](manifest.json) | 顶层归档文件的来源、字节数、SHA256 与历史标注；不是各子目录的总清单 | 随各条目，均为历史归档 | 10-10 至 10-28 | 用于追溯归档，不代替当前交付结果 |

`t75`–`t79` 是开发时的任务编号，只作目录名，不表示交付等级或验收状态。证据正文保留当时记录，过时状态由文件顶部的“当前状态”说明衔接。

- [t79_63vl/stopped_initial/](t79_63vl/stopped_initial/) 与同目录的 `initial_*` 是按旧停止条件中止的初次记录；P1471/B2 后来在新目录按相同参数重跑，当前结果以该目录 summary 及 [run_receipt.json](t79_63vl/run_receipt.json)为准。
- `t77_rtl_compat/v1_*` 保留第一版运行、停止现场及失败日志，见 [v1_summary.md](t77_rtl_compat/v1_summary.md)。
- [t77_rtl_compat/v2_raw/R1/](t77_rtl_compat/v2_raw/R1/) 与 [E2E/](t77_rtl_compat/v2_raw/E2E/) 为两次独立布线：前者重新导入第一版原样 VQM 打包、布线，后者从兼容修正后的 RTL 完整构建。两次时序和落位结果相同，用于说明该锁定布线在这两次流程中可复现；不据此推广为跨机器或跨安装的确定性结论。
