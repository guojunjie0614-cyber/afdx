# T1 RAM与工具链探测

原生eLinx3.0.7／ModelSim SE2020.4；EQ6HL130、CSG484_H、TT/no_pack、clk=10ns。未布局布线，无时序例外和外部I/O假预算。
表中RAM数是stratix_ram_block实例数，不由总位数除4096估算，也不代表装箱后的物理占用。逻辑单元含探测包装的寄存器。
日志根为out/synth；每行目录下mapping.log／timing.log及SQLite synthesized_timing.pb保存原始数字。未跑项原因直接列出。

| 探测 | lcell | RAM | setup WNS(ns) | hold WNS(ns)/失败端点 | Fmax(MHz) | 日志目录（相对out/synth） |
|---|---:|---:|---|---|---|---|
| P1 2048x8 | 40 | 8 | +6.831 | -0.068/8 | 315.556976 | probe_p1_2048x8/20261007_201206_524939 |
| P1 128x32 | 80 | 32 | 未跑：本项只验映射/初值 | 未跑：同左 | 未跑：同左 | probe_p1_128x32/20261007_201212_903764 |
| P1 4096x44 | 114 | 44 | 未跑：本项只验映射/初值 | 未跑：同左 | 未跑：同左 | probe_p1_4096x44/20261007_201217_804078 |
| P1 4096x13 | 52 | 13 | 未跑：本项只验映射/初值 | 未跑：同左 | 未跑：同左 | probe_p1_4096x13/20261007_201222_718057 |
| P2 65536x13 | 233 | 208 | +6.089 | -0.068/208 | 255.689087 | probe_p2_array/20261007_201227_619587 |
| P3 16banks | 447 | 208 | +6.831 | -0.068/208 | 315.556976 | probe_p3_banks/20261007_201235_529869 |
| P4 staged（128×32） | 145 | 32 | +5.171 | -0.068/32 | 207.082214 | probe_p4_staged/20261007_201243_455423 |
| P4 direct（128×32） | 105 | 32 | +5.171 | -0.068/32 | 207.082214 | probe_p4_direct/20261007_201249_901442 |
| P5 zero（2048×8） | 0 | 8 | 未跑：本项只验映射/初值 | 未跑：同左 | 未跑：同左 | probe_p5_zero/20261007_201256_373707 |
| P5 readmemh（2048×8） | 0 | 8 | 未跑：本项只验映射/初值 | 未跑：同左 | 未跑：同左 | probe_p5_readmemh/20261007_201313_491234 |

P1四种规格均实际推断RAM；2048×8、128×32、4096×44、4096×13分别8、32、44、13个，不能按理想密度推算小表占用。
P2与P3均208个RAM；P3增加逐bank输出寄存器，setup最差改善0.742ns；整体hold仍失败，不宣称100MHz完整通过。P3的单级16选1是T1指定比较原型，产品仍按ARCH第9节分拍。
P2/P3所报最差setup路径为RAM内部port_b_address_dff/Q到后级ff/D；完整起终点见对应timing_summary.json的worst_path。路径子集出现RAM，不证明所有RAM弧覆盖。
P4两种都先寄存地址、写数据/使能和减数；分拍版145 lcell、直算版105 lcell，均32 RAM、setup +5.171ns。直接表达式的已寄存地址被工具合入RAM读控制。
初版P4直算地址直接来自端口时为9770 lcell/0 RAM；该非最终包装的旧日志保留在out/synth/probe_p4_direct/20261007_200749_656477，不作为本表比较。
P5两种initial语法均接受、0警告、8 RAM，生成auto_generator_rom_*.mif；2048个8位MIF字与全0/输入hex逐项一致，未忽略逻辑初值。
但P5导出RAM的port_b_first_bit_number仅0/1重复，尚不能证明8个逻辑位的初值映射正确。init_check_final.log明确UNVERIFIED、退出2；原失败init_check.log保留，未用模型修改隐藏疑点。
P5没有运行网表初始化行为或烧录验证；保留上述元数据疑问，不将语法接受写成硬件初值已验证。
原生VQM的lcell/RAM数与mapped.il全部对应；STA五项setup失败0，hold失败如表。Memorys等厂商字段与这些实例单位不混算。
单次映射约4.2—16.2秒，STA约0.8—1.4秒（最终矩阵）；准确耗时见tool_metrics.json。

## 复现命令

以下从schemes/scheme_c3执行，输出目录自动隔离，不覆盖已有产物：
1. E:/Tools/PowerShell/7/pwsh.exe -NoProfile -File sim/run.ps1 -Test tb_ram_sdp
2. E:/Tools/PowerShell/7/pwsh.exe -NoProfile -File sim/regress.ps1
3. E:/anaconda3/python.exe tools/probe_t1.py <ISO工具截止时间>（完整P1—P5）
4. E:/Tools/PowerShell/7/pwsh.exe -NoProfile -File elinx/synth.ps1 -Top <表中目录名前半部> [-Sta]
5. E:/anaconda3/python.exe tools/check_init.py <P5完整输出目录> zero或readmemh（MIF正确、位偏移未验证时退出2）

RAM RTL测试20764检查／0错误；全地址覆盖四种规格、恰好一拍读、禁读保持、禁写后最低/最高地址不变。仅端口检查，同拍读写同址未依赖。
最终日志out/sim/tb_ram_sdp/20261007_202545_478121/simulation.log；入口回归一次PASS，-Netlist预留／缺失测试模块都实际返回非0，日志out/checks_20261007_201917。
C3网表功能仿真尚未运行，-Netlist未实现且帮助明确；其他任务未执行。
