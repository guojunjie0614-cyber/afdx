# AFDX 端系统 FPGA 工程

本仓库是中科亿海微赛题的 C3 端系统实现，顶层为 `AFDX_top`，双网 GMII 使用单时钟 125 MHz。当前 `c3-gbe` 为收发核心每周期一个字节的原生千兆版本，RTL 定稿 `2e03d0a7`；`c3`（`b5bf270d`）保留为 117.68 Mbps 的回退版本。可手工开发，不需要 AI 助手。

## 目录

- `rtl/`：端系统、原生字节收发核心、配置总线和服务模块；旧 GMII 速率适配器仅保留独立模块测试。
- `tb/`：自检测试平台；`sim/`：ModelSim do 文件、回归入口及固定向量。
- `tools/`：Python 参考模型、独立检查器和工具运行脚本。
- `elinx/`：图形工程、工程默认设置、8 ns 约束及命令行入口。
- `docs/`：架构、任务和验收记录；`spec/`：赛题、1008 版答疑、ARINC 664P7 与 615A-2002 原文件。
- `out/`：运行生成的日志、抓包、波形和工作库，Git 忽略此目录。

`docs/TASKS.md` 和各 `PROBE` 是 AI 辅助开发的过程记录，手工开发不必遵循其中给 AI 的派发规则；证据路径指向未上传的历史 `out/`，可用对应仿真、回归和综合入口重新生成。

## 软件准备

自行安装 Windows 版 eLinx 3.0.7、ModelSim SE-64 2020.4、Python 3.10 或更新版本。本机验证使用 Python 3.12.7 和 Windows PowerShell 5.1，不需要 PowerShell 7。
五功能 do 文件只需要 ModelSim；脚本入口还需要 Python，全回归依赖 `psutil`、`pyasn1==0.4.8`。在实际选用的 Python 环境执行 `python -m pip install psutil pyasn1==0.4.8`。
软件不随仓库分发，ModelSim、eLinx 的许可证需自行配置。脚本不主动提权，需要工作目录可写；本机未单独验证非管理员会话。当前脚本使用 Windows 可执行文件和进程接口，未适配 Linux/macOS。

| 环境变量 | 设置方式；不设置时的查找规则 |
|---|---|
| `AFDX_PYTHON` | 完整 `python.exe` 路径；否则用 PATH 中的 `python` |
| `MODELSIM_HOME` | 含 `vsim.exe`、`vlog.exe`、`vlib.exe` 的目录，如安装中的 `win64`；否则从 PATH 找 `vsim.exe` |
| `ELINX_HOME` | 含 `bin/shell/bin` 的 eLinx 安装根目录；否则从 PATH 找 `eLinx_synthesis.exe` |
| `AFDX_MEM_FLOOR_GB` | 系统可用内存下限，默认 5 GiB；0 关闭此项保护 |
| `AFDX_MEM_LIMIT_GB` | 本次工具进程树内存上限，默认 10 GiB；0 关闭此项保护 |

内存变量按 GiB（1024³ 字节）计，接受非负数，在启动脚本前设置；8 GB 电脑可按实际情况降低阈值，例如 `$env:AFDX_MEM_FLOOR_GB='1'; $env:AFDX_MEM_LIMIT_GB='4'`。这两项不影响独立 ModelSim do 入口；超时保护仍生效，运行器只处理自己启动的进程树。

## 仿真和综合入口

以下命令均在仓库根目录执行，先按上表设置安装路径或 PATH。在 ModelSim Transcript 窗口也可先 `cd` 到仓库根目录，再执行 `do sim/run_services.do`；结束显示 `MODELSIM ENTRY PASS`，GUI 保留波形。

```powershell
$simExe=if($env:MODELSIM_HOME){Join-Path $env:MODELSIM_HOME 'vsim.exe'}else{(Get-Command vsim.exe -ErrorAction Stop).Source}
New-Item -ItemType Directory -Force out | Out-Null
& $simExe -c -l out/startup.log -do 'do sim/run_services.do'
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run.ps1 -Test tb_ram_sdp
powershell -NoProfile -ExecutionPolicy Bypass -File sim/regress.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File elinx/synth.ps1 -Top AFDX_top -Sta
```

五功能入口覆盖双向用户数据、冗余/完整性检查、SNMP Get、RTC 同步、615A 先加载再卸载，输出在 `out/modelsim/`。全回归是 `sim/tests.txt` 的 32 项，输出在 `out/regress/` 和 `out/sim/`；更多单项、参数和网表命令见 [FLOW](docs/FLOW.md)。
图形综合：在 eLinx 打开 `elinx/AFDX_EndSystem.epr`，点 Run Synthesis。保持 `AFDX_EndSystem_assignment_defaults.qdf` 与工程相邻，使用 Speed 设置和 `constraints.edc`；器件 EQ6HL130、封装 CSG484_H。

## 从哪里读起

先读 [ARCH](docs/ARCH.md) 第 1、2 节理解整体和端口，再沿下面的模块表读代码。

| RTL 文件（均在 `rtl/`） | 职责 | ARCH 节 |
|---|---|---|
| `AFDX_top.v` | 集成双网收发、GMII、配置和三种服务，共用 125 MHz 时钟。 | 1、2、7、8、14、15 |
| `afdx_cfg.v` | 解码配置总线，管理配置读写握手和事件计数器。 | 7 |
| `afdx_timebase.v` | 生成周期时间和冗余判定的粗时间，复位后字节使能每拍有效。 | 4 |
| `afdx_ram_sdp.v` | 提供参数化单时钟、单写口、同步读 RAM。 | 9 |
| `afdx_crc32_d8.v` | 按一个字节组合更新 Ethernet CRC32。 | 3、5.5、6.2 |
| `afdx_tx_core.v` | 连接发送缓冲、调度、组帧、回收和两网 MAC。 | 5.6 |
| `afdx_tx_buf.v` | 接收应用消息、分配页并提交完整消息的队列描述。 | 5.2 |
| `afdx_tx_engine.v` | 轮询 VL，按 BAG 和 LOOKAHEAD 决定消息发送时机。 | 5.3 |
| `afdx_tx_builder.v` | 读取负载，组成 Ethernet、IPv4、UDP 和序号字节流。 | 3、5.4 |
| `afdx_tx_free.v` | 管理空闲页及链表，回收发送或放弃的消息页。 | 5.2 |
| `afdx_mac_tx.v` | 每拍输出一个 GMII 字节，加入前导、SFD、FCS 和 12 拍帧间隔。 | 5.5 |
| `afdx_gmii_tx.v` | 历史发送速率适配器，保留独立模块测试，顶层不再使用。 | 14.1 |
| `afdx_gmii_rx.v` | 历史接收速率适配器，保留独立模块测试，顶层不再使用。 | 14.2 |
| `afdx_mac_rx.v` | 检查前导、长度、FCS，输出去掉 FCS 的帧内容及类别脉冲。 | 6.2 |
| `afdx_rx_core.v` | 连接双网 MAC、解析器、共享接收引擎及应用交付。 | 6.6 |
| `afdx_rx_parse.v` | 检查报文头并暂存负载，坏帧回退，仅提交完好帧描述。 | 6.3 |
| `afdx_rx_engine.v` | 检查映射、配置、序号完整性和冗余，提交可交付消息。 | 6.4 |
| `afdx_rx_deliver.v` | 预取环形缓冲中的负载并连续交付应用口，释放读地址。 | 6.5 |
| `afdx_svc.v` | 按整条消息仲裁应用与服务发送，将收到的服务消息分发给对应模块。 | 8.1 |
| `afdx_rtc.v` | 维护秒和纳秒时钟，以标准 48 字节 SNTP 报文同步。 | 8.2、8.3 |
| `afdx_ntp_fraction.v` | 用移位加减迭代换算纳秒与 NTP 的 32 位二进制小数。 | 8.3 |
| `afdx_snmp.v` | 处理 SNMP v1/v2c 单变量 Get、GetNext、Set 及 v2c Trap。 | 8.4–8.8 |
| `afdx_615a.v` | 通过 TFTP 执行 615A 加载和介质定义卸载，管理加载 RAM。 | 15 |

数据路径：应用 `app_tx_*` → `afdx_svc` → `afdx_tx_core`（缓冲、调度、组帧）→ `afdx_mac_tx` → GMII 链路 → `afdx_mac_rx` → `afdx_rx_parse` → `afdx_rx_engine` → `afdx_rx_deliver` → `afdx_svc` → 应用 `app_rx_*`。对应 ARCH 第 5、6、8.1、14 节；RTC、SNMP、615A 共用此路径，见第 8、15 节。
`tb_tx_*`、`tb_rx_*` 对应 `afdx_ref.py` 及 `tx_ref.py`、`rx_ref.py`；`tb_sys_*` 对应系统、GMII 和各服务参考模型，`tb_net_services` 对应 `net_services_ref.py`，由 `eda.py` 生成向量并调用检查器。ModelSim do 入口使用 `sim/vectors/net_services/` 的固定向量和测试平台自检；验证记录格式见 ARCH 第 10 节。

## 协作约定

- 从 `c3-gbe` 拉自己的开发分支，例如 `git checkout c3-gbe` 后 `git checkout -b feature/your-work`；完成后提交并合并回 `c3-gbe`。`c3` 是 117.68 Mbps 回退版本。
- 合并前运行 `sim/regress.ps1`，32 项全过；改了影响综合的代码，再运行 `elinx/synth.ps1 -Top AFDX_top -Sta`，检查 8 ns setup 裕量（当前门槛 2.0 ns）。
- 本机当前版本脚本整顶层综合工具耗时 113.593 秒，完整五功能综合网表仿真 4243.657 秒。旧 117.68 Mbps 版本的五功能 do 入口 10.281 秒、全回归 729.172 秒、图形界面综合约 23 分钟仅为历史参考；电脑、并行负载和工具许可会改变耗时。
- 不提交 `out/`、eLinx 图形界面生成物及 `.obsidian/` 本机笔记配置；工程 `.qdf` 和约束是源文件，需要保留。
- 图形界面保存会改写 `elinx/AFDX_EndSystem.epr` 的注释和 OutOfDate 状态。只有增删源文件时才提交 epr；其余改动不提交，先确认没有自己的源文件清单变更，再用 `git checkout -- elinx/AFDX_EndSystem.epr` 恢复。
- Verilog-2001；端口、信号小写，参数大写；关键时序和异常处写简短中文注释；脚本通过环境变量或 PATH 找工具，不写死本机路径。
- `.gitattributes` 的 `* -text` 禁止 Git 换行转换；避免编辑器批量重写向量。修改行为时同步 RTL、对应 Python 参考模型和测试；新增测试同步 `sim/tests.txt`，增删 RTL 同步 epr；改变五功能用例时同步 do 入口的固定向量。
- RTL 仿真通过与综合网表仿真通过分别记录；当前时序数字是综合后估算，不含布线延时。

## 当前状态和待办

已实现用户发送、用户接收、SNMP 网络管理、615A 加卸载、RTC 同步；收发含双网冗余、VL/BAG 调度、序号和完整性检查，组播目的 IP 为 224.224 加 VLID。
SNMP 支持 v1/v2c Get、GetNext、Set 与 v2c Trap，一次一个变量绑定；RTC 使用标准 SNTP。615A 目标端支持 A3/A4（默认 A4）、单头文件/单数据文件上传至 8 KiB RAM、介质定义卸载 `MEMORY.BIN`，TFTP 请求端口默认 59；LCI/LNO 初始化请求返回状态 1002。
验收数字见 [PROBE_T16](docs/PROBE_T16.md) 和 [PROBE_T17](docs/PROBE_T17.md)：RTL 原有 32 项及新增两项集中释放测试全部通过（34/34），RESULT 合计 1185754960、CHECK 合计 2305789；默认综合网表清单 8/8，整顶层五功能网表 1123 检查、65 项独立核对，六份外部记录与本卡重新生成的同激励 RTL 完全一致，含 615A 加载后卸载。独立 ModelSim do 入口本卡未重跑。
定稿 RTL 重新综合 29917 逻辑单元、783 未装箱 RAM 切片，8 ns setup 裕量 +2.749 ns、hold -0.068 ns；器件 EQ6HL130/CSG484_H。RAM 切片为映射统计，不当作装箱后物理块数；图形界面综合未对本版本重跑。
技术指标为 T16 RTL 实测，A/B 双网每方向、每网单算，冗余份不叠加：1471 字节 UDP 载荷、BAG=125000 周期（1 ms），77 条 VL 双向每方向 906.136 Mbps，81 条 VL 953.208 Mbps，10 条 VL 117.680 Mbps；0/257 周期链路延迟两组均通过，发送口与去重交付口一致，零丢失、零乱序、零异常脉冲。
T16 固定错开提交且没有服务报文争用的稳定窗口最大端到端时延 24.408 µs（应用末字节至交付末字节，只扣固定链路延迟），最大发送时延 0.248 µs；满载发送抖动 0 µs。轻载 1/17/18/1471/511 字节同长度组的发送及端到端抖动均为 0 µs，最大发送时延 0.296 µs、端到端 24.400 µs。77 条 VL 满载叠加 RTC 的最大对时误差 10788 ns（10.788 µs），为空载及用户流量下的共同理想时钟仿真结果。
上述时延使用错开提交、两 BAG 暖机和固定 21 ms 测量窗，换工况前排空并静默一 BAG；无静默换负载额外探针为 323.112 µs，含上一工况的 BAG 等待与排队，T14 同样保留 BAG 等待。预装 77/81 条队列同时释放的清空时间分别为 959.272/1008.488 µs，不混入固定工况的单消息指标。
时序为综合后未布局估算，不含布线延时；当前综合报告 Fmax 为 190.440 MHz，hold 裕量仍为负，不代表物理时序已签核。网表功能验证通过不替代吞吐性能网表或上板测量。
尚未做：性能网表、布局布线及布线后时序签核、本版本图形界面综合；设计文档、测试报告、提交包按用户要求保留。当前定稿代码的五功能及清单内综合网表仿真已在 T17 完成。
T17 争用补测（RTL）：8/77 条 VL 首轮同拍释放，1471/17 字节各测24轮，共同理想时刻的最大偏差分别为 8/1471字节：86.144µs、8/17字节：4.752µs、77/1471字节：935.120µs、77/17字节：52.432µs，包含同一 GMII 的串行排队；定时器随后按实际起点加 BAG 推进。77 条长帧满载插入 RTC/SNMP/615A 报文时，数据帧间隔（125000 拍=1ms）分别为 ES1 [125000,125258]拍、ES2 [125000,125312]拍；逐VL结果见 PROBE_T17，原零抖动结论仅限原固定工况。
未实现的扩展：615A 信息操作和操作员定义卸载的后续传输、FIND/WAIT/ABORT/整文件重试、TFTP 可选项协商，SNMP GetBulk/多变量/v1 Trap，IP 分片重组等；具体范围见 ARCH。
可优化方向取自 [TASKS 的“完成后再考虑”](docs/TASKS.md#完成后再考虑)：布线后时序、短帧利用率与突发接收、RTC 异步时钟及非对称链路精度、SNMP/615A/664 扩展及指标测量覆盖；现在不自动启动这些工作。
