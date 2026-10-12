# T25b：结果汇总包含最后一次检查

- 原因已复现：子模块计数已增加，但输出端口连线要稍后更新；原版默认为9238项，`-voptargs=+acc`为9234项。
- 三个评委测试在正常结束和超时输出前等待1 ns，再读取全部计数；只改测试的结果汇总，不改RTL或激励。
- `tb_net_services`也有最后一次配置读回检查未计入的问题：`+acc`修前1122项、修后1123项；`tb_rm_phase`在完成标记后等计数稳定再汇总。
- 另修六处系统/共用测试的超时输出。615A、RTC、两个SNMP测试的正常汇总前已等下降沿，`sys_suite`已等2 ns，RAM测试最后计数早于完成标记；其余结果使用本地计数。
- 三个测试各跑默认和`+acc`：`tb_elinx`均9238项、容量均49924项、SNMP均699项，六次全部PASS。
- 临时副本把最后一项改错：原版`+acc`仍误报PASS、errors=0；修后为FAIL、checks=9238、errors=1。
- 三个超时分支另做同拍故意报错的副本测试，`+acc`均输出FAIL、checks=1、errors=2，包含注入错误和超时错误。
- 完整回归38/38通过，自检合计1183249131项，独立核对2305780项；未重新综合或运行网表。
- 纯ModelSim评委入口在无Python的PATH下7/7通过，耗时627.787秒；README列出的检查数均一致，吞吐906.136 Mbps、时延24.408 µs、抖动0、RTC误差0/10788 ns不变。
- `.gitignore`忽略`/elinx/*.sim/`；README记录已收到的界面实测通过结论，并说明Finish Vsim选“否”保留窗口。
- RTL、界面保存的`.epr`和收到的任务卡均经逐字节核对；保留`.epr`未提交改动，不推送。
- 证据均在`out/t25b/`：`before.json`、`after.json`、`port_audit.json`、`timeouts.json`、`validation.json`；复现脚本为`focused.py`、`port_audit.py`、`timeout_probe.py`及标准回归/评委入口。
