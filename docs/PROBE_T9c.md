# T9c A4 协议版本与选项兼容验收摘要

2026-10-08；起点 `4b2a71e3`，分支 `explore/c3-20261007`；23:27:06开始，23:51:13验证收齐，用时24分7秒，未超90分钟。
依据：第2版原文与 [arinc-615a](https://git.thomas-vogt.de/avionics/arinc-615a) 提交 `7b806af231cab992b07edfa42e18250d32da18d5`（MPL 2.0）；第3/4版原文未取得，不声称已核读。
参考库只克隆到 `out/reference/arinc615a_t9c_20261008_2327` 阅读版本、协议文件和TFTP选项定义，没有复制其代码；第3/4版共用A4，LUI/LUR/LUS字段沿用第2版格式。
实现选择：字地址0xBB PROTOCOL_VERSION，低16位ASCII，复位0x4134（A4）；可写0x4133（A3），其他值或进行中写入忽略；LUI/LUS取配置版本，LUR独立接受A3或A4。
RRQ/WRQ忽略mode终止NUL后的所有RFC 2347选项；不回OACK，仍回DATA1/ACK0，用512字节块和REQUEST_PORT；现有解析路径已可忽略尾部，增加明确注释与实际选项测试。
专项首跑：`sim/run.ps1 -Test tb_sys_615a -Deadline 2026-10-09T00:57:06+08:00`，9场景PASS，RESULT 24757、CHECK 442、0错误；证据 `out/sim/tb_sys_615a/20261008_233443_588661/`。
场景0：复位A4且RRQ/WRQ均带blksize=1024、port=5555，仍以512字节块完整加载1500字节，端口59，未出现OACK。
场景1–4：1536字节空DATA4结束、首发丢包恢复、数据损坏、持续丢包重试耗尽；原期望均通过。
场景5–7：A4目标/A3 LUR（端口1059）、A3目标/A4 LUR、A3目标/A3 LUR，均完整加载1500字节；版本读回、非法配置写和忙时写保护通过。
场景8：A4目标收到A5 LUR，沿原元数据不支持路径拒绝，STATUS=0x0103、TFTP ERROR1/FAIL 1、最终LUS1003；无头/数据RRQ、LOADED_BYTES=0，只有初始及失败两份LUS。
最终615A回归同为RESULT 24757、CHECK 442、0错误；全部抓包314帧，六次成功从配置总线读回9036字节逐字节相同，并发用户流量双向各8条恰好交付；证据 `out/sim/tb_sys_615a/20261008_234539_474211/`。
全回归32/32 PASS，RESULT合计609241657项，CHECK合计1173218项，仿真0错误/0致命错误/0警告；入口 `sim/regress.ps1 -Deadline 2026-10-09T00:57:06+08:00`，证据 `out/regress/rtl_20261008_233621_3907953/summary.json`。
综合：8ns，29267逻辑单元、921 RAM切片，未布局setup裕量2.749ns ≥2.0ns；hold −0.068ns仅记录。综合/时序0警告、0错误；未作为布线后时序签核。
综合命令：`elinx/synth.ps1 -Top AFDX_top -Sta -Deadline 2026-10-09T00:57:06+08:00`；证据 `out/synth/AFDX_top/20261008_234703_327559/` 的mapping.log、timing_summary.json。
Wireshark 4.6.8：最终回归的一次A4上传37帧，原生a615a识别LUI1/LUR1/LUS5且版本均A4，19项字段比对0差异，IP/FCS均Good、malformed=0；UDP校验未提供，有37条固定TTL=1 Notes，ERROR/OACK=0。
外部证据：`out/wireshark/t9c_20261008_2327/` 的原样PCAP、a4_summary.json和tshark文本，命令/字段详见 `PROBE_WIRESHARK.md`；LUI状态1、LUS counter1..5及末项状态3、比例100与发送值一致。
测试选择：615A服务VL配置双方单播IP，给原生TFTP解析器提供正确的反向会话；实际GMII抓包地址未重写，用户流量保留原配置。
ARCH只修改第15节；芯片VERSION保持0xC3110000，本卡配置改变的是615A协议文件版本。冻结模块、TASKS及旧方案目录未改，未参考旧方案。
最终32次回归及本次综合记录的输入摘要均与当前源码一致，0处不符；汇总 `out/t9c_acceptance.json`。任务要求冲突：无。
未运行布局布线、网表仿真或硬件测试（本卡未要求）；未做故意改错试验。
完成后再考虑：第3版新增可选port、part number、checksum选项的协商及语义；本卡均未实现，状态码0004未使用。
