# AFDX 端系统 FPGA 工程

当前源码采用 T45 的 S2d 结构改动（9b277556）与初始化参考修复（bb1180d1），使用可由界面复现的 PRES1.50 布线选项；验证截至 2026-10-24。125 MHz 全量内部路径 setup 0 失败，最差 +0.013 ns、hold +0.229 ns，满足 125 MHz 时序要求。

本工程是中科亿海微赛题“AFDX 端系统”的 FPGA 实现，顶层模块为 `AFDX_top`，A、B 双网 GMII 接口共用一个 125 MHz 时钟，目标器件 EQ6HL130（封装 CSG484_H）。提供 eLinx 3.0.7 的综合、实现入口和 ModelSim 自检仿真，不需要硬件平台；当前布线后时序见“综合与布线结果”。

已实现赛题要求的五项功能：用户数据发送、用户数据接收（含双网冗余、虚拟链路带宽间隔调度、序号和完整性检查）、SNMP 网络管理、ARINC 615A 数据加载和卸载、RTC 时钟同步。

## 目录

- `rtl/`：可综合的设计源码，共 24 个文件，模块分工见“模块一览”。
- `tb/`：自检测试平台；`tb/lib/` 是测试平台共用的端点和链路模型。
- `sim/`：ModelSim do 文件、回归入口、测试清单和固定向量。
- `tools/`：Python 参考模型、独立检查器和工具运行脚本。
- `elinx/`：eLinx 工程文件、工程默认设置、8 ns 时钟约束和命令行综合入口；`elinx/probe/` 是内部基础单元探测模块。
- `out/`：运行时生成的日志、抓包、波形和工作库，不随工程提交。

## 软件准备

基本走查只需 Windows 版 eLinx 3.0.7、ModelSim SE-64 2020.4 和 Windows PowerShell 5.1，不需要 PowerShell 7。纯 ModelSim 入口包含下面列出的八个用例，不依赖 Python。
完整 39 项回归、独立报文检查器及命令行综合/网表脚本另需 Python 3.10 或更新版本（验证版本为 3.12.7），以及 `psutil`、`pyasn1==0.4.8`。在实际选用的 Python 环境执行 `python -m pip install psutil pyasn1==0.4.8`。
软件不随工程分发，ModelSim、eLinx 的许可证需自行配置。脚本不主动提权，需要工作目录可写；当前脚本使用 Windows 可执行文件和进程接口，未适配 Linux/macOS。

| 环境变量 | 设置方式；不设置时的查找规则 |
|---|---|
| `AFDX_PYTHON` | 完整 `python.exe` 路径；否则用 PATH 中的 `python` |
| `MODELSIM_HOME` | 含 `vsim.exe`、`vlog.exe`、`vlib.exe` 的目录，如安装中的 `win64`；否则从 PATH 找 `vsim.exe` |
| `ELINX_HOME` | eLinx 安装根目录，即 `eLinx3.0.exe` 所在目录，其下应有 `bin/Passkey/bin` 和 `bin/shell/bin`；否则从 PATH 找 `Implementation.exe` |
| `AFDX_MEM_FLOOR_GB` | 系统可用内存下限，默认 5 GiB；0 关闭此项保护 |
| `AFDX_MEM_LIMIT_GB` | 本次工具进程树内存上限，默认 10 GiB；0 关闭此项保护 |

内存变量按 GiB（1024³ 字节）计，接受非负数，在启动脚本前设置；8 GB 电脑可按实际情况降低阈值，例如 `$env:AFDX_MEM_FLOOR_GB='1'; $env:AFDX_MEM_LIMIT_GB='4'`。这两项不影响独立 ModelSim do 入口；超时保护仍生效，运行器只处理自己启动的进程树。

## 快速上手

先走不需要 Python 的步骤 1、2。测试会自动建立工作库和输入文件，不必先做综合。
工程路径不要含中文或空格。实测 ModelSim 2020.4 在中文路径下无法创建工作库，在带空格的路径下无法载入仿真；入口会提前提示更换目录。

1. 在 ModelSim 的 Transcript 窗口进入工程根目录，把下面的占位文字换成实际目录。

   ```tcl
   cd {工程所在目录}
   ```

   预期：命令不报错，当前目录中能找到 `rtl`、`tb` 和 `sim`。

2. 运行五功能、容量、网络管理、突发排队、时钟同步、吞吐和变长帧测试。

   ```tcl
   do sim/run_judge.do
   ```

   预期：八个用例都打印 `JUDGE CASE PASS`，最后打印 `JUDGE ENTRY PASS cases=8`；中途失败会打印 `JUDGE ENTRY FAIL`。

   Warning 只计数和提示，Error、Fatal 或测试打印的 FAIL 会判失败。成功和失败都会回到工程根目录，恢复原来的 Transcript 记录设置；可直接重新运行这条命令。

   指标见下面的表，汇总保存在 `out/modelsim/judge_<时间>_<进程>/result.txt`，各用例目录里有原始日志。吞吐测试会运行较久，可从 `performance/simulation.log` 查看已到达的测试阶段。

下列 PNG 为此前版本的归档截图，表中时间窗口对应这些原图；当前管理响应拍数以本版联测结果为准。

报告波形：在仓库根目录执行 `do sim/wave/tx_dual.do`；另外四个脚本是 `rx_redundancy.do`、`rx_fcs_error.do`、`tx_bag.do`、`snmp_get.do`，均自行编译、运行并显示真实 ModelSim Wave 窗口，采用默认黑底配色。生成输入向量时需要上述 Python 环境。切换场景前执行 `quit -sim`，再切回根目录。
批量截图用 `python sim/wave/export.py`，单个场景可追加 `--scene tx_bag`。脚本通过 Windows 的 `PrintWindow` 捕获本次 ModelSim 会话的 Wave 窗口，保留菜单、信号名、数值、时间轴和光标读数。PNG 在 `sim/wave/png/`；工作库、WLF、原始窗口截图和日志保存在 `out/wave/`。

| 图片 | 时间窗口（us） | 观察内容 |
|---|---:|---|
| `tx_dual_1.png` | 685.900–688.900 | 应用输入与 A、B 双网发送的时序总览 |
| `tx_dual_2.png` | 688.100–688.420 | 放大双网帧起点和部分帧头字节 |
| `rx_redundancy_1.png` | 3013.980–3014.240 | A 网交付事件及交付给应用的字节 |
| `rx_redundancy_2.png` | 3029.820–3030.080 | B 网帧尾字节与副本丢弃事件，光标间隔 16.016 us |
| `rx_fcs_error_1.png` | 798.350–799.600 | A 网 FCS 错误计数从 0 变为 1，B 网正常交付 |
| `rx_fcs_error_2.png` | 798.700–799.020 | 放大错误帧的部分字节 |
| `rx_fcs_error_3.png` | 972.992–973.040 | 独立读地址 0x49，一拍请求经两级流水后有效返回 1 |
| `tx_bag.png` | 10.000–830.000 | 两个帧起点的光标间隔为 800 us |
| `snmp_get_1.png` | 525.280–525.600 | Get 请求的双网帧起点及部分帧头字节 |
| `snmp_get_2.png` | 531.660–531.980 | Response 的双网帧起点及部分帧头字节 |

本轮 CE2 八用例实测如下；耗时随电脑和当时负载变化，合计包含编译、生成输入和检查记录。

| 用例 | 实测耗时（秒） |
|---|---|
| 五功能（`services`） | 12.923 |
| 128 条发送 / 4096 条接收配置（`capacity`） | 18.341 |
| 网络管理报文字段核对（`snmp`） | 87.429 |
| 77 条虚拟链路突发（`burst77`） | 6.709 |
| 81 条虚拟链路突发（`burst81`） | 6.852 |
| 时钟同步（`rtc`） | 439.326 |
| 吞吐、时延和抖动（`performance`） | 3535.807 |
| 变长帧与多虚拟链路（`perf_var`） | 4678.308 |
| 合计 | 8787.198 |

该次运行在 `out/` 下生成 **1016.6 MiB** 的工作库、输入、波形和记录。每次运行使用新目录。

下面是本轮八行用例结果和总结果：

```text
JUDGE CASE PASS services checks=1124 errors=0 warnings=0 elapsed_s=12.923
JUDGE CASE PASS capacity checks=49924 errors=0 warnings=0 elapsed_s=18.341
JUDGE CASE PASS snmp checks=699 errors=0 warnings=0 elapsed_s=87.429
JUDGE CASE PASS burst77 checks=643552 errors=0 warnings=0 elapsed_s=6.709
JUDGE CASE PASS burst81 checks=673500 errors=0 warnings=0 elapsed_s=6.852
JUDGE CASE PASS rtc checks=10675857 errors=0 warnings=0 elapsed_s=439.326
JUDGE CASE PASS performance checks=756655316 errors=0 warnings=0 elapsed_s=3535.807
JUDGE CASE PASS perf_var checks=1402134376 errors=0 warnings=0 elapsed_s=4678.308
JUDGE ENTRY PASS cases=8 warnings=0 elapsed_s=8787.198 output_mib=1016.6
```

[评委入口参考输出](sim/reference/judge_result.txt) 和 [完整回归参考汇总](sim/reference/regression.json) 对应 2026-10-24 冻结版 `83e5d5e8`；性能定义与数值见 [性能证据](docs/evidence/perf_r97.json)。耗时、时间戳、输出目录和文件大小随运行变化。参考汇总中的 `Folder`、`Ucdb` 路径相对于仓库根目录，统一为 `out/sim/...`，指向该次运行的输出位置；这里只规范化原路径前缀，检查数、结果及原 UCDB 绑定保持不变。本仓库不附带这些原运行目录及各测试的原始 UCDB。

下面两步需要先按“软件准备”安装 Python 依赖，并在 PowerShell 中进入同一工程根目录。

3. 运行全部 39 项测试，参考检查器会另行核对报文和周期记录。

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File sim/regress.ps1
   ```

   预期：末尾表格中的 39 项都为 `PASS`（耗时见本轮实际记录）；汇总位于 `out/regress/`，每项日志位于 `out/sim/`。

管理协议引擎使用同一个 125 MHz 时钟，通过时钟使能（Clock Enable，CE）每两拍更新；接收捕获、发送输出、配置口、RAM 端口和 RTC 计时保持全速。顶层参数 `CE_DIV` 可取 1 或 2，默认 2。两种配置的完整回归和评委入口可分别运行：

```powershell
$env:AFDX_CE_DIV='1' # 第二轮改为 2
powershell -NoProfile -ExecutionPolicy Bypass -File sim/regress.ps1
vsim -c -do 'do sim/run_judge.do'
```

该环境变量仅选择 RTL 仿真参数；官方综合使用工程中顶层参数的默认值 2。定长性能用例的原生仿真墙钟预算为 5400 秒，变长帧用例为 14400 秒，测试中的周期数和判定条件保持原值。

ModelSim 静态检查：在仓库根目录执行 `vlib out/lint_work`，再执行 `vlog -lint -vlog01compat -work out/lint_work rtl/*.v`；ModelSim 工具目录需在 PATH 中。
本轮官方流程覆盖当前 24 个 RTL 模块；编译及静态检查结果由对应日志定位。

代码覆盖率默认关闭。完整回归追加 `-Coverage`，单项运行用 `sim/run.ps1 -Test tb_ram_sdp -Coverage`；仅 RTL 按 `+cover=sbceft` 编译，每项在输出目录保存带唯一测试名的 `coverage.ucdb`，测试平台不计入覆盖率。
用 ModelSim 的 `vcover merge merged.ucdb input1.ucdb input2.ucdb ...` 合并，再用 `vcover report -codeAll "-du=work.afdx_snmp" -output report.txt merged.ucdb` 导出模块报告，替换其中的模块名即可。参考数字、原始报告和合并数据库在 `sim/reference/coverage/`，统计口径见该目录 README。

本轮 CE2 完整 39 项覆盖率回归统计 24 个 RTL 模块，按 `sbceft` 插桩，测试平台不计入。统计按真实设计单元的已覆盖／总统计项合计，百分比按工具习惯截断；状态机合计为状态加转换。

| 覆盖类别 | 已覆盖 / 总数 | 百分比 |
|---|---|---|
| 语句 | 6981 / 7083 | 98.55% |
| 分支 | 3844 / 3985 | 96.46% |
| 条件 | 610 / 717 | 85.07% |
| 表达式 | 1760 / 1991 | 88.39% |
| 状态机，含状态和转换 | 248 / 418 | 59.33% |
| 状态 | 110 / 110 | 100.00% |
| 转换 | 138 / 308 | 44.80% |
| 翻转 | 41314 / 53632 | 77.03% |

逐模块数字和原始报告见 `sim/reference/coverage/`；未覆盖项保持原统计范围，不沿用旧版源码行号或未重新核对的原因说明。

4. 综合完整顶层，并检查 8 ns 时钟约束下的估算时序。

   先设置 `ELINX_HOME` 为 eLinx 安装根目录，即 `eLinx3.0.exe` 所在目录（可在桌面快捷方式上右键“打开文件所在的位置”找到），其下应有 `bin/Passkey/bin` 和 `bin/shell/bin`。把下面的占位文字换成实际路径；未设置时脚本会提示 `Set ELINX_HOME` 并退出：

   ```powershell
   $env:ELINX_HOME='eLinx安装根目录'
   powershell -NoProfile -ExecutionPolicy Bypass -File elinx/synth.ps1
   ```

   预期：打印 `OFFICIAL SYNTH PASS`，`out/latest_AFDX_top.json` 给出资源数、时序裕量、耗时及 `.vqm` 路径。综合工具仅调用 `quartus_map.exe`、`quartus_cdb.exe` 和 `Implementation.exe`，按工程设置依次完成分析综合、VQM 导出、装箱和综合后时序；所有运行产物写入 `out/synth/AFDX_top/`，不覆盖界面结果。

综合后运行 `powershell -NoProfile -ExecutionPolicy Bypass -File elinx/impl.ps1` 完成官方布局布线。`elinx/constraints.edc` 设置 PRES_FAC_MULT=1.50，eLinx 工程与命令行均读取这一份约束源；输出 constraints.sdc 是它的副本。本次 PRES1.50 在 125 MHz 下为 0 个失败、setup +0.013 ns、hold +0.229 ns；交付工程没有 cluster 坐标赋值。

主机配置访问优先；主机与 SNMP MIB 同时读同一地址时共用返回值，不同地址时 MIB 保持请求到主机释放总线。主机读延迟仍为两拍。接收映射、配置或序号检查拒绝的报文多用一拍登记判断，正常数据帧保持原处理拍数。

协议引擎的同域寄存器路径使用 16 ns；跨引擎、捕获、配置、RAM、发送输出及数据面内部路径仍为 8 ns。本版 eLinx 的 `-hold 0` 对应原同沿保持检查；小网表实测 `-hold 1` 会把检查移到前一拍，因此采用经过原始报告核实的写法。约束按真实网表依赖分组，避免工具建立大规模全连接矩阵。

综合和实现入口自动检查寄存器的 CE 逻辑锥、时钟、集合边界和内部连接覆盖，并按查找表真值验证 CE 为低时全部引擎寄存器保持，以及 CE 副本同步复位后逐拍翻转。每组使能驱动至多 32 个协议寄存器位，所有副本仍使用同一个主时钟。RTL 改动导致集合变化时，先使用失败运行留下的 VQM 更新这一份约束，再重新综合：

```powershell
python tools/check_multicycle.py <本次VQM路径> --constraints elinx/constraints.edc --output out/multicycle_audit --refresh
```

布线完成后执行 `python tools/report_routed_timing.py`，复用已布线图和延迟导出全部端点，核对每条报告路径的 16 ns／8 ns 要求以及同沿 hold，产物放在 `out/timing/`。它不会重新布局布线。综合、实现和全量时序报告入口均支持硬截止时间保护；用 `--deadline` 传入 ISO 时间。

也可用 eLinx 打开 `elinx/AFDX_EndSystem.epr`，点击 Run Synthesis。两个入口使用同一套官方引擎，默认器件为 EQ6HL130、封装为 CSG484_H；保持相邻的默认设置文件和 `constraints.edc` 不动。命令行不需要先运行界面；已有 `.qsf` 时保留其中的综合设置，干净检出时按 `.epr` 的当前设置生成运行副本。网表验证见“综合后网表仿真”。

| 测量内容 | 从哪里看结果，预期是什么 |
|---|---|
| 定长与混合帧长性能 | gbe77 每方向 **906.136 Mbps**；var_high **904.752 Mbps**。链路0拍时 L_app 末字节最大 **24.432 µs**，257拍时 **26.488 µs**；R97应用首字节抖动 **0.008 µs**。定义、四类新工况与各段数值见[事实清单](docs/FACTS.md#二性能数字与测量方法)，出处为[性能证据](docs/evidence/perf_r97.json)的 `main_table`。 |
| 77/81 条虚拟链路同时提交消息后，队列全部发完的时间 | `JUDGE METRIC burst_vls=... queue_clear_us=...` 分别为 **959.288/1008.504 µs**；81 条的用例特意检查超过 1 ms 的边界。 |
| 时钟同步误差 | `JUDGE METRIC rtc_...` 给出最大误差；空载为 **0 ns**，普通用户流量和 77 条虚拟链路满载时均为 **10788 ns**。 |
| 赛题五功能 | `tb_net_services` 的 `[FUNCTION]` 行检查用户收发、网络管理、时钟同步、加载和卸载，最后须为 `[RESULT] ... PASS ... errors=0`。 |
| 虚拟链路容量 | `capacity` 每端配置 4096 条接收虚拟链路，并逐字节验证索引 0、4095 和中间 126 项。每端全部 128 条发送虚拟链路都发出消息，对端每条只交付一次。 |
| 网络管理（SNMP，Simple Network Management Protocol） | `snmp` 检查 Get、GetNext、Set 的请求号回显、错误码为 0、返回值与配置口寄存器一致；Trap 检查错误码为 0、启动通知类型和运行时间寄存器。 |

按[1022答疑](docs/sources/FPGA创新大赛问题汇总1022.xlsx) R95/R97，吞吐只计接收应用口去重后的有效载荷；时延分别报 L_gmii（TX SFD→RX SFD）、L_tx（提交完成→TX SFD）、L_rx（RX SFD→交付首/末字节）、L_app（提交完成→交付首/末字节）。L_gmii在直连模型中为0.000/2.056 µs，不能当成端系统性能。R97抖动是同一VL时延最大减最小，再取各VL最大；旧相邻发送间隔偏离BAG称发送间隔偏差（gbe77为0.000 µs）。

新变长工况只对 var_high 检查≥100 Mbps；var_fixed/var_cycle/var_burst的给定负载较低，实测分别为57.794/70.403/57.794 Mbps，只报告。所有工况所有帧 L_gmii/L_app≤2000 µs；R97抖动只报告，50 µs为项目检查器历史参考值，不是官方上限。当前 `JUDGE BASELINE` 的应用末字节扣链路基线为24.432 µs；2026-10-23 的历史值为24.424 µs，更早的24.408 µs由54877a09增加接收映射读两拍后增加16 ns；旧兼容字段 `jitter_us` 仍指发送间隔偏差。来源：[性能证据](docs/evidence/perf_r97.json)的 `policy`、`main_table`。

变长多VL测试：`powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_sys_perf_var`；纯ModelSim在仓库根目录执行 `set ::env(AFDX_JUDGE_CASE) perf_var`、`do sim/run_judge.do`。取消筛选用 `unset ::env(AFDX_JUDGE_CASE)`。五种载荷、VL/BAG与窗口见[工况表](docs/FACTS.md#变长帧与多虚拟链路工况)。

`tb_gbe_burst` 的突发指标在发送核心的消息输入口和接收核心的消息交付口之间测量。顶层将这两路核心直接接到 GMII，没有另加适配缓存或流水延迟。
队列全部发完的时间从同时提交所有消息时起算，与单条消息的时延不同。以上吞吐和周期指标是 RTL 仿真测量；布线后静态时序另见“综合与布线结果”，不能当作上板实测。

## 从 eLinx 界面运行自检

1. 用 eLinx 打开 `elinx/AFDX_EndSystem.epr`，在 Settings → Tool Settings → 3rd Party Simulators 设置 ModelSim 的安装目录。该目录应包含 `modelsim.exe`。
2. 在 Sources → Simulation Sources → `sim_1` 中确认目标仿真文件是 `tb_elinx.v`、仿真顶层是 `tb_elinx`，并且有 `judge_endpoint.v`。这些设置已写入工程，综合顶层仍是 `AFDX_top`。
3. 点击 Flow → Run Behavioral Simulation。ModelSim 会运行两个端系统经双网互发 1、64、1471 字节消息的自检；预期依次看到三条 `[ELINX_MESSAGE] ... both_directions=PASS`，最后是 `[RESULT] tb_elinx PASS checks=9238 errors=0`。测试不需要 Python、输入文件或额外的 include 路径和宏。

此入口已在 eLinx 界面实测通过，仿真时间约 2.56 ms，界面截图见 `sim/wave/png/tb_elinx.png`。仿真结束时 ModelSim 会弹出 Finish Vsim 对话框，选“否”可保留窗口查看输出。

## 综合后网表仿真

界面 Run Synthesis 和命令行 `elinx/synth.ps1` 导出同一官方流程的 `.vqm`，共用下面的仿真入口。先完成快速上手第 4 步，再在 PowerShell 中执行：

```powershell
$net = (Get-Content out/latest_AFDX_top.json -Raw | ConvertFrom-Json).netlist
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_gui_netlist.ps1 -Test tb_net_services -Netlist $net
```

入口先仿真 RTL，再用相同激励仿真新生成的 VQM，逐字节比较七份外部记录。自检项数必须与本次 RTL 一致，独立检查错误为 0；`exact_external_records` 七项均须为 `true`。

冻结版 `83e5d5e8` 的本次官方 VQM 与同次 RTL 在 tb_net_services 中均通过 1124 项自检，错误均为 0；网表独立检查 65 项、错误 0，同激励 RTL 独立检查 59 项，网表另含 6 项精确记录对照；七份外部记录逐字节一致。网表仿真 8793.406 秒，同激励 RTL 17.469 秒；原网表 SHA-256 与冻结版官方综合一致。

使用界面产物时省略 `-Netlist`，默认读取 `elinx/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm`。两种入口都不重新综合；每次仿真的网表副本、日志、独立检查和 `summary.json` 放在 `out/gui_netlist/` 下的新目录。出错时打印 `GUI NETLIST FAIL` 或 `GUI NETLIST ENTRY FAIL` 并返回非零退出码，总时限为五小时。

较长的双端双网互发自检可用 `sim/run_gui_netlist.ps1 -Test tb_elinx -Netlist $net`。此前界面网表已通过 9238 项检查、0 错误，仿真约 130 分钟；本次只重跑新网表的五功能测试。

官方导出的网表省略了取默认值的输入和参数，而配套单元仿真模型没有给这些输入和参数设默认值，直接仿真时寄存器不会更新。`tools/adapt_gui_vqm.py` 仅在仿真副本上补齐：省略输入按组件声明和单元模型的默认上拉、下拉取值；原有进位连接补上 `cin_used="true"`。原有连接、功能参数、查找表内容以及厂商模型均不改。复制寄存器的 `created_from` 仅记录综合来源，厂商仿真模型没有该参数；仿真副本将这项元数据转存审计报告。补全数量和来源记录保存在 `summary.json` 的 `adaptation` 中。

## 综合与布线结果

当前结果来自冻结版 `83e5d5e8` 的 S2d + PRES1.50 官方测量，RTL 与工程设置保持一致。器件 EQ6HL130、封装 CSG484_H，唯一主时钟为 8 ns（125 MHz），顶层 CE_DIV=2。125 MHz 全量内部路径 setup 0 失败、最差 +0.013 ns，hold +0.229 ns，多周期最差 +0.940 ns，满足 125 MHz 时序要求；交付工程使用 PRES1.50，无单元坐标约束。

| 项目 | 当前官方结果 |
|---|---:|
| 查找表（LUT） | 34294 |
| 触发器（FF） | 17454 |
| 可配置逻辑块（CLB） | 4521 |
| 存储器（Memory） | 366 |
| 用户引脚 | 259 |
| 布线后建立裕量／保持裕量 | +0.013 / +0.229 ns |
| 布线后最高频率估算 | 125.203 MHz |
| 布线后 setup 失败端点 | 0 / 45745 |
| 8 ns 路径数／最差 setup | 153342 / +0.013 ns |
| 16 ns 路径数／最差 setup | 50296 / +0.940 ns |
| 同沿 hold 路径数 | 203638 |

约束检查为 2755 个引擎寄存器，不合格寄存器和遗漏内部连接均为 0；综合、实现与全量报告三次审查通过。轻量结果及前十路径见 [T45 时序证据](docs/evidence/t45_timing.json)。D3 f60aaacd 的历史对照为 LUT/FF 38297/19947、1 个失败、setup −0.090 ns；本版 LUT 减少 4003（10.5%）、FF 减少 2493（12.5%），原始口径保留在 [T43 时序证据](docs/evidence/t43_timing.json)。

本次 CE2 回归 39/39、评委 8/8、16 份初始化等价检查均通过；回归中的一次槽位准入错误已真实补跑，原失败记录保留。源码包括接收交付队列 RAM、统计事件两拍流水、数据发送缓冲、接收 payload 预登记与管理请求/元数据两级寄存。数据发送增加一拍（8 ns），管理发送相对前一版再增加一拍；性能基线和 R97 参考按本次完整窗口测量更新。

冻结版五线终验已全部通过：官方 VQM 五功能对照、CE1 并行 39 项、CE2 覆盖率 39 项及双 CE 评委各 8 项；39 个 UCDB 与原生结果已逐项核对。sim/reference/ 对应本次冻结版。布线后静态时序不是上板实测，也未覆盖完整外部 I/O 延迟预算。

## 模块一览

| 文件（均在 `rtl/`） | 职责 |
|---|---|
| `AFDX_top.v` | 集成双网收发、GMII、配置和三种服务，共用 125 MHz 时钟。 |
| `afdx_cfg.v` | 解码配置总线，管理配置读写握手和事件计数器。 |
| `afdx_timebase.v` | 生成周期时间和冗余判定的粗时间，复位后字节使能每拍有效。 |
| `afdx_ram_sdp.v` | 提供参数化单时钟、单写口、同步读 RAM。 |
| `afdx_crc32_d8.v` | 按一个字节组合更新 Ethernet CRC32。 |
| `afdx_tx_core.v` | 连接发送缓冲、调度、组帧、回收和两网 MAC。 |
| `afdx_tx_buf.v` | 接收应用消息、分配页并提交完整消息的队列描述。 |
| `afdx_tx_engine.v` | 轮询 VL，按 BAG 和 LOOKAHEAD 决定消息发送时机。 |
| `afdx_tx_builder.v` | 读取负载，组成 Ethernet、IPv4、UDP 和序号字节流。 |
| `afdx_tx_free.v` | 管理空闲页及链表，回收发送或放弃的消息页。 |
| `afdx_mac_tx.v` | 每拍输出一个 GMII 字节，加入前导、SFD、FCS 和 12 拍帧间隔。 |
| `afdx_mac_rx.v` | 检查前导、长度、FCS，输出去掉 FCS 的帧内容及类别脉冲。 |
| `afdx_rx_core.v` | 连接双网 MAC、解析器、共享接收引擎及应用交付。 |
| `afdx_rx_parse.v` | 检查报文头并暂存负载，坏帧回退，仅提交完好帧描述。 |
| `afdx_rx_engine.v` | 检查映射、配置、序号完整性和冗余，提交可交付消息。 |
| `afdx_rx_deliver.v` | 预取环形缓冲中的负载并连续交付应用口，释放读地址。 |
| `afdx_svc.v` | 按整条消息仲裁应用与服务发送，将收到的服务消息分发给对应模块。 |
| `afdx_rtc.v` | 维护秒和纳秒时钟，以标准 48 字节 SNTP 报文同步。 |
| `afdx_ntp_fraction.v` | 用移位加减迭代换算纳秒与 NTP 的 32 位二进制小数。 |
| `afdx_snmp.v` | 全速捕获 SNMP 请求、配置与 MIB 桥接、保存报文 RAM 并连接输出。 |
| `afdx_snmp_engine.v` | 通过 CE 每两拍处理一次 SNMP v1/v2c 单变量 Get、GetNext、Set 及 v2c Trap。 |
| `afdx_615a.v` | 全速捕获 615A/TFTP 请求，桥接配置与加载 RAM，连接发送输出。 |
| `afdx_615a_engine.v` | 通过 CE 每两拍推进一次 615A 加载、卸载和 TFTP 协议。 |
| `afdx_mgmt_tx.v` | 在全速域读取管理响应 RAM，按 valid/ready 连续发送字节。 |

数据路径：应用 `app_tx_*` → `afdx_svc` → `afdx_tx_core`（缓冲、调度、组帧）→ `afdx_mac_tx` → GMII 链路 → `afdx_mac_rx` → `afdx_rx_parse` → `afdx_rx_engine` → `afdx_rx_deliver` → `afdx_svc` → 应用 `app_rx_*`。RTC、SNMP、615A 三种服务报文和用户数据共用这条路径，由 `afdx_svc` 按整条消息仲裁。

`AFDX_top` 保留赛题模板的 `clk`、`reset`、`tx_data`、`rx_data`、`tx_valid`、`rx_valid`、`tx_ready`、`rx_ready`，这一组是 A 网 GMII。另外增加了 B 网 GMII（`*_b`）、应用收发口（`app_tx_*`、`app_rx_*`）和配置口（`cfg_*`），用于双网冗余、提交和取回用户消息、写入虚拟链路配置。以太网线路不能暂停，`rx_ready` 不使用。

[1022答疑](docs/sources/FPGA创新大赛问题汇总1022.xlsx) R110说明模板是端系统对外应用数据接口；当前模板八位口实际用作A网GMII，应用另走 `app_*`、B网另增端口，与该说明有差别。原理解依据为R61“GMII是PHY接口”和R95-2“两次例化MAC”；已准备向官方确认，本次不改接口、不宣称解释已获认可。R112允许以仿真截图及仿真演示视频代替开发板照片和视频。

测试与参考模型的对应：`tb_tx_*`、`tb_rx_*` 对应 `afdx_ref.py`、`tx_ref.py`、`rx_ref.py`；`tb_sys_*` 对应系统、GMII 和各服务的参考模型；`tb_net_services` 对应 `net_services_ref.py`。`tools/eda.py` 负责生成向量、调用仿真和检查器。ModelSim do 入口使用 `sim/vectors/` 中的固定向量和测试平台自检，不调用 Python。

## 实现范围

- 用户收发：UDP/IPv4/Ethernet 组帧，组播目的 IP 为 224.224 加虚拟链路号；每端 128 条发送虚拟链路、4096 条接收虚拟链路；按带宽间隔调度；接收端做序号完整性检查和双网冗余去重。
- SNMP：v1/v2c 的 Get、GetNext、Set 和 v2c Trap，一次一个变量绑定。
- RTC：标准 48 字节 SNTP 报文的双向对时，回应丢失时超时重发。
- 615A：目标端经 TFTP 完成上传（单头文件、单数据文件，写入 8 KiB RAM）和介质定义卸载（`MEMORY.BIN`），支持 A3/A4（默认 A4），请求端口默认 59；信息操作和操作员定义卸载的初始化请求返回状态 1002。

没有实现：615A 的信息操作、操作员定义卸载的后续传输、FIND/WAIT/ABORT 和整文件重试，TFTP 可选项协商，SNMP 的 GetBulk、多变量绑定和 v1 Trap，IP 分片重组。

## 测量条件和限制

- 性能是RTL仿真测量，R95有效载荷吞吐不重复计算A/B副本。gbe77定长1471字节为906.136 Mbps；混合1、17、256、1024、1471字节的var_high为904.752 Mbps。四类工况均有0/257拍延迟、双向和A/B两网，详情见[工况表](docs/FACTS.md#变长帧与多虚拟链路工况)。
- 稳态 L_app 末字节最大24.432 µs（链路0拍），包含257拍链路时为26.488 µs；var_cycle的R97抖动9.992 µs主要来自BAG相位等待（ΔTX +11.904、ΔRX −1.912 µs）。var_burst从实际提交完成到末字节最大34.840 µs，从计划释放到首/末字节为174.464/174.592 µs，两种口径抖动最大均0.008 µs；差额主要来自单应用口串行注入。来源：[性能证据](docs/evidence/perf_r97.json)的 `main_table`、`jitter_top3`。历史争用实验的理想释放偏差935.120 µs不是R97抖动，见[边界说明](docs/FACTS.md#五报告必须主动说明的边界)。
- 时钟同步误差在两端使用同一个理想时钟的仿真中测得：空载 0 ns，有用户流量时最大 10788 ns。
- R95-2建议调用并两次例化 `Tri_Mode_Ethernet_Mac`；R111说明无强制使用要求。本设计保留自研MAC，未集成官方MAC IP，理由及配置范围见[对照](docs/FACTS.md#九附录设计取舍依据的专项实验)。
- 综合后网表仿真使用官方流程导出的 VQM，不含布局布线延迟；吞吐等性能指标没有在网表上重测。布局布线后导出的 `.vo` 网表没有通过仿真，原因是工具导出的 18/36 位 RAM 写数据位序与仿真库不一致；按赛题答疑，综合后仿真即可。
- 已采用 PRES1.50 完成官方布局布线，时序见“综合与布线结果”；尚未做硬件实测，未覆盖外部 I/O 时序预算。
