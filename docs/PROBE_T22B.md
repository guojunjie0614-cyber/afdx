# T22b 官方 MAC IP 实测

基线 `035b437f`；TripleSpeedEthernet / `t22_official_mac`，eLinx 3.0.7、ModelSim SE-64 2020.4；试验在 `out/t22/b/`，原始IP和现有设计未改。`.v/.vo` 行号指用户生成文件；手册指安装包 `bin/ip/doc/TripleSpeedEthernet_User_Guide.pdf`。“帧长”含FCS、不含前导码；一拍8ns。
## 1. 原始网表与单帧自环

原始 `.vo` 的字节副本直接通过编译、自环及后续压力测试，无工具错误/告警；其 `sdf_annotate` 原本已注释，未修网表、未用 `.vqm` 替代仿真。使用安装包 `Simulation/elinx_lib/stratix_atoms.v`，入口和逐次命令见 `run_sim.py`、`jobs/*/*/tool_metrics.json`。
36 位收发 FIFO 经长帧、多次地址回绕和变化数据检验未出现位序错误；本 IP 自带 `.vo` 的 Stratix 原语及读写置换配对，与 T22 布线后 `.vo` / `elinx_atoms.v` 的失败路径不同，不能据此宣称后者已修复。
## 2. FIFO、连续帧与模式

生成源码 `.v:564–579,789,1005–1020`：用户 FIFO 实际为 128×36（32 位数据、4 位控制），发送在积累 12 字即 48 字节后启动；网表还含收发各 4096×8 数据 FIFO及长度 FIFO，512 字节不是整个 IP 的缓存总量。
测试端先为帧体追加独立 CRC32，再送 IP；118 帧包含连续 50 帧 64 字节、连续 50 帧 1518 字节，1/2/4 实例均逐字节正确、无丢帧、帧内 GMII/RX 用户输出无空洞、无 TX/RX 错误；四实例逐拍一致，结果见 `result_stress_crc*.json`、`results.json`。
1518 字节帧均在最后输入字节前开始上网，证明本配置可直通长帧。存储转发未运行：手册§2.3提及该模式，但生成接口无模式控制，`.v:789` 固定阈值；寄存器输出 `tx_enable/rx_enable/eth_speed/soft_reset/loop_enable` 在顶层无消费者（`:152–160`），不能凭手册假定运行时可切换。
## 3. 同帧对照、延迟与错误

T22 原 19 帧的字节和间隔字段原样复用：IP 只发“7×55、D5、输入字节”，19 帧均未自动追加 FCS，与自研线上记录不同；输入单独的 17 字节欠长帧后再等 8000 拍仍不发送，也未自动补零。证据 `result_baseline.json`、`result_runt.json`；发送源码 `.v:980–1001`。
由测试端补 FCS 后，118 帧的 94,282 个线上字节与自研完全一致；IP 接收保留 FCS和零填充，自研剥 FCS、保留填充。64/1518 字节的错误 FCS反例各1帧均原样交付，`ff_rx_err` 全程为0；注入 `p0_rxer` 的阳性对照能置错，见 `result_bad_crc.json`、`result_rxer.json`。这是本生成配置的结果，不能按手册§2.3.2/2.3.3/2.4.2视作已具备自动补零、CRC生成和有效CRC报错。
延迟按同一上升沿计数：各8帧空闲短/长帧均 TX=59拍、RX=15拍；持续排队时首字节接纳到首前导码为59–649拍，最长5.192µs。连续长帧稳定起点间隔1540拍，最短帧84拍；详细逐帧记录在 `analysis.json`，不把队列积压当作空闲抖动。
## 4. 实际端口、时钟与上电

输入：`clk_sys,rst_b,p0_txc,p0_rxc,p0_rxd[7:0],p0_rxdv,p0_rxer,p0_col,p0_crs,ff_tx_clk,ff_tx_data[7:0],ff_tx_sop,ff_tx_eop,ff_tx_err,ff_tx_wren,ff_rx_clk,ff_rx_rdy,reg_wr,reg_rd,reg_addr[3:0],reg_data_in[31:0]`。
输出：`mdc,phy_rstb0,p0_gtxc,p0_txd[7:0],p0_txen,p0_txer,ff_tx_rdy,ff_tx_al_full,ff_rx_data_vld,ff_rx_data[7:0],ff_rx_sop,ff_rx_eop,ff_rx_err,reg_data_out[31:0],reg_acc_bsy`；双向：`mdio`。共37个具名端口，原声明见 `.v:17–67`、`ports.json`。
5个输入时钟同接125MHz的上述自环通过；`p0_txc` 仅声明未使用，`p0_gtxc=p0_rxc`、`phy_rstb0=1`（`.v:29,72–73`），MDC实测1.25MHz。寄存器写入0次即可收发：`reg_wr/reg_rd/reg_addr/reg_data_in=0`，读输出可悬空；发送仅在ready高时置wren，接收ready恒1。
MDIO应接PHY或仿真应答模型：实际请求PHY地址1、寄存器17，本试验回复`16'ha400`，已只读确认IP采到a400且link=1；仅用`tri1`上拉的一帧也能自环，但读回全1不能代表真实PHY链路。未验证异步时钟或上板；手册未提供本核完整寄存器地址表，GUI分频40与实测100分频也不相同。
## 5. 资源与运行时间

EQ6HL130/CSG484_H原生pack实测：官方IP复用用户VQM，1400 LUT、975 FF、24 RAM、209 CLB；四份数量相加为5600/3900/96/836，非四核联合布局结果。自研单口TX+RX封装经现有脚本综合、pack为556 LUT、198 FF、0 RAM、69 CLB；现有双网TX共享控制，不能把单口乘四当作整机精确增减。见 `result_resources_*.json` 的 `packed_utilization`。
118帧持续收发测速排除编译/优化/加载：官方1/2/4实例为1952/708/198拍每秒，四实例111380拍耗562.151秒；自研RTL 1/4实例为441474/186466拍每秒，综合网表为5843/584拍每秒。官方空闲1/4实例为5367/759拍每秒，速度随负载和实例数明显变化。
按T20当前源码对应的37项周期数与实例数外推，RTL+官方`.vo`混合回归在“空闲成本/持续收发成本”模型下约30.7/109.2小时；这是条件估算，不是实测上下界，二实例空闲成本用插值，未计编译和接口适配。五功能124759拍的混合仿真约2.7/10.5分钟；沿T20整顶层综合网表口径，以原3717.625秒减去自研MAC估算开销再加IP开销，持续收发模型约68.9分钟。公式和来源见 `results.json`、`regression_baseline.json`。
## 6. 并排结论与集成影响

| 项目（125MHz） | 自研MAC | 本次官方IP配置 |
|---|---|---|
| 64/1518字节帧的帧体吞吐，不计FCS | 714.286/984.395 Mbps | 714.286/983.117 Mbps，FCS由测试端提供 |
| 空闲TX：首字节请求/接纳→首前导码 | 0/−8拍；先发前导码再接纳 | 59/59拍，即472ns |
| RX：GMII末FCS→用户末字节 | 2拍，输出不含FCS | 15拍，输出含FCS；剥离适配尚未做 |
| 连续同长IFG（短/长）；空闲TX抖动 | 12/12拍；0 | 12/14拍；0；排队延迟会变化 |
| 时钟 | 1个输入clk | 5个时钟输入，可在本例共用1个125MHz源 |
| 单口LUT/FF/RAM | 556/198/0 | 1400/975/24 |
| 四实例仿真拍/秒 | RTL 186466；综合网表584 | 原始`.vo` 198（持续收发） |
| 上电配置、FCS、错误 | 无寄存器初始化；生成/校验/剥FCS | 本例0次写；需处理MDIO、补FCS和CRC错误通路 |

整机指标仅推算：若补齐校验/握手且保留原77VL、1ms调度，77×1540=118580拍＜125000拍，线路容量仍容纳906.136Mbps（1471字节载荷极限955.195Mbps），不证明整机吞吐已保持。若前后级时序不变，仅空闲TX就多59拍=0.472µs（24.408→24.880µs的分项估算），接收适配和FIFO排队另计，未得到新的整机上界；空闲同长仍可零抖动，不能据此保证原77VL工况为0。
集成至少涉及新增MAC/CRC封装、`afdx_tx_core.v`、`afdx_rx_core.v`、`AFDX_top.v`、`tb/lib`、`tools/eda.py`与`sim`清单：双网ready、SOP/EOP、tx_sof/eof、长度/末字节/错误及MDIO约定均需适配。条件性估计2–4人日接口与校验工作，另加上述回归墙钟；首要拦路项是本生成配置缺失的CRC行为和手册不一致，不替用户决定是否替换。
复现入口 `out/t22/b/run_stage.ps1 -Script run_sim.py -ExtraArgs '--mode','stress_crc','--count','4'`（另传未来UTC的`-Deadline`）；同入口运行 `run_remaining.py`、`run_self.py`、`run_resources.py`，汇总 `python out/t22/b/collect.py`。命令、捕获和日志在 `out/t22/b/jobs/`。本轮未集成、未重跑整机37项/五功能、未验证布局布线时序；TASKS内容原样提交，未推送。
