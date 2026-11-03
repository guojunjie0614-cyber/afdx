# T76 官方 VQM 复现

此入口沿用 eLinx Run Post-Implementation Simulation 的网表仿真方式：把实现仿真使用的 `.vo` 改为 `synth_1/AFDX_EndSystem.vqm`。当前复用 T75 原始 VQM，SHA-256 为 `3cd8f5f8456c9881d083fe67dd7a60ed9c6779909ee1cb10dbf9367dc9729b6e`。候选 VQM 的功能图仅重编号，但原锁定下的试布线失败；RTL 已恢复，未替换这份基准。

1. 设置任务卡环境，工作目录为 `E:/2026_Embedded_FPGA/worktrees/active/c3_t76`。`AFDX_PYTHON` 指向 `E:/anaconda3/python.exe`；`MODELSIM_HOME` 指向 `E:/Verilog/ModelSim/setup_pack/win64`；`ELINX_HOME` 指向 `E:/2026_Embedded_FPGA/setup_pack`。保留 CE_DIV=2 和 3 GiB 运行内存底线；启动前仍需 4 GiB 空闲内存和 E 盘 20 GiB 空间。
2. `sim/t76_net_jobs.json` 定义 TX/RX 窗口和各自 RTL 参考（另保留已通过的单 VL RTL smoke），`tools/par_regress.py` 以明确的作业清单执行。生成后的每个输出目录保存 `inputs/`、原始 VQM 哈希、`adaptation` 审计、编译日志、公开端口捕获、PID/创建时刻/截止、工具耗时和工作集峰值。
3. TX/RX 官方入口实际调用 `sim/run_t76_post_synth.do PREPARED_RUN_FOLDER`；`official_inputs.tcl` 明确列出替换后的 `.vqm`、完整厂商模型和测试台源文件。它运行独立批处理 `vlog` / `vsim`，保留 `.vo` 到 `.vqm` 的替换关系，规避本机 vish/vsim RPC 连接限制。没有通过实际短入口时，不得称该步骤已通过。
4. VQM 的仿真副本用既有 `tools/adapt_gui_vqm.py` 补齐厂商单元默认输入、进位使用标记，并保留不被厂商模型识别的来源属性到审计中。原 VQM、LUT 内容及既有连线不变。这是 T75 已用的模型适配，不将适配副本称为原始网表。
5. 接收端只需 RTL 时，把同一份 `rtl/AFDX_top.v` 的模块名改为 `AFDX_top_rtl` 后编译；RTL 依赖模块不变。接收方向的窗口交换两端实例选择，让接收端为唯一 VQM。每个 VQM 必须逐字节等于同参数 RTL 参考的十一份外部记录，且复位、初始化和配置完成后 90 位公开输出全部无 X/Z。

未跳过 MAC 或 RAM 初始化，也未在提交 RTL 中加入仿真捷径。原因是主要初始化开销包含 65536 项 RX 映射清零；强制完成标志会引入未初始化 RAM，不能视为等价初始化。测试台取消额外等待，配置模块在公开 ready 后立即工作。正常初始化仍计入实际耗时；每个窗口以 24 小时为硬上限，不预称四小时目标已达到。

两个满负载窗口输入时间长 125001 拍，超过 1 ms；均配置 81 VL，80 条为最大单帧载荷，另一条为 1472 字节两帧长消息。每条普通 VL 注入两次，可观察 BAG；长消息按两次 BAG 发送机会计费。为等到所有已接受消息交付，实际仿真还包含必要尾部排空。8192 字节不在新 VQM 窗口重复，留给 RTL 混合场景。原 81 VL 混合场景的 RX 溢出保持 FAIL；独立声明的 63 VL 混合场景已完成 100 ms 及三种长消息逐字节验证，见 mixed_search.json。

重新复现已准备的短入口时，在 ModelSim 执行：

```tcl
do E:/2026_Embedded_FPGA/worktrees/active/c3_t76/sim/run_t76_post_synth.do PREPARED_RUN_FOLDER
```

`PREPARED_RUN_FOLDER` 必须取实际 VQM 队列中相应作业的 `Folder`，不能使用示例占位目录。最终状态以 `netlist_queue.json`、实际运行的 `summary.json` 和外部记录逐字节比对结果为准；RTL 参考通过不等于 VQM 已通过。

后续优先级覆盖：未启动的单 VL VQM smoke 已合并进 TX/RX 正式 .do 入口，避免重复初始化；两个窗口均使用旧 VQM。TX 于 11-03 23:02:01 启动，RX 在 T75 首次释放核后于 23:07:02 优先启动。T76 自身网表上限为三，全机 ModelSim≤10、实际计算核≤6；官方 .do 等待子进程的宿主占进程槽位、不重复计作计算核。挂起的 RTL 内核保留原 PID/截止并原地恢复。兼容候选试布线已失败并恢复旧 RTL，不重启这些窗口。
