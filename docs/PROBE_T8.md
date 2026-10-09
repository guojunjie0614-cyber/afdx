# T8 SNMP 验收摘要

2026-10-08；起点 `4aa8c4d1`，分支 `explore/c3-20261007`；开始19:43，完成20:37，约54分钟。
回归：原29项 + tb_sys_snmp，共30/30 PASS；RESULT合计 609207258 项、CHECK合计 1171862 项、0错误；仿真0警告、无RAMCOLL/GMIITX。
回归索引：`out/regress/rtl_20261008_202517_6189047/summary.json`（逐项数字及实际目录）；命令 `sim/regress.ps1 -Deadline 2026-10-08T22:13:17+08:00`。
SNMP：RESULT 36695、CHECK 902、0错误；114请求、112回应，v1/v2c各35次Get、v2c遍历35对象后endOfMibView，全部同拍配置值一致。
SNMP证据：`out/sim/tb_sys_snmp/20261008_203317_772160/` 中 simulation.log、snmp_results.txt、check_summary.json；后者保存每次查询的采样周期和值。
标准抓包：同目录 snmp_exchange.pcap 为实际GMII请求/回应2帧；pyasn1 0.4.8 BER读回v1 Get/A2、request-id=-1、sysDescr=C3 AFDX endpoint，FCS正确。
出错：community不符静默，BAD_COMMUNITY 0→1；未知对象v1 noSuchName(2,index1)，v2c noSuchObject；Set静默；GetNext末尾endOfMibView，均PASS。
配置与总线：public、c3manage、16字节community均通过；回应VL=2、UDP源161/目的为管理源端口；主机同址读合并、异址读优先、释放后代理独立读均通过。
用户流量：先双向各7条，管理期间继续各114条；每端发送/交付121/121，字节、顺序、元数据正确，无SNMP请求泄漏到代理应用口、无异常丢弃脉冲。
综合：8 ns，23261逻辑单元、873 RAM切片；setup裕量 3.147 ns ≥2.0，hold -0.068 ns（仅记录）；综合和时序0警告/错误。
综合证据：`out/synth/AFDX_top/20261008_202005_628624/` 的 mapping.log、timing_summary.json；命令 `elinx/synth.ps1 -Top AFDX_top -Sta`，同上Deadline。
实现选择：单变量绑定、请求≤256字节/OID≤16字节、单请求在途；默认停用、community 1–16字节；只读对象；私有根P=1.3.6.1.4.1.424242.3（演示号），细节在ARCH第8节。
对象表：S1/S3分别为1.3.6.1.2.1.1.1.0和1.3.6.1.2.1.1.3.0；数字k表示P.k.0；下列值依次为v1 / v2c的Get结果（不是同一次整体快照）。

| OID／对象 | v1 / v2c | OID／对象 | v1 / v2c |
|---|---|---|---|
| S1 sysDescr | C3 AFDX endpoint / C3 AFDX endpoint | 17 a_cfg | 0 / 0 |
| S3 sysUpTime | 1 / 1 | 18 a_ic | 0 / 0 |
| 1 version | 0xC3080000 / 0xC3080000 | 19 a_ovf | 0 / 0 |
| 2 USER_ID | 9029 / 9029 | 20 b_good | 51 / 121 |
| 3 rtc_seconds | 123 / 123 | 21 b_fcs | 0 / 0 |
| 4 rtc_sync_count | 0 / 0 | 22 b_len | 0 / 0 |
| 5 accept | 20 / 90 | 23 b_hdr | 0 / 0 |
| 6 drop_dis | 0 / 0 | 24 b_unk | 0 / 0 |
| 7 drop_full | 0 / 0 | 25 b_cfg | 0 / 0 |
| 8 drop_long | 0 / 0 | 26 b_ic | 0 / 0 |
| 9 drop_nopage | 0 / 0 | 27 b_ovf | 0 / 0 |
| 10 tx_a | 30 / 100 | 28 rm_drop | 67 / 137 |
| 11 tx_b | 32 / 102 | 29 deliver | 69 / 139 |
| 12 a_good | 35 / 105 | 30 a_gdrop | 0 / 0 |
| 13 a_fcs | 0 / 0 | 31 b_gdrop | 0 / 0 |
| 14 a_len | 0 / 0 | 32 snmp_requests | 34 / 69 |
| 15 a_hdr | 0 / 0 | 33 bad_community | 0 / 0 |
| 16 a_unk | 0 / 0 | — | — |

完成后再考虑：Set、Trap、GetBulk、多变量绑定；对外产品化时使用正式企业号。
未跑：布局布线、网表仿真（按卡留到T9）；未做故意改错试验。未发现规格冲突；冻结RTL与TASKS未动，ARCH只改第8节和版本说明；其他改动是回归接入及VERSION期望更新。
