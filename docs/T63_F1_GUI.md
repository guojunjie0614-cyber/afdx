# F1 界面复跑步骤

在 eLinx 3.0.7 中按以下步骤复跑。当前完成的是 CLI 验证与界面入口静态核对，真实 GUI 仍待用户验证。

1. 在 `E:/2026_Embedded_FPGA/worktrees/active/c3_t63` 打开 `elinx/AFDX_EndSystem.epr`。顶层 `AFDX_top`，器件 `EQ6HL130/CSG484_H`，源文件只登记 `afdx_all.v`。约束集为 `physical_only.edc`、`timing_only.sdc`，目标约束为前者。
2. 执行 **Run Synthesis**，成功后执行 **Run Implementation**，保留 `elinx/AFDX_EndSystem.runs/synth_1/`、`imple_1/` 全部产物。遇到许可或工具错误就保留日志、停止该项，不改系统设置。
3. 查看两目录新生成的 `AFDX_EndSystem.run.psf`：`source` 读取物理 EDC，目标约束指向该 EDC；`read_sdc` 只读取 `timing_only.sdc`。双文件拼接与完整 `constraints.edc` 一致；PRES、管脚和簇位置不得送入 SDC 解析器。CLI 副本可 `source` 完整 EDC，再 `read_sdc` 纯 SDC。
4. 核对日志：`clk` 为 125 MHz / 8.000 ns，setup uncertainty 0.30 ns，多周期 setup 2 / hold 1，PRES 1.30；无 `invalid-command`、SDC 解析错误、`[ERROR]` / `[CRIT]`。控制台未落盘时，保存到 `out/t63/gui_console.log`；比对报告的 trace 字段只记录日志中实际找到的标记，不能代替此步。
5. 在工作区根目录的 PowerShell 执行只读比对，脚本只新建 JSON 报告：

   ```powershell
   & 'E:/anaconda3/python.exe' -B -X utf8 tools/t63_verify_gui.py
   # 如需同时读取保存的控制台日志：
   & 'E:/anaconda3/python.exe' -B -X utf8 tools/t63_verify_gui.py --console-log out/t63/gui_console.log
   ```

   产物在别处时追加 `--runs-dir <AFDX_EndSystem.runs路径>`。基线为 `docs/evidence/t63_f1_final.json`；报告在 `out/t63/gui_compare/`。全部匹配时打印 `T63 F1 ARTIFACT COMPARISON PASS`、退出码 0；失败报告列出检查项及不一致的端口或簇。

| 核对对象 | F1 应有结果 |
|---|---|
| 原始精度 setup / hold 最差余量 | +16 / +229 ps（+0.016 / +0.229 ns） |
| setup / hold 失败端点 | 0 / 0；各 53,882 个端点 |
| P0 管脚落点 | 172/172 与批准管脚号及坐标一致 |
| 固定簇落点 | 5,540/5,540 与批准位置一致（5,136 CLB + 404 M4K） |
| `.place` | SHA-256 与 CLI 冻结结果完全相同 |
| 官方综合资源 | LUT 39,895、FF 20,885、CLB 5,136、M4K 404、管脚 172 |
| 网表和约束 | 除 VQM 导出日期与 wire 声明顺序外，映射电路与 CLI 一致；批准约束不变 |

固定布局来自 C0 加局部手工微调；改 RTL 会使布局失效。用户完成实际 GUI 操作及上述核对前，界面状态保持“待用户验证”；脚本的 CLI 自检不证明 GUI 已运行。
