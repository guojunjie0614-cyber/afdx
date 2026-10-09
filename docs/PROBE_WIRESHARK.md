# Wireshark 外部抓包核对

T9b 历史核对（2026-10-08）：基线 `5bdd5de1`，分支 `explore/c3-20261007`；以下旧抓包来自 T9b 最后一次回归，T9c 新结果另列于文末。
安装：winget 1.29.380 的 `WiresharkFoundation.Wireshark --version 4.6.8 --source winget --architecture x64 --silent --skip-dependencies`；Wireshark/tshark 4.6.8（v4.6.8-0-ge677bf052328），[官方稳定版发布记录](https://www.wireshark.org/news/20260812.html)。
官方 MSI 哈希经 winget 核验、Authenticode 为 Valid/Wireshark Foundation；只选择 Wireshark、TShark 和必需组件，关闭文件关联及快捷方式；本次未安装、更新或启停原有 Npcap 1.60，驱动前后 SHA256 相同。
输出根目录 `$P='E:/2026_Embedded_FPGA/worktrees/active/c3/schemes/scheme_c3/out/wireshark/20261008_2256'`；安装命令参数、日志、版本、签名及 Npcap 前后证据均保存在这里。
来源：`out/regress/rtl_20261008_224107_5444423/summary.json` 的 tb_sys_snmp、tb_sys_snmp_settrap、tb_sys_615a、tb_sys_rtc；`$P/capture_sources.json` 列出各原始绝对路径与副本 SHA256，四份原始 PCAP 未改。
以下为 PowerShell 命令，公共参数：`$T='C:/Program Files/Wireshark/tshark.exe'; $O=@('-n','-2','-o','ip.check_checksum:TRUE','-o','udp.check_checksum:TRUE','-o','eth.check_fcs:TRUE','-o','eth.fcs:never')`。
Get：`& $T @O -r "$P/snmp_exchange.pcap" -V > "$P/snmp_exchange.verbose.txt"`；2帧 SNMPv1/public GetRequest/GetResponse，request-id=−1、error-status/index=0；OID `1.3.6.1.2.1.1.1.0`，回应 OCTET STRING=`C3 AFDX endpoint`。
Set/Trap：`& $T @O -r "$P/snmp_set_trap.pcap" -V > "$P/snmp_set_trap.verbose.txt"`；3帧：v1 SetRequest/GetResponse，request-id=501、OID `1.3.6.1.4.1.424242.3.2.0`、Gauge32=13398、noError；v2c Trap 至162，sysUpTime=1、snmpTrapOID=coldStart (`1.3.6.1.6.3.1.1.5.1`)。
TFTP 首次：`& $T @O -r "$P/upload.pcap" -d udp.port==59,tftp -d udp.port==1059,tftp -V > "$P/upload.verbose.txt"`；54 条 RRQ/WRQ 可识别，170 条动态端口报文仅显示 UDP/data。
TFTP 补充：`& $T @O -r "$P/upload.pcap" -d udp.port==59,tftp -d udp.port==1059,tftp -d udp.port==33024-33077,tftp -V > "$P/upload.all_tid.verbose.txt"`。
补充后 224 帧全部解为 TFTP：RRQ18、WRQ36、DATA65、ACK103、ERROR2；请求均 octet，文件含 DEMC3_1.LUI/LUR/LUS、DEM0001.LUH/LUP，DATA/ACK 块号及空 DATA4 可见；另自动解出 36 帧 A615A LUR/LUS（版本 A3）。
发现：仅指定服务端口不能自动关联动态 TID；实际两方向 IP 为 `10.0.0.2→224.0.0.2`、`10.0.0.3→224.0.0.3`。未改抓包、RTL 或测试，只追加显式 decode-as；不把成功解码当成完整 615A 符合性证明。
TFTP 专家警告 2 条：第147帧 ERROR code=0/`FAIL 3`，第183帧 ERROR code=0/`FAIL 5`；对应原测试故意损坏数据、持续丢包后重试耗尽。均非 malformed 或网络层校验错误。
RTC：`& $T @O -r "$P/sntp_exchange.pcap" -V > "$P/sntp_exchange.verbose.txt"`；2帧 NTPv4、UDP 123→123、48字节、LI=0，请求 mode3/stratum0，回应 mode4/stratum1、LOCL；UTC请求Transmit=2000-01-01 00:16:47.200000047，回应Origin同值、Receive=00:16:41.000075111、Transmit=00:16:41.000075535；超前来自原同步测试初始偏差。
长度（以太网不含 FCS/IP/UDP，字节范围）：Get 83–99/68–84/48–64；Set/Trap 89–109/74–94/54–74；TFTP 60–559/32–544/12–524；NTP 91/76/56；231 帧无截断，IP=20+UDP，以太网包含 C3 填充及末尾1字节 SN，全部一致。
231 个 IP 头校验均 Good；231 个 UDP 校验和均 `0x0000`，tshark 标为 Not present/zero-value ignored，不能称 UDP 校验通过；四份抓包 malformed=0、坏 IP 校验=0。
原PCAP不含FCS：按时间戳和完整以太网字节匹配原GMII文本，取原有4字节FCS保存 `$P/fcs_*.pcap`，没有重算；映射见 `*.fcs_sources.json`。命令同上，输入加 `fcs_` 前缀、改用 `eth.fcs:always`；231帧FCS均Good，malformed=0、坏校验=0，仍只有2条TFTP警告。
完整命令见 `$P/commands.json`、`tftp_all_tid_commands.json`；文本为 `*.verbose.txt`、`*.fields.tsv`、`*.expert.txt`，含 FCS 和 TID 补充结果；汇总为 `dissection_summary.json`、`tftp_all_tid_summary.json`、`layer_summary.txt`。
上述外部核对阶段仅提交本文；没有修改实现或做实时网卡捕获。历史限制为动态TID需显式解码、UDP未提供校验。
615A 字段补充（同一 `upload.pcap`，未修改）：原生 a615a 识别 LUR 6/6、LUS 30/30，LUI 0/6；不是三类全部识别通过。
命令仍用上述三组 TFTP decode-as，另以 `-T fields -E occurrence=a` 提取 `a615a.type/file_length/protocol_version/status_code/counter/load_ratio/file_count/file_name/part_number/status`（完整 `-e` 参数见 `$P/a615a_commands.json`）。
LUR：均为 A3、文件长38、file_count=1，头文件名 `DEM0001.LUH`、件号 `DEM4C-0001-0001`，与6份实际发送载荷及 `vectors/0_lur.bin` 至 `5_lur.bin` 相同；LUR 不含状态码、counter、load ratio。
LUS：均为 A3，每场 counter=1,2,3,4,5；第一份 file_count=0，随后均为1且头文件名/件号同 LUR；总状态依次为 1,2,2,2，末项成功时3、失败时4099 (`0x1003`)；文件状态为2，末项成功时3、失败时4103 (`0x1007`)。
LUS 总/文件 load ratio（文件存在时两者相同）：场景0/2/5为0,0,0,34,100；场景1为0,0,0,33,100；场景3为0,0,0,34,99；场景4为0,0,0,34,34。失败末项描述分别 `FAIL 3`、`FAIL 5`，均与原发送记录相符。
LUI：第2/39/78/116/153/189帧仍为 TFTP DATA/data，TFTP 文件名和全部 a615a 字段为空；原始文件字节均 `000000094133000100`，自行读得长度9、A3、状态1、描述长度0，与原发送记录相同，但这不是 tshark 的 LUI 字段解码结果。
原因判断：LUI 应答的 AFDX 组播 IP 对不能反向匹配 RRQ 会话，导致文件名未传到子解析器；[4.6.8 TFTP源码](https://github.com/wireshark/wireshark/blob/v4.6.8/epan/dissectors/packet-tftp.c)按IP/端口关联，[a615a源码](https://github.com/wireshark/wireshark/blob/v4.6.8/epan/dissectors/packet-arinc615a.c#L340-L359)在文件名为空时直接拒识；未重写抓包地址、插入请求或修改解析器来获得通过。
比对：以本次 T9b 的 `load_results.txt`、`check_summary.json` 和已存 LUR 向量为依据，318项 a615a 字段与48项载荷/原记录核对，0差异；LUI未识别单独记录，malformed=0，未改 RTL 或测试。
补充证据：`$P/a615a.fields.tsv`、`a615a.verbose.txt`、`a615a_comparison.json`、`a615a_commands.json`；复现 `E:/anaconda3/python.exe -B -X utf8 "$P/a615a_compare.py"`，只读取原记录并将输出写入 `$P`。
T9c A4追加：`$Q='E:/2026_Embedded_FPGA/worktrees/active/c3/schemes/scheme_c3/out/wireshark/t9c_20261008_2327'`；`$Q/upload_A4.pcap` 是最终回归 `out/sim/tb_sys_615a/20261008_234539_474211/upload_A4.pcap` 的原样副本，一次完整上传37帧；来源及SHA256在 `a4_summary.json`。
命令：`& $T @O -r "$Q/upload_A4.pcap" -d udp.port==59,tftp -d udp.port==33024-33032,tftp -V > "$Q/a4.verbose.txt"`；全部字段、FCS及专家命令见 `a4_commands.json`，文本为 `a4*.verbose.txt`、`a4*.fields.tsv`、`a4*.expert.txt`。
原生a615a识别LUI=1、LUR=1、LUS=5，七份版本全为A4；LUI长9/状态1，LUR长38/头文件数1/DEM0001.LUH/DEM4C-0001-0001，LUS counter=1..5、状态1/2/2/2/3、比例0/0/0/34/100；与实际发送记录19项核对，0差异。
37帧IP校验Good；从对应GMII帧原样取回FCS的 `upload_A4_with_fcs.pcap` 亦37帧Good；UDP全部0/Not present，malformed=0、ERROR/OACK=0。专家信息只有37条IPv4 TTL=1 Notes（ARCH固定TTL=1），未掩盖或修改。
T9c测试将615A服务VL配置为10.0.0.2↔10.0.0.3单播，使LUI反向会话及文件名关联成立；本次实际GMII抓包中LUI已识别，未重写PCAP地址或插入请求。此前T9b组播抓包的LUI未识别结论保留。
