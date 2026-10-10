# T21 官方 .vo 流程与工具选项摸底

输入 `346f3abf`（RTL 同 `d5e3ec93`）；EQ6HL130/CSG484_H、8 ns、eLinx 3.0.7、ModelSim SE-64 2020.4；全部试验在 `out/t21/`。
## 1. 官方 .vo 生成与未回标仿真

生成成功：`out/t21/projects/baseline/elinx/AFDX_EndSystem.runs/imple_1/AFDX_EndSystem.vo` 与同名 `.sdo`；五段工具合计 946.139 s。
私有 qsf 加 `EDA_SIMULATION_TOOL "ModelSim (Verilog)"`；私有 imple_1/run.psf 加 `SDF_FILE_GENERATE 1`；按 map→export→pack→route→timing 调用厂商工具，安装目录未改。
同激励 RTL：1123 项自检、59 项外部核对、下载核对器41项均PASS，124759 拍，仿真工具 6.843 s；参考 `out/t21/projects/baseline/out/sim/tb_net_services/20261010_214134_782482`。
未回标 `.vo`：只注释原 `$sdf_annotate` 行；FAIL，270 项检查、12 错误，仿真工具 1129.078 s（含优化/加载）；日志 `out/t21/sim/functional/20261010_214606_267147/simulation.log`。
首错：phase=2、cycle=65951，`fault injection while source is idle`；用户数据阶段完成，其余阶段未完成。四份 GMII 首帧与 RTL 一致，第65877拍多发 SN=64 的有效CRC帧；六份记录逐字节比对为0/6一致，见 `out/t21/external_compare.json`。
定位：导出 `.vo` 的 tx_state RAM 写入位序被重排，读出仍为自然索引；例 wd[22]→输入[20]→读出[20]，原 VQM 为 wd[22]→读出[22]。厂商源模型逐位写读，因此该网表/模型组合不等价；未改设计、网表连接或模型。
证据：上述 `.vo`:937637（输入）、41822（输出），原 `synth_1/AFDX_EndSystem.vqm`:425497 起；安装目录 `Simulation/verilog/elinx_atoms.v`:3381、3467、3610、3636 起。运行同时保留15条RAM位宽告警，库由本机ModelSim从原始源码重编译。
首次启动因系统可用内存低于5 GiB被保护中止，未完成任何功能阶段；保留 `result_functional_memory_guard.json`。随后仅将本次进程的下限设2 GiB，进程树上限仍10 GiB；网表及激励不变。
## 2. 125 MHz 带延迟试验

结果：未通过（建立时间违规，记录后结束）；仿真工具 991.219 s；停止原因 `出现明确建立时间违规后主动结束，未到2倍上限`；预算为未回标仿真时间的两倍（2258.156 s），并受整轮截止时间约束。
首个失败现象：`# ** Error: $setup( ena:7107 ps, posedge clk &&& reset:7167 ps, 170 ps );`。
日志：`out/t21/sim/sdf/20261010_223332_391942/simulation.log`。保留原始 `$sdf_annotate` 并复制实际 `.sdo`；由于未回标版本已不等价，本项不能独立归因于125 MHz时序。
## 3. 选项对照

T18旧RTL默认参考为 setup −11.542 ns、51.172 MHz；本轮另跑当前RTL默认，避免将版本差异算作选项收益。逻辑单元取官方前端的Total logic elements，LUT/CLB取布线后报告，不与T20另一前端的29954混用。

| 设置 | setup/ns | Fmax/MHz | 前端逻辑单元 | 布线后LUT/CLB |
| --- | ---: | ---: | ---: | ---: |
| 本轮默认 | -10.368 | 54.443 | 32,846 | 32847/4648 |
| Max Fanout=32 | -11.702 | 50.756 | 33,776 | 33777/4775 |
| Max Fanout=128 | -11.695 | 50.774 | 32,952 | 32953/4569 |
| Packing=Compact | -11.874 | 50.317 | 32,846 | 32847/3522 |
| Performance Explore（候选14） | -10.342 | 54.520 | 32,846 | 32847/4648 |

五组选项对照；Performance Explore按安装目录 `data/common.ini` 的20个预置候选，完成17/20，最多同时两个独立工具进程，共享执行锁覆盖整批；详细候选/命令/耗时在 `out/t21/options_status.json` 和 `out/t21/jobs/`。
Performance Explore首次因候选imple_1缺VQM而未启动布局，补复制同一VQM后继续，未改厂商脚本（原记录 `out/t21/options_setup_failure.json`）；候选10、12、16达到沿用T18的单次30分钟调用预算，未取得时序、未计入最佳值，详见对应result JSON。
Max Fanout由qsf的 `set_instance_assignment -name MAX_FANOUT <值> -to *` 控制；Compact为综合私有psf的 `VPACKFULL full`；Performance Explore用原生 `run_route_smart_explore_run.tcl`。本轮已测最高54.520 MHz，仍低于125 MHz；默认设置不变。
## 4. 复现、资料与边界

本机复现生成：`powershell -NoProfile -ExecutionPolicy Bypass -File out/t21/run_stage.ps1 -Mode baseline -Label repro_新名称 -Deadline <截止时间>`；须用新目录名；厂商Tcl实际命令保存在对应job目录，工具cwd为安装目录 `bin/shell/bin`。
复跑本轮已保存的baseline网表：同一脚本 `-Mode functional` 或 `-Mode sdf`（这两种模式固定读取baseline，不使用新Label）；选项为 `-Mode options`。临时驱动、网表、日志及库未提交；团队从ref教程及FLOW步骤建立自己的副本。
与旧教程差异：3.0.7本次直接导出VQM到synth_1，VO/SDF在imple_1；延迟文件为 `.sdo`，不是教程末尾的 `.vdo`，也不带示例中的 `_v`。顶层模块已是AFDX_top，仿真副本命名AFDX_top.vo。
资料按原文件逐字节复制：教程docx提交；UG102手册PDF在ref且被.gitignore忽略。README目录、FLOW步骤已补；受保护的已跟踪文件和T21状态行均未改。
未做：未修VO/库接口失配；未完成失败点之后的VO五功能验证；未做125 MHz物理时序签核或修改工具默认值。Performance Explore未完成候选数=3。
