# T22 官方以太网 MAC IP 摸底

基线 `9faadb16`，eLinx 3.0.7、ModelSim SE-64 2020.4、EQ6HL130/CSG484_H；试验仅在 `out/t22/`，现有设计和默认设置未改。
## 1. IP 选择

选 `Tri_Mode_Ethernet_Mac`：其手册§1.1明确支持全系列，§2.2/3.4给出1000M GMII及8位类AXI4-Stream接口；比 `TripleSpeedEthernet` 的类Avalon接口更接近现接口。两份原手册位于安装目录 `bin/ip/doc/`，本轮均已读；旧核手册§2.3还区分直通和存储转发，不能将它的能力套给新核。
## 2. 生成情况与用户操作

未生成IP：两款官方生成程序以 `--help` 从私有目录启动，均驻留10秒、无帮助输出和产物，随后仅结束本次进程；手册未提供批处理入口，按卡停止此项。原记录 `out/t22/cli_probe/result.json`；以下步骤依据Tri手册§4.1和UG102§2.3、8.3的界面，尚未实际点选。

1. eLinx起始页点 `Manage IP` → `Create IP` → `Next`；`Device` 选 `EQ6HL130`，`Target language` 保持 `Verilog`，`IP location` 填本工作区的 `out/t22/ip_tri` 的完整路径。
2. 点 `Finish`；在 `IP Catalog` 的 `Interface protocols` → `Ethernet` 下双击 `Tri_Mode_Ethernet_Mac`（主窗口也可用 `Windows` → `IP Catalog` 打开）。
3. `Component Name` 填 `t22_official_mac`；`data rate` 保持 `10M/100M/1000M`，手册说明此项不可修改。
4. `interface` 页的 `PHY interface` 选 `GMII`；不勾选 `PHY Device RD/WR Port`（仅不暴露用户读写PHY的端口，不能据此认为内部MDIO管理已取消）。
5. `features` 页不勾选 `HALF Duplex`、`Frame Filter`、`RX Flow Control`，随后点 `OK`。
6. `Generate Output Products` 中保持 `Synthesis Options` → `Out of context per IP`，点 `Generate`；保留该独立目录的 `.eci`、`.v`、仿真 `.vo`（若生成）及日志，实际文件名和位置需按输出确认。
## 3. 自环、帧格式与时延对照

官方IP没有生成物，未运行其自环、未取得逐字节对照；Tri手册§3.4.11.1描述双缓存和tlast提交完整帧，但是否必须存完一帧才发送、具体发送延迟仍待实测。
自研MAC对照PASS：19帧含64/1518字节合法帧、各8帧连续短/长帧，以及1帧欠长反例；这里帧长含FCS、不含前导码。激励及外部记录保存在 `out/t22/jobs/mac_baseline/20261011_073841_823254/`，结果 `out/t22/result_mac_baseline.json`。
按125MHz采样周期计，首字节VALID到首前导码：空闲0拍，本组连续帧15拍（120ns）；若从首字节VALID&&READY接纳计则为−8拍，因为自研MAC先发8字节前导/SFD才接纳首字节；不是完整帧缓存后发送。
GMII最后一个FCS字节到用户最后一个数据字节为2拍（16ns），到f_end为3拍；连续发送最小帧间隔12拍（96ns），64/1518字节帧起点间隔分别84/1538拍。
连续帧用户口吞吐为714.286/984.395Mbps（60/1514字节，不含FCS）；1518字节帧的1500字节Ethernet载荷为975.293Mbps。这是单MAC稳态数据，不是整机AFDX吞吐或37项回归结论。
19帧线上字节均与独立参考一致：7×55、D5、输入内容、低字节在前的CRC32；自研MAC不自动补零，17字节输入变为21字节欠长帧，接收长度错误符合预期。合法短帧的零填充由激励提供；正式设计由 `rtl/afdx_tx_builder.v:284` 处理。
## 4. 时钟结构

Tri手册§3.2/4.2：4个输入时钟gtx_clk、eth_rx_clk、mdio_clk、mii_tx_clk，3个输出tx_mac_aclk、rx_mac_aclk、eth_tx_clk；千兆发送/接收为125MHz，MDIO为25MHz，mii_tx_clk为预留输入。
因此不能把“全部接125MHz”当作符合手册且已验证的接法；理想自环可让发送和接收同源125MHz，仍须25MHz管理时钟及PHY/MDIO应答条件。真实PHY接收时钟随路输入，接收用户口也属该时钟域；若与现核心不同源则需跨时钟适配（CDC），本轮未实施或仿真该连接。
## 5. 资源与仿真速度

没有IP综合网表实测。Tri手册表2.1仅给参考LUT=2262、FF=1231、MEMORY=13、CLB=320，不能当作本器件/本配置的实测逻辑单元数或RAM块数。
自研对照14740拍、仿真工具2.641秒（含优化/加载，约5581拍/秒）；没有官方IP.vo的测量值，不能据此估算换用IP后的37项回归和整顶层五功能耗时，均标为未测。
## 6. RAM 位序最小复现

复用 `ram_probes.v` 的probe_sdp及 `tb_probe_ram` 检查循环，只在副本改顶层/位宽/深度和失败打印；六种位宽统一128深度，单比特及固定随机种子数据，两轮共各256次检查。RTL与.vo激励一致，.vo只注释sdf_annotate；均完成原生map→VQM→pack→route。
结果（每种各256次）：8、9、16、32位的RTL与.vo均0错误；18位RTL 0、.vo 237错误；36位RTL 0、.vo 239错误；六次.vo仿真的ModelSim工具错误/告警均为0，失败来自数据自检。
18位 `.vo` 输入把wd[8]送到bit16，读出未逆排：写00100读10000；36位把wd[8]送到bit32：写000000100读100000000。证据为 `out/t22/projects/ram_w18/elinx/RAMProbe.runs/imple_1/RAMProbe.vo:303`、w36同路径`:465`；厂商模型 `Simulation/verilog/elinx_atoms.v:3610` 按位存储。
9位通过，所以不是“带第9位的宽度都失败”；本轮证实18/36位的多组9位拼接在导出时重排写端而读端保持自然索引，8/9/16/32未重排。适用范围是本次128深度、器件和工具/库组合；未取得IP.vo，不能宣称其RAM/FIFO正常或异常。
入口为 `out/t22/run_stage.ps1`（`run_ram.py` / `run_mac.py`）；原命令、输入、日志在 `out/t22/jobs/`，汇总 `ram_summary.json`、`ram_bit_map.json`。首次pack因副本缺epr停止，补齐私有epr后复用已通过的RTL和VQM继续；原失败日志保留，未改安装目录或原工程。
## 7. 影响、工作量与未完成项

尚无官方IP的吞吐、时延、抖动收益数据；双帧缓存、管理时钟和随路接收时钟可能改变现有调度与时延，不能承诺保持906.136Mbps、24.408µs或固定工况零抖动。当前拦路项是GUI生成、PHY管理应答以及IP.vo/库的真实兼容性。
静态集成范围：新增官方MAC封装和MDIO仿真应答模型；至少涉及 `rtl/AFDX_top.v`、`rtl/afdx_tx_core.v:118`、`rtl/afdx_rx_core.v:121`，并适配双网ready、tx_sof/eof、接收末字节/错误/长度和跨时钟边界，更新仿真/综合清单及参考检查器。
条件性工作量估计2–4人日（IP生成与单核仿真先通过，不含未知工具问题和未测回归墙钟）；随后才有依据评估37项回归、8项综合网表及整顶层五功能。未替换、未改变正式版本，不替用户决定第二步。
