# 615A 介质定义卸载验收摘要

2026-10-09；分支 `explore/c3-20261007`，起点 `0f37e396`；09:10:32开工，硬截止12:10:32，验证在限时内收齐。
依据：615A Supplement 2第6.3.4、6.4.1、6.4.6节；对照Thomas Vogt实现 `7b806af231cab992b07edfa42e18250d32da18d5` 的下载请求/状态文件，字段相符；只读参考，未复制代码。
实现选择：最近一次成功上传的字节作为一个 `MEMORY.BIN` 文件；开始新上传撤销旧有效长度，卸载只读现有8192字节RAM，不改变LOADED_BYTES。
实际流程：RRQ LND → DATA1/ACK1 → 初始LNS → WRQ LNR/DATA1/ACK1 → LNS0002 → WRQ MEMORY.BIN/ACK0 → DATA/ACK → LNS0003/ACK1；沿用端口、超时、重试和A3/A4配置。
正常用例：A4的1500字节、1536字节、一次ACK2丢失，以及A3的1500字节，四次成功卸载共6036字节，逐字节等于先前加载的原文件；1536字节以空DATA4结束。
失败用例：不存在的ABSENT.BIN（端口1059）无数据WRQ，STATUS=0x0103；A3持续丢ACK2重试2次，加载端已收到1024字节，STATUS=0x0503；最终均为LNS1003、文件状态1007。
忙时用例：上传中读LND、卸载中读LUI均返回初始化状态1000及BUSY描述；原传输随后成功，主TID和重发缓冲保持。
615A专项最终RESULT 44014、CHECK 727（卸载285），0错误；9个上传场景、6个卸载场景、2个忙时拒绝；上传成功内容从配置总线读回9036字节相同，双向用户各8条。
专项证据：`out/sim/tb_sys_615a/20261009_103118_000622/` 的simulation.log、check_summary.json、download_results.txt、download_check.json和原生抓包。
全RTL回归32/32 PASS，RESULT合计802094842、CHECK合计1184303；全部编译/仿真无错误或警告，全部检查器0错误。
回归入口：`sim/regress.ps1 -Deadline 2026-10-09T12:10:32+08:00`；证据 `out/regress/rtl_20261009_102026_8916736/summary.json`。
双端五功能含16字节先加载再卸载：RESULT 1973、CHECK 59，0错误；`sim/run.ps1 -Test tb_net_services`，证据 `out/sim/tb_net_services/20261009_103157_735170/`。
ModelSim独立入口：`vsim -c -do "do sim/run_services.do"`，PASS 1972 checks、0错误/0警告；证据 `out/t13/modelsim_entry/20261009_103217_521089/summary.json`，输出 `out/modelsim/20261009_103218_42248/`。
脚本综合：`elinx/synth.ps1 -Top AFDX_top -Sta`，30012逻辑单元、921未装箱RAM切片，8ns setup 2.749ns；证据 `out/synth/AFDX_top/20261009_101835_826664/`。
图形工程流程命令行复现（工程副本、Speed）：LUT 34420、FF 14228、装箱Memory 601、IO 259，8ns setup 2.532ns；证据 `out/project_synth/T13/20261009_101343_333971/summary.json`。
工程时序修正：615A头指针范围检查结果先寄存一位，下一拍选择成功/失败；判定和字段不变，内部多1拍。两条流程setup均≥2.0ns，hold均为−0.068ns，仅为未布局估算。
Wireshark 4.6.8：最终回归原样download.pcap共177帧，a615a识别LND 6/LNR 6/LNS 22（另含忙时LUI 1），A4 23/A3 12；237项字段核对0差异，malformed=0，177个IP校验Good。
外部字段包括版本、文件长度、状态、counter、ratio、文件数/名称；UDP校验为0，TTL=1仅Note，TFTP ERROR只在指定失败场景。证据 `out/wireshark/t13_final_20261009_1032/` 的commands.json、fields.tsv、verbose.txt、comparison.json。
回归/专项/两条综合的1386份输入哈希记录与当前源码一致；ModelSim独立入口另核对全部输入未变；汇总 `out/t13/acceptance.json`。
TASKS、设计文档、测试报告、SUBMIT_README及out/submit共582个受保护文件哈希未变；ARCH仅更新第15节；收发核心、GMII适配器、SNMP、RTC、timebase和公共RAM未改。
用户图形界面保存的EPR注释/OutOfDate元数据变更保留在工作区，不纳入本卡提交。未打开旧方案目录；未删除、未推送。
未跑：综合网表仿真（本卡要求不重跑）、布局布线、硬件测试。规格疑问：无。
完成后再考虑：操作员定义卸载LNO/LNL/LNA；信息操作、FIND及第3版可选TFTP选项协商仍未实现。
