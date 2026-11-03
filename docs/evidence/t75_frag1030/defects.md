# 缺陷与环境问题

当前没有已确认的协议或功能设计缺陷；完整回归和三项官方 VQM 仍在执行，不能据此宣称无缺陷。

环境/测试问题已单独保留：

1. 原始 56 项全部受 ModelSim 声明前引用编译错误影响；原始错误见 `out/t75/baseline_source/out/sim/*/*/compile.log`。使用仿真副本兼容，不改 RTL。
2. 本机 Python 3.12 与 psutil 5.9.0 的 disk_usage 组合抛出 `SystemError: argument 1 (impossible<bad format char>)`；发生时尚未启动仿真。已改用 Windows GetDiskFreeSpaceExW，保存最初控制器日志。
3. B 类映射入口读取整份 RTL 时，eLinx_synthesis 的 Verilog 前端不能处理 `afdx_tx_buf.v:115` 的 `$fatal`。各顶层映射失败记录保留，不把 A 类官方综合通过换算成 B 类通过，也不为此改 RTL。
4. 原 TX drop 平台接受一次只等待一帧，长消息合法分片后出现 drain timeout；参考模型 build_frame 同时拒绝 >1471 长度。这是旧测试口径，修正后须实际重跑。
