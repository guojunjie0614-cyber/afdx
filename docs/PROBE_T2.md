# T2 MAC、CRC32 与网表验证

基线 12550a47、ARCH v0.2；eLinx3.0.7／ModelSim SE2020.4，EQ6HL130/CSG484_H、TT、clk=10ns。B 为 no_pack 未布线估算，无时序例外或外部 I/O 假预算。
以下目录均相对 schemes/scheme_c3/out；B 每行目录内 mapping.log、timing.log、synthesized_timing.pb 和 timing_summary.json 是原始数字入口。五项 RAM 均为 0。

| 综合顶层 | lcell | setup WNS(ns) | hold WNS(ns) | 最差 setup 起点 → 终点 | 日志目录 |
|---|---:|---:|---:|---|---|
| afdx_timebase | 33 | +7.532 | +0.710 | `_34_\|ff/Q → c3_native_cell_22\|ff/D` | `synth/afdx_timebase/20261007_232709_546528` |
| afdx_mac_tx | 576 | +7.409 | +0.710 | `c3_native_cell_118\|ff/Q → c3_native_cell_124\|ff/D` | `synth/afdx_mac_tx/20261007_232715_551845` |
| afdx_mac_rx | 244 | +6.980 | +0.710 | `c3_native_cell_92\|ff/Q → c3_native_cell_47\|ff/ena` | `synth/afdx_mac_rx/20261007_232723_135887` |
| probe_mac_tx | 617 | +7.409 | +0.620 | `c3_native_cell_118\|ff/Q → c3_native_cell_124\|ff/D` | `synth/probe_mac_tx/20261007_232729_673644` |
| probe_mac_rx | 279 | +6.960 | +0.620 | `c3_native_cell_89\|ff/Q → c3_native_cell_100\|ff/ena` | `synth/probe_mac_rx/20261007_232737_265182` |

五项 setup 均≥4.0ns，setup/hold 失败端点均0，综合及原生STA无错误/警告；该结论不代替完整工程、外部I/O或物理时序签核。

| 网表测试 | 检查数 / 错误 | simulation.log 所在目录 |
|---|---:|---|
| tb_mac_tx | 1703516 / 0 | `net/tb_mac_tx/20261007_232744_720214` |
| tb_mac_rx | 409817 / 0 | `net/tb_mac_rx/20261007_232806_953475` |
| tb_mac_loop | 7110567 / 0 | `net/tb_mac_loop/20261007_232816_492136` |
| tb_probe_ram/probe_p1_2048x8 | 4096 / 0 | `net/tb_probe_ram/20261007_232957_477918` |
| tb_probe_ram/probe_p2_array | 131072 / 0 | `net/tb_probe_ram/20261007_233002_716210` |

最终 sim/regress.ps1 -Netlist：5/5通过，编译/仿真退出0且零错误/警告。loop 的 timebase、TX和两个RX实例全部使用对应网表；RAM先全写全读，再改写偶地址并全读，未验证上电初值。
RTL回归4/4通过：tb_ram_sdp 20764、tb_mac_tx 1703516、tb_mac_rx 409817、tb_mac_loop 7110567；均0错误/警告。t2_final_tests.json 的 rtl 条目给出四个完整目录，各含 simulation.log、summary.json 和工具指标。
覆盖：TX72案例（八相位、三处欠载及中途复位）、RX70案例、loop224帧；loop的A/B抓包112/123帧，坏帧0，RTL与网表逐字节及起始周期一致；证据为上述loop目录的dump_*.txt、network_*.pcap、rtl_capture_comparison.json。
参考工具selftest 16检查通过；5组向量同种子逐文件一致；pcap四类坏输入正确分类。证据 `reference_final_20261007_233025/audit.json`、selftest.log。
旧失败保留：net/tb_probe_ram/20261007_230948_153760/simulation.log 为8位向量四位文本引起的2条警告；已改按位宽输出，最终4096项复验无警告。

## hold 与布局布线核查
D核查用时20.7分钟；原始路径和数值见 hold_route_20261007_233544/hold_summary.json，尝试结果见同目录result.json。
8个违例终点均为RAM写数据寄存器 port_a_data_in_dff/D；首条起点 c3_native_cell_31|ff/Q，终点完整层级见 hold_summary.json。不是地址或写使能引脚。
单位ps：发射时钟1152、捕获时钟1906、偏差754；数据延迟696（FF输出490+RAM输入弧206）、走线0、保持要求10，所以696−754−10=−68。
原生装箱/布局/布线命令已执行；impl/probe_p1_2048x8_route/20261007_234619_188116/utilization_routed.rpt 报40 LUT、40 FF、4个物理RAM块、51引脚；8个逻辑切片合成4块。
布线后setup/hold未取得有效结果：同目录implementation.edi记录route.dly.pb.tr.cfg版本/延迟导入错误，时序报告仍为零走线延迟的+6.831/−0.068ns；这些数不能记作布线后通过。route_status.rpt的routable/fully-routed计数均0，与路由文件不能直接形成完整覆盖判定。
已试工具入口工作目录、确认无IP/初值后省略EPR扫描、原生时序导出及依赖保存/加载；所有原始失败保留。235004_767761尝试发生原生异常；235244_979766依赖加载虽无诊断，但走线时延仍0且路由统计重复。缺少可验证的路由延迟导入/完整路由状态，不修改模型或约束规避。
结论：A/B/C完成；D已定位原始hold并完成命令行尝试，尚未证实hold在布线后消失。没有运行SDF时序仿真，也没有执行T3。
边界偏离：收尾确认原生setlogfile回写了安装目录 E:/2026_Embedded_FPGA/setup_pack/bin/shell/bin/log4cpp.property 的日志目标；运行前内容未留存，未手工恢复未知原值。C3入口已改为out私有副本，额外probe_p1_128x32综合/STA实测原安装文件字节和mtime均未再改变，见 private_logging_audit.json、synth/probe_p1_128x32/20261008_000505_931548；此遗留副作用交Claude验收。
