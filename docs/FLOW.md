# C3 工具入口

工作目录为仓库根目录（含 `rtl/`、`tb/`、`sim/`、`tools/`、`elinx/`）。脚本仿真、综合的日志、抓包、波形和工作库写入 `out/`；图形工程产物由 eLinx 在工程目录中管理。
`sim/run.ps1`、`sim/regress.ps1` 和 `elinx/synth.ps1` 均支持可选的 `-Deadline <带时区的ISO时间>`，不会延长任务预算。以下命令按需执行，不必全部依次运行。

## 软件入口

软件版本与安装要求见根目录 `README.md`：eLinx 3.0.7、ModelSim SE-64 2020.4、Python 3.10 或更新版本；Python 检查器依赖 `psutil` 和 `pyasn1==0.4.8`。
PowerShell 使用 PATH 中的 `powershell.exe`。Python 优先使用 `AFDX_PYTHON` 指定的 `python.exe`，否则从 PATH 查找 `python`。
ModelSim 优先使用 `MODELSIM_HOME` 指定的目录（其中应有 `vsim.exe`、`vlog.exe`、`vlib.exe`），否则从 PATH 查找 `vsim.exe` 所在目录。
eLinx 脚本优先使用 `ELINX_HOME` 指定的安装根目录下 `bin/shell/bin`，否则从 PATH 查找 `eLinx_synthesis.exe` 所在目录。图形工程打开 `elinx/AFDX_EndSystem.epr`，保持同目录的 `AFDX_EndSystem_assignment_defaults.qdf`，再执行 Run Synthesis。

## 五功能与 RTL 运行

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
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_gmii_tx
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_gmii_rx
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

RTL 清单 `sim/tests.txt` 为 34 项（含两种 `tb_tx_basic` 参数组合、`tb_sys_615a`，以及 `tb_gbe_burst` 的 `COUNT=77`、`COUNT=81` 两项集中释放测试）；每行是“测试名”或“测试名|参数1=值,参数2=值”。
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

```powershell
$flowNetTops=@('afdx_timebase','afdx_mac_tx','afdx_mac_rx','probe_p1_2048x8','probe_p2_array','afdx_tx_core','afdx_rx_core','AFDX_top')
foreach($top in $flowNetTops){ & $flowShell -NoProfile -ExecutionPolicy Bypass -File elinx/synth.ps1 -Top $top -Sta }
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/regress.ps1 -Netlist
$flowNets=@('afdx_timebase','afdx_mac_tx','afdx_mac_rx') | ForEach-Object { Join-Path ((Get-Content "out/latest_$_.json" -Raw | ConvertFrom-Json).folder) 'netlist.v' }
& $flowShell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_mac_loop -Netlist ($flowNets -join ',')
```

网表适配使用 `tools/fix_lut_mask.py`，补全 LUT 字面量、算术进位参数和模型缺省输入；仅写仿真副本，保留原网表和厂商模型。
`tb_sys_net` 的双端顶层网表自动使用 `SYS_TOP_NETLIST`，关闭内部慢线抓包，选择最近通过的同名 RTL 记录，逐字节比较 8 份 GMII、2 份 D 行及 `sys_events.txt`，只打印外部 CHECK。运行前须已有当前版本通过的 RTL `tb_sys_net`。
整顶层五功能网表的历史验收见 `docs/PROBE_T10.md`，输入版本和覆盖范围以该摘要为准。

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
