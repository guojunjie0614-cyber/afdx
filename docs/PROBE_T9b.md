# T9b 615A 配置与标准 SNTP 验收摘要

2026-10-08；起点9bf39aa7，explore/c3-20261007；22:15:35开始，22:51:55完成验证，用时36分20秒。
回归32/32 PASS；RESULT合计609233803项，CHECK合计1173041项，0错误、0警告，无RAMCOLL/GMIITX。
回归索引：`out/regress/rtl_20261008_224107_5444423/summary.json`；命令 `sim/regress.ps1 -Deadline 2026-10-09T00:15:35+08:00`。

| 615A配置字地址 | 规范与实际复位读值 | 测试设置 |
|---|---|---|
| B8 REQUEST_PORT | 59；615A §5.3.2.3.2 | 原五场景59；另一次完整上传1059 |
| B9 TIMEOUT_CYCLES | 250000000个125 MHz周期=2秒；附件4 §3.1 | 250000周期=2 ms |
| BA RETRY_LIMIT | 1；附件4 §3.2，初发之外允许重传1次 | 2；实际耗尽时重传2次、共3次尝试 |

615A：tb_sys_615a RESULT 16903、CHECK 265、0错误；复位后未写配置即读取上述三项，再验证配置读回和实际收发。
端口59下：1500字节、1536字节（空DATA4结束）、DATA2首发丢失恢复均成功；损坏时STATUS=0303，持续丢失时STATUS=0503；B7累计0、0、1、1、3。
端口1059下追加1500字节完整上传成功，双方初始请求均使用1059，B7仍为3；四次成功从配置总线读回共6036字节逐字节相同；用户流量双向各6条恰好交付。
证据：`out/sim/tb_sys_615a/20261008_224953_673564/`；upload.pcap的224帧标准TFTP解码通过（RRQ18、WRQ36、DATA65、ACK103、ERROR2）。
RTC：tb_sys_rtc RESULT 242197、CHECK 702、0错误；初始超前/落后、主从互换、跨秒、停止保持均通过；20次空载同步最大误差16 ns ≤40 ns。
双向用户流量各40条恰好交付，8次带负载同步最大误差39364 ns（记录，不设本卡门槛）；72组纳秒/小数向量双向转换均正确。
RTC证据：`out/sim/tb_sys_rtc/20261008_224856_455502/`的rtc_results.txt、两份GMII记录、check_summary.json、ntp_decode.json及sntp_exchange.pcap。
实际56个NTP报文、28对应回应：48字节，VN=4、请求mode3、回应mode4；Originate逐位等于请求Transmit；Receive/Transmit位置与二进制小数格式全部核对。
PCAP示例原始64位时间戳：请求Transmit=bc17c5ef33333401；回应Originate同值，Receive=bc17c5e90004ec2b，Transmit=bc17c5e90004f348；标准NTP结构读回通过。
实现选择：配置秒以2000-01-01 UTC为起点，线上加3155673600；新增afdx_ntp_fraction按32轮、每轮两拍换算，无乘除法器；原四时间戳算法、采样点、RTC寄存器地址保持。
主端stratum1、LOCL，Poll4、Precision−26、Root Delay/Dispersion为0；Reference Timestamp记录配置装入时刻。按卡保留原PERIOD复位1 ms、测试0.5 ms，不声称完整公网SNTP客户端行为。
综合：8 ns，29237逻辑单元、921 RAM切片，setup 2.749 ns ≥2.0；hold −0.068 ns仅记录；综合/时序0警告、0错误。
综合证据：`out/synth/AFDX_top/20261008_225014_430240/`的mapping.log、timing_summary.json；命令 `elinx/synth.ps1 -Top AFDX_top -Sta`，同上Deadline。
最终32份仿真及综合的输入摘要全部与当前源码一致；冻结模块、TASKS未改；ARCH仅改RTC、615A两节及版本说明，VERSION和已有期望同步为C3110000；未参考旧方案。
未跑布局布线、网表仿真（按卡）；未做故意改错试验。任务卡冲突：无。
完成后再考虑：公网SNTP客户端的轮询/超时策略；Wireshark外部打开抓包核对，沿用已有清单。
