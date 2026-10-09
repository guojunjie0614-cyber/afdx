# T5 验收摘要

## 1. 第 0 步结论

起点 `7bd4611c`，种子 `20261007`；唯一主证据 `out/t5_preflight/final_acceptance.json`，其引用原始日志；所有路径相对 `schemes/scheme_c3/`。PASS：前端预定义 `SYNTHESIS`；`ifndef` 监视前后两探针网表除日期外逐行一致。`probe_p1_128x32` 80 LC/32 RAM、`probe_p3_banks` 447/208；证据 `out/t5_preflight/monitor_equivalence.json`（含前后目录和哈希）。
## 2. 25 项 RESULT 与 CHECK

最终串行25/25 PASS；数字为 checks/errors、items/errors，系统CHECK顺序=ES1_TX、ES2_TX、ES1_RX、ES2_RX、系统；目录 `out/sim/<测试>/<时间戳>/`。参考自检16/0（`out/selftest/t5_afdx_20261008_143500.log`），RX篡改5/5拒绝、7项同种向量相同（`out/selftest/t5_rx_20261008_143400/summary.json`）。
| 测试（参数非默认时注明） | RESULT | CHECK | 时间戳 |
|---|---|---|---|
| tb_ram_sdp | 20764/0 | — | 20261008_144641_692114 |
| tb_mac_tx | 1703516/0 | — | 20261008_144645_546847 |
| tb_mac_rx | 409817/0 | — | 20261008_144650_226418 |
| tb_mac_loop | 7110567/0 | — | 20261008_144654_578452 |
| tb_tx_basic | 1122481/0 | 7986/0 | 20261008_144700_786507 |
| tb_tx_basic:TX_PAGE_AW=5,TX_OFF_AW=11 | 1121477/0 | 7986/0 | 20261008_144706_234442 |
| tb_tx_bag | 14082026/0 | 14757/0 | 20261008_144711_713073 |
| tb_tx_multi | 14787228/0 | 43309/0 | 20261008_144726_244728 |
| tb_tx_drop | 30306474/0 | 4864/0 | 20261008_144743_131537 |
| tb_tx_net | 249109/0 | 240/0 | 20261008_144810_286299 |
| tb_rx_basic | 23378949/0 | 123855/0 | 20261008_144814_949459 |
| tb_rx_fault | 1362575/0 | 890/0 | 20261008_144834_218382 |
| tb_rx_icrm | 4860713/0 | 1274/0 | 20261008_144839_438507 |
| tb_rx_load | 6407701/0 | 19180/0 | 20261008_144845_957315 |
| tb_rx_ovf_ring:RX_RING_AW=9 | 543629/0 | 99/0 | 20261008_144854_262859 |
| tb_rx_ovf_dq:RX_DQ_AW=1 | 414970/0 | 57/0 | 20261008_144859_175599 |
| tb_rx_net | 428774/0 | 110/0 | 20261008_144903_840524 |
| tb_sys_basic | 5436641/0 | 292/0; 294/0; 145/0; 145/0; 1808/0 | 20261008_144908_482909 |
| tb_sys_fault | 39198558/0 | 499/0; 499/0; 274/0; 274/0; 4695/0 | 20261008_144914_741323 |
| tb_sys_delay | 13830132/0 | 309/0; 309/0; 175/0; 175/0; 2459/0 | 20261008_144929_349681 |
| tb_sys_load | 97337256/0 | 17289/0; 3779/0; 2135/0; 8658/0; 69048/0 | 20261008_144937_708336 |
| tb_sys_cfg | 16689165/0 | 13049/0; 89/0; 45/0; 7173/0; 688838/0 | 20261008_145012_154376 |
| tb_sys_reset | 10567828/0 | 340/0; 340/0; 112/0; 112/0; 2476/0 | 20261008_145024_680683 |
| tb_sys_ovf (RX_RING_AW=9) | 9405750/0 | 129/0; 129/0; 46/0; 46/0; 1000/0 | 20261008_145032_489784 |
| tb_sys_net | 2669193/0 | 89/0; 89/0; 45/0; 43/0; 889/0 | 20261008_145039_766701 |
## 3. 43 个原有记录

J1后17项PASS，新增10333次cfg_ok检查；最终回归再与起点原件比较，13次核心×3份记录加MAC TX/LOOP各2份抓包，43/43逐字节一致，起点保存文件哈希也未变化。`out/t5_preflight/baseline_records.json`、`j1_equivalence.json`、`final_acceptance.json` 均留有精确路径和哈希。
## 4. 系统流量、非零计数器与配置等待

每格分别为ES1、ES2；收下=accept，交付=D行；非零计数器列实际读值最大值（复位场景按各次读的最大值）。25种计数器均已读到非零且逐次与脉冲一致。
| 测试 | 收下/交付 ES1；ES2 | 非零计数器读值 ES1；ES2 | 写最长等待 ES1/ES2 |
|---|---|---|---|
| basic | 16/16; 16/16 | accept=16,tx_a=12,tx_b=12,a_good=12,b_good=12,rm_drop=8,deliver=16; accept=16,tx_a=12,tx_b=12,a_good=12,b_good=12,rm_drop=8,deliver=16 | 1/1 |
| fault | 24/23; 24/23 | accept=24,tx_a=24,tx_b=24,a_good=23,a_fcs=2,b_good=23,b_fcs=2,rm_drop=15,deliver=23,a_ic=2,b_ic=2,a_len=1,b_len=1,a_unk=1,b_unk=1,a_hdr=2,b_hdr=2,a_cfg=1,b_cfg=1; accept=24,tx_a=24,tx_b=24,a_good=23,a_fcs=2,b_good=23,b_fcs=2,rm_drop=15,deliver=23,a_ic=2,b_ic=2,a_len=1,b_len=1,a_unk=1,b_unk=1,a_hdr=2,b_hdr=2,a_cfg=1,b_cfg=1 | 1/1 |
| delay | 15/18; 15/18 | accept=15,tx_a=15,tx_b=15,a_good=15,b_good=15,rm_drop=12,deliver=18; accept=15,tx_a=15,tx_b=15,a_good=15,b_good=15,rm_drop=12,deliver=18 | 1/1 |
| load | 787/194; 194/787 | accept=787,drop_nopage=98,tx_a=787,tx_b=787,a_good=194,b_good=194,rm_drop=194,deliver=194,drop_dis=1,drop_full=1,drop_long=1; accept=194,tx_a=194,tx_b=194,a_good=787,b_good=787,rm_drop=787,deliver=787 | 1/1 |
| cfg | 652/4; 4/652 | accept=652,tx_a=652,tx_b=652,a_good=4,b_good=4,rm_drop=4,deliver=4; a_good=652,deliver=652,accept=4,tx_a=4,tx_b=4,b_good=652,rm_drop=652 | 16/27 |
| reset | 16/7; 16/7 | accept=13,tx_a=13,tx_b=13,a_good=6,b_good=6,rm_drop=4,deliver=4,a_unk=3,b_unk=3; accept=15,tx_a=15,tx_b=15,a_good=9,a_unk=3,b_good=9,b_unk=3,rm_drop=6,deliver=6 | 1/1 |
| ovf | 6/3; 6/3 | accept=6,tx_a=6,tx_b=6,a_good=3,a_ovf=3,b_good=3,b_ovf=3,rm_drop=3,deliver=3; accept=6,tx_a=6,tx_b=6,a_good=3,a_ovf=3,b_good=3,b_ovf=3,rm_drop=3,deliver=3 | 1/1 |
| net | 4/4; 4/4 | accept=4,tx_a=4,tx_b=4,a_good=4,b_good=4,rm_drop=4,deliver=4; accept=4,tx_a=4,tx_b=4,a_good=3,a_fcs=1,b_good=4,rm_drop=3,deliver=4 | 1/1 |
## 5. 六种故障与计数器

| 故障/阶段 | 每个端系统对应计数增量（ES1=ES2） | 收下/交付（每端） |
|---|---|---|
| FCS/fcs | a_fcs+2,b_fcs+2 | 7/6 |
| A/B重复及同网重放/duplicate | rm_drop+1,a_ic+1,b_ic+1 | 1/1 |
| 乱序/reorder | a_ic+1,b_ic+1 | 6/6 |
| 超长/len | a_len+1,b_len+1 | 1/1 |
| 未知VL/unk | a_unk+1,b_unk+1 | 1/1 |
| IP及UDP校验和/ip_hdr+udp_hdr | a_hdr+2,b_hdr+2 | 2/2 |
附加覆盖：drop每端4/4交付；cfg每端a_cfg+1、b_cfg+1且2/2交付；ovf每端a_ovf+3、b_ovf+3且6条中交付3条；cfg原值重写tx/map/cfg=600/300/300次，最大等待16/27/27拍，三表均出现受阻。
## 6. 时延与抖动

单位为周期（×10ns）；每阶段写 W最大/均值、接收最大/均值、端到端最大/均值、W公式上限；—表示无前一帧不算W。接收硬上限15000，W硬上限=公式×4。均值保留2位。
| 测试 | 各阶段 W；接收；端到端；公式上限 |
|---|---|
| basic | basic: 4403/1147.00; 26/26.00; 28637/17521.81; 22280 |
| fault | cfg: —/—; 34/30.00; 13654/13649.75; 40912； drop: 37/34.88; 26/26.00; 13648/13645.88; 16304； duplicate: 37/35.50; 26/26.00; 13648/13646.50; 16304； fcs: 37/35.40; 26/26.00; 13648/13646.25; 16304； ip_hdr: 37/34.50; 26/26.00; 13648/13645.50; 16304； len: 37/34.50; 26/26.00; 13648/13645.50; 16304； reorder: 36/34.75; 26/26.00; 13647/13645.75; 16304； udp_hdr: 37/34.50; 26/26.00; 13648/13645.50; 16304； unk: 33/32.50; 26/26.00; 13644/13643.50; 16304 |
| delay | a_late: 38/34.17; 26/26.00; 13649/13645.17; 16304； b_late: 38/35.50; 26/26.00; 13649/13646.50; 16304； boundary_inside: 38/34.17; 26/26.00; 13649/13645.17; 16304； boundary_outside: 38/35.50; 26/26.00; 25937/19790.50; 16304； equal: 35/33.50; 26/26.00; 13648/13645.17; 16304 |
| load | all128: 71790/71790.00; 830/33.25; 110551/66744.14; 16304–1578912； all128_round2: 96728/52951.01; 830/33.25; 110331/66740.22; 16304–1578912； bidirectional: 32116/26367.93; 26/26.00; 319723/166540.54; 32160； drops: 44/0.98; 26/26.00; 4306164/2158176.84; 55680； sixteen153: 30880/26153.08; 27/26.01; 472141/245790.88; 32160 |
| cfg | pulse_reads: 34/24.71; 26/26.00; 13645/13643.50; 16304； registers: 35/33.50; 26/26.00; 13648/13645.17; 16304； rewrite: 37/0.17; 26/26.00; 23232/18424.07; 16304 |
| reset | reset: 35/33.80; 26/26.00; 13648/13644.64; 16304 |
| ovf | ovf: 39/34.83; 26/26.00; 13643/13640.50; 16304 |
| net | net: 0/0.00; 26/26.00; 15932/14790.50; 5048 |
全部w_over=0，无需LOOKAHEAD=128追加运行；硬上限均通过。delay界线内/外到达差唯一为2/3单位，两端接收either均0。系统记录篡改自检6/6检出（删D/重复D/交换D/计数/M周期/删抓包，各错1/1/3/1/29/12）；`out/selftest/t5_sys_final_20261008_141600/summary.json`。
## 7. 21 种故意改错

21/21检出，副本RTL与原件差异仅指定改错，原件未改。证据 `out/mut/results_20261008_141817_442643.json`、`results_20261008_141903_026777.json`，各项含完整运行目录与原始错误。
| 编号、改动、测试→检出项（每项均检出） | 同左 | 同左 | 同左 |
|---|---|---|---|
| K1 顶层 A/B 发送线路互换；basic→G5 network set message 0 | K2 顶层 A/B 接收线路互换；basic→H1 A e=102226 expected {'good'}, pulses=0 | K3 app_rx_port 误接源端口；basic→H4 delivery A e=102226 idx=0 | K4 应用发送源/目的端口互换；basic→G1/G4 frame fields message 4 net=A |
| K5 USER_ID 只连接低八位；basic→G1/G4 frame fields message 0 net=A | K6 tx_ready 仅看发送核心；basic→ES1 cycle=1032 combined initialization deadline | K7 接收 now_c 误取 now[26:11]；delay→H2 B e=545122 sn=9 expected={'rm_drop'} actual=deliver | K8 tx_cfg 外壳和总线均跳过 cfg_ok；cfg→RAMCOLL tx_cfg |
| K9 rx_map 外壳和总线均跳过 cfg_ok；cfg→RAMCOLL rx_map | K10 rx_cfg 外壳和总线均跳过 cfg_ok；cfg→RAMCOLL rx_cfg | K11 总线不等 cfg_ok 就清待写，外壳保持原样；cfg→运行中重写三表等待覆盖失败（全部等待1拍；四个核心CHECK通过） | K12 待写期间 cfg_ready 仍为一；cfg→ES1 cycle=85658 configuration ready after acceptance |
| K13 tx_cfg 地址最低位取反；cfg→G2 message 0: drop_dis, allowed=['accept'] free=256..256 queue=0..0 | K14 rx_map/rx_cfg 写使能互换；cfg→H2 A e=99914 sn=0 expected={'deliver'} actual=a_unk | K15 0x30000 地址段误映射到 rx_map；cfg→ES1 cycle=86096 configuration ready after acceptance | K16 读 a_fcs/a_len 计数器时互换；fault→ES1 cycle=557538 read data including E(t-1), excluding E(t) |
| K17 accept 计数器仅八位；load→ES1 cycle=1059908 read data including E(t-1), excluding E(t) | K18 统计计数器读后清零；cfg→ES1 cycle=207343 read data including E(t-1), excluding E(t) | K19 运行中复位不清统计计数器；reset→ES2 cycle=134227 read data including E(t-1), excluding E(t) | K20 cfg_rvalid 晚一拍；cfg→ES1 cycle=85963 read response exactly t+2 |
| K21 计数器读值漏掉前一拍的脉冲；cfg→ES1 cycle=207377 read data including E(t-1), excluding E(t) | — | — | — |
## 8. 综合与 100 MHz 时序

| 目标 | 逻辑单元/RAM切片；setup/hold ns | 最差setup起点→终点；目录 out/synth/ |
|---|---|---|
| AFDX_top | 14722/591; 5.187/-0.068 | c3_native_cell_1612\|ff/Q→c3_native_cell_3179\|ff/ena; AFDX_top/20261008_142400_223446 |
| afdx_tx_core | 5625/291; 5.719/-0.068（包装5806/291; 5.719/-0.068） | \afdx_ram_sdp:tx_payload\|memory:rtl_mem15786\|altsyncram_ak71:auto_gen0_1\|ram_block1a227\|port_b_address_dff[0]/Q→c3_native_cell_1085\|ff/D; afdx_tx_core/20261008_142549_722857；包装 probe_tx_core/20261008_142609_804263 |
| afdx_rx_core | 6575/300; 5.199/-0.068（包装6735/300; 5.199/-0.068） | c3_native_cell_527\|ff/Q→c3_native_cell_1566\|ff/D; afdx_rx_core/20261008_142629_769308；包装 probe_rx_core/20261008_142651_788368 |
## 9. 网表回归

7/7 PASS；以下目录相对 `out/net/`：tb_mac_tx:afdx_mac_tx RESULT=1703516/0 @ tb_mac_tx/20261008_142917_989005； tb_mac_rx:afdx_mac_rx RESULT=409817/0 @ tb_mac_rx/20261008_142938_139806； tb_mac_loop:afdx_timebase,afdx_mac_tx,afdx_mac_rx RESULT=7110567/0 @ tb_mac_loop/20261008_142947_321959； tb_probe_ram:probe_p1_2048x8 RESULT=4096/0 @ tb_probe_ram/20261008_143114_304057； tb_probe_ram:probe_p2_array RESULT=131072/0 @ tb_probe_ram/20261008_143119_813591； tb_tx_net:afdx_tx_core RESULT=249109/0 CHECK=240/0 @ tb_tx_net/20261008_143539_139003； tb_rx_net:afdx_rx_core RESULT=428774/0 CHECK=110/0 @ tb_rx_net/20261008_143957_558068。tx_net、rx_net各events及两网抓包共6/6与最终RTL逐字节相同；证据 `out/t5_preflight/final_acceptance.json`。
## 10. 未完成项与规格解释

T5全部完成。J4明确app_tx_ready直连m_ready，旧§7“不收消息”按主机须等tx_ready解释，ARCH已说明；RTL除授权J1/J5外无T2–T4缺陷修正。正常验收日志RAMCOLL=0，不包括故意错误K8–K10；未做T6布局布线、物理RAM块数确认及整个顶层网表仿真。时序仅未布线clk寄存器路径，未设置外部I/O延迟；hold −0.068ns未签核，留T6；未推送，未启动T6或恢复C_v2。
