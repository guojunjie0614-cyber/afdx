# 缺陷与环境问题

最终结果已收齐：RTL 66/67 PASS，`tb_sys_perf` 保持 FAIL；`tb_elinx` 与 `tb_net_services` 官方 VQM 完整版均 PASS，分片前缀为 PASS-PREFIX。本轮没有确认协议或功能设计缺陷；已知性能门槛差异及未覆盖网表范围单独保留。

环境/测试问题已单独保留：

1. 原始 56 项全部受 ModelSim 声明前引用编译错误影响；原始错误见 `out/t75/baseline_source/out/sim/*/*/compile.log`。使用仿真副本兼容，不改 RTL。
2. 本机 Python 3.12 与 psutil 5.9.0 的 disk_usage 组合抛出 `SystemError: argument 1 (impossible<bad format char>)`；发生时尚未启动仿真。已改用 Windows GetDiskFreeSpaceExW，保存最初控制器日志。
3. B 类映射入口读取整份 RTL 时，eLinx_synthesis 的 Verilog 前端不能处理 `afdx_tx_buf.v:115` 的 `$fatal`。各顶层映射失败记录保留，不把 A 类官方综合通过换算成 B 类通过，也不为此改 RTL。
4. 原 TX drop 平台接受一次只等待一帧，长消息合法分片后出现 drain timeout；参考模型 build_frame 同时拒绝 >1471 长度。这是旧测试口径；修正后相关 TX 用例已定向重跑，并在最终整表全部 PASS。
5. T65 的旧应用容量和输入记账拍次、RM fixture 的位置端口/数值状态码均已按新契约修正。13 项定向用例全部重跑 PASS，具体目录见调度汇总 indices 223..235；未修改设计或放弃断言。
6. 只读准入复核发现 max(全机原生进程数, 自有 worker 数) 在存在外部作业及自有编译/排队阶段时可能少算预留。最终工具已改为自有 worker 加外部槽位，13 个 ModelSim/eLinx 边界清单通过；实际运行期间未观察到超出 10 个 ModelSim 内核或 6 个 eLinx 的情形。修正未重启现有仿真。

## 仍保持 FAIL 的旧性能门槛

原始及最终整表的 `tb_sys_perf` 均为 FAIL。最终 HDL 683408635 项、四份 TX/RX 独立检查和 GMII 检查通过，旧系统性能子检查有 702 项失败（外部合计 1325290 项）。独立复核分为 692 项内部 M 完成时刻被当作固定公共注入时刻，10 项要求线上间隔抖动严格为零。最终性能指标字典以及公共输入/完成时戳与两端单网 GMII 的三份完整记录均与已诊断基线一致。

公共注入间隔均为 125000 拍；线上间隔为 125000 或 125001 拍，没有低于最小 BAG。最大正残差 8 ns 可复核，但不能被写成 R139 统计验收已通过。详见 `performance_difference.md` 与 `out/t75/performance_diagnostic.json`。

T75 将抖动统计留到另卡，本任务保留旧门槛和最终 FAIL。该差异不冒充已确认协议缺陷，也不被计为 PASS；其余正式运行的结果继续单列。

11-03 21:30 获批调整再次确认保留该 FAIL，新口径检查器由 T76 线 3 处理。分片前缀若匹配只记 PASS-PREFIX，完整 8192 字节及故障恢复 VQM 覆盖留待 T76；这些范围边界不属于已确认设计缺陷。

## 获批的分片截断结果

11-04 01:46 达到 A/B 各 6 帧、RX 4 条后，核对原内核 PID 33644、创建时间及专用控制台归属，发送该仿真自身的 CTRL-C 中断。其他 5 个内核在操作后仍保持原 PID/创建时间。事件缓冲随正常退出刷新，截止 199578 拍的 8 行事件得到保留。

A/B 各前 6 行、RX 前 4 行、全部 8 行发送记录及事件前缀，5 组共 32 行全部逐字节匹配显式配对 RTL，结果为 PASS-PREFIX，0 错误。原 GUI 包装器的非零退出是该获批截断的原始状态，保留为 raw FAIL；没有最终 HDL RESULT，也不借用 RTL 的 33 项检查数。证据见 prefix_result.json、prefix_stop.json；完整 8192 字节和故障恢复网表覆盖仍未验证。
