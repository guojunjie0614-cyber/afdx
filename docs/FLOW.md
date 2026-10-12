# C3 工具入口

工作目录为仓库根目录（含 `rtl/`、`tb/`、`sim/`、`tools/`、`elinx/`）。脚本仿真、综合的日志、抓包、波形和工作库写入 `out/`；图形工程产物由 eLinx 在工程目录中管理。
`sim/run.ps1`、`sim/regress.ps1` 和 `elinx/synth.ps1` 均支持可选的 `-Deadline <带时区的ISO时间>`，不会延长任务预算。以下命令按需执行，不必全部依次运行。

## 软件入口

软件版本与安装要求见根目录 `README.md`：eLinx 3.0.7、ModelSim SE-64 2020.4、Python 3.10 或更新版本；Python 检查器依赖 `psutil` 和 `pyasn1==0.4.8`。
PowerShell 使用 PATH 中的 `powershell.exe`。Python 优先使用 `AFDX_PYTHON` 指定的 `python.exe`，否则从 PATH 查找 `python`。
ModelSim 优先使用 `MODELSIM_HOME` 指定的目录（其中应有 `vsim.exe`、`vlog.exe`、`vlib.exe`），否则从 PATH 查找 `vsim.exe` 所在目录。
eLinx 脚本优先使用 `ELINX_HOME` 指定的安装根目录下 `bin/shell/bin`，否则从 PATH 查找 `eLinx_synthesis.exe` 所在目录。图形工程打开 `elinx/AFDX_EndSystem.epr`，保持同目录的 `AFDX_EndSystem_assignment_defaults.qdf`，再执行 Run Synthesis。

## 五功能与 RTL 运行

评委无 Python 入口为 `do sim/run_judge.do`（先 `cd` 到仓库根目录）：串行完成五功能、128/4096 VL 容量、SNMP Get/GetNext/Set/Trap、77/81 VL 突发、RTC 自检和 77 VL 吞吐测试，打印 `JUDGE ENTRY PASS cases=7` 或 FAIL；`out/modelsim/judge_<时间>_<进程>/result.txt` 汇总实际队列时延和 RTC 误差。固定 RTC 小数向量位于 `sim/vectors/judge/fractions.txt`，来自 `tools/rtc_ref.py` 的 72 项整数参考，运行入口不调用生成器。该入口不包含 Python 独立报文检查和完整吞吐矩阵，完整验收仍用下面的回归脚本。`sim/run.ps1` 在性能/RTC 独立检查通过后追加 `[METRIC]` 行，数值直接读取本次 `check_summary.json`。

五功能 do 文件只需 ModelSim：在 Transcript 窗口先 `cd` 到仓库根目录，再运行 `do sim/run_services.do`；命令行方式如下。

```powershell
$flowVsim=if($env:MODELSIM_HOME){Join-Path $env:MODELSIM_HOME 'vsim.exe'}else{(Get-Command vsim.exe -ErrorAction Stop).Source}
New-Item -ItemType Directory -Force out | Out-Null
& $flowVsim -c -l out/startup.log -do 'do sim/run_services.do'
```

脚本入口和参考工具使用下面两个变量；软件路径按上一节配置。

```powershell
$flowShell=(Get-Command powershell.exe -ErrorAction Stop).Source
$flowPython=if($env:AFDX_PYTHON){$env:AFDX_PYTHON}else{(Get-Command python -ErrorAction Stop).Source}
& $flowPython -B -X utf8 tools/afdx_ref.py selftest
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_mac_tx -Seed 20261007
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_tx_basic -Param TX_PAGE_AW=5,TX_OFF_AW=11
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_rx_ovf_ring -Param RX_RING_AW=9
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_sys_perf
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_sys_snmp_settrap
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_sys_snmp
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_sys_rtc
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_sys_615a
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_sys_cfg
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_sys_ovf -Param RX_RING_AW=9
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_net_services
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/regress.ps1
& $flowShell -NoProfile -ExecutionPolicy Bypass -File elinx/synth.ps1 -Top AFDX_top -Sta
```

RTL 清单 `sim/tests.txt` 为 37 项（原37项删去两个未用于顶层的 GMII 适配器测试，加入 `tb_judge_capacity` 和 `tb_judge_snmp`）；每行是“测试名”或“测试名|参数1=值,参数2=值”。原有两种 `tb_tx_basic` 参数组合和 `tb_gbe_burst` 的 `COUNT=77`、`COUNT=81` 均保留。
三个新增用例可用 `sim/run.ps1 -Test <测试名>` 单独运行：冗余用例经真实MAC检查双网0–20拍错开、粗边界前后相位、忙时处理及SkewMax=0窗口外行为，并加速公开粗时间输入检查持续负载老化；RTC两项分别检查丢回应/主从使能顺序恢复，以及错误/过期Originate和跨请求周期的校时计算。
`run.ps1` 自动生成独立向量、编译 `tb/lib/`，并按网表模块名排除同名 RTL；支持逗号分隔的多个原始 `netlist.v`。
`afdx_tx_core`、`afdx_rx_core` 和 `AFDX_top` 的综合网表固定为默认参数，入口拒绝不匹配参数；备用分页和两个小容量溢出测试使用 RTL 的 `-Param` 验证。
输出入口为 `out/sim`、`out/net`、`out/synth`，每次创建新目录。`summary.json` 保存输入摘要和结果，`tool_metrics.json` 保存原生命令、退出码、耗时和内存峰值，`active_job.json` 保存当前作业和精确进程身份。
成功需要 `[RESULT] PASS`、零错误和零警告；`tb_tx_*`、`tb_rx_*`、`tb_sys_*` 和 `tb_net_services` 还自动运行对应参考检查器，必须 `[CHECK] PASS`。退出码 0 本身不足以替代这些结果。
SNMP 测试自动生成请求并检查回应、同拍配置采样和 `snmp_exchange.pcap`；原始记录在 `snmp_results.txt`、`manager_gmii.txt` 和 `agent_gmii.txt`。Set/Trap 测试使用 `snmp_ref.py` 的 `settrap_vectors/settrap_check`，生成 `snmp_set_trap.pcap`。
RTC 测试经公开端口自检，并由 `rtc_ref.py` 核对记录及标准 SNTP 报文；615A 测试由 `load_ref.py` 及其辅助检查器核对上传、卸载和不支持操作的记录。
原 9 个系统测试的链路按 GMII 每拍一字节运行，输出四套慢线记录、四个 GMII 抓包目录及 `sys_events.txt`；RTL 下四份核心、系统和 GMII 共六行 CHECK 全过才通过。性能数据在 `check_summary.json` 的 `reports.system.performance`，周期号统一在 posedge 的 NBA 之前采样。
`regress.ps1` 将每次调用的实际输出目录和 RESULT/CHECK 数字写入 `out/regress/<批次>/summary.json`，两个 `tb_tx_basic` 参数组合分别保留，不依赖最后一次 latest 覆盖。

## 网表入口

`sim/tests_netlist.txt` 为 8 项；每行是“测试名|综合顶层列表[|参数列表]”。以下综合准备其所需网表；网表回归复用 `out/latest_<顶层>.json`，检查网表和综合输入摘要，源码变更后须重新综合。
完整顶层网表单项实测超过一小时，应显式传入整批截止时间；下面以五小时为例，实际使用时按任务预算设置。默认仿真和时序选项不变。

```powershell
$flowNetTops=@('afdx_timebase','afdx_mac_tx','afdx_mac_rx','probe_p1_2048x8','probe_p2_array','afdx_tx_core','afdx_rx_core','AFDX_top')
$flowNetDeadline=(Get-Date).AddHours(5).ToString('o')
foreach($top in $flowNetTops){ & $flowShell -NoProfile -ExecutionPolicy Bypass -File elinx/synth.ps1 -Top $top -Sta -Deadline $flowNetDeadline }
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/regress.ps1 -Netlist -Deadline $flowNetDeadline
$flowNets=@('afdx_timebase','afdx_mac_tx','afdx_mac_rx') | ForEach-Object { Join-Path ((Get-Content "out/latest_$_.json" -Raw | ConvertFrom-Json).folder) 'netlist.v' }
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_mac_loop -Netlist ($flowNets -join ',') -Deadline $flowNetDeadline
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_net_services -Deadline $flowNetDeadline
$flowTopNet=Join-Path ((Get-Content out/latest_AFDX_top.json -Raw | ConvertFrom-Json).folder) 'netlist.v'
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_net_services -Netlist $flowTopNet -Deadline $flowNetDeadline
```

网表适配使用 `tools/fix_lut_mask.py`，补全 LUT 字面量、算术进位参数和模型缺省输入；仅写仿真副本，保留原网表和厂商模型。
`tb_sys_net` 的双端顶层网表自动使用 `SYS_TOP_NETLIST`，关闭内部慢线抓包，选择最近通过的同名 RTL 记录，逐字节比较 8 份 GMII、2 份 D 行及 `sys_events.txt`，只打印外部 CHECK。运行前须已有当前版本通过的 RTL `tb_sys_net`。
当前T20网表验收见 `docs/PROBE_T20.md`：清单8/8和完整五功能全部通过，五功能含615A加载后卸载；新版本RTL参考记录及逐字节比对路径见摘要。上面的五功能命令先生成本版本RTL参考，再用整顶层网表验证；本轮按T17的两条队列并行执行，最多同时两个仿真。

## 手工核对与抓包转换

以下命令复用已通过对应测试的输出目录；不会启动仿真。

```powershell
$flowSnmp=(Get-Content out/latest_tb_sys_snmp.json -Raw | ConvertFrom-Json).folder
& $flowPython -B -X utf8 tools/snmp_ref.py check --dir $flowSnmp
$flowSystem=(Get-Content out/latest_tb_sys_basic.json -Raw | ConvertFrom-Json).folder
& $flowPython -B -X utf8 tools/sys_run_checks.py --test tb_sys_basic --dir $flowSystem
$flowTx=(Get-Content out/latest_tb_tx_basic.json -Raw | ConvertFrom-Json).folder
& $flowPython -B -X utf8 tools/afdx_ref.py check --test tb_tx_basic --dir $flowTx
$flowMac=(Get-Content out/latest_tb_mac_loop.json -Raw | ConvertFrom-Json).folder
& $flowPython -B -X utf8 tools/afdx_ref.py pcap --dump (Join-Path $flowMac 'dump_a.txt') --out (Join-Path $flowMac 'manual_a.pcap')
```

`tb_mac_loop` 自动把 `dump_a.txt`、`dump_b.txt` 转为按每周期 8 ns 的纳秒时间戳 pcap，并要求坏帧为 0；原始抓包保留字节数、周期号和完整线上字节。

## 官方 .vo 生成与仿真（T21）

教程见 [ref 中的原始 docx](../ref/vqm文件和.vo文件生成与使用20230605.docx)。UG102使用手册位于 `$env:ELINX_HOME/UG102_eLinx_Design_Suite_User_Guide_ehiway_v2024.9.pdf`；本机ref副本被Git忽略。相关内容为4.3、4.4、第6章Floor Planning、第7章Timing及第11章Simulation。

1. 在 `out/` 的独立工程副本中使用当前RTL、工程默认qdf和8 ns约束；本轮复用T18生成的qsf及报告配置并重定向路径，其他机器按教程建立工程。副本qsf增加 `set_global_assignment -name EDA_SIMULATION_TOOL "ModelSim (Verilog)"`。
2. 在副本elinx目录依次调用安装目录 `bin/Passkey/bin/quartus_map.exe --read_settings_files=on --write_settings_files=off AFDX_EndSystem`，再用 `quartus_cdb.exe AFDX_EndSystem -c AFDX_EndSystem --vqm=<副本synth_1/AFDX_EndSystem.vqm>` 导出。
3. 副本imple_1的run.psf设 `set_global_assignment -name SDF_FILE_GENERATE 1`，等效勾选Generate SDF File。使用安装目录原始run_pack.tcl/run_pack、run_route.tcl/run_route、run_timing_report.tcl/run_tming_report；Implementation.exe的cwd必须是安装目录bin/shell/bin，log4cpp.property和所有输出指向副本。
4. 3.0.7实际输出为副本 `AFDX_EndSystem.runs/imple_1/AFDX_EndSystem.vo` 和 `.sdo`。模块已为AFDX_top；复制成AFDX_top.vo用于仿真，只注释 `initial $sdf_annotate("AFDX_EndSystem.sdo");` 这一行。保留该行且带上同目录.sdo则为延迟回标。
5. 仿真库必须与ModelSim版本匹配；不匹配时按手册11.4，用 `vlib elinx_local` 建本地库，再用 `vlog -work elinx_local -vlog01compat <库源码>` 编译。T21用SE-64 2020.4重编译安装目录 `Simulation/verilog/` 的220model.v、elinx_atoms.v、elinx_mf.v，没有改厂商模型。
6. 按原入口先取得同版本RTL的tb_net_services参考。新仿真目录调用 `tools/net_services_ref.py vectors --dir <目录>`；编译.vo、tb/lib/*.v和tb_net_services.v，带 `+define+SYS_TOP_NETLIST` 与 `+incdir+<tb/lib>`，不再编译RTL的AFDX_top。
7. T21实际命令为 `vsim -c -t 1ps -L elinx_local tb_net_services -wlf simulation.wlf -do "do run.do"`；run.do执行run -all，以RESULT/CHECK判定，退出0不能代替PASS。完成后用 `tools/net_services_ref.py check --dir <目录> --rtl-reference <同激励RTL目录>` 逐字节比对外部记录，失败时记录首个差异和未到达的阶段。

本机临时驱动入口（脚本和证据在out，不随仓库分发）：第一条另建新Label；后两条复跑本轮保存的baseline，固定读取该目录，不使用新Label。

```powershell
$voDeadline=(Get-Date).AddHours(5).ToString("o")
powershell -NoProfile -ExecutionPolicy Bypass -File out/t21/run_stage.ps1 -Mode baseline -Label repro_new -Deadline $voDeadline
powershell -NoProfile -ExecutionPolicy Bypass -File out/t21/run_stage.ps1 -Mode functional -Deadline $voDeadline
powershell -NoProfile -ExecutionPolicy Bypass -File out/t21/run_stage.ps1 -Mode sdf -Deadline $voDeadline
```

`.vqm`是可再综合/装箱的映射网表；现有综合后仿真入口使用映射后转换的netlist.v和厂商单元模型。`.vo`来自布局布线之后；关闭SDF回标仅检查该网表的功能，保留回标才包含导出的连线及单元延迟。
Max Fanout Limit限制综合扇出；qsf用MAX_FANOUT实例约束。Packing Strategy权衡布通率与资源，Standard为VPACKFULL classic，Compact为full。Performance Explore遍历安装目录common.ini预置参数并择优，使用原生run_route_smart_explore_run.tcl；它要求将同一VQM复制到每个候选的imple_1目录。
T21实测：当前默认54.443 MHz；扇出32为50.756、128为50.774 MHz；Compact为50.317 MHz；Performance Explore为54.520 MHz（完成17/20候选）。仓库默认选项保持不变，完整对照见 [PROBE_T21](PROBE_T21.md)。
T21的.vo生成成功，未回标五功能仿真失败（发送状态RAM输入/输出位序与源库不匹配，六份外部记录不一致）；带延迟结果为未通过（建立时间违规，记录后结束）。这些结果单独记录，不计为已通过的综合网表验证或物理时序签核。

## 布局布线现状

历史流程能走完并导出资源和 checkpoint，但布线延迟导入报版本错误，未拿到有效布线后时序；详见 `docs/PROBE_T6.md`。`elinx/implement.tcl` 保留供统一工具的 `impl` 分支读取，布局布线包装脚本已移除。

## 工具约束

1. eLinx 3.0.7；ModelSim SE2020.4；EQ6HL130/CSG484_H、TT/no_pack、clk=8ns（125MHz），综合估算不含走线延迟。
2. RAM 地址、数据和使能寄存后进入 afdx_ram_sdp；同拍同址读写结果不作假设，禁读保持输出。
3. 原生 RTLIL 非法实例标识符只在输出副本中修名；原始 mapped.il 保留。RAM 切片数不直接称为物理块数。
4. 时序 SQLite 数据库使用 ps；synthesized_timing.pb 不是文本。有限最差路径列表不证明全部 RAM 弧或外部 I/O 已签核。
5. initial 生成 MIF 不等于完整初值行为通过；T2 RAM 测试先写后读，不依赖上电初值。
6. 测试向量十六进制位数必须适配数据宽度；8位存储器使用两位文本，保留旧格式警告日志。
7. 不添加假 I/O 预算、时序例外或修改厂商模型；当前8ns下setup门槛为2.0ns；hold和布局布线结果见PROBE_T6.md，旧T2测量保留其原时钟口径。
8. 运行器串行执行，仅保护自己启动的精确进程树：默认 10GiB 树上限、5GiB 系统可用内存下限；分别用 `AFDX_MEM_LIMIT_GB`、`AFDX_MEM_FLOOR_GB` 调整，0 关闭对应保护，见 README；不操作其他任务。
9. Implementation.exe 初始化依赖安装入口的相对路径，运行工作目录使用 经 ELINX_HOME 或 PATH 解析的 eLinx 安装目录 bin/shell/bin，设计和输出路径均指向 out；布局布线步骤结束不等于路由延迟已正确导入，T2和T6均遇到布线延迟导入版本错误。
10. 原生 setlogfile 会回写传入的 property；综合和布局布线入口均只使用本次 out 目录的私有副本。
