# T8b Set 和 Trap 验收摘要

2026-10-08；起点3b4c3882，explore/c3-20261007；20:40开始，21:10完成，约30分钟。
回归：31/31 PASS；RESULT合计609216737项，CHECK合计1172074项，0错误；仿真0警告，无RAMCOLL/GMIITX。
回归索引：`out/regress/rtl_20261008_205748_2362307/summary.json`；命令 `sim/regress.ps1 -Deadline 2026-10-08T22:40:42+08:00`。
Set/Trap：tb_sys_snmp_settrap RESULT 8563、CHECK 188、0错误；22请求、18回应、2 Trap。
证据：`out/sim/tb_sys_snmp_settrap/20261008_210612_109326/` 的simulation.log、snmp_results.txt、check_summary.json、manager_gmii.txt、agent_gmii.txt。

| 检查 | v1 | v2c |
|---|---|---|
| Set USER_ID后回应、Get、配置读 | 0x3456 / 0x3456 / 0x3456 | 0xABCD / 0xABCD / 0xABCD |
| 写只读或不存在对象 | noSuchName=2，index=1，值不变 | notWritable=17，index=1，值不变 |
| 错误类型（OCTET STRING） | badValue=3，index=1，值不变 | wrongType=7，index=1，值不变 |

Trap：启用代理时coldStart和community不符时authenticationFailure各1条，均为v2c A7、UDP161→162、TX_VL=2，sysUpTime=1（10 ms单位）。
首两绑定依次为sysUpTime.0和snmpTrapOID.0；通知OID分别1.3.6.1.6.3.1.1.5.1、1.3.6.1.6.3.1.1.5.5；关Trap时启用及认证失败均不发送，末尾再等100000周期无重发。
已发Trap计数0→1→2，P.34.0（P=1.3.6.1.4.1.424242.3）经v1/v2c Get及配置0x9C均读到2；四次坏community无回应，计数到4，其中Set未改变USER_ID。
PCAP：上述目录snmp_set_trap.pcap的3帧为实际GMII Set请求、匹配回应和coldStart；去前导/FCS后写PCAP再读回，pyasn1 0.4.8标准BER解码PASS。
用户消息：双向各29条发送、各29条恰好交付一次，数据和元数据正确，无异常丢弃；SNMP请求未泄漏到代理应用口。
Get/GetNext：tb_sys_snmp RESULT 37611、CHECK 926、0错误；36对象v1/v2c逐项查值、36项完整遍历及末尾异常通过；`out/sim/tb_sys_snmp/20261008_210548_317458`。
综合：8 ns，23903逻辑单元、873 RAM切片，setup 2.749 ns ≥2.0；hold -0.068 ns仅记录，综合/时序0警告和错误。
综合证据：`out/synth/AFDX_top/20261008_205433_900666/` 的mapping.log、timing_summary.json；命令 `elinx/synth.ps1 -Top AFDX_top -Sta`，同上Deadline。
自行确定：同一community授权读写；仅USER_ID可写、Gauge32范围0–65535；只发v2c Trap，共用配置的回应VL，request-id=0；每种事件一个挂起位，按单请求在途约定处理。
旧方案参考问题：没有。已核对T5起本对话及三名参与T5/T6的子助手工具调用记录，未打开A、B、C_v2、D目录内的设计、代码、测试文件作参考；只沿用T1已复制在C3内的工具脚本。本卡也未打开旧方案目录。
范围：冻结RTL、TASKS未动；ARCH升v0.9，仅改第8节和版本说明；原SNMP测试的公共端点移到tb/lib复用，VERSION期望同步更新。
未跑：布局布线、网表仿真（按卡）；未做故意改错试验。规格冲突：无。
完成后再考虑：GetBulk、多变量绑定、正式企业号；v1 Trap本卡不实现。
