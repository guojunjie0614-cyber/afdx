# 1030 答疑实现记录

本记录对应 `feature/fragmentation-timing-1030` 开发分支。依据为 [1030 答疑表](sources/FPGA创新大赛问题汇总1030.xlsx) Sheet1 R138、R139。F1/T65 的历史 PASS、覆盖率、吞吐和时序数字不能用于本次修改后的 RTL 验收。

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

通用 RAM、应用 RAM、TX 上下文 RAM 及重组数据 RAM 均加入写使能控制的数据隔离，读延迟和有效写入内容保持不变。相同 EQ6HL130/eLinx3.0.7 的 128×8 小规模映射实验中，直接写数据的综合 hold 为 −0.068 ns；隔离后为 +0.282 ns、失败端点为零，LUT 从 23 到 31，FF 23、RAM 1 不变。该结果是实施依据，整机仍需重新验证。实验位于 `.scratch/timing-architecture/hold/{direct,gated}/`。

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

## 当前证据

- 第二轮 TX 重构后的发送基础、BAG、多 VL 检查及原独立报文检查器通过：`out/checks1030/20261102_215622/summary.json`。新增 `tb_context_pipeline` 通过 134 项检查，覆盖 8192 字节六片、1472 字节三片、同 VL 后续短消息、动态配置变化、共享 ID、SN、实际发帧 BAG 及页偏移：`out/checks1030/20261102_220322/summary.json`。
- `tb_cfg_local_ready` 在主仓库的固定基线入口通过 6090 拍逐周期比较（`out/checks1030/20261102_221518/`），覆盖各配置 bank 独立应答、读有效延迟、host/MIB 优先级和活动请求期间复位。基线固定为原始提交 c857aba8361e7f9cea74801d4a4d908f49a76436，运行时仅重命名原模块。
- RTC Originate/恢复检查通过于 `out/checks1030/20261102_205544/summary.json`；BANKED_RX 模式另通过 34 项检查，位于 `out/checks1030/20261102_211820/`。这些是相应模块证据，不能替代新整机验证。
- 首轮新 RTL 的官方综合、导出和装箱完成：53082 LUT、26041 FF、7051 CLB、546 存储块；新网表 CE 审查通过，2755 个受约束寄存器、无无效寄存器、无遗漏内部连接。
- 首轮综合 setup 为 −1.504 ns、hold 为 −0.068 ns。最差路径为 `rx_core.engine.op_idx[0] → reassembly.reject_events[0]`，35 级逻辑、9.129 ns；该轮布线已停止。原始记录位于 `out/build1030/AFDX_top_1030/20261102_205823_962564/`。
- 第二轮架构重构的首次整机综合（`out/build1030/AFDX_top_1030/20261102_222637_362860/`）setup 为 +2.771 ns、失败端点 0；hold 仍为 −0.068 ns，但失败端点从 1495 降到 24，全部来自重组校验字段表和 TX 回滚页表。资源为 55630 LUT、27257 FF、7072 CLB、544 存储块。为补齐这两张小 RAM 的隔离，主动停止该次布线；此运行不是最终全正结果。
- 补齐两张小 RAM 后，整机 Verilog-2001 编译通过；定向发送基础/独立报文检查器及重组事务测试通过于 `out/checks1030/20261102_223625/`。
- 第二轮合并 RAM 隔离后的集中检查通过，位于 `out/checks1030/20261102_222525/`：TX 上下文 134 项、重组容量/超时 71 项、查询取消/并发事务/校验和/8192 字节交付 35 项、接收引擎与重组联调 30 项。联调测得 take→resolve 最长 17 个实际时钟，双网同时请求的 take 间隔为 18 拍（CE_DIV=2）；这证明控制服务预算，不代表双网全部负载吞吐已验收。
- RX 重构后的原 `tb_rx_basic` 通过 9956451 项检查和独立参考检查器 123855 项检查，位于 `out/checks1030/20261102_221417/tb_rx_basic/`；该次运行早于随后加入的 RAM 写数据隔离。
- 第二轮端到端分片验证通过于 `out/fragmentation/20261102_222558/`：HDL `errors=0`、完整应用交付 11 次，独立 Python 检查器 PASS。覆盖正常 1464/1471/1472/8192 字节、8193 字节回滚、小 Lmax 拒收，以及双网互补、重复副本、坏 FCS、重叠、坏 UDP 校验和、缺片和格式错误后的恢复。5 条正常 TX 消息形成 11 个物理帧；另外 6 次交付来自故障注入后的合法恢复消息。
- 上述端到端仿真在最后两张小 RAM 补齐写数据隔离前编译；两处后续改动在原写使能为真时仍写原值，接口与状态时序不变，最终 RTL 的相关 TX/重组定向回归已另行通过。未为这两处组合隔离重复运行整套长仿真。
- 首轮端到端及整机配置仿真的 600 秒超时记录保留为历史失败，不能当作 PASS。整机 RTC 测试的旧端口初始化语法与 Icarus 不兼容，已改为等价模块内初始化；整机配置/RTC 完整回归仍未重新完成。
- 补齐 RAM 隔离后的官方综合（`out/build1030/AFDX_top_1030/20261102_223625_073169/`）内部时钟 setup 为 **+2.771 ns**、hold 为 **+0.192 ns**，两类失败端点均为 **0 / 109953**；新网表 CE 审查通过。资源为 **55654 LUT、27257 FF、7079 CLB、544 存储块、0 DSP、0 PLL、172 引脚**。125 MHz 和 0.30 ns setup uncertainty 保持不变。
- 同一运行的布局布线于 2026-11-02 22:52 完成，工具退出码为 0，但内部 setup 为 **−5.443 ns**、失败端点 **7987 / 73456**；hold 为 **+0.604 ns**、失败端点 **0 / 73456**。构建入口因此返回 2，`summary.json` 中 `route_completed=true`、`timing_closed=false`，不是工具崩溃。综合全正结论仍成立，但不能据此声称 125 MHz 布线时序通过。当前也没有本次 RTL 的综合后仿真证据。

### 布线失败定位

本轮实测最差路径为 `rx_core.reassembly.complete[15] → output_vl[0]`：10 级逻辑，总延迟 13.068 ns，其中逻辑 3.393 ns、连线 9.675 ns，路径最大扇出 219。对应 RTL 为 `rtl/afdx_rx_reassembly.v` 中完成槽优先选择与同拍读取输出元数据的组合链。连线占该路径数据延迟约 74%；综合报告的 net delay 为 0，不能用综合余量推算实际布线余量。

已从原始布线数据库生成 `out/build1030/AFDX_top_1030/20261102_223625_073169/routed_path_families.json`，保留按完整键关联的节点详情。当前保存的 setup 样本为 100 条路径、44 个不同端点，涉及以下路径；这些样本不能代表全部 7987 个失败端点的分布：

| 样本路径族 | 最差 slack / ns |
| --- | ---: |
| complete → output_vl | −5.443 |
| complete → output_sport | −5.126 |
| reserve_slot → expected | −5.063 |
| expected → expected | −4.992 |
| complete → output_total | −4.926 |
| RX engine.phase → reassembly.dst 写使能 | −4.862 |
| scan → row_src | −4.860 |
| pending → context_event | −4.847 |

这些路径促成第三轮同时重构 RX 存储、局部控制和完成输出流水，并调整应用 RAM 与 TX busy 查询。上述数字保留为第二轮失败基线。

### 第三轮架构与在跑证据

- RX 改为两个 bank、每 bank 八个上下文，四类单读单写同步表分别为 key 8×92、header 8×92、admission 8×28、progress 8×46。RTL 指定 M4K；是否实际保留 RAM 由本轮导出的 VQM 检查，物理存储块数仍以 native utilization 为准。
- allocation 不写 progress，仅清 copy_initialized；首次复制从 header 取得初始校验和，后续从退休的 progress 读取。只有片段复制退休写 progress，从结构上保留单写口。准入使用含 UDP 头的 IPv4 端点，17 位范围校验通过后才截到 14 位。
- engine phase 4 捕获映射返回，phase 5 查询；查询结果延迟 16 个实际时钟，phase 23 逻辑接纳队列/RM/预留，phase 24 物理写 bank 和 DQ，phase 25 结束。已接纳的本地写命令不受随后 cancel 撤销。FRAME 每拍推进，未增加多周期例外。
- deliver 先送元数据并等 prepared，再启动不可暂停的环形缓存字节流水。完成槽选择、同步 header 读取和 payload 预取分拍；输出内部持续每拍一字节。复制和完整消息输出仍串行，不能把控制预算等同于满载吞吐验收。
- 应用收发各采用 4×8192×9 bank，写命令 E0 接受、E1 物理写入；提交指针/描述符可见性与退休对齐。读路径为 RAM、bank result、注册 bank mux 三拍，reader 的在途信用随 READ_LATENCY=3 对齐。payload 与预取队列 RAM 都保留写数据隔离。
- TX busy 读取拆为四组 32 选 1 的本地寄存，再进行四 bank 选择；ENQ 使用 phase 1/2 的快照，phase 4 提交，扫描复用原阶段。当前该版 `tb_context_pipeline` 通过 134 项检查，位于 `.scratch/timing-architecture/tx_banked_busy.vvp` 的本轮运行输出。
- 应用 owner 的定向 TB 通过 135295 项检查，覆盖跨 bank/环回、反压、持续传输、长短连续消息及 8193 字节回滚。此结果早于主线程为 reader.bytes 补等有效写入的数据隔离，不扩大为最终整机通过。
- RX 本轮 Verilog-2001 顶层编译及三个定向检查首次通过：limits 71 项、transactions 46 项、engine 30 项。实测 take→resolve 最大 26 拍，CE_DIV=2 时双网 take 间隔 28 拍。日志位于 `.scratch/timing-architecture/tb_reassembly_*-simulation.log`，覆盖同步准备链、已接纳写命令退休及完整/legacy 输出仲裁。owner 在编译后仅更正 engine 相位注释，未再改功能代码。
- 本轮正式运行目录为 `out/build1030/AFDX_top_1030/20261103_001755_858051/`，使用目录内固定源码快照。综合 setup **+3.311 ns**、hold **+0.192 ns**，两类失败端点均 **0 / 125242**；CE 及两 bank 的四类 RAM 审查通过。资源为 **50613 LUT、24899 FF、6632 CLB、829 存储块、0 DSP、0 PLL、172 引脚**。比第二轮 LUT/FF/CLB 减少，存储块增加 285，不能把全部面积指标称为改善。
- 只读映射审查确认八个 app payload bank 各保留 write_q 1 位、address_q 13 位、data_q 9 位、result_q 9 位的真正 regout；两套 payload 顶层各保留两级 bank 选择和 9 位注册返回。native cluster 归属显示 app TX/RX payload 各为 4×18=72 个 memory cluster，与原各 72 相同，拆 bank 没有增加这部分报告计数。829 与 544 的增量主要来自 RX payload 显式 M4K 映射，不能笼统归因元数据移入 RAM。旧 auto 深 RAM 的 cluster 描述 64K×8 地址范围，却统一标为 wb_m4kblk_hc/M4K；新显式 M4K 的 cluster 描述 4096×1。该证据证明统一 Memorys 标签下的映射形状不同，不能将 285 个计数增量解释为新增 285 个等容量 4Kbit 物理块，也不能据此计算等容量利用率。旧 131072×8 与新 2×65536×8 均为 1,048,576 bit，逻辑容量保持 128 KiB。旧深 RAM 的后续物理容量合法性尚未由此次只读审查证明；不据标签猜测 M-RAM 或容量缺陷。
- 第三轮布局布线于 2026-11-03 00:32:57 完成，setup **−3.798 ns**、失败端点 **4643 / 77394**；hold **+0.604 ns**、失败端点 **0 / 77394**。工具正常完成，构建按时序失败返回 2。相比第二轮 setup −5.443 ns、7987 个失败端点改善，但仍未收敛。
- 最差路径转为 bank0 `output_position[1] → payload.port_b_address_dff[6]`，总延迟 11.794 ns，逻辑 2.378 ns、连线 9.416 ns、最大扇出 129。原始实际报告仍只保存 100 条 setup 路径、37 个端点，不能推断全部 4643 个失败端点分布；复制 `.tr.cfg.pb` 本身没有让实际 report 启用 10000 路径。
- 为本轮作一次隔离官方报告回放，位于 `.scratch/timing-architecture/routed-third-expanded/`。扩展得到 10000 条 setup 路径、1212 个不同失败端点；其 TNS 比原始值差 24 ps，故不严格可比，不替代上述正式时序数字。辅助样本另指向 query 捕获、copy last→checksum、retire→pending、age 使能、parser 长度阶段和 cfg_ready_m 到服务寄存器。
- 下一整批针对上述实测路径：RX payload 拆成每上下文 8192×8 存储及本地读写命令；RX owner 同时处理捕获/退休/计龄控制。主线程为 SNMP/loader/RTC 的 21 个写字段加入同拍 ready 副本，保持握手和写入拍次，固定基线逐周期比较 6090 项通过于 `out/checks1030/20261103_004659/`。parser 改用局部片标志和预译码字段脉冲，长度算术与最终限值选择分拍。
- 构建脚本改为项目本地原厂 route procedure 副本，在原始 report 前调用 `do_timing_analysis` 并记录数据库中实际采样数量；不改安装目录。该同进程组合待下一轮实测，不能仅凭配置文件声称扩展成功。
- 上述补充批次已完成：每bank八个8192×8 payload slot使用本地命令与返回寄存器；incoming byte E0本地捕获、E1校验累加与slot写命令、E2物理写及末字节progress退休。query在外部E0完整采样、E1分组捕获，结果延迟17拍，engine phase22取得结果、phase23接纳、24物理写、25结束，32拍watchdog不变。row独热commit/retire/check命令及age_due/默认14+14位计数使控制局部化。
- 新定向证据为 `.scratch/timing-architecture/rx-local-*`：limits71、transactions47、engine30项通过。交叉接口修复后，legacy在header接受时发布metadata，重组在payload读取期间提前发布，分别领先首valid6/5拍；现有engine首valid检查前三拍ports历史，重跑32项通过，service26、paired28拍，顶层Verilog-2001编译通过于 `rx-ports-*`。未增加报文场景，未重复未受影响的定向测试。
- 首次新批次构建 `20261103_011237_541334` 在analysis 28.554秒因系统可用内存低于5GiB触发保护，工具树峰值约3.80GiB，未产生时序结果。资源诊断空闲8.56GiB后，单次重跑采用3GiB保留内存、10GiB工具树上限，RTL/时序约束保持一致。
- 本批 parser 长度流水与 RX 合并后的基础接收检查通过于 `out/checks1030/20261103_011238/tb_rx_basic/`：HDL 9956451项，独立参考123855项，均errors0；不把基础接收检查扩大为完整长分片端到端验收。
- 本批重跑 `out/build1030/AFDX_top_1030/20261103_011352_336275/` 于01:22:35完成综合。setup **+3.311ns、0/134958**，hold **−0.068ns、256/134958**，按门槛跳过route，构建返回2；不是工具崩溃。资源51846LUT、26752FF、7100CLB、829Memory，RX四表RAM及CE审查通过。保存10000条hold路径覆盖全部256个失败端点，均为slot write_data FF到payload RAM数据输入的直接路径（数据696ps、时钟偏斜.754ns）。新slot结构中RTL条件隔离未实际保留，正在修正映射组织，容量和流水拍次保持不变；此次没有新的布线测量值。
- 将slot RAM及本地寄存器搬入同文件独立子模块后，`20261103_012621_673260` VQM保留16个slot/128个写隔离LUT（mask8888），256个RAM数据输入全部经LUT，slot新层级无bypass命名。顶层编译和受影响engine32项检查通过（rx-hold-*）。本轮正式综合setup **+3.311ns**、hold **+0.192ns**，两类 **0/134564**；资源51452LUT、26470FF、7039CLB、829Memory。
- 该轮route运行544.494秒后以 **0xC0000409** 异常退出，内存保护未触发。日志已过setup/hold修复并保存route.dly.pb/tbg.pb，但未完成正式时序报告、route结果写出、checkpoint和VO；不能当作布线完成或时序通过。新增的同进程do_timing_analysis组合未得到验证，具体崩溃命令尚未确定；构建已恢复直接调用未修改的原厂run_route.tcl。一次隔离saved-route graph恢复报告正在进行，原始失败summary保留，恢复证据单独标记。
- 一次隔离官方恢复成功，位于 `.scratch/timing-architecture/routed-slot-recovery/`：clk 8ns/TT，setup **−1.867ns**、TNS−2187572ps、**1945/86716**失败；hold **+0.604ns、0/86716**。10000条setup路径含3523不同端点及1945不同失败端点，覆盖本次native全部失败端点；不是把路径数当端点数。该报告来自已保存route图/延迟，同run synth版本元数据；无原始本轮报表可比较，原流程未最终完成状态保持。
- 最差转为TX fragment_active→context_active（−1.867ns，逻辑2.813/连线6.679ns），其它主要族含loader端口判定、RX state返回、TX bank索引、SNMP now、cfg地址可用、RTC增量/控制、应用RAM读地址、RX age/退休和slot局部写使能。已按TX、RX、app、RTC/config四个所有权域并行实施协调批次，不对当前负setup架构重复相同布线。
- 父级service通道已改为RX服务/应用两支分别同拍捕获valid/data/metadata，整体增加一拍且metadata领先不变；TX在消息之间插入一个带ready背压的仲裁空拍，使远程ready/last不直接驱动served。包内仍1B/clk。必要短事务检查 `tb_service_pipeline` 127项通过，后续同批整机STA和分片验证仍待完成。
- 新整批现已完成并启动正式 `out/build1030/AFDX_top_1030/20261103_022243_938798/`。应用8×4KiB/读4拍/局部query与计数前瞻通过135295项；TX16×8 bitmap、五metadata RAM及局部grant命令、builder准备多2拍/精确launch补偿、同步rollback表，通过context134、基础660851/独立7606，必要RETURN子集1448723/独立189项。旧完整drop套件含不适用的>1471强制drop_long，待时序全部通过后更新，当前不称该整套通过。
- RTC/config七RTL批次通过cfg固定基线6090、RTCbanked34/recovery28、局部timebase/loader等价366、converter/RX历史1972项。SNMP本地timebase逐拍等值；RTC接收选择父级捕获前的历史时间，NTP局部换算done多1拍并保持65拍最早重接受窗口，TX/reference采样不变。
- RX新结构为每slot四个8192×2 lane，读E4不变，最后物理写E2、校验carry flush后progress E3退休。state/config增加本地返回，map地址分发移到engine但总查询相位不变；独立描述符/字段捕获和parser发布分组。顶层V2001、limits71/transactions47/engine32通过，service26/paired28；基础接收及独立参考与官方EDA并行且只运行一次。新网表门槛检查metadata两bank及16slot/64lane/128隔离LUT/256RAM输入，需实际导出证明。
- `022243_938798` 新网表RAM/隔离门槛及CE审查通过，正式综合 setup **+3.448ns**、hold **+0.192ns**，两类 **0/171811**，已进入未修改原厂route。官方资源57852LUT、31826FF、9719CLB、809Memorys、0DSP/PLL、172pins。相较上一51452/26470/7039/829，增加6400LUT/5356FF/2680CLB、Memorys原生计数减少20；这是全批结构变化的总结果，不把它全部归因RX或用不等容量Memorys标签推算容量增减。逻辑容量仍8192字节/消息、应用各32KiB、重组128KiB。
- `022243_938798` 原厂实际布局布线正常完成：route 623.194秒、exit0，最终原厂及构建完成标记齐备；完整构建942.130秒。clk 8ns/TT，setup **−1.988ns**、TNS **−1245293ps**、**800/92288**失败，hold **+0.604ns、0/92288**，故构建返回2而非工具异常。最差loader `half_rate.engine.deny_wd[4] → cmd_deny_wd[4]`，数据9.613ns（逻辑0.773/连线8.840ns）、1级/fanout2。正式报告仅100路径/65不同端点。唯一隔离扩展报告 `routed-batch-expanded` 于10.225秒完成，原生summary指标完全一致（metric_differences=[]），实际10000/10采样，10000条setup路径包含3134不同终点及800不同失败终点，覆盖全部800失败端点但非所有到达路径；原始结果仍保留。互斥owner端点RX410、services/config167、TX146、app77。最差loader单连线从(153,56)到(24,65)，跨129列；下一步先按新网表位置与容量判断区域布局，避免继续盲目增加寄存器。
- 同批RX基础接收已完成：`out/checks1030/20261103_022216/tb_rx_basic/` HDL **9956451**项、独立参考 **123855**项均PASS/errors0，检查启动后未再改RTL。前述RAM门槛也已由新VQM实际证实（16slot/64lane/128隔离LUT/256全隔离输入），不再是待验证预期。
- 基于同版实际位置/资源/carry链分析，下一步保持RTL冻结，复用`022243_938798`的packed checkpoint，在新目录`out/build1030/AFDX_top_1030_regions/20261103_025612_780223/`重新place+route（后台bdr02zt8k）。六区域涵盖loader/RTC/SNMP/TXMAC/两RX bank，共4228簇；器件完整M4K footprint与carry链归属已核对，不将整个597Memory的RX强塞小区。调用未修改原厂程序，8ns/.30ns/CE/172pins/PRES1.30不变。区域命令返回码、逐簇真实落点及最终checkpoint/VO输出会与正式时序一起验收；此时尚无本候选通过结论。
- 六区域实验`025612_780223`已结束并否决：原生流程388.396秒、exit0、完成标记与route/checkpoint/timing齐备；setup **−2.874ns、TNS−6706765ps、3002/92288**失败，hold **+.604ns、0/92288**。12条区域命令code0后，原生`Placer_Udmin_17`仍拒绝相交bounding boxes并只保留后一区域；bank0实际15簇框内/901框外，另五区域全落框。因此未完整实现原拟六区域，不能将其当作该方案合法性通过，更不能采用。wrapper最初返回1的直接原因是错误把未生成的.vo设为必需（上一正常run同样无.vo）；此为脚本验收错误，已改为记录可选VO状态，并补入原生禁止区域相交的启动前检查。原run summary保留，新增review.json记录真实结果，无重跑EDA。
- 下一批已回到`022243_938798`完整800端点诊断，RX410/服务配置167/TX146/App77四owner并行实施。范围新增TX core/free；App RX允许完整入口命令+1拍，payload内部read4/8credits/写E1与正确退休可见性保持；父级es接loader READY_PREDICT1/enable_next，控制owner保持同拍enable递推。暂不再做区域或seed扫描；每owner整批后只跑受影响必要检查，父线程负责唯一顶层编译与正式EDA，最终按新报告判断。
- 新批App最终冻结为reader总8credits（pending/queued/两FF输出槽统一计数，无额外outer队列）、TX配置E3退休、RX外部E0捕获/E1本地命令/E2物理写与committed/descriptor发布。`tb_app_payload_pipeline`最终135312项/errors0，替代存在额外outer队列的中间135305；包括8credit饱和和必要配置相邻拍检查。payload读4拍/每环32KiB不变。
- 新批TX六RTL最终冻结：真实两项49bit buffer入口、末字节后至EVENT关闭下一消息入口、length_full预测、core main/skid ready预测；独立payload helper始终同步读但只对真实request消费/诊断，保留写隔离；builder分段due与−8补偿、pointer写命令局部退休、free占用槽保持、MAC三bit FCS token。context134/MAC218924项通过（tx_batch_mac_context_20261103_031700）；basic661331及独立7606通过（tx_physical_20261103_032044），310帧的309个SOP间距全672=BAG；必要rollback1448737及独立189通过（tx_rollback_20261103_032044）。首次入口消息顺序失败已修正，旧中止run不计通过；旧完整drop_long套件仍未通过。三条now单寄存跨区端点未直接切开，需新STA判断。
- 主线程service仲裁改为本地request快照和两拍安静仲裁，既有127项全通过（service-local-request-result.txt），RX捕获与RTC历史1拍不变。cfg→es→top接两份同拍app_cfg_ready；loader接READY_PREDICT1/CFG_READY_PREDICT1、service_ready_next，cfg_write_request保留完整LOAD_ADDR_GROUP高位资格；MIB user外层冗余ready由cfg内部同拍字节资格取代。AFDX_top物理接口172pins不变。硬件契约revision4仍draft；RX新调度待最终实测交接后写入。
- 新批控制9RTL最终冻结（原7个加615a_engine/mgmt_tx）：loader同拍运行/7字段ready FF、3bit拒绝格式在物理写端译码、CE2 header地址保持且CE1兼容；SNMP1250000clk tick分段预测和32bit uptime字节carry；RTC period_zero/read副本与秒增量分段，既有历史/转换窗口不变。`out/checks1030/20261103_033225/`配置6090/RTCbanked34/recovery28均PASS，包含ready副本逐拍/next预测断言；短保存源对照control-locality-batch2为2860、converter-history-batch2为2629，全PASS且-g2001无警告。仍有未直接改的服务端口/数据、sender ready及小RAM地址等远端路径，不能由仿真断言167端全部物理关闭。
- RX整批RTL通知可作待验证snapshot后，main唯一顶层`-g2001 -grelative-include -DAFDX_CE_DIV=2 -s AFDX_top`编译通过且无警告（top_batch2.vvp）。正式普通构建已启动于`out/build1030/AFDX_top_1030/20261103_034346_513774/`，后台bx1qxp9wf/阶段终态监听ba9shwj1h，memfloor3/limit10，无区域/seed变体。与RX唯一必要检查并行；若需改RTL，旧snapshot明确失效。
- RX首轮limits71/engine32项通过；engine实测service31、paired32..32，既有场景逐周期cfg-ready旧谓词对照无差异。新调度query19、FRAME map5/query寄存6/外部Q0=7/result26/decision27/原子接纳28/写29/结束30；state/config窄8bit片本地读命令/返回，FRAME捕获10、AGE捕获3/回写5，payload读5、copy退休E4。transactions既有碰撞fixture首次把reserve放到外部Q33，超过保持不变的Q32 watchdog，故失败；owner仅把同一场景的copy准备提前，将碰撞排到Q27后重跑，不改RTL或延长watchdog。transactions仅fixture对齐后49项/5 deliveries通过（17→19的既有取消阶段循环延展增加2项计数，无新增场景），RTL无修补；最终三定向71/49/32全过。唯一RXbasic/ref由owner后台b0g4n0xhz运行。RX六文件已冻结，主线程逐文件内容比较确认与034346导出快照完全一致，不计算哈希；parse/deliver/MAC本批未改。cfg ready谓词对照仅覆盖既有轨迹，AGE老化流未另加验证。
- `034346_513774`首次于147.483秒停止在CE gate，map/export均原生exit0，RX两bank四表及16slot/64lane/128隔离LUT/256隔离RAM输入通过。旧CE checker强制所有engine寄存器进入MCP集合，新增deny_format[2:0]三FF未登记；原2748个MCP寄存器全有效、仅这3条内部弧漏登记。保留SDC原样，这三FF继续严格8ns；checker仅显式登记三个命令终点，并独立证明clk/CE低保持、唯一loader_ce_q[28]相位，禁止它们加入MCP集合，STA检查也要求它们8ns。新网表及上一022243网表均通过修正审查。原ce_audit和pre_resume_summary保留，修正证据ce_audit_recheck。未重复map/export，以scratch resume_034346_after_ce_audit.py调用相同官方pack/STA/route函数继续同一网表、同一约束，后台bhyfvoeag/监听ba65vnk6v；这是checker修正，不是RTL或约束放宽。
- `034346`续跑的native pack进程exit0但EDI有两条Timer_M_1 CRIT：`No valid object(s) found for -to ... deny_wd*~I`，官方wrapper正确停止；未运行STA/route，不是资源溢出或时序负余量。集成loader未使用的旧deny_wd输出已消失，原SDC仍保留其空终点组。已只删除该空组：解析核对254→253，其余全部组和.30ns完全相同，8ns时钟及新deny_format严格8ns不变；旧034346网表对清理后SDC审查PASS。checker增加空源/空终点集合检查，避免再次浪费native pack。旧run原报告保持失败证据。
- RX最终边界复核补充一行局部保护：reclaim_row屏蔽已注册commit_row_command，防外部Q32接受命令在解锁后Q33物理写拍被age_due回收。既有id26事务改为deadline边界reserve、物理写拍cancel，transactions-deadline49项/5 deliveries PASS，无新增报文场景；证据rx-800-tb_reassembly_transactions-deadline-*。limits71/engine32和在跑的唯一RXbasic属于保护前版本，范围明确，不标为最后源码重跑。此RTL变化使034346快照不再代表最终版，因此启动新普通官方构建`20261103_035555_864292`（b3wl4nwdr/监听bzx18r1pk），含最终保护及清理后的空约束，memfloor3/limit10，仍不使用区域候选。后续仅按该新run报告判断最终时序。
- `035555`新网表已再次通过RX存储/隔离和CE gate，进入native pack。Analysis含51项warning，不能称商业综合零警告；其中`fsm_encoding="none"`不被本版工具识别，但实际VQM保留engine四个op[3:0] FF（并非由属性名推断独热）。其它告警含已知截位、未使用字段、仿真system-task、RAM读写旁路及忽略部分maxfan；本次未因告警外观另改RTL，最终以映射结构/STA和对应功能证据判断。
- RX唯一基础接收与独立参考已完成：`out/checks1030/20261103_034544/` HDL9956451项、reference123855项/errors0。该快照包含本批全部core/engine/query/checksum/payload流水，未含随后bank一行deadline回收保护；最终保护另有transactions-deadline49项，范围分开记录，不重复长测。最终metadata重组6拍/legacy6拍，末payload物理写E2/progress与pending E4退休；empty在seed/init后退休。MAC CRC20个旧失败端点本批未直接改，core初始化及engine小族也未逐一直接改；不把结构处理等同全部路径已关闭，等待新STA。所有owner均已冻结并停止额外旧报告排查。
- `035555_864292`正式native pack和综合STA已通过，内部clk 8ns/TT：setup **+2.498ns、0/162320**，hold **+0.192ns、0/162320**。实际原厂route已启动，尚无本轮布线结论；不能用综合通过替代route通过，也不把未约束NONE↔clk外部组当内部时序结果或板级IO签核。
- `035555_864292`实际原厂route正常完成，整个构建1040.084秒，exit2表示时序不通过而非工具异常。综合setup **+2.498ns**/hold **+.192ns**、两类0/162320；route setup **−1.206ns、TNS−647355ps、551/93619**，hold **+.604ns、0/93619**。资源58632LUT/32854FF/9549CLB/816Memorys/172pins/DSP0/PLL0；对比022243为+780LUT/+1028FF/−170CLB/+7Memorys（原生标签，不推算等容量块）。route WNS从−1.988改善.782ns，失败端点总数800→551，仍未闭合；不声称551是旧800的逐点子集。最差SNMP idle_q→req_wdata[6] ena：logic1.580/net7.156ns、4级、fanout25。正式仅100路径/63不同终点，不足覆盖551；已派原flow owner仅一次隔离saved-route扩展，输出routed-035555-expanded，必须与本run原生summary严格一致并核验全551覆盖，不重综合/pack/place/route、不改原run、不做hash。
- `routed-035555-expanded`唯一隔离报告10.745秒exit0，strictly_comparable=true、metric_differences=[]，实际10000/10；10000条setup样本/3810不同终点/1320负路径/551不同失败终点，覆盖全551失败终点，但非每终点全部路径。互斥sink owner为App186/RX162/services-config128/TX75。每终点最差保存路径549/551 net>logic，只有22个终点levels>=6；这不是549条都跨区的证明。坐标已证实SNMP内部空间展开、RX map clear近源汇却经远处WideAnd折返、App/service/TX跨域控制，另RAM自身2.455ns、bounds/header比较仍有实际宏/逻辑负担。新全population没有MAC失败终点，不按旧20端点候选盲目改MAC。
- 新鲜物理证据支持先保持RTL冻结，只做一个经过完整资源/簇/原生语法预审的区域候选，而不再立即添加整批FF。flow owner仅准备regions-035555-disjoint.edc及容量证明：所有区域严格不相交、完整M4K横向两列、完整carry与混合簇唯一归属、全设计资源竞争；main之后负责唯一实际place+route及全成员落点检查。旧六区和15区重叠候选仍否决。scratch driver已补精确leaf/层级成员识别、实际M4K X+1落框、原生Placer_Udmin_17拒绝使有效性失败且保留时序；用既有旧实验验证仍启动前拒绝重叠、且实查bank0原901越界。新候选尚未交付/执行，不声称布局或时序通过。
- 唯一新候选`regions-035555-disjoint.edc/.json`已交付，六区两两不相交且全设计10365个CLB/Memory簇有一对一容量见证，418条carry链无部分/跨组选择；TX区24个混合簇携带32个顶层成员已明示。约束6418CLB/418Memory，自由3131/398；M4K完整两列，CLB只计BLK。旧025612五个实际生效区内分别有184/45/352/48/1082个完全未被六组selector选中的自由簇，实证native允许使用框内余位，静态匹配不再依赖未证实的非排他假设。55个map失败终点仍未被直接限框，不声称此候选覆盖所有路径原因。
- 已启动唯一实际区域place+route于`out/build1030/AFDX_top_1030_regions/20261103_043828_392886/`（btti16hlr，拒绝/终态监听bi30t5xte）。复用035555同版ver.pb/packed ecp，保留8ns/.30ns/253合法CE组/172pins/PRES1.30，RTL不动、不重综合/pack、不算hash。六框：TX-App-Svc X45..164/Y1..44，bank0 X1..79/Y73..100，bank1 X1..79/Y45..72，loader X80..119/Y55..100，RTC X120..164/Y45..75，SNMP X120..164/Y76..100。实跑必须确认原生无区域拒绝、所有成员及混合携带簇/完整M4K落框、实际setup/hold；当前仅已进入原生placer，尚未有通过结论，不把静态容量当作拥塞或时序证明。
- `043828_392886`于04:50:33正常完成，724.628秒，native exit0；区域有效、无拒绝，六组2798/852/856/980/735/615个簇全部落框（含TX24混合簇及M4K完整占位）。但实际setup−2.194ns、2351/93619失败、TNS−2840160ps；hold+.604ns/0失败，wrapper正确因时序exit2。与普通035555同packed设计比较，setup和失败端点均恶化，故否决该物理候选，不能将静态可容纳及实际落框解释为时序收益。不再扫区域/seed。
- 依据普通035555完整551端点证据启动下一整批RTL，flow owner另只做一次043828隔离报告解释耦合。App负责reader信用本地延迟退休等实证族，TX负责真实双输入槽的数据预采集/valid token分离，控制负责SNMP写数据连续采集和其它实证控制族，RX负责map终值分段预判及metadata RAM返回判断。main保留svc/top/es/contract/SDC/flow；不改容量/外部接口/有效约束，RX服务及watchdog仍32实际clk上限。每owner整批后只做受影响必要检查，合并一次普通EDA，旧快照结果不作为新源码通过。
- `routed-043828-expanded`唯一隔离报告10.716秒完成，native summary严格同比、差异[]，10000路径覆盖2351/2351失败端点。App186→132、RX162→1353、services128→694、TX75→172；map55→870。AppTX部分路径改善，但service→SNMP入口跨区及自由map/config/AppRX放置退化，证明区域对局部收益和整体耦合存在取舍。普通551仍是新RTL的工作基准，区域新增失败不自动扩大改动范围。
- main服务边界调整已完成：`completed_message`在首个既有仲裁quiet clock本地更新turn，served仍稳定、下一grant拍不变，切断App output_count→turn两个enable路径；app_rx_last如data直接透传捕获值，仅在app_rx_valid有效时消费，切断SNMP configured/claim→top delivery_last。有效接收字节和last拍次不变，AppRX实际存储及active更新均由delivery_valid限定。既有service定向127项PASS/0errors，证据`service-token-result.txt`及`tb_service_pipeline_token.vvp`。契约draft revision5记录这两个边界；尚无新源码时序通过结论。
- App owner已提出并获准同批处理完整application失败族：take_q延迟返还信用；lookup各级数据连续流水，仅FSM tag受配置忙控制；descriptor消费本地retire_q并对下一地址/非空前递；rollback full判断消除read_enable→加法链；RAM读tag与bank选中分开捕获。每个逻辑4KiB bank改为4×1024×9独立物理slice，E2本地结果后在原E3选择，保持每环32KiB/read4/writeE1/总8credit；增加返回选择扇入和FF，收益待STA，不以源码形状宣称通过。契约draft rev5已记录物理组织和reserved=实际占用+take_q。
- TX owner已获准配套搬移payload寄存边界：默认AW17存储改为8×16KiB×8 leaf；E0原请求/E1本地地址/E2物理RAM/E3原FIFO捕获，移除builder旧payload_qr，保持fetch_delay/return_pipe/页所有权及SOP/BAG。物理写拍和容量不变；实际请求碰撞诊断随E2读地址/tag对齐，小参数保留单bank。双49位真实输入槽只由占用状态控制数据预采，远端valid仅赋予所有权；builder本地fifo_pop_eligible预测当前字节资格，ready只进一位token。控制owner另按现有拍次处理无条件请求候选数据、读结果独热合并及mgmt_tx候选数据/所有权分离；新增候选FF不代表额外公开缓存信用。均待整批必要验证及官方EDA，不宣称时序收益。
- TX本批3RTL已冻结（buf/builder/core），engine/free/MAC未改。`out/checks1030/tx_handshake_20261103_050135/`输入协议139695项及buffer边界49800项通过；覆盖双槽/反压/同时传输/复位，1/8192/8193/7字节、VL/端口及闭门至EVENT。`tx_physical_20261103_050135` basic661331/独立7606通过，A/B dump及events与032044直接逐字节相同，无hash；310帧、309个SOP间距均672。`tx_rollback_20261103_050135`既有nopage/refill子集1448737/独立189通过。源级估计净增111 FF bit，实际映射RAM/隔离和8:1返回mux时序待EDA；不将功能与周期对照通过扩大为PPA通过。
- App本批4文件已冻结（read/tx/payload及原TB；app_rx未改）。唯一`tb_app_payload_pipeline_local_retire.vvp`运行477130项PASS/0errors，其中原135312项字节/命令检查保留，另341818次为同一交通的逐拍信用不变量核对，未扩交通场景。coverage direct45113/TX49192/RX40999/sustained43644/rollback1，持续1B/clk原断言无泡通过；容量/接口/外部拍保持。main实查payload E0/E1/E2/E3选择对齐和本地信用递推，未重跑模块检查。slice返回FF之后的32路选择是下一STA实际待验点；原delivery_last根终点已由main服务tag改动覆盖。
- 控制本批6RTL已冻结（SNMP/cfg/615a/615a_engine/RTC/mgmt_tx；snmp_engine/timebase/ntp_fraction未改）。`20261103_050148` cfg6090/RTC34+28通过；`control-batch3`保存源对照：mgmt31146项/7268字节/32报文、SNMP3010项、CE1/2 locality各3570项（55deny写/3header读）、RTC历史2629项、reason组合8192项全部通过。数据候选与token分离、独热配置返回、局部匹配与互斥reason/overflow保持现有公开拍次和容量，不宣称PPA已过。人工播种短TB补齐了计数预测flags的自洽状态，未放宽行为比较。
- App在上述477130首次通过后，按已批准的局部选择要求又将payload返回改为bank内4路独热掩码及跨8bank独热归并，保留中间bank_data边界；此前结果仅属于动态选择中间版，最终独热源正在一次受影响复核，main暂不snapshot。源级估计每应用+216 result FF/+87 control FF，两应用合计+606显式FF；容量不变，实际RAM/FF/时序待EDA。
- TX最终冻结后仅移除storage父层冗余的当前请求仿真碰撞诊断，保留leaf实际E2已登记请求/地址诊断；硬件和调度无变，未重复回归，已通过的验证覆盖全部保留行为。
- App最终独热源已完成受影响复核并冻结：`tb_app_payload_pipeline_local_retire_onehot.vvp`重编译/实际运行477130项PASS/0errors，coverage与中间版完全相同，复核后无源码/TB/诊断改动；最终以此产物为准。每应用+303显式FF是源级估计，不冒充native资源。
- RX本批内部调度已明确：admission Q17局部返回FF/Q18比较与admit/Q19root保持；header增加output arm，metadata领先只增；map分段终值预测及写slice本地清零计数保持地址范围和原初始化完成拍。core内部next-enable精确预测init_done的原递推，engine新预测参数默认关闭；集成cfg_ok注册副本必须逐拍等于原enable&&quiet，不能改变同拍配置受理。deliver提前准备首ring地址，但实际ownership/首读/prepared/释放指针不提前。FRAME相位与32拍上限保持，等待RX最终验证，不提前snapshot。
- 当前继续优化，尚未达到用户指定的综合/布线全部 setup/hold 通过条件。达到条件后才更新项目内受本次接口/延迟变化影响的必要测试并做一次合并版端到端验证；不增加过度防御性测试，不重复有效模块检查。

### 054632 普通完整构建与前次门槛失败

- 本批最终RX功能已冻结：limits71、transactions49、engine32全通过，CE_DIV2实测service31、paired32；engine配置允许副本与原谓词逐拍相同。唯一最终core/deliver basic在`out/checks1030/20261103_052656/tb_rx_basic/`完成，HDL9956451、独立123855项PASS/0errors，覆盖map配置地址bareFF/局部清零、core预测和四位读slice及deliver首地址预装。无重复basic，功能证据不等于时序通过。
- `20261103_052819_640250`的map135.969秒、export3.442秒成功，但没有综合STA或route。首个存储审查误将新write_qualifier隔离LUT计为0；修正审查器识别该局部使能名，同时保留真实comb_only/mask8888和primitive连接条件后，同一新VQM验证16slot、64lane、128隔离LUT、256隔离RAM输入、0直连。原错误报告保留，修正结果为`rx_storage_audit_recheck.json`。首次进程已在启动时import旧审查器，不能靠修改磁盘文件让运行进程自动更新。
- 同一导出网表继续CE gate时，原`reason*~I`误选新增reason_checksum_event/reason_retry_event/reason_event三个组合cell，检查器正确拒绝；2747个受约束FF有效，51749内部弧、0未覆盖。尝试收窄为`reason[[]*~I`的Python对照保留全部253组FF集合，但只读Tcl查询返回选择表达式，不能证明原生匹配。native pack最终明确`[CRIT][Timer_M_1] No valid object(s)`拒绝该选择器；虽然进程exit0，wrapper按实际CRIT返回失败，没有STA/route。原run保留错误及两次续跑记录，不再续跑。
- 已完全恢复canonical SDC原`reason*~I`及checker原语法。main仅将7个新增loader组合事件wire改为local_description_event/local_length_event/local_checksum_event/local_tftp_event/local_retry_event/local_clear_event/local_event，reason寄存器、CE、D函数和更新拍均保持，避免原glob碰撞。未采用放宽约束或新匹配语法；名称修改后合并顶层编译无警告通过，不为纯改名重跑旧功能用例。
- 当前新普通完整构建为`out/build1030/AFDX_top_1030/20261103_054632_416289/`，后台`bjpujmda1`，阶段/失败/终态监听`b8eo7gkx6`。修正审查器在新进程启动前已在位；使用原253组合法MCP、8ns/.30ns、EQ6HL130/CSG484_H和172pins，memfloor3/limit10，无区域/seed扫描。所有RTL冻结，等待实际存储/CE gate、native pack、综合setup/hold及实际route；四项正且0失败后才更新必要项目测试和最终合并分片集成。

- `054632`已完成map/export；新VQM实际审查通过两bank四表、16slot/64lane、128隔离LUT和256个隔离RAM数据输入，0直连。原253组MCP下CE审查通过：2747有效FF、0无效、0遗漏内部弧、无误选组合cell。纯组合wire改名已消除前次误选，原生pack运行中；尚无综合/route时序结论。

- `054632`原生pack和综合STA均正常通过：clk setup **+2.888ns**、hold **+.192ns**，两类失败端点均0；setup相较035555的+2.498ns增加.390ns。已自动进入真实route，05:52:14原生Launched Placer。当前只证明综合门槛通过，布线余量与最终资源以本次正常完成报表为准。

- `054632`最终普通flow于06:00:06正常完成，814.534秒，所有native阶段exit0、wrapper因时序exit2。综合setup+2.888ns/hold+.192ns，两类0/177184；实际route setup **−3.254ns**、TNS−8010716ps、**1236/109601**失败，hold+.604ns、0失败。资源62226LUT/35491FF/10147CLB/1068Memorys/172pins；对比035555增加3594LUT/2637FF/598CLB/252Memorys，容量未变但实际物理代价上涨。新批综合setup改善.390ns，route setup由−1.206退化为−3.254，不能宣布收敛。
- 本次原生仍仅100路径/30终点，全部集中TX payload RAM→builder payload_fifo样本，不能代表其它1206失败端点；最差6级、logic4.278ns/net6.232ns。已派flow owner做唯一隔离saved-route扩展与严格summary比较，目标覆盖1236失败端点并按owner互斥分类；TX owner只分析把当前leaf地址前1拍移到独立RAM返回FF的成套替代方案，保持请求到FIFO总延迟/容量/BAG，暂不编辑。其余源码冻结，待完整诊断决定下一批，不扫seed/区域，不提前更新规范测试。

- 唯一`routed-054632-expanded`已11.804秒正常完成，严格原生summary差异[]，10000路径中5962负路径、2917不同总端点，覆盖全部1236失败端点；全端点覆盖不代表路径穷尽。互斥sink为TX848、RX234、服务/配置115、App39、MAC0，对比035555为75/162/128/186/0。App明显改善，TX新存储组织是本批主要退化。TX内payload目的697、builder73、engine74、buffer4；RAM返回FIFO族64失败，其余大量payload内部失败来自buffer.payload_wa广播至RAM地址（例fanout256、logic.686ns/net9.957ns、slack−2.634）。不能仅修64个返回端点。实际Memory1068/1200=89%、CLB10147/13616=75%，该占用是事实，但未据此单独断言所有退化原因。已请四个原owner基于精确源汇给输入/返回、本地ready、RX终值与准备、RTC采集允许的批次方案，暂不编辑/跑测；main负责统一时序/容量/采样契约与实施决策。

- 完整映射计数对照进一步排除了App/RX存储总数上涨的假设：TXpayload原生对象2→256（八bank各32）贡献+254，loader/SNMP各−1，净+252；AppTX/AppRX payload各64→64、RX cfg28→28/state43→43。旧两个对象与新256个对象不是等容量基本块，不据此推断容量改变。下一批优先恢复旧TX存储推断/有效返回边界，保留已实证改善的ingress/App/SNMP/map/cfg改动。
- main已解冻`afdx_es.v`，契约revision6 draft：新增TX/RX各一份现有afdx_timebase，clk/reset完全相同，TX使用本地完整now，RX使用本地now[27:12]及原样注册的低12位终值tick；原RTC/服务/global byte_en不变。相同确定性递推保证每拍值与wrap/复位边沿相同，无新增可见延迟；standalone core外部时间端口不变。目标为消除timebase→TX/RX寄存器经共享RX now_previous组合节点绕行，尚无新映射/时序证明。054632现在仅为对应旧快照诊断，不能作为正在修改源码的通过结论。

- TX下一批架构已由main明确：恢复035555单个完整AW×8的独立payload RAM推断及E1 RAM/E2独立builder payload_qr/E3 FIFO，保本批有效ingress/fifo_pop；不采用8bank×4lane及约+962FF候选。单store本地完整写bundle持续采集，命令/独立qualifier控制下一拍物理写，内部写可见性+1；owner必须证明提交到首次读余量、回滚/复用/复位及实际写隔离，core容量/字节吞吐/SOP不变。允许builder当前真实last-byte take/VL内部先导，在原fragment_done发布边沿被16组engine本地command/index捕获，仍于原下一边沿清busy，保grant commit优先级和所有旧输出拍。engine默认参数关闭新先导以保旧standalone连接，集成打开。TX owner已获整批实施权限，冻结后只运行受影响context、TX basic/独立和RETURN子集；不重跑未变ingress/MAC。main已将这些明确架构写入revision6 draft，后续资源/STA仍以实际mapped结果判定。

- TX新批四RTL（core/builder/engine/buf）已最终冻结，验证后无改：`tx_single_context_20261103_061717`134项PASS，集成completion=1逐拍比较原清忙predicate；`tx_physical_20261103_061717` basic661331/独立7606 PASS，A/B/events与032044逐字节相同、310帧/309 SOP间隔均672；`tx_rollback_20261103_061717` HDL1448737/独立189 PASS，同epoch accept4+4/no-page2+2及两次1024恢复。未变ingress/MAC不重测。新single RAM含27bit本地write bundle、64bit completion、1bit同拍ingress_open，恢复8bit qr、删除118bit八bank地址/tag，源级净−18FF；实际物理对象/隔离待mapped。写可见性：最后store L、发布L+1、desc写/捕获bundle L+2、payload写L+3、最快首RAM读L+39，36拍余量；8193回滚最后迟写P+3，最早归还P+4。首reset边可退休旧写，ownership作废且命令清零，之后无跨reset旧写。旧035555的20个payload输入失败实际为read-side高位地址→RAM ena，不能声称本地write bundle已结构性切断它们，保留新实现检查。
- App五项整批已完成，最终5文件read/tx/rx/payload/TB冻结。唯一实际编译/仿真851719项PASS/0errors：原477130交通/credit检查、249726 available/head断言、124863周期旧054632接口等价组；coverage仍direct45113/TX49192/RX40999/sustained43644/rollback1，未增加消息场景，仅原两消息同值cfg脉冲覆盖lookup busy重启和last-retire。证据`tb_app_payload_pipeline_054632_equiv.vvp`，scratch旧源fixture不进综合。公开ready/valid/last/drop及有效data/VL、内部q_ready逐周期完全相同。PREDICT_LIMIT/EARLY_DATA/SPLIT_RETURN默认0且完全忽略未连接可选端口，只有指定TX/RX实例开启。源级净−74FF/Memory0，读4拍/8credit/容量及物理写退休边沿不变；新的单capture→32组、raw→4pair和两组E3→E4 OR仍需新STA。
- RX进一步收敛后本批暂不采用只剩1端点的map地址大合并，避免配置地址旧路径回归；因此不再计先前方案的−768FF和约−800FF估计。保bank/deliver/engine主族整批，实际资源以最后冻结源差值报告。RTC采样协调确认root公开首valid为原事件，svc固定历史仍1，不给内部可变准备加固定补偿。控制A+B+C已获统一实施授权，main ES已接CFG_READY_TERMS=1、base/rx_term及现有最后RX ack副本和完整RTC raw host group；默认接口保兼容、原next/publicready不改。CE极小负余量保严格要求，在新物理实现重查，不新增MCP/虚假例外。

- RX本批bank/deliver/engine已最终冻结，root只更新lead注释、core/map未改。`out/checks1030/20261103_063501/summary.json`单次定向全PASS：limits71/deliveries18；transactions126/deliveries9；engine39/accepted6/duplicates2，service31/paired32..32不变。短边界包括N1/2/3/129、真实pending63拒绝与退至62再接纳、一次物理commit/retire同Q31、ready撤回/空长B不读不释放、旧尾与D_QUIET原一拍信用，以及F26 pop可受理/F27 pop不可提前受理和AGE phase5同tick；原场景未删。冻结后无RTL修改，唯一RXbasic/ref后台`bybq2n6s8`，尚未回报，不重复运行。
- 控制侧C跨模块接口已明确：cfg输出`service_ready_base/service_ready_rx_term`，loader和RTC可选`CFG_READY_TERMS=1`目的地合并base||(term&&ack)，默认0不读悬空输入；ES将ack接现有`rx_cfg_ok[RX_CONFIG_BANKS-1]`，与0号同D/复位且同拍，原public/next ready不变。RTC raw cfg_write_request保留cfg_wr及完整RTC_ADDR_GROUP高位资格。新许可FF位于外层615a/RTC/sender，禁止新增未登记half_rate.engine FF或修改CE checker/MCP；现有微小CE负余量仍保持严格原时序要求待新实现判断。

### 最终 RTL 收敛与 125 MHz 综合/布线全闭合（2026-11-03）

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

R139 的抖动描述为“最大时延－最小时延－BAG 配置值”，适用分组和多片消息口径仍有歧义。本轮保留原始完整消息时延、首字节时延、逐片发帧时间和 BAG 间隔，不把长消息多次等待 BAG 的时间擅自扣除后宣称合格。参考模型输出中的旧 R119 极差统计仅作兼容字段，不代表已完成 R139 验收。

完整性能负载、全文设计/测试报告、ModelSim 综合后仿真、完整外部 I/O 延迟预算仍需各自的实际证据。实现或局部仿真通过不等于全部要求验收完成。
