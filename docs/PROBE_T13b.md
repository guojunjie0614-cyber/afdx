# 组播地址与615A不支持操作验收摘要

2026-10-09；起点 `2ecdc8f`，分支 `explore/c3-20261007`；10:34:10开始，12:04:10硬截止，验证在限时内收齐。
组播：按664P7图3-38把系统用户/服务VL及故障注入向量的目的IP改为 `0xE0E00000 | VLID`；SNMP、RTC、tb_net_services及ModelSim公开向量同步。615A服务仍为10.0.0.2/10.0.0.3单播；发送核心未改。
实际GMII核对54份记录：7152个组播帧记录均为224.224加帧内VLID，786个单播帧记录保留，0错误；独立ModelSim的IC向量为VLID101/224.224.0.101。证据 `out/t13b/multicast_summary.json`。
不支持操作：Supplement 2第6.4.1节四种初始化文件中，LUI/LND接受，LCI/LNO以对应初始化文件拒绝；新TID、DATA1、长度9、配置版本、状态1002、空描述、ACK1；不启动后续操作，不改变状态、字节数或重发缓冲。
新测试在A4和A3下各读LCI/LNO：四次均为RRQ/DATA1/ACK1，无TFTP ERROR或后续状态传输；独立CHECK 25项，0错误。最终615A RESULT 44098、CHECK 752，原9上传/6卸载/2忙时场景全部通过。
615A证据：`out/sim/tb_sys_615a/20261009_105732_524133/` 的simulation.log、unsupported_results.txt、unsupported_check.json及原生PCAP。
Wireshark 4.6.8：unsupported.pcap 12帧，LCI显示Load Configuration Initialization、LNO显示Load Downloading Operator，各2份；A4/A3各2份，版本/长度/状态均正确，status_code=4098（0x1002），19项核对0差异、malformed=0、IP校验全Good。
外部命令与文本：`out/wireshark/t13b_final_unsupported/` 的commands.json、fields.tsv、verbose.txt、comparison.json；另核对最终download.pcap的LND6/LNR6/LNS22，237项0差异、0 malformed，证据 `out/wireshark/t13b_final_download/`。UDP校验为0，TTL=1仅Note。
全RTL回归32/32 PASS，RESULT合计802094926、CHECK合计1184328，编译/仿真0错误/0警告、检查器0错误；`sim/regress.ps1 -Deadline 2026-10-09T12:04:10.147061+08:00`，证据 `out/regress/rtl_20261009_104709_9929290/summary.json`。
双端五功能含加载后16字节卸载：`tb_net_services` RESULT1973/CHECK59、0错误，证据 `out/sim/tb_net_services/20261009_105813_229177/`；`sim/run_services.do`独立ModelSim PASS1972、0错误/0警告，证据 `out/t13b/modelsim_entry/20261009_105820_908869/summary.json`。
脚本综合：`elinx/synth.ps1 -Top AFDX_top -Sta`，30022逻辑单元、921未装箱RAM切片，8ns setup 2.749ns；证据 `out/synth/AFDX_top/20261009_104526_183307/`。
图形工程流程命令行复现（工程副本、Speed）：LUT34611、FF14230、装箱Memory601、IO259，8ns setup 2.522ns；证据 `out/project_synth/T13b/20261009_104116_617817/summary.json`。两条setup均≥2.0ns，未布局hold均−0.068ns。
1387份回归/专项/两条综合输入哈希记录与当前源码一致，ModelSim入口另核对全部输入未变；汇总 `out/t13b/acceptance.json`。ARCH仅改第3、15节；除afdx_615a外全部RTL未变。
TASKS、设计文档、测试报告、SUBMIT_README、out/submit共582个文件哈希未变；用户图形程序保存的EPR注释/OutOfDate元数据保留且不提交。未看旧方案，未删除，未推送，未重跑网表或布局布线。
规格疑问：无。完成后再考虑：信息操作及操作员定义卸载的实际传输、FIND、WAIT、ABORT、整文件重试；本卡只补初始化1002拒绝。
