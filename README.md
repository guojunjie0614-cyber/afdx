# AFDX 端系统 FPGA 工程

T79 已统一声明满负载每端 **63 TX / 63 RX VL**，每 VL BAG=1 ms / Lmax=1471，线路占用约 77.5%，单向计划载荷 741.384 Mbit/s；配置规模仍为发送 128 / 接收 4096 条 VL。单消息上限 8192 字节，TX 256 页、RX 16 重组上下文，默认 21 VL 子集不变。63 VL 基础七场景已按最新裁定验收：五项周期场景最大抖动 3.360 µs，B2 最大 96.752 µs（0x0114、1471 B），全部判据组 <100 µs；B1 的 HDL/完整性/双统计 PASS，122/126 组公式不成立、不作抖动判据。已验证单条 VL 发 8192 B（63 VL 混合场景）；多条 VL 并发长消息未验证；专项已暂停、未完成，已有局部结果不作规格依据，结果见 [T79 证据](docs/evidence/t79_63vl/summary.md)。81 VL 保留为超出声明的压力测试：周期最大抖动 3.368 µs；BAG 对齐撞车最大 107.7 µs 超门槛；混合溢出。**声明、RTL 性能与官方网表分别验收。** 交付边界见 [T78 交付总表](docs/evidence/frag1030_delivery/summary.md)。

**已验证单条 VL 发 8192 B（63 VL 混合场景）；多条 VL 并发长消息未验证**。多条 VL 边界专项已暂停、未完成；已有局部结果仅保存在 T79 证据，不作为并发规格限制。

> 2026-11-03 `feature/fragmentation-timing-1030` 分支已按 [1030 答疑](docs/sources/FPGA创新大赛问题汇总1030.xlsx) R138/R139 完成单消息 8192 字节 IPv4 分片与 16 上下文重组，并在不放宽约束（EQ6HL130/CSG484_H、125 MHz / 8.000 ns、0.30 ns setup uncertainty、CE_DIV=2、172 引脚、253 组合法 CE 多周期）下实现综合与布线后时序全闭合：官方综合 setup `+4.148 ns` / hold `+0.192 ns`（`0 / 164,745` 失败），配合 `PRES 1.30` 与固定簇布局 `elinx/tiles_1030.edc`（`11,044` 簇：`62,274` LUT、`35,597` FF、`10,230` CLB、`814` Memory）布线后 setup `+0.029 ns` / hold `+0.604 ns`（`0 / 96,142` 失败）。下文正文中 F1/T65 的旧资源与 `+0.016 / +0.229 ns` 保留为分片前历史基线；新版本集中构建与验证入口为 `tools/build_1030.py --route`、`tools/run_1030_checks.py` 和 `sim/run_fragmentation.ps1`，完整记录见 [1030 实现记录](docs/1030_IMPLEMENTATION.md)。

当前 F1 的 RTL 与 r5 A `18d1606c` 零差异；原 V1/V2 验证提交为 `t63@92ab7d7e`，F1b 在 `67d2e618` 基础上仅修正宏内测试观测。**V1 功能终验通过**：模块及整顶层网表清单 8/8 PASS，`tb_sys_net` 自检与独立核对通过；V2 时序复核通过；界面复跑通过（与 CLI 产物逐项比对 PASS，`.place`、`.route` 逐字节相同）。器件 EQ6HL130、封装 CSG484_H，主时钟 125 MHz（8.000 ns），CE_DIV=2。采用 PRES 1.30 和固定布局后，全部 53,882 个端点 setup/hold 均为 0 失败，最差余量为 +0.016 / +0.229 ns；setup 已含 0.30 ns 时钟不确定度。原始精度为 +16 / +229 ps，门槛按原始精度判定。

本工程是中科亿海微赛题“AFDX 端系统”的 FPGA 实现，顶层模块为 `AFDX_top`，A、B 双网 GMII 接口共用一个 125 MHz 时钟，目标器件 EQ6HL130（封装 CSG484_H）。提供 eLinx 3.0.7 的综合、实现入口和 ModelSim 自检仿真，不需要硬件平台；当前布线后时序见“综合与布线结果”。

已实现赛题要求的五项功能：用户数据发送、用户数据接收（含双网冗余、虚拟链路带宽间隔调度、序号和完整性检查）、SNMP 网络管理、ARINC 615A 数据加载和卸载、RTC 时钟同步。

## 设计与测试报告

- [设计报告 PDF](docs/design/AFDX端系统FPGA设计文档.pdf)
- [测试报告 PDF](docs/test/AFDX端系统FPGA测试报告.pdf)
- [报告源码与编译说明](docs/README.md)

## 目录

- `rtl/`：可综合的设计源码，共 34 个文件，模块分工见“模块一览”。
- `tb/`：自检测试平台；`tb/lib/` 是测试平台共用的端点和链路模型。
- `sim/`：ModelSim do 文件、回归入口、测试清单和固定向量。
- `tools/`：Python 参考模型、独立检查器和工具运行脚本。
- `elinx/`：eLinx 工程文件、工程默认设置、8 ns 时钟约束和命令行综合入口；`elinx/probe/` 是内部基础单元探测模块。
- `out/`：运行时生成的日志、抓包、波形和工作库，不随工程提交。

## 软件准备

基本工具为 Windows 版 eLinx 3.0.7、ModelSim SE-64 2020.4 和 Windows PowerShell 5.1，不需要 PowerShell 7。本分支的 7 份 RTL 使用 `MODEL_TECH` 条件分支处理 21 处声明顺序：ModelSim 自动定义该宏，编译提前声明；其他工具保留原位置声明及表达式。不要在综合命令中定义 `MODEL_TECH`。本分支仿真入口默认直接编译 `rtl/`，使用 `AFDX_MODELSIM_DECL_ORDER=0` 关闭 T75 兼容副本。
完整 56 项回归（原有 40 项 + T65 新增 16 项）、独立报文检查器及命令行综合/网表脚本另需 Python 3.10 或更新版本（验证版本为 3.12.7），以及 `psutil`、`pyasn1==0.4.8`。在实际选用的 Python 环境执行 `python -m pip install psutil pyasn1==0.4.8`。
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

命令行参考模型使用 `AFDX_PYTHON=E:/anaconda3/python.exe`。保持 `AFDX_MODELSIM_DECL_ORDER=0`（默认值），再运行步骤 1、2；ModelSim Transcript 中可执行 `set ::env(AFDX_MODELSIM_DECL_ORDER) 0`。测试会自动建立工作库和输入文件，不必先做综合。T77 的双工具编译、五项直接 RTL 仿真及综合输入文本等价证据见 [T77 执行报告](docs/evidence/t77_rtl_compat/summary.md)；下面 F1 界面走查结果保留为历史记录。

单独编译整顶层可在 ModelSim 的可写输出目录中执行 `vlib work`，然后 `vlog -vlog01compat <工程路径>/rtl/*.v`；无需显式 `+define+MODEL_TECH`。命令行自检示例：

```powershell
$env:AFDX_MODELSIM_DECL_ORDER='0'
$env:AFDX_CE_DIV='2'
& 'E:/anaconda3/python.exe' -B -X utf8 tools/eda.py sim --test tb_elinx
```

`$fatal`、`$finish_and_return` 保持原样。当前 ModelSim 会对未定义的 `$finish_and_return` 和两个未连接的可选输入端口发出警告，入口完整保留这些已知警告；其他警告、Error、Fatal、`RX_ASSERT` 与 RAM 冲突仍判失败。该兼容验收不证明 `$finish_and_return` 被触发时可以终止仿真。

T77 已通过五项直接 RTL 自检及改动后源码的完整 `build_1030.py --route --pres 1.30` 流程：默认 11,044 个锁定簇、172 个 P0 管脚不变，布线 setup `+29 ps` / hold `+604 ps`，setup/hold 各 `0/96,142` 失败端点。原样重综合网表 `e9e1734c…` 从官方 VQM 导入入口重新打包、锁定布线，也复现相同数值。旧基准 VQM `3cd8f5f8…` 和本次新 VQM `96d14e2f…` 分别绑定各自的布线证据；不要仅凭文本等价或结构等价混用网表、检查点与时序报告。

官方综合导出的 VQM 存在排列不确定性；本轮比较的五份 VQM 名称和功能结构相同，保序文本不同。将运行副本的 `NUM_PARALLEL_PROCESSORS` 设为 1 已验证生效，但没有恢复基准顺序，也未证明输出固定。界面 Run Behavioral Simulation 已于 11-04 人工验证 PASS：checks=9238 errors=0，Elapsed 0:02:18，Warnings 90；[截图](docs/evidence/t79_63vl/elinx_gui_behav_pass.png)及警告边界见 [T79 证据](docs/evidence/t79_63vl/summary.md)。
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

   本地 ModelSim 的 `vsim -c` 会经 vish 与 vsim 之间的本地 RPC 传输连接 `::1`，部分主机上该传输不可用（`RPC_Init ... WinError 10013`）。用批处理模式启动即可绕开，命令行为 `vsim -batch -do "do sim/run_judge.do; quit -f"`；本仓库的参考结果都在批处理模式下产生。

   指标见下面的表，汇总保存在 `out/modelsim/judge_<时间>_<进程>/result.txt`，各用例目录里有原始日志。吞吐测试会运行较久，可从 `performance/simulation.log` 查看已到达的测试阶段。

### 应用激励入口（只注入 VLID 和应用数据）

R124、R126 要求顶层激励文件只注入 VLID 和应用数据，R120-3 说明发送侧输入、接收侧输出都是包含 VLID 的原始有效载荷。`sim/run_app.do` 的顶层激励只负责应用数据，系统配置移到 `tb/lib/afdx_sys_config.v`；默认直接编译 RTL，评委不需要编写配置寄存器激励：

```tcl
do sim/run_app.do
do sim/run_app.do sim/vectors/app/small_stimulus.txt
```

- `sim/vectors/app/vl_config.txt`：每行一条发送 VL，`<VLID> <BAG µs> <Lmax 字节> <源端口> <目的端口>`，默认 21 条，VLID 为四位十六进制。非顶层 `afdx_sys_config` 读取该文件，经 `cfg_*` 写两端配置；激励中的 VLID 两字节直接送入新顶层，不在测试平台换算成发送序号。
- `sim/vectors/app/stimulus.txt`：每行一条消息，`<发送时刻 µs> <VLID 四位十六进制> <载荷十六进制>`，`#` 开头为注释；时刻可以相同，相同时刻按文件顺序排队注入；载荷 1–8192 字节；超过 1471 字节时使用分片测试入口。VLID 不在配置中的行直接报错停止。
- 默认激励同时覆盖 1、17、256、1024、1471 字节，21 条 VL 并发，并在 1–4 ms 的窗口内以约 210 Mbps 注入有效载荷；`tools/gen_app_vectors.py` 可重新生成这两份默认文件。

运行结果在 `out/app/<运行名>/`：`rx.txt` 每行 `<交付首字节拍> <交付末字节拍> <VLID> <载荷十六进制>`；`summary.txt` 给出第 2 节定义的三项指标和判定；`es1_tx/`、`es2_rx/`、`es1_gmii_*/` 等目录保存原始记录。入口自检每条消息恰好交付一次、逐字节一致、A/B 冗余副本不重复交付，成功打印 `APP ENTRY PASS`，失败打印 `APP ENTRY FAIL`。默认第 3 个参数可给运行名，便于固定输出目录。

下列 PNG 为此前版本的归档截图，表中时间窗口对应这些原图；当前管理响应拍数以本版联测结果为准。

报告波形：在仓库根目录执行 `do sim/wave/tx_dual.do`；另外四个脚本是 `rx_redundancy.do`、`rx_fcs_error.do`、`tx_bag.do`、`snmp_get.do`，均自行编译、运行并显示真实 ModelSim Wave 窗口，采用默认黑底配色。生成输入向量时需要上述 Python 环境。切换场景前执行 `quit -sim`，再切回根目录。
批量截图用 `python sim/wave/export.py`，单个场景可追加 `--scene tx_bag`。脚本通过 Windows 的 `PrintWindow` 捕获本次 ModelSim 会话的 Wave 窗口，保留菜单、信号名、数值、时间轴和光标读数。`sim/wave/png/` 已更新为分片版 11-03 波形截图（来源提交 `12858ddf`），`tb_elinx.png` 为 11-04 eLinx 界面人工验证截图；工作库、WLF、原始窗口截图和日志保存在 `out/wave/`。

| 图片 | 时间窗口（us） | 观察内容 |
|---|---:|---|
| `tx_dual_1.png` | 686.020–689.020 | 应用输入与 A、B 双网发送的时序总览 |
| `tx_dual_2.png` | 688.220–688.540 | 放大双网帧起点和部分帧头字节 |
| `rx_redundancy_1.png` | 3014.186–3014.446 | A 网交付事件及交付给应用的字节 |
| `rx_redundancy_2.png` | 3030.026–3030.286 | B 网帧尾字节与副本丢弃事件，光标间隔 16.016 us |
| `rx_fcs_error_1.png` | 798.446–799.696 | A 网 FCS 错误计数从 0 变为 1，B 网正常交付 |
| `rx_fcs_error_2.png` | 798.780–799.100 | 放大错误帧的部分字节 |
| `rx_fcs_error_3.png` | 972.991–973.039 | 独立读地址 0x49，一拍请求经两级流水后有效返回 1 |
| `tx_bag.png` | 10.000–830.000 | 两个帧起点的光标间隔为 800 us |
| `snmp_get_1.png` | 525.400–525.720 | Get 请求的双网帧起点及部分帧头字节 |
| `snmp_get_2.png` | 537.804–538.124 | Response 的双网帧起点及部分帧头字节 |

本次 F1 评委入口八项均通过，Error/FAIL/RAMCOLL 为 0；下列为本轮实际耗时，包含当时机器负载的影响。

| 用例 | 实测耗时（秒） |
|---|---:|
| services | 8.059 |
| capacity | 10.028 |
| snmp | 46.268 |
| burst77 | 11.819 |
| burst81 | 11.489 |
| rtc | 311.964 |
| performance | 2253.870 |
| perf_var | 3674.099 |
| 总入口 | 6337.985 |

```text
JUDGE CASE PASS services checks=1122 errors=0 warnings=0 elapsed_s=8.059
JUDGE CASE PASS capacity checks=49924 errors=0 warnings=0 elapsed_s=10.028
JUDGE CASE PASS snmp checks=699 errors=0 warnings=0 elapsed_s=46.268
JUDGE CASE PASS burst77 checks=530765 errors=0 warnings=0 elapsed_s=11.819
JUDGE CASE PASS burst81 checks=554697 errors=0 warnings=0 elapsed_s=11.489
JUDGE CASE PASS rtc checks=10675841 errors=0 warnings=0 elapsed_s=311.964
JUDGE CASE PASS performance checks=683383807 errors=0 warnings=0 elapsed_s=2253.870
JUDGE CASE PASS perf_var checks=1254269621 errors=0 warnings=0 elapsed_s=3674.099
JUDGE ENTRY PASS cases=8 warnings=0 elapsed_s=6335.395 output_mib=1099.5
```

[评委入口参考输出](sim/reference/judge_result.txt) 和 [原 40 项回归参考汇总](sim/reference/regression.json) 对应 F1 终验，验证提交为 `92ab7d7e`。当前 56 项标准回归的结果见 [T65b 合并验收](docs/T65b_REGRESS.md)及[完整汇总](docs/evidence/t65b_regress/regression_summary.txt)。性能来自同一版本的完整窗口记录，见[性能证据](docs/evidence/perf_r97.json)。耗时、时间戳和输出目录随运行变化。

下面两步需要先按“软件准备”安装 Python 依赖，并在 PowerShell 中进入同一工程根目录。

3. 运行全部 56 项测试（原有 40 项 + T65 新增 16 项），参考检查器会另行核对报文和周期记录；新增项由 `tools/t65_check.py` 独立核对。

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File sim/regress.ps1
   ```

   预期：末尾表格中的 56 项都为 `PASS`；汇总位于 `out/regress/`，每项日志位于 `out/sim/`。T65b 在 CE_DIV=2 下实跑 56/56 PASS，Error/Fatal/Warning/FAIL/RAMCOLL 均为 0，耗时 6038.613 秒（1 小时 40 分 39 秒）；原 40 项检查数与 F1/T64 一致，新增 16 项与 T65 一致。本次未运行 56 项 CE1 回归。

管理协议引擎使用同一个 125 MHz 时钟，通过时钟使能（Clock Enable，CE）每两拍更新；接收捕获、发送输出、配置口、RAM 端口和 RTC 计时保持全速。顶层参数 `CE_DIV` 可取 1 或 2，默认 2。两种配置的完整回归和评委入口可分别运行：

```powershell
$env:AFDX_CE_DIV='1' # 第二轮改为 2
powershell -NoProfile -ExecutionPolicy Bypass -File sim/regress.ps1
vsim -batch -do 'do sim/run_judge.do; quit -f'
```

该环境变量仅选择 RTL 仿真参数；官方综合使用工程中顶层参数的默认值 2。定长性能用例的原生仿真墙钟预算为 5400 秒，变长帧用例为 14400 秒，测试中的周期数和判定条件保持原值。

ModelSim 静态检查：在仓库根目录执行 `vlib out/lint_work`，再执行 `vlog -lint -vlog01compat -work out/lint_work rtl/*.v`；ModelSim 工具目录需在 PATH 中。
本轮官方流程覆盖当前 29 个 RTL 文件；编译及静态检查结果由对应日志定位。

综合和界面共用的唯一源文件入口是 `elinx/afdx_all.v`：`elinx/AFDX_EndSystem.epr` 只列这一个文件，增删 RTL 文件时改总文件，不改 epr。
总文件按固定顺序包含 `rtl/` 下每个 `.v` 恰好一次，界面与命令行因此读到同一份源文件集合。
修改后运行 `python tools/check_wrapper.py`，确认 epr 只列总文件、包含关系不多不漏且总文件没有其它语句。

代码覆盖率默认关闭。完整回归追加 `-Coverage`，单项运行用 `sim/run.ps1 -Test tb_ram_sdp -Coverage`；仅 RTL 按 `+cover=sbceft` 编译，每项在输出目录保存带唯一测试名的 `coverage.ucdb`，测试平台不计入覆盖率。
用 ModelSim 的 `vcover merge merged.ucdb input1.ucdb input2.ucdb ...` 合并，再用 `vcover report -codeAll "-du=work.afdx_snmp" -output report.txt merged.ucdb` 导出模块报告，替换其中的模块名即可。T64 冻结基线与原始报告在 `docs/evidence/t64_f1_coverage/`；T65 合并统计与原始报告在 `docs/evidence/t65_gap_tests/`，输入清单和数据库摘要见其中 `ucdb_inputs.json`、`coverage.json`。大型 UCDB 不随提交包分发。

### T65 合并覆盖率与定向补测

T65 的 16 项新增测试补测了 A 网队列满及恢复、应用收发封装资源边界，以及 RX 引擎、MAC TX、应用 TX 三个登记状态的复位恢复；正向测试和独立核对全部通过。登记目标中，A01 的 26 项、A02 的 2 项、G3 的 3 项均有 UCDB 命中证据，合计 31 项；G3 备选 T64-0906 未注入。32 个仿真反例和 32 个离线捕获破坏反例均被检出。详见 [T65 补测报告](docs/T65_GAP_TESTS.md)与[目标命中记录](docs/evidence/t65_gap_tests/target_hits.json)。

当前合并统计复用 T64 的 40 份成功 UCDB，加入 T65 的 16 份正式 UCDB，共 56 次尝试、29 个 RTL 设计单元；失败及反例未纳入。以下数字来自 [T65 合并统计](docs/evidence/t65_gap_tests/coverage.json)，百分比按计数截断到两位。T65b 的 56 项普通回归不带覆盖率，未生成新的覆盖率批次。

| 覆盖类别 | 已覆盖 / 总数 | 百分比 |
|---|---|---|
| 语句 | 7760 / 7866 | 98.65% |
| 分支 | 4354 / 4495 | 96.86% |
| 条件 | 893 / 1001 | 89.21% |
| 表达式 | 1788 / 2059 | 86.83% |
| 已识别状态 | 127 / 127 | 100.00% |
| 已识别转换 | 159 / 338 | 47.04% |
| 翻转 | 46008 / 59950 | 76.74% |

**合并统计与 T64 有 9 组设计单元/指标的分母不同，根因尚未证明；接受该结果作为当前集合的统计，不计算同口径增幅，也不据百分比下降判定功能退化。** 原始分母保留，未增加排除项，差异见 [分母核对](docs/evidence/t65_gap_tests/denominators.json)。状态 100% 仅限工具识别集合；接收封装压力为模块级，复位只覆盖登记的三个精确状态，1 字节输入仅观察，不代表全部资源组合或复位边均已覆盖。

新增 16 项已由 T65b 并入 `sim/tests.txt`，独立检查器纳入正式入口，验收见 [T65b 报告](docs/T65b_REGRESS.md)。`tools/t64_coverage.py` 专用于原 40 项冻结集合，当前 56 项清单会触发其预期集合校验失败；保留该工具及历史证据，不把此失败计为功能失败。

### T64 冻结覆盖率基线

T64 冻结覆盖率基线：冻结提交 `e5cd8150`，CE_DIV=2，40 项完整 RTL 回归、29 个 RTL 设计单元、40 份 UCDB，按 `sbceft` 插桩，测试平台不计入。40/40 PASS，Error/Fatal/Warning/FAIL/RAMCOLL 均为零；普通回归复用 40 项，补跑 0 项，Checks、CheckItems 及 491 个确定性产物一致。详细来源与复用边界见 [T64 覆盖率报告](docs/T64_F1_COVERAGE.md)。

| 覆盖类别 | 已覆盖 / 总数 | 百分比 |
|---|---|---|
| 语句 | 7754 / 7864 | 98.60% |
| 分支 | 4344 / 4491 | 96.72% |
| 条件 | 882 / 1001 | 88.11% |
| 表达式 | 1767 / 2027 | 87.17% |
| 状态机，含状态和转换 | 282 / 465 | 60.64% |
| 已识别状态 | 127 / 127 | 100.00% |
| 已识别转换 | 155 / 338 | 45.85% |
| 翻转 | 44903 / 57890 | 77.56% |

百分比按各设计单元已覆盖项数／总项数汇总并截断到两位。状态 100% 仅限工具识别集合，两个服务引擎的主 `state` 未被识别，不能据此宣称全部状态机控制路径已验证。完整未覆盖索引包含 13,806 个 bin，其中 10,578 个尚不能判断原因或可达性；未增加排除项。原始报告、逐模块统计和缺口分析见 [T64 证据](docs/evidence/t64_f1_coverage/coverage.json)及 [未覆盖项分析](docs/evidence/t64_f1_coverage/gap_analysis.md)。

T64 串行覆盖率回归实际耗时 17,896.286 秒（约 4 小时 58 分），含冻结、对照和合并报告的原生批次耗时 18,093.625 秒（约 5 小时 2 分）。历史 T57 的 39 项、24 模块覆盖率保留在 `sim/reference/coverage/`，源码与统计分母不同，不能将两次总百分比差直接解释为验证进退。

4. 综合完整顶层，并检查 8 ns 时钟约束下的估算时序。

   先设置 `ELINX_HOME` 为 eLinx 安装根目录，即 `eLinx3.0.exe` 所在目录（可在桌面快捷方式上右键“打开文件所在的位置”找到），其下应有 `bin/Passkey/bin` 和 `bin/shell/bin`。把下面的占位文字换成实际路径；未设置时脚本会提示 `Set ELINX_HOME` 并退出：

   ```powershell
   $env:ELINX_HOME='eLinx安装根目录'
   powershell -NoProfile -ExecutionPolicy Bypass -File elinx/synth.ps1
   ```

   预期：打印 `OFFICIAL SYNTH PASS`，`out/latest_AFDX_top.json` 给出资源数、时序裕量、耗时及 `.vqm` 路径。综合工具仅调用 `quartus_map.exe`、`quartus_cdb.exe` 和 `Implementation.exe`，按工程设置依次完成分析综合、VQM 导出、装箱和综合后时序；所有运行产物写入 `out/synth/AFDX_top/`，不覆盖界面结果。

综合后运行 `powershell -NoProfile -ExecutionPolicy Bypass -File elinx/impl.ps1` 完成官方布局布线。`elinx/constraints.edc` 包含 PRES_FAC_MULT=1.30、172 条 P0 管脚和 5,540 条簇位置语句，固定布局来自 C0 加局部手工微调；改 RTL 会使布局失效。界面工程登记物理 EDC 与纯时序 SDC 两份文件，CLI 经 Tcl `source` 完整 EDC、再 `read_sdc` 纯时序 SDC。本轮在 125 MHz、0.30 ns setup uncertainty 下为 setup +0.016 ns、hold +0.229 ns，setup/hold 各 0/53,882 失败端点；界面复跑结果相同。eLinx 界面会对登记的每个约束文件生成 `read_sdc`，并对 `.edc` 另加 `source`，因此 `physical_only.edc` 也会交给 SDC 解析器；解析器对其中约 5,700 条 PRES、管脚和簇位置语句逐条报 `invalid command`，这是预期现象，这些语句已由 `source` 生效，界面结果与 CLI 逐字节一致。

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
| 定长与混合帧长性能 | gbe77 / var_high 每方向最小注入 906.136/904.752 Mbps。gbe77 的主时延最大 48.288/50.344 µs（链路 0/257 拍），20 个窗口的最大值为 63.576 µs。R119-2 抖动最大 19.536 µs，位于 var_cycle_d0、es1_to_es2、VL25、256 字节，帧 2666→3266。var_burst 的计划释放→首/末字节最大 185.760/185.888 µs，释放口径抖动最大 0.008 µs。释放口径包含主机串行注入排队，与从首字节 valid 起算的主口径分开报告。逐方向原值见 [性能证据](docs/evidence/perf_r97.json)。 |
| 超出声明的历史压力测试：77/81 条 VL 同时提交后的队列排空时间 | 本轮 `JUDGE METRIC burst_vls=... queue_clear_us=...` 分别为 983.424/1032.640 µs；81 条用例覆盖超过 1 ms 的边界。 |
| 时钟同步误差 | 空载最大 0 ns，普通用户流量最大 0 ns，77 条 VL 满载最大 0 ns；共用理想时钟和对称链路，经公开配置口读回比较，未测试晶振漂移或硬件误差。 |
| 赛题五功能 | `tb_net_services` 的 `[FUNCTION]` 行检查用户收发、网络管理、时钟同步、加载和卸载，最后须为 `[RESULT] ... PASS ... errors=0`。 |
| 虚拟链路容量 | `capacity` 每端配置 4096 条接收虚拟链路，并逐字节验证索引 0、4095 和中间 126 项。每端全部 128 条发送虚拟链路都发出消息，对端每条只交付一次。 |
| 网络管理（SNMP，Simple Network Management Protocol） | `snmp` 检查 Get、GetNext、Set 的请求号回显、错误码为 0、返回值与配置口寄存器一致；Trap 检查错误码为 0、启动通知类型和运行时间寄存器。 |

按[1026答疑](docs/sources/FPGA创新大赛问题汇总1026.xlsx) R119/R120，端到端时延取消息首字节在应用发送口第一次 `valid` 为高到接收应用口交付该消息末字节（L_entry_last），同时报告到首字节（L_entry_first）；GMII SFD→SFD 的旧 R97-1 口径和“应用末字节提交”口径（L_gmii、L_app 等）只作兼容字段，不再作为主指标。R119-2 抖动按同一 VL、同一帧长分组取极差再取最大，并给出所在 VL、帧长和两帧编号；旧“同一 VL 不区分帧长”的口径已被取代。R120-1 吞吐在发送注入口按握手成功的有效载荷字节数统计，并报告反压拍数、最长连续反压和相对计划释放的落后拍数。

新变长工况只对 var_high 检查注入 ≥100 Mbps；var_fixed/var_cycle/var_burst 的给定负载较低，实测 57.794/70.403/57.794 Mbps，只报告。所有工况所有帧 L_entry_last ≤2000 µs，丢帧、重复和溢出均为 0；R119-2 抖动逐项报告，并按项目检查线 50 µs 核对；该检查线不是官方上限。当前 `JUDGE BASELINE` 的 gbe77 L_entry_last 为 48.288/50.344 µs（链路 0/257 拍），旧 L_app 兼容字段见[性能证据](docs/evidence/perf_r97.json)的 `policy`、`main_table`。

变长多VL测试：`powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_sys_perf_var`；纯ModelSim在仓库根目录执行 `set ::env(AFDX_JUDGE_CASE) perf_var`、`do sim/run_judge.do`。取消筛选用 `unset ::env(AFDX_JUDGE_CASE)`。五种载荷、VL/BAG与窗口见[工况表](docs/FACTS.md#变长帧与多虚拟链路工况)。

`tb_gbe_burst` 的突发指标在发送核心的消息输入口和接收核心的消息交付口之间测量。该专项按核心消息边界统计；应用封装首字节到对端交付的 R119 指标另行记录。
队列全部发完的时间从同时提交所有消息时起算，与单条消息的时延不同。以上吞吐和周期指标是 RTL 仿真测量；布线后静态时序另见“综合与布线结果”，不能当作上板实测。

## 从 eLinx 界面运行自检

当前源码的 Run Behavioral Simulation 已于 11-04 人工点击验证通过：`[RESULT] tb_elinx PASS checks=9238 errors=0`，Errors 0、Warnings 90、Elapsed 0:02:18，[截图](docs/evidence/t79_63vl/elinx_gui_behav_pass.png)。Warnings 为既有 ModelSim 系统任务/可选端口诊断，完整说明见 [T79 证据](docs/evidence/t79_63vl/summary.md)。官方网表复现见 [T76 复现说明](docs/evidence/t76_frag1030/official_reproduction.md)。

若界面卡在 “Loading...”，已定位的原因是 vish 与仿真内核的本机连接失败（`couldn't open socket: invalid argument`），可关闭代理/VPN 后重试；也可在 `elinx/AFDX_EndSystem.sim/sim_1/behav` 下执行 `vsim -batch -t 1ps work.tb_elinx -do "run -all; quit -f"`。该备用入口已有 15 s、9238 检查 PASS 记录（任务卡提供，本轮未重跑）。

1. 用 eLinx 打开 `elinx/AFDX_EndSystem.epr`，在 Settings → Tool Settings → 3rd Party Simulators 设置 ModelSim 的安装目录。该目录应包含 `modelsim.exe`。
2. 在 Sources → Simulation Sources → `sim_1` 中确认目标仿真文件是 `tb_elinx.v`、仿真顶层是 `tb_elinx`，并且有 `judge_endpoint.v`。这些设置已写入工程，综合顶层仍是 `AFDX_top`。
3. 点击 Flow → Run Behavioral Simulation。ModelSim 会运行两个端系统经双网互发 1、64、1471 字节消息的自检；预期依次看到三条 `[ELINX_MESSAGE] ... both_directions=PASS`，最后是 `[RESULT] tb_elinx PASS checks=9238 errors=0`。测试不需要 Python、输入文件或额外的 include 路径和宏。

分片版已于 11-04 在界面人工复跑通过：`[RESULT] tb_elinx PASS checks=9238 errors=0`，仿真时间 2,557,777 ns，Elapsed 0:02:18，Errors 0、Warnings 90；界面截图见 `sim/wave/png/tb_elinx.png`。仿真结束时 ModelSim 会弹出 Finish Vsim 对话框，选“否”可保留窗口查看输出。

## 综合后网表仿真

界面 Run Synthesis 和命令行 `elinx/synth.ps1` 导出同一官方流程的 `.vqm`，共用下面的仿真入口。先完成快速上手第 4 步，再在 PowerShell 中执行：

```powershell
$net = (Get-Content out/latest_AFDX_top.json -Raw | ConvertFrom-Json).netlist
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_gui_netlist.ps1 -Test tb_net_services -Netlist $net
```

入口先仿真 RTL，再用相同激励仿真新生成的 VQM，逐字节比较七份外部记录。自检项数必须与本次 RTL 一致，独立检查错误为 0；`exact_external_records` 七项均须为 `true`。

本次 F1 官方重建 VQM 与同次 RTL 的 `tb_net_services` 均通过 1122 项自检，Error/FAIL/RAMCOLL 均为 0；网表独立检查 65 项，七份外部记录逐字节一致。网表使用本卡 V2 的 VQM，不含布线延迟；证据见 `docs/evidence/t63_f1_functional.json` 的 `services_netlist`。

使用界面产物时省略 `-Netlist`，默认读取 `elinx/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm`。两种入口都不重新综合；每次仿真的网表副本、日志、独立检查和 `summary.json` 放在 `out/gui_netlist/` 下的新目录。出错时打印 `GUI NETLIST FAIL` 或 `GUI NETLIST ENTRY FAIL` 并返回非零退出码，总时限为五小时。

较长的双端双网互发自检可用 `sim/run_gui_netlist.ps1 -Test tb_elinx -Netlist $net`。此前界面网表已通过 9238 项检查、0 错误，仿真约 130 分钟；本轮只重跑新网表的五功能测试。

官方导出的网表省略了取默认值的输入和参数，而配套单元仿真模型没有给这些输入和参数设默认值，直接仿真时寄存器不会更新。`tools/adapt_gui_vqm.py` 仅在仿真副本上补齐：省略输入按组件声明和单元模型的默认上拉、下拉取值；原有进位连接补上 `cin_used="true"`。原有连接、功能参数、查找表内容以及厂商模型均不改。复制寄存器的 `created_from` 仅记录综合来源，厂商仿真模型没有该参数；仿真副本将这项元数据转存审计报告。补全数量和来源记录保存在 `summary.json` 的 `adaptation` 中。

## 综合与布线结果

当前 F1 的 RTL 与 r5 A `18d1606c` 零差异；原 V1/V2 验证提交为 `t63@92ab7d7e`，F1b 在 `67d2e618` 基础上仅修正宏内测试观测。**V1 功能终验通过**：模块及整顶层网表清单 8/8 PASS，`tb_sys_net` 自检与独立核对通过；V2 时序复核通过；界面复跑通过（与 CLI 产物逐项比对 PASS，`.place`、`.route` 逐字节相同）。器件 EQ6HL130、封装 CSG484_H，主时钟 125 MHz（8.000 ns），CE_DIV=2。采用 PRES 1.30 和固定布局后，全部 53,882 个端点 setup/hold 均为 0 失败，最差余量为 +0.016 / +0.229 ns；setup 已含 0.30 ns 时钟不确定度。原始精度为 +16 / +229 ps，门槛按原始精度判定。

| 项目 | 当前官方结果 |
|---|---:|
| 查找表（LUT） | 39895 / 136160（29.30%） |
| 触发器（FF） | 20885 / 136160（15.34%） |
| 可配置逻辑块（CLB） | 5136 / 13616（37.72%） |
| 存储器（M4K） | 404 / 1200（33.67%） |
| 用户引脚 | 172 / 339（50.74%） |
| DSP / PLL | 0 / 0 |
| 布线后建立裕量／保持裕量 | +0.016 / +0.229 ns |
| 布线后 setup / hold 失败端点 | 0 / 53882；0 / 53882 |
| 8 ns 单周期路径数／最差 setup | 181000 / +0.016 ns |
| 16 ns 多周期路径数／最差 setup | 50296 / +0.268 ns |
| 同沿 hold 路径数 | 231296 |

`elinx/constraints.edc` 包含 PRES 1.30、172 条 P0 管脚语句和 5,540 条簇位置语句；固定布局来自 C0 布局加局部手工微调。**改 RTL 会使布局失效**，必须重新生成并验证位置约束。界面工程登记 `physical_only.edc` 与 `timing_only.sdc`，两者拼接与完整 EDC 一致；物理语句经 Tcl `source`，纯时序部分经 `read_sdc`，0.30 ns uncertainty 与已批准多周期约束保持不变。eLinx 界面会对登记的每个约束文件生成 `read_sdc`，并对 `.edc` 另加 `source`，因此 `physical_only.edc` 也会交给 SDC 解析器；解析器对其中约 5,700 条 PRES、管脚和簇位置语句逐条报 `invalid command`，这是预期现象，这些语句已由 `source` 生效，界面结果与 CLI 逐字节一致。

约束审查覆盖 2755 个引擎寄存器、51992 条内部寄存器连接，invalid/uncovered 均为 0。资源、原始时序和前十路径见 [F1 时序证据](docs/evidence/t63_f1_timing.json)，功能终验及输入绑定见 [F1 终验记录](docs/evidence/t63_f1_final.json)。

当前标准 CE2 回归已扩展为 56 项，T65b 实跑 56/56 PASS，Error/Fatal/Warning/FAIL/RAMCOLL 均为 0。原 F1 的评委 8/8、默认及小激励、wrapper、官方 VQM 五功能，以及 F1b 补验后的模块及整顶层网表 8/8 结果继续沿用原证据；T65/T65b 未改 RTL 或约束，也未重跑这些入口。T64 的 40 项覆盖率基线与 T65 新增 16 项的合并统计分别保留，T57 旧记录仅作为历史保留。

F1b 已修正 `SYS_TOP_NETLIST` 下的公开输入消息观测和双网接收来源观测。RTL＋宏及同一 F1 V2 官方 VQM 的 `tb_sys_net` 均通过 2,792,645 项自检、0 错误，独立核对 88/88（含 16 项固定检查和 72 项帧级检查）；Error/Fatal/Warning/FAIL/RAMCOLL 均为 0。仅宏内显式跳过以私有核心末次握手为起点的两项 96 拍时限检查，保留结果对应、容量、顺序、原主机/排空期限和外部逐字节核对。无宏 CE1/CE2 的有效预处理 HDL 逐字节一致；原始预处理输出的行号指令和空白行单独保留。原始失败、超时和控制脚本错误保留于 [前序失败证据](docs/evidence/t63_f1_sys_net_failure.json)，本次通过证据及边界见 [F1b 补验](docs/evidence/t63_f1b_sys_net_pass.json)。

F1 的界面复跑已完成，产物比对 PASS，记录见 [界面比对](docs/evidence/t63_f1_gui_compare.json)；操作步骤见 [F1 界面复跑](docs/T63_F1_GUI.md)。

`sim/wave/png/` 已更新为来源 `12858ddf` 的分片版 11-03 波形，`tb_elinx.png` 使用 11-04 eLinx 界面截图。静态时序不等于上板实测，也未覆盖完整外部 I/O 延迟预算。

## 模块一览

| 文件（均在 `rtl/`） | 职责 |
|---|---|
| `AFDX_top.v` | VLID 与载荷的应用字节流封装，连接收发适配和端系统核心。 |
| `afdx_es.v` | 集成双网收发、GMII、配置和三种服务，共用 125 MHz 时钟。 |
| `afdx_app_tx.v` | 接收应用消息，查找发送 VL，保存和提交完整消息。 |
| `afdx_app_rx.v` | 接收交付载荷，反查 VLID 并输出连续应用字节流。 |
| `afdx_app_map.v` | 同步保存接收索引对应的 VLID。 |
| `afdx_app_read.v` | 预取发送封装 RAM，向核心连续提交字节。 |
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

数据路径：应用 `tx_data/tx_valid` 经 `afdx_app_tx` 到 `afdx_es` 的发送、GMII、接收和服务通路，再经 `afdx_app_rx` 输出 `rx_data/rx_valid`。A/B 网各有独立 `gmii_*` 引脚；配置口、事件口和同步时钟直接引出。`app_*` 只属于内部核心接口，完整顶层端口共占 172 个用户引脚。

R120-3 说明 `tx_data` 是送进端系统发送端的数据、`rx_data` 是接收端处理完的输出，数据流是包含 VLID 的原始有效载荷；R124、R126 说明评测时顶层激励文件只注入 VLID 和应用数据，用于综合的 TOP 端口可以自定。本设计的可综合 `AFDX_top` 直接接收并交付 VLID 两字节及载荷，GMII 单独引出为 `gmii_*_a/_b`，不再有顶层 `app_*` 端口；`sim/run_app.do` 直接驱动并记录这组应用端口。PDF 模板的 tx_data 方向与 R120-3 相反，本设计按 R120-3。R122 说明只要能正常综合，资源占用不作为评分项；R112 允许用仿真截图及演示视频代替开发板照片和视频。

测试与参考模型的对应：`tb_tx_*`、`tb_rx_*` 对应 `afdx_ref.py`、`tx_ref.py`、`rx_ref.py`；`tb_sys_*` 对应系统、GMII 和各服务的参考模型；`tb_net_services` 对应 `net_services_ref.py`。`tools/eda.py` 负责生成向量、调用仿真和检查器。ModelSim do 入口使用 `sim/vectors/` 中的固定向量和测试平台自检，不调用 Python。

## 实现范围

- 用户收发：UDP/IPv4/Ethernet 组帧，组播目的 IP 为 224.224 加虚拟链路号；每端 128 条发送虚拟链路、4096 条接收虚拟链路；按带宽间隔调度；接收端做序号完整性检查和双网冗余去重。
- SNMP：v1/v2c 的 Get、GetNext、Set 和 v2c Trap，一次一个变量绑定。
- RTC：标准 48 字节 SNTP 报文的双向对时，回应丢失时超时重发。
- 615A：目标端经 TFTP 完成上传（单头文件、单数据文件，写入 8 KiB RAM）和介质定义卸载（`MEMORY.BIN`），支持 A3/A4（默认 A4），请求端口默认 59；信息操作和操作员定义卸载的初始化请求返回状态 1002。

没有实现：615A 的信息操作、操作员定义卸载的后续传输、FIND/WAIT/ABORT 和整文件重试，TFTP 可选项协商，SNMP 的 GetBulk、多变量绑定和 v1 Trap，IP 分片重组。

## 测量条件和限制

- 性能是 RTL 仿真测量，R120-1 的注入有效载荷不重复计算 A/B 副本。gbe77 定长 1471 字节注入 906.136 Mbps；混合 1、17、256、1024、1471 字节的 var_high 注入 904.752 Mbps。四类工况均有 0/257 拍延迟、双向和 A/B 两网，详情见[工况表](docs/FACTS.md#变长帧与多虚拟链路工况)。
- gbe77 的主时延最大 48.288/50.344 µs（链路 0/257 拍），20 个窗口的最大值为 63.576 µs。R119-2 抖动最大 19.536 µs，位于 var_cycle_d0、es1_to_es2、VL25、256 字节，帧 2666→3266。var_burst 的计划释放→首/末字节最大 185.760/185.888 µs，释放口径抖动最大 0.008 µs。释放口径包含主机串行注入排队，与从首字节 valid 起算的主口径分开报告。逐方向原值见 [性能证据](docs/evidence/perf_r97.json)。
- 时钟同步误差：空载最大 0 ns，普通用户流量最大 0 ns，77 条 VL 满载最大 0 ns；共用理想时钟和对称链路，经公开配置口读回比较，未测试晶振漂移或硬件误差。
- R95-2建议调用并两次例化 `Tri_Mode_Ethernet_Mac`；R111说明无强制使用要求。本设计保留自研MAC，未集成官方MAC IP，理由及配置范围见[对照](docs/FACTS.md#九附录设计取舍依据的专项实验)。
- 综合后网表仿真使用官方流程导出的 VQM，不含布局布线延迟；吞吐等性能指标没有在网表上重测。本轮没有进行含布线延迟的网表仿真；历史 `.vo` 的 RAM 位序不匹配记录不能作为本轮 VQM 结果。
- 已采用 PRES1.30 和 5,540 条簇位置约束完成官方布局布线，时序见“综合与布线结果”；尚未做硬件实测，未覆盖外部 I/O 时序预算。

## T76 混合负载声明

混合最大声明为 **63 TX / 63 RX VL**；T79 已将纯短消息同步下调为 63 TX / 63 RX VL，81 VL 保留为超出声明的压力测试。固定激励的二分相邻边界为 70 VL 通过 20 ms、71 VL 失败，取 63 VL 留出 10.0% 余量，随后 100 ms 功能与逐字节交付通过，两套统计一致，TX 页上界不超过 256。此边界是按既定二分法、固定激励及其单调性假设得到，不冒称穷举所有 VL 数。性能门槛另见统计表，原 81 VL 混合溢出继续列为限制。

[完整规格](docs/ARCH.md#t76-混合负载声明搜索确认)；[证据与各门槛](docs/evidence/t76_frag1030/summary.md)。

## frag1030 复现步骤（T78）

在工程根目录运行；软件安装及许可证见前文。先设置：

```powershell
$env:AFDX_PYTHON='E:/anaconda3/python.exe'
$env:MODELSIM_HOME='E:/Verilog/ModelSim/setup_pack/win64'
$env:ELINX_HOME='E:/2026_Embedded_FPGA/setup_pack'
$env:AFDX_CE_DIV='2'
$env:AFDX_MEM_FLOOR_GB='3'
$env:AFDX_MODELSIM_DECL_ORDER='0'
```

1. RTL：打开 `elinx/AFDX_EndSystem.epr`，仿真顶层 `tb_elinx`，点 Run Behavioral Simulation；该界面点击路径已于 11-04 人工验收 PASS 9238，截图见 T79 证据。已验证命令行等价入口：

   ```powershell
   & $env:AFDX_PYTHON -B -X utf8 tools/eda.py sim --test tb_elinx
   ```

   预期 `[RESULT] tb_elinx PASS checks=9238 errors=0`；直接编译原样 RTL。

2. 综合后仿真：按答疑第 155 条，用 `synth_1/AFDX_EndSystem.vqm` 替换实现仿真 `.do` 中的 `.vo`，厂商库保持原样。下列脚本保留超出当前声明的 81 VL 历史压力测试复现，准备运行目录、唯一官方 VQM、参数及 `official_inputs.tcl`，并调用 `sim/run_t76_post_synth.do`：

   ```powershell
   & $env:AFDX_PYTHON -B -X utf8 tools/t76_sim.py --help
   $env:AFDX_T76_SPEC_CONFIRMED='1'
   & $env:AFDX_PYTHON -B -X utf8 tools/t76_sim.py --netlist '<synth_1/AFDX_EndSystem.vqm>' --reference '<同参数RTL运行目录>' --deadline '<本轮ISO截止>' --param VL_COUNT=81 --param GROUP_LENGTH=1471 --param MIXED=2 --param DUPLEX=0 --param DURATION=125001 --param SMOKE=0 --param SWAP=0
   ```

   同参数 RTL 参考先用相同命令去掉 `--netlist` 和 `--reference` 生成；反方向用 `SWAP=1`。预期 `[RESULT] tb_t76_load PASS checks=161 errors=0`、`T76 OFFICIAL .VO TO .VQM ENTRY PASS`，且 11 份公开输出与显式 RTL 参考逐字节相同。现存准备目录可用 `vsim -batch -do "do sim/run_t76_post_synth.do <PREPARED_RUN_FOLDER>"` 重放。此命令会运行耗时网表仿真，T78 没有重跑；历史两窗口各约 7.5 小时，不能用 RTL 的四小时上限替代。

3. 最终快速回归：输出目录必须不存在；52 项基础及 11 项分支用例，最多 6 个 ModelSim，原样 RTL：

   ```powershell
   $env:AFDX_SIM_TIMEOUT_SECONDS='3600'
   & $env:AFDX_PYTHON -B -X utf8 tools/par_regress.py --output out/reproduce_t78 --list sim/t78_quick_tests.txt --branch-tests --raw-sources --max-sims 6 --max-owned-sims 6 --rtl-hours 1
   & $env:AFDX_PYTHON -B -X utf8 tools/t76_app.py --deadline '<本轮ISO截止>'
   & $env:AFDX_PYTHON -B -X utf8 tools/t76_app.py --small --deadline '<本轮ISO截止>'
   ```

   预期 `PAR PASS` 63 项、`PAR FINISHED`；两个配置隔离入口均 `T76 APPLICATION ENTRY PASS`。各项 HDL/独立检查数见 [T78 回归证据](docs/evidence/frag1030_delivery/regression.json)。四个长用例不纳入快速版，其中 `tb_sys_perf` 引用 T76 修正检查器结果：HDL 683408635，独立项 1357450；其余引用 T75。T77 证明 MODEL_TECH 分支对 ModelSim 与兼容副本等价、对综合逐 token 保序相同。目标 30 分钟、上限 1 小时；已启动的原长用例保持原进程和原截止，收尾不等待。`tools/t78_run.py` 保留原全量启动历史；`tools/t78_fast.py` 是本轮快速收尾接管记录，无重试。

4. 实现：eLinx 工程中按综合、实现顺序执行，或命令行：

   ```powershell
   & $env:AFDX_PYTHON -B -X utf8 tools/build_1030.py --route --pres 1.30 --deadline '<本轮ISO截止>'
   ```

   预期 routed setup `+0.029 ns`、hold `+0.604 ns`，setup/hold 各 `0/96142` 失败端点；核对全部 11044 个锁定簇和 172 个 P0 管脚。新输出须绑定自身 VQM SHA256；T77 已验证文本排列不同但结构和锁定布线时序相同，不保证任意安装的普遍确定性。

当前 63 VL 统一声明、81 VL 压力测试、GUI 人工验收及工程基准差异见 [交付总表](docs/evidence/frag1030_delivery/summary.md)。
