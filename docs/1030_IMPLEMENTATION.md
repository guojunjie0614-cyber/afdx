# 1030 答疑实现记录

本记录对应分片交付版。依据为 [1030 答疑表](sources/FPGA创新大赛问题汇总1030.xlsx) Sheet1 R138、R139。

## 实现边界

- 应用消息格式保持两个大端 VLID 字节加应用数据，连续 valid 区间表示一条消息。
- 单消息应用载荷上限为 8192 字节，应用收发缓存分别为 32 KiB。8192 是项目选择；FAQ 只明确要求分片，没有规定最大消息长度。
- 每个发送数据报共用一个 IPv4 Identification。UDP 头仅出现在首片；MF 和片偏移按 IPv4 编码，每片独立遵守 VL BAG 并取得自己的 AFDX SN；同帧 A/B 副本保持一致。
- 正常 Lmax=1471 时，非末片 IPv4 数据长度为 1472 字节，首片应用数据为 1464 字节。片偏移包括 UDP 头，以 8 字节为单位。
- Lmax 继续限制单帧。长度不超过 1471 的旧消息仍需满足配置 Lmax；较长消息的片预算为 `min(Lmax+8,1479)`，非末片向下取 8 的倍数。
- 接收端先完成逐帧 FCS/IP 检查和 IC/RM，再进入重组。重组资源在 RM 接纳前预留，数据从每网环形缓存复制到重组 RAM，避免未完成长消息占住接收环。
- 默认 16 个重组上下文，总应用数据 RAM 为 128 KiB；键包含 VL 索引、源/目的 IPv4、Identification，协议限定 UDP。默认超时 250000000 拍，开放上下文无待复制片时计龄，成功预留时重新计龄。
- 当前支持顺序片偏移。缺首片、乱序、重叠、长度矛盾和资源不足均拒收；保留原有 IC/RM 序号规则。完整数据报通过 UDP 长度及非零校验和检查后，才输出应用消息。
- 重组准入、超时及完整 UDP 校验失败复用对应网络事件位 7（0x80），目前没有细分原因的外部计数器。

## 时序修改

RTC 接收由整包 384 位移位改为按字节位置采集所需字段，并寄存 Originate 的逐字节比较结果。配置模块为用户 ID 写入提供本地就绪副本，并预先寄存接收配置地址可用条件。SNMP 内部毫秒分频计数器缩到 21 位，公开 uptime 保持 32 位。

主时钟仍为 125 MHz、周期 8 ns，setup uncertainty 仍为 0.30 ns，默认 CE_DIV=2。保留 172 个引脚及全部 253 组合法多周期约束（仅移除已不存在的空 `deny_wd` 组），并在新导出 VQM 上审查实际 CE 行为；没有新增 false path 或放宽多周期范围。综合/装箱阶段不加固定簇约束，布局布线阶段默认加载针对冻结新网表验证收敛的 `elinx/tiles_1030.edc`（11,044 个簇位置：10,230 CLB + 814 M4K；修改 RTL 时须传 `--no-tiles` 重新自由布局并更新锁文件）。

第二轮 TX 控制重构将 128 个分片上下文拆成三张单写口、同步读表：142 位不变元信息、27 位剩余长度/片偏移，以及页号/页内偏移。GRANT phase 0 读取工作快照，phase 5 选择长度和预算，phase 6 计算片长，phase 7 寄存完整授权元信息和下一进度，phase 8 提交。builder 完成后独立写回页指针；busy 位阻止未完成 VL 再次获得授权。有效位和忙位复位，RAM 内容通过有效状态隔离，不整体复位。

第二轮 RX 重组使用四个 bank、每 bank 四个槽位，分拍查询、选择、读取和准入。查询后 8 拍产生寄存结果，接收引擎 phase 4 查询、phase 14 原子提交队列/RM/预留、phase 16 取消并结束。选中上下文在决策期间受保护；超时仍计龄，达到阈值后饱和并延迟回收，查询 32 拍 watchdog 保证锁可释放。复制过程只更新本地写位置和校验和，片段边界写回上下文；超时事件先寄存到各上下文再汇总。

通用 RAM、应用 RAM、TX 上下文 RAM 及重组数据 RAM 均加入写使能控制的数据隔离，读延迟和有效写入内容保持不变。相同 EQ6HL130/eLinx3.0.7 的 128×8 小规模映射实验中，直接写数据的综合 hold 为 −0.068 ns；隔离后为 +0.282 ns、失败端点为零，LUT 从 23 到 31，FF 23、RAM 1 不变。该结果是实施依据；整机结果见下文“最终 RTL 收敛”一节。

验收分别记录综合 setup、综合 hold 和布线 setup/hold。`build_1030.py` 在综合存在非正 slack 或失败端点时返回非零，不再把“工具运行完成”当作时序通过。综合 setup 或 hold 未通过时跳过昂贵布线。

## 集中验证入口

在仓库根目录执行：

```powershell
# 公共应用口、双 GMII、独立 IPv4/UDP 参考模型
./sim/run_fragmentation.ps1

# 发送兼容性、BAG、多 VL、配置握手及 RTC 行为
./.venv/Scripts/python.exe tools/run_1030_checks.py

# 官方 eLinx 分析、导出、CE 审查、装箱、时序和布线（默认加载 elinx/tiles_1030.edc；若修改 RTL 请加 --no-tiles）
$env:ELINX_HOME='C:\Program Files (x86)\eHiWay\eLinx3.0'
./.venv/Scripts/python.exe tools/build_1030.py --route

# 复用已完成综合目录的快速布线与 CLB 簇位置优化入口
./.venv/Scripts/python.exe tools/route_1030_frozen.py --source <build1030目录> --tag verify --physical elinx/tiles_1030.edc
./.venv/Scripts/python.exe tools/optimize_1030_clusters.py --run <route目录> --vqm <VQM路径> --out elinx/tiles_1030.edc
```

分片场景含 1464、1471、1472、8192 字节，以及超长回滚、小 Lmax 拒收、A/B 互补丢片、重复副本、坏 FCS、重叠、坏 UDP 校验和、缺片与随后恢复。测试同时记录 GMII 帧、应用消息、事件和周期；Python 独立核对帧长度、校验和、片偏移、MF、SN、BAG、A/B 一致性及逐字节应用交付。

`tools/gen_app_vectors.py --long --out <目录>` 可以生成带长消息的应用激励；`sim/run_app.do` 检测到长消息后切换到分片测试平台。该 ModelSim 入口需要本机具备 ModelSim，Icarus 运行不能替代综合后仿真。

## 最终 RTL 收敛与 125 MHz 综合/布线全闭合（2026-11-03）

- **最终 RTL 收敛批次（18 个可综合文件冻结）**：针对物理实现中跨 bank/跨域等效寄存器自动合并拉扯与局部高扇出组合链，在不改变外部接口、缓存容量、流水拍次及协议语义的前提下完成最后一批局部隔离（涉及 `AFDX_top.v`、`afdx_es.v`、`afdx_svc.v`、`afdx_timebase.v`、`afdx_app_tx.v`、`afdx_snmp.v`、`afdx_rtc.v`、`afdx_615a.v`、`afdx_cfg.v`、`afdx_tx_engine.v`、`afdx_tx_builder.v`、`afdx_tx_buf.v`、`afdx_mac_tx.v`、`afdx_rx_deliver.v`、`afdx_rx_reassembly_bank.v`、`afdx_rx_reassembly.v`、`afdx_rx_engine.v`、`afdx_rx_core.v`）：
  1. `afdx_svc.v` 将服务接收分支拆为独立的 SNMP、615A loader 与应用三组 `preserve / dont_merge` 本地捕获寄存器，消除服务接收总线在芯片两侧的共享扇出。
  2. 为各分布式 bank/副本状态寄存器（如 `afdx_es.v` 双网 `tx_init/rx_init` 副本、`afdx_timebase.v` 本地时基、`afdx_tx_engine.v` 16 组 busy/completion 本地寄存器、`afdx_rx_reassembly_bank.v` 两 bank 查询/行控制寄存器、`afdx_app_tx.v` 描述符查询副本、`afdx_cfg.v` / `afdx_snmp.v` / `afdx_rtc.v` / `afdx_615a.v` 本地就绪与地址译码副本）补齐 `(* preserve, dont_merge *)`，防止 `quartus_map` 将物理远距副本重新合并为单一全局寄存器。
  3. 隔离 `afdx_tx_buf.v` / `afdx_tx_builder.v` / `afdx_mac_tx.v` 与 `afdx_rx_deliver.v` / `afdx_rx_engine.v` / `afdx_rx_core.v` 的局部控制路径，综合关键路径深度显著下降。
- **官方综合、导出与门禁结果（`out/build1030/AFDX_top_1030/20261103_103410_728861/`）**：
  - `quartus_map`（0 error）、`quartus_cdb --vqm`（0 error）、`rx_storage_audit`（`passed = true`：两 bank 四类元数据 RAM、16 slot / 64 lane、128 写隔离 LUT、256 隔离 RAM 数据输入、0 直连）及 `check_multicycle`（`passed = true`：2,747 个受约束寄存器有效、0 无效、0 遗漏内部弧）全部通过。
  - **资源统计**：`62,274` LUTs、`35,597` FFs、`10,230` CLBs、`814` Memorys、`172` Pins、`0` DSP、`0` PLL（共 `11,044` 个物理簇：`10,230` CLB + `814` M4K）。
  - **综合后 STA（`clk` 125 MHz / 8.000 ns，含 0.30 ns setup uncertainty）**：
    - `setup_worst_slack = +4.148 ns`，失败端点 `0 / 164,745`；
    - `hold_worst_slack = +0.192 ns`，失败端点 `0 / 164,745`。
- **官方布局布线与物理簇优化收敛（`out/build1030_route/AFDX_top_1030_opt5_p130/20261103_123844_269789/`）**：
  - 复用 `20261103_103410_728861` 冻结 `synth_1` 装箱检查点，通过 `tools/optimize_1030_clusters.py` 在保持全部 `814` 个 M4K、172 个引脚与全部垂直进位链（`cout -> cin` 固定 `(0, -1)` 偏移）严格合法的前提下消除远距绕行 CLB 簇，生成 `11,044` 条固定簇位置约束并保存至 `elinx/tiles_1030.edc`。
  - 调用未修改的原厂 `run_route.tcl`（`PRES 1.30`，耗时 `169.88 s`，退出码 `0`），`AFDX_EndSystem.edi` 中 `0 ERROR / 0 CRIT / 0 WARN / 0 Udmin`，`AFDX_EndSystem.place` 与 `elinx/tiles_1030.edc` 的 `11,044` 个簇位置逐一核对 **0 偏差**。
  - **布线后官方 STA（`clk` 125 MHz / 8.000 ns，含 0.30 ns setup uncertainty，253 组合法 CE 多周期）**：
    - **Routed Setup**：`+0.029 ns`（`+29 ps`），失败端点 **`0 / 96,142`**（`TNS = 0.000 ns`；最紧路径 `es|tx_core|engine|candidate -> es|cfg_regs|receive_bus[7].transmit_ack_q`，3 级逻辑，`logic = 1.423 ns`，`net = 6.173 ns`）；
    - **Routed Hold**：`+0.604 ns`（`+604 ps`），失败端点 **`0 / 96,142`**。
  - **全芯片 `96,142` 端点完整时序与多周期独立复核（`.../20261103_123844_269789/full_timing/audit/timing.json`）**：
    - 导出全端点 `full_timing.tan.pb` 并执行 `check_multicycle.timing()` 复核：`passed = true`，覆盖全部 `96,142` 个芯片终点（`failed_endpoints = 0`，`invalid_requirements = 0`）：
      - 单周期 8.000 ns 路径（含 0.30 ns uncertainty）：`269,131` 条，最差 `+0.029 ns`，失败 `0`；
      - 已证明 CE 多周期 16.000 ns 路径：`50,050` 条，最差 `+0.720 ns`，失败 `0`；
      - Hold 路径：`319,181` 条，最差 `+0.604 ns`，失败 `0`。
- **最终冻结 RTL 的定向功能回归与验证边界**：
  - 顶层严格编译 `iverilog -g2001 -grelative-include -DAFDX_CE_DIV=2 -s AFDX_top elinx/afdx_all.v` 零错误、零警告。
  - 在最终冻结 RTL 上复跑全部关键模块与跨模块流水线回归均 PASS：
    - `out/checks1030/20261103_100549/`：`tb_cfg_local_ready`（`6,090` 项，与 `c857aba` 基线逐拍一致）、`tb_reassembly_engine`（`39` 项）、`tb_reassembly_transactions`（`126` 项）、`tb_rtc_banked`（`34` 项）；
    - `out/checks1030/20261103_130040/`：`tb_service_pipeline`（`127` 项，覆盖三分支独立捕获后服务/应用/仲裁握手）、`tb_context_pipeline`（`134` 项）、`tb_reassembly_limits`（`71` 项）；
    - `out/checks1030/20261103_130059/`：`tb_rtc_originate`（`34` 项）、`tb_rtc_recovery`（`28` 项）、`tb_app_payload_pipeline`（`726,856` 项）；
    - `out/checks1030/20261103_130336/`：`tb_tx_ingress_elastic`（`139,695` 项）、`tb_tx_buffer_bounds`（`49,800` 项）；
    - 顶层 `AFDX_top` 双网端到端实测确认复位初始化完成（`tx_init=1, rx_init=1, es_rdy=1, cfg_rdy=1, app_rdy=1` @ 65,550 拍）、7 条发送消息完整受理，以及 `1464`、`1471`、`1472`（双片重组）与 `17` 字节逐字节交付和 `8192` 字节分片精确 `125,000` 拍（`1000 µs` BAG）发帧间距；`sim/run_fragmentation.ps1` 默认超时已上调至 `5400` 秒以容纳双 `AFDX_top` Icarus 全长约 85 万拍运行。
  - **边界说明**：`elinx/tiles_1030.edc` 与当前冻结 RTL 网表一一对应；后续若修改任何可综合 RTL，须使用 `tools/build_1030.py --route --no-tiles` 重新布局并用 `tools/optimize_1030_clusters.py` 更新锁文件。旧测试套件中将 `>1471` 字节一概判为 `drop_long` 的历史规则（`tools/tx_ref.py`）属于分片前口径，分片规则以 `tb_fragmentation` / `tb_tx_buffer_bounds` / `tb_context_pipeline` 为准。

## 最新答疑的测量解释

R139-1 给出抖动≈最大时延−最小时延−BAG 配置值；R139-2 说明系统满负载下不出现三位数（µs）以上的抖动即可。本设计在 63 VL 满负载七场景上按此验证：周期场景取同 VL、同载荷的最大−最小，BAG 等待场景取最大−首帧−BAG。B2 最大 96.752 µs，全部分组 <100 µs；B1 为固定输入顺序，存在公式前提不成立的组，不作抖动判据。完整性、逐组公式前提及结果见 [63 VL 满负载验证](evidence/vl63_full_load/summary.md)。长消息整条完成时延单列，不套用单帧抖动判据。

当前交付已有以下记录，覆盖范围分别列示：

- 性能负载：[63 VL 七场景](evidence/vl63_full_load/summary.md)及 [63 VL 长短消息混合](evidence/frag_load/summary.md)，包含逐字节交付与独立统计；[分片版评委入口结果](../sim/reference/judge_result_frag1030.txt)保留定长、变长性能检查。
- 三份报告：[技术文档报告](report/AFDX端系统FPGA技术文档报告.pdf)、[设计文档](design/AFDX端系统FPGA设计文档.pdf)、[测试报告](test/AFDX端系统FPGA测试报告.pdf)已在仓库发布。
- 综合后功能验证：官方 VQM 零延迟网表仿真，[完整窗口与分片前缀](evidence/frag1030_delivery/vqm_official.json)、[TX/RX 配对窗口](evidence/frag1030_delivery/vqm_windows.json)分别记录检查结果和 RTL 对照；8192 字节分片和故障恢复在 RTL 上验证，分片网表对照覆盖前 199,578 拍（含 1472 字节两帧重组）。
- eLinx 界面仿真：Run Behavioral Simulation PASS checks=9238 errors=0，见 [截图与说明](evidence/vl63_full_load/summary.md#elinx-界面仿真验证)及 [原始截图](evidence/vl63_full_load/elinx_gui_behav_pass.png)。
- 时序：[布线后 STA](evidence/frag1030_delivery/timing.json)覆盖全部内部路径，setup/hold 均 0 失败；外部 I/O 时序随板级约束指定，见 [验证方式与使用条件](FACTS.md#七功能范围与使用条件)。
