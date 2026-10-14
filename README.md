# AFDX 端系统 FPGA 工程

本工程是中科亿海微赛题“AFDX 端系统”的 FPGA 实现，顶层模块为 `AFDX_top`，A、B 双网 GMII 接口共用一个 125 MHz 时钟，目标器件 EQ6HL130（封装 CSG484_H）。全部通过 eLinx 3.0.7 和 ModelSim 编译、仿真，不需要硬件平台。

已实现赛题要求的五项功能：用户数据发送、用户数据接收（含双网冗余、虚拟链路带宽间隔调度、序号和完整性检查）、SNMP 网络管理、ARINC 615A 数据加载和卸载、RTC 时钟同步。

## 目录

- `rtl/`：可综合的设计源码，共 21 个文件，模块分工见“模块一览”。
- `tb/`：自检测试平台；`tb/lib/` 是测试平台共用的端点和链路模型。
- `sim/`：ModelSim do 文件、回归入口、测试清单和固定向量。
- `tools/`：Python 参考模型、独立检查器和工具运行脚本。
- `elinx/`：eLinx 工程文件、工程默认设置、8 ns 时钟约束和命令行综合入口；`elinx/probe/` 是 RAM 等基础单元的综合探测模块，网表回归会用到。
- `out/`：运行时生成的日志、抓包、波形和工作库，不随工程提交。

## 软件准备

基本走查只需 Windows 版 eLinx 3.0.7、ModelSim SE-64 2020.4 和 Windows PowerShell 5.1，不需要 PowerShell 7。纯 ModelSim 入口包含下面列出的七个用例，不依赖 Python。
完整 38 项回归、独立报文检查器及命令行综合/网表脚本另需 Python 3.10 或更新版本（验证版本为 3.12.7），以及 `psutil`、`pyasn1==0.4.8`。在实际选用的 Python 环境执行 `python -m pip install psutil pyasn1==0.4.8`。
软件不随工程分发，ModelSim、eLinx 的许可证需自行配置。脚本不主动提权，需要工作目录可写；当前脚本使用 Windows 可执行文件和进程接口，未适配 Linux/macOS。

| 环境变量 | 设置方式；不设置时的查找规则 |
|---|---|
| `AFDX_PYTHON` | 完整 `python.exe` 路径；否则用 PATH 中的 `python` |
| `MODELSIM_HOME` | 含 `vsim.exe`、`vlog.exe`、`vlib.exe` 的目录，如安装中的 `win64`；否则从 PATH 找 `vsim.exe` |
| `ELINX_HOME` | 含 `bin/shell/bin` 的 eLinx 安装根目录；否则从 PATH 找 `eLinx_synthesis.exe` |
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

2. 运行五功能、容量、网络管理、突发排队、时钟同步和吞吐测试。

   ```tcl
   do sim/run_judge.do
   ```

   预期：七个用例都打印 `JUDGE CASE PASS`，最后打印 `JUDGE ENTRY PASS cases=7`；中途失败会打印 `JUDGE ENTRY FAIL`。

   Warning 只计数和提示，Error、Fatal 或测试打印的 FAIL 会判失败。成功和失败都会回到工程根目录，恢复原来的 Transcript 记录设置；可直接重新运行这条命令。

   指标见下面的表，汇总保存在 `out/modelsim/judge_<时间>_<进程>/result.txt`，各用例目录里有原始日志。吞吐测试会运行较久，可从 `performance/simulation.log` 查看已到达的测试阶段。

一次七用例实测如下（ModelSim SE-64 2020.4）；耗时会随电脑和当时负载变化，合计包含编译、生成输入和检查记录。

| 用例 | 实测耗时（秒） |
|---|---:|
| 五功能（`services`） | 2.199 |
| 128 条发送 / 4096 条接收配置（`capacity`） | 2.477 |
| 网络管理报文字段核对（`snmp`） | 5.670 |
| 77 条虚拟链路突发（`burst77`） | 2.420 |
| 81 条虚拟链路突发（`burst81`） | 2.454 |
| 时钟同步（`rtc`） | 51.122 |
| 吞吐、时延和抖动（`performance`） | 457.380 |
| 合计 | 524.347 |

该次运行在 `out/` 下生成约 **0.57 GiB（579.3 MiB）** 的工作库、输入、波形和记录。每次运行使用新目录，并保留以前的结果。

下面是该次运行的七行用例结果和总结果：

```text
JUDGE CASE PASS services checks=1123 errors=0 warnings=0 elapsed_s=2.199
JUDGE CASE PASS capacity checks=49924 errors=0 warnings=0 elapsed_s=2.477
JUDGE CASE PASS snmp checks=699 errors=0 warnings=0 elapsed_s=5.670
JUDGE CASE PASS burst77 checks=643550 errors=0 warnings=0 elapsed_s=2.420
JUDGE CASE PASS burst81 checks=673498 errors=0 warnings=0 elapsed_s=2.454
JUDGE CASE PASS rtc checks=10675857 errors=0 warnings=0 elapsed_s=51.122
JUDGE CASE PASS performance checks=756575324 errors=0 warnings=0 elapsed_s=457.380
JUDGE ENTRY PASS cases=7 warnings=0 elapsed_s=524.347 output_mib=579.3
```

运行结果可与 [评委入口参考输出](sim/reference/judge_result.txt) 和 [完整回归参考汇总](sim/reference/regression.json) 对照。评委入口的七条 `JUDGE CASE PASS`、最终 `JUDGE ENTRY PASS cases=7`、检查项数、错误数以及 `JUDGE METRIC` 的指标应一致；回归汇总的 38 项测试名、参数、PASS 状态和检查项数也应一致。耗时、时间戳、输出目录名和输出文件大小会随机器或运行时间变化，不用逐字比较。参考汇总中的路径相对于仓库根目录，指向那次运行的输出位置，本仓库不附带这些运行目录。

下面两步需要先按“软件准备”安装 Python 依赖，并在 PowerShell 中进入同一工程根目录。

3. 运行全部 38 项测试，参考检查器会另行核对报文和周期记录。

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File sim/regress.ps1
   ```

   预期：末尾表格中的 38 项都为 `PASS`（一次实测约 20 分钟）；汇总位于 `out/regress/`，每项日志位于 `out/sim/`。

4. 综合完整顶层，并检查 8 ns 时钟约束下的估算时序。

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File elinx/synth.ps1 -Top AFDX_top -Sta
   ```

   预期：综合和时序分析成功，`out/latest_AFDX_top.json` 给出资源数、时序裕量和网表目录。

也可用 eLinx 打开 `elinx/AFDX_EndSystem.epr`，点击 Run Synthesis。工程默认器件为 EQ6HL130、封装为 CSG484_H；保持相邻的默认设置文件和 `constraints.edc` 不动。两种综合产生的网表怎样仿真，见“综合后网表仿真”。

| 测量内容 | 从哪里看结果，预期是什么 |
|---|---|
| 77 条虚拟链路的吞吐、最大端到端时延和发送抖动 | do 入口打印 `JUDGE METRIC tb_sys_perf`。链路延迟为 0 或 257 拍时，两个方向分别为 **906.136 Mbps、24.408 µs、0 µs**；两网冗余副本不相加。Python 入口 `sim/run.ps1 -Test tb_sys_perf` 应得到相同结果。 |
| 77/81 条虚拟链路同时提交消息后，队列全部发完的时间 | `JUDGE METRIC burst_vls=... queue_clear_us=...` 分别为 **959.272/1008.488 µs**；81 条的用例特意检查超过 1 ms 的边界。 |
| 时钟同步误差 | `JUDGE METRIC rtc_...` 给出最大误差；空载为 **0 ns**，普通用户流量和 77 条虚拟链路满载时均为 **10788 ns**。 |
| 赛题五功能 | `tb_net_services` 的 `[FUNCTION]` 行检查用户收发、网络管理、时钟同步、加载和卸载，最后须为 `[RESULT] ... PASS ... errors=0`。 |
| 虚拟链路容量 | `capacity` 每端配置 4096 条接收虚拟链路，并逐字节验证索引 0、4095 和中间 126 项。每端全部 128 条发送虚拟链路都发出消息，对端每条只交付一次。 |
| 网络管理（SNMP，Simple Network Management Protocol） | `snmp` 检查 Get、GetNext、Set 的请求号回显、错误码为 0、返回值与配置口寄存器一致；Trap 检查错误码为 0、启动通知类型和运行时间寄存器。 |

吞吐测试先运行两个带宽间隔，再测量 21 ms 内交付的用户字节数。端到端时延从应用提交末字节算到对端交付末字节，只扣除设定的线路延迟。发送抖动表示同一虚拟链路相邻两帧的发送间隔偏离 1 ms 的程度。

`JUDGE REQUIREMENT` 对照赛题门限并打印余量：吞吐至少 100 Mbps、最大端到端时延至多 2000 µs、抖动至多 50 µs。`JUDGE BASELINE` 另行检查是否仍为 906.136 Mbps、24.408 µs、0 µs；门限不达标和基线不一致会分别标出 FAIL。

`tb_gbe_burst` 的突发指标在发送核心的消息输入口和接收核心的消息交付口之间测量。顶层将这两路核心直接接到 GMII，没有另加适配缓存或流水延迟。
队列全部发完的时间从同时提交所有消息时起算，与单条消息的时延不同。以上是仿真测量；综合时序也尚未计入布局布线延迟，不能当作上板或物理时序结果。

## 从 eLinx 界面运行自检

1. 用 eLinx 打开 `elinx/AFDX_EndSystem.epr`，在 Settings → Tool Settings → 3rd Party Simulators 设置 ModelSim 的安装目录。该目录应包含 `modelsim.exe`。
2. 在 Sources → Simulation Sources → `sim_1` 中确认目标仿真文件是 `tb_elinx.v`、仿真顶层是 `tb_elinx`，并且有 `judge_endpoint.v`。这些设置已写入工程，综合顶层仍是 `AFDX_top`。
3. 点击 Flow → Run Behavioral Simulation。ModelSim 会运行两个端系统经双网互发 1、64、1471 字节消息的自检；预期依次看到三条 `[ELINX_MESSAGE] ... both_directions=PASS`，最后是 `[RESULT] tb_elinx PASS checks=9238 errors=0`。测试不需要 Python、输入文件或额外的 include 路径和宏。

此入口已在 eLinx 界面实测通过，仿真时间约 2.56 ms。仿真结束时 ModelSim 会弹出 Finish Vsim 对话框，选“否”可保留窗口查看输出。

## 综合后网表仿真

综合有两种做法：在 eLinx 界面点击 Run Synthesis，或运行命令行入口 `elinx/synth.ps1`。两种做法生成的网表都已通过综合后仿真，步骤分别如下。

### 界面综合生成的网表

1. 在 eLinx 中打开 `elinx/AFDX_EndSystem.epr`，点击 Run Synthesis，完成后应有 `elinx/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm`。下面的命令直接使用这份网表，不会重新综合。
2. 按“软件准备”安装 Python 依赖、设置工具环境变量，在 PowerShell 中进入工程根目录后运行：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_gui_netlist.ps1
   ```

   预期最后打印 `GUI NETLIST PASS tb_elinx mode=gui checks=9238 errors=0`。运行的是与界面自检相同的 `tb_elinx`，只是把 RTL 换成网表。
3. 核对赛题五功能时运行下面这条命令。它先仿真 RTL，再用相同激励仿真界面网表，并逐字节比较七份外部记录；预期两个阶段都打印 `GUI NETLIST PASS tb_net_services ... checks=1123 errors=0`。

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_gui_netlist.ps1 -Test tb_net_services
   ```

实测结果：`tb_elinx` 为 9238 项检查、0 错误，仿真约 130 分钟；五功能为 1123 项检查、0 错误，仿真约 52 分钟，独立检查器的 65 项全部通过，七份外部记录与 RTL 完全一致。耗时随电脑而变，入口的总时限是五小时。每次运行的网表副本、日志和 `summary.json` 放在 `out/gui_netlist/` 下的新目录；出错时打印 `GUI NETLIST FAIL` 或 `GUI NETLIST ENTRY FAIL` 并返回非零退出码。

界面导出的网表省略了取默认值的输入和参数，而 eLinx 自带的单元仿真模型没有给这些输入和参数设默认值，直接仿真时寄存器不会更新。`tools/adapt_gui_vqm.py` 在仿真用的副本上把它们补齐：省略的输入按 eLinx 组件声明和单元模型的默认上拉、下拉取值；原网表接了进位输入的单元补上 `cin_used="true"`，让模型使用这条进位。当前网表共补 427486 个输入连接和 3933 个进位参数。原有连接、参数和查找表内容不变，原网表和厂商仿真模型也不改。

### 命令行综合生成的网表

先综合完整顶层，再用同一个五功能测试分别仿真 RTL 和综合网表；网表仿真的外部记录要与 RTL 逐字节一致才算通过。在 PowerShell 中进入工程根目录后执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File elinx/synth.ps1 -Top AFDX_top -Sta
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_net_services
$net = Join-Path ((Get-Content out/latest_AFDX_top.json -Raw | ConvertFrom-Json).folder) 'netlist.v'
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_net_services -Netlist $net
```

预期：最后一条命令打印 `[RESULT] tb_net_services PASS checks=1123 errors=0` 和 `[CHECK] PASS`。完整顶层的网表仿真一次约一小时。

`sim/tests_netlist.txt` 另列了 8 项模块级网表测试（MAC、RAM、发送核心、接收核心和双端顶层）。先把各项用到的顶层逐个综合，再运行网表回归：

```powershell
foreach($top in 'afdx_timebase','afdx_mac_tx','afdx_mac_rx','probe_p1_2048x8','probe_p2_array','afdx_tx_core','afdx_rx_core','AFDX_top'){
  powershell -NoProfile -ExecutionPolicy Bypass -File elinx/synth.ps1 -Top $top -Sta
}
powershell -NoProfile -ExecutionPolicy Bypass -File sim/regress.ps1 -Netlist
```

网表回归会核对源码的摘要，修改 `rtl/` 后需要重新综合。eLinx 导出的网表在仿真前由 `tools/fix_lut_mask.py` 补全查找表字面量和进位参数，只写仿真用的副本，原网表和厂商仿真模型不改。

## 综合结果

器件 EQ6HL130、封装 CSG484_H，时钟约束 8 ns（125 MHz）。两种综合方式的数字不同，因为图形界面多一个分析综合阶段并按速度优化，命令行入口只调用综合程序。

| 项目 | eLinx 图形界面 Run Synthesis | 命令行 `elinx/synth.ps1` |
|---|---:|---:|
| 查找表（LUT） | 32847 | 29962 |
| 触发器（FF） | 13869 | 13011 |
| 存储器 | 340（Memory） | 783（未装箱的 RAM 切片） |
| 建立时间裕量 | +2.522 ns | +2.749 ns |
| 最高频率估算 | 182.548 MHz | 190.440 MHz |
| 保持时间裕量 | −0.068 ns | −0.068 ns |
| 综合耗时 | 约 17.5 分钟 | 约 1.5 分钟 |

以上时序是综合后的估算，没有计入布局布线延迟。保持时间裕量为负也出现在这一阶段，通常由布局布线修正，本工程没有做布线后的时序确认。

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
| `afdx_snmp.v` | 处理 SNMP v1/v2c 单变量 Get、GetNext、Set 及 v2c Trap。 |
| `afdx_615a.v` | 通过 TFTP 执行 615A 加载和介质定义卸载，管理加载 RAM。 |

数据路径：应用 `app_tx_*` → `afdx_svc` → `afdx_tx_core`（缓冲、调度、组帧）→ `afdx_mac_tx` → GMII 链路 → `afdx_mac_rx` → `afdx_rx_parse` → `afdx_rx_engine` → `afdx_rx_deliver` → `afdx_svc` → 应用 `app_rx_*`。RTC、SNMP、615A 三种服务报文和用户数据共用这条路径，由 `afdx_svc` 按整条消息仲裁。

`AFDX_top` 保留赛题模板的 `clk`、`reset`、`tx_data`、`rx_data`、`tx_valid`、`rx_valid`、`tx_ready`、`rx_ready`，这一组是 A 网 GMII。另外增加了 B 网 GMII（`*_b`）、应用收发口（`app_tx_*`、`app_rx_*`）和配置口（`cfg_*`），用于双网冗余、提交和取回用户消息、写入虚拟链路配置。以太网线路不能暂停，`rx_ready` 不使用。

测试与参考模型的对应：`tb_tx_*`、`tb_rx_*` 对应 `afdx_ref.py`、`tx_ref.py`、`rx_ref.py`；`tb_sys_*` 对应系统、GMII 和各服务的参考模型；`tb_net_services` 对应 `net_services_ref.py`。`tools/eda.py` 负责生成向量、调用仿真和检查器。ModelSim do 入口使用 `sim/vectors/` 中的固定向量和测试平台自检，不调用 Python。

## 实现范围

- 用户收发：UDP/IPv4/Ethernet 组帧，组播目的 IP 为 224.224 加虚拟链路号；每端 128 条发送虚拟链路、4096 条接收虚拟链路；按带宽间隔调度；接收端做序号完整性检查和双网冗余去重。
- SNMP：v1/v2c 的 Get、GetNext、Set 和 v2c Trap，一次一个变量绑定。
- RTC：标准 48 字节 SNTP 报文的双向对时，回应丢失时超时重发。
- 615A：目标端经 TFTP 完成上传（单头文件、单数据文件，写入 8 KiB RAM）和介质定义卸载（`MEMORY.BIN`），支持 A3/A4（默认 A4），请求端口默认 59；信息操作和操作员定义卸载的初始化请求返回状态 1002。

没有实现：615A 的信息操作、操作员定义卸载的后续传输、FIND/WAIT/ABORT 和整文件重试，TFTP 可选项协商，SNMP 的 GetBulk、多变量绑定和 v1 Trap，IP 分片重组。

## 测量条件和限制

- 吞吐、时延、抖动均为 RTL 仿真结果，A、B 两网每个方向单独计算，冗余副本不相加。工况为 1471 字节 UDP 载荷、带宽间隔 1 ms：77 条虚拟链路每方向 906.136 Mbps，81 条 953.208 Mbps，10 条 117.680 Mbps。
- 最大端到端时延 24.408 µs 和发送抖动 0 µs 的条件是各虚拟链路错开提交、没有服务报文插入。77 条虚拟链路同拍提交 1471 字节消息时，最后一条要等前面的排完，相对理想时刻最多晚 935.120 µs；满载时插入 RTC、SNMP、615A 报文，数据帧间隔会比 1 ms 多出最多 312 个时钟周期（约 2.5 µs）。
- 时钟同步误差在两端使用同一个理想时钟的仿真中测得：空载 0 ns，有用户流量时最大 10788 ns。
- MAC 层是本工程自己编写的，没有使用 eLinx 的 MAC IP。
- 综合后网表仿真覆盖界面综合和命令行综合两种网表，都是功能仿真，不含布局布线延迟；吞吐等性能指标没有在网表上重测。布局布线后导出的 `.vo` 网表没有通过仿真，原因是工具导出的 18/36 位 RAM 写数据位序与仿真库不一致；按赛题答疑，综合后仿真即可。
- 时序数字是综合阶段的估算，没有上板，也没有布线后的时序结果。
