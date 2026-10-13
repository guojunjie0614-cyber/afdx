# T26c：界面综合网表功能仿真通过

- 基线 `bfd4e3f9`；使用用户在 eLinx 界面生成的 `elinx/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm`，没有重新综合。
- 原网表 SHA256：`3d98d1b93be02287d2a058ec349dd745a3e368e361ea923def7ae9de181c57eb`；仿真副本 SHA256：`57841773a21957d9914e8fbc909984a0cc844333d9f94bfc6092b23fc3aa2291`。
- 处理 32846 个逻辑单元和 538 个 RAM 单元；沿用 T26b 的 427486 个默认输入补值，新补 `cin_used="true"` 3933 项（3679 个算术单元、254 个普通单元）。本轮只新增进位使用参数这一类，未修改 LUT 字面量。
- 下表路径相对于 eLinx 安装根目录；组件声明为 `bin/Passkey/libraries/vhdl/wysiwyg/stratix_components.vhd`，模型为 `Simulation/elinx_lib/stratix_atoms.v`。

| 省略项 | 补全依据与独立证据 |
|---|---|
| lcell 默认输入 | 组件声明 546–561 行及模型 1012–1013 行；备用 cin0/cin1 默认未启用，模型 406–409、665–699 行。逐端口补值沿用 [T26b](PROBE_T26b.md)。 |
| RAM 默认输入 | 模型 3114–3137 行的 `tri0`、`tri1`；数据和字节掩码按参数位宽补值，详见 T26b。 |
| 原有进位连接的使用参数 | 模型 979、1037、692–698 行：默认 `cin_used=false` 会忽略实际 `cin`；仅按原网表连接补 true，不能把适配器新增的常量当成原有进位。 |

- 进位单元实验本轮重新执行，a/cin 为 00、01、10、11 时，原实例输出为 0/0/1/1，只补使用参数后的输出为 0/1/1/0；四项符合实际进位计算，见 `out/t26c/carry_probe.json`。
- 原样 `tb_elinx`：PASS，checks=9238、errors=0；1/64/1471 字节双向交付均通过，仿真耗时 7826.703 秒。
- 原样五功能 `tb_net_services`：RTL 和界面网表均 PASS，checks=1123、errors=0；分别耗时 3.453、3118.406 秒，均在 cycle=124759 完成。
- 独立检查：RTL 59 项、网表 65 项全部通过，RTC 差值 0 ns；七份记录 `net_services.txt`、`es1_a.txt`、`es1_b.txt`、`es2_a.txt`、`es2_b.txt`、`es2_rx_a.txt`、`download_results.txt` 逐字节相同。
- 主流水线三个阶段的 ModelSim Error/Fatal/Warning 均为 0；原生命令、日志、最终结果及比对见 `out/t26c/pipeline.json` 所列目录的 `summary.json`、`simulation.log`、`check.log`。
- 复现入口：`powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_gui_netlist.ps1`；先在界面点 Run Synthesis，默认跑 tb_elinx，追加 `-Test tb_net_services` 会先生成同激励 RTL 参考并检查外部记录。
- 候选 PowerShell 入口用 `-Test tb_net_services` 完整复跑并返回 0：RTL/网表仍各 1123 项、0 错误，分别 3.703/3121.109 秒；独立 65 项和七份记录比对再次通过，见 `out/t26c/entry_validation.log` 及 `out/gui_netlist/tb_net_services_gui/20261013_213142_900813/summary.json`。
- PowerShell 5.1 解析和 UTF-8 BOM 检查通过；缺少网表的实际运行打印 FAIL、返回 1；候选补全脚本输出与主流水线副本逐字节相同。
- 纳入仓库前复核初始 157 个已跟踪文件、原网表和五份厂商模型，摘要全相同；提交仅含 README、三个新入口脚本和本报告，任务卡保持原样。未改 RTL、eLinx 工程或 runs，未重新综合、未推送、未触碰其他工作区。
- 范围：综合后功能仿真，不含布线延时，不替代性能网表或上板测量。README 保留源码自检步骤，并补充界面网表步骤及实跑结果。
