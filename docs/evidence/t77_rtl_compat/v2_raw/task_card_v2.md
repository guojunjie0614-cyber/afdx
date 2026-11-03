# T77：让原样 RTL 能在 ModelSim 下编译，同时官方综合出的 VQM 不变

## v2 修订（11-04 00:45，覆盖下文 v1 中的验收和步骤 1、4）

v1 发现：**原样源码重新综合，VQM 就和基准不同**（2,729 行位置不同，首处是 RAM 译码节点声明的排列顺序）。说明 `quartus_map` 的输出顺序本身不确定，逐字节比对 VQM 这个门槛做不到。T76 试布线失败也未必是源码修改造成的。交付的时序是绑定在基准 VQM（`3cd8f5f8…`）这一份文件上的，不靠重新综合复现。

因此 v2 改为证明“综合工具读到的源码文本没有变”，不再比 VQM 字节：

1. 按“目标与思路”第 1 种做法（`ifdef MODEL_TECH` 分支）改全部 21 处。v1 已证实编译选项无法降级 vlog-2730，第 2 种做法不再考虑。`$fatal` / `$finish_and_return` 两类不做。
2. **文本等价证明（主要验收）**：在不定义 `MODEL_TECH` 的条件下，对改动前后的 7 个文件分别做预处理（不定义任何宏，或者只定义 `quartus_map` 会定义的宏；用 iverilog `-E` 或自写的条件编译展开都可以，写明方法）。去掉空行后，逐个 token 比较必须完全相同。另外，用 `quartus_map` 实际读入的文件清单核对，确认没有别的入口。
3. **结构等价（辅助）**：用改动后的源码跑一次官方综合，参照 T76 `vqm_comparison.json` 的方法，与基准 VQM 做名字一一对应后的结构比对，记录结果。不一致时，先用原样源码再综合一次做对照（v1 的 `e9e1734c…` 已经是一份）；如果原样源码和基准之间也同样不一致，就说明差异来自工具本身的不确定性，不算本卡失败。
4. **不布线**。交付继续使用基准 VQM 和已有的布线结果。
5. 编译与仿真验收同 v1 第 3、5 步。直接 RTL 仿真时设置 `AFDX_MODELSIM_DECL_ORDER=0`，关闭 T75 的兼容副本。
6. 另写一节“综合不确定性”：记录基准、v1、v2 三份 VQM 的 SHA256，两两之间差异的性质（只是排列和命名，还是结构变化），并说明交付的时序依赖基准 VQM 这一份文件。
7. 时间上限 3 小时；资源限制同 v1。
9. 追加（11-04 01:00，用户目标：eLinx 里仿真能通过，且时序和之前一样为正）：用户 11-02 在界面工程跑出的 VQM（`02199801…`）与基准不同，但布线 slack 同样是 +0.029。先比较 02199801 和 3cd8f5f8，去掉注释行后是否逐行相同，并找出 e9e1734c 不同的原因（并行处理器数、机器负载、路径）。最终验收改为端到端：改动后的源码跑完整的 `build_1030.py --route --pres 1.30`，要求 setup > 0、hold ≥ 0、0 失败端点；这一项取代 R2，R1 保留。时序为负就停下回报，不改锁定。总时间上限 5 小时。
8. 追加（用户批准）：交付可复现性布线测试。R1：用 v1 原样重综合的 VQM（`e9e1734c…`）加锁定布线；如果不能从已有 VQM 开始，就直接对原样源码跑 `build_1030.py --route`。R2：如果能从 VQM 开始，就用基准 VQM 按同一入口布线，确认能复现 +0.029 / +0.604 ns。只记录结果，不改锁定，eLinx 串行，每次上限 60 分钟。

## 状态

- v1，11-04 00:20 写；用户要求另派子代理去做。与 T75、T76 同时进行。
- 工作区 `E:/2026_Embedded_FPGA/worktrees/active/c3_t77`，分支 `t77`，起点 `edbbd1fb`（t76 当前提交）。
- **只读、不能碰**：`worktrees/active/c3_frag1030`（T75）、`worktrees/active/c3_t76`（T76）。两边都有仿真在跑，不结束、不挂起它们的进程，不写它们的文件。

## 背景

- 原样 RTL 只有 Icarus 能编译。ModelSim `vlog` 报 vlog-2730（信号先用后声明，21 处，清单见 `E:/2026_Embedded_FPGA/worktrees/active/c3_frag1030/out/t75/declaration_order_errors.json`）。评委如果在 eLinx 里点 RTL 仿真，或者直接用 ModelSim 编译 RTL，会报错。
- T76 试过直接挪动声明位置，加上 `ifndef SYNTHESIS` 和 `$fatal` 替换：
  - VQM 的功能图只是重新编号（65,255 个单元一一对应、逻辑相同）；
  - 但打包后的簇成员变了，锁定有一个对不上，布线 setup 变成 −7664 ps，1426 个端点失败。
  - 证据：`E:/2026_Embedded_FPGA/worktrees/active/c3_t76/docs/evidence/t76_frag1030/`（`vqm_comparison.json`、`vqm_difference_excerpt.json`、`trial_gate.json`、`source_compat_edits.json`）。
- 结论：**任何改动都必须让官方综合（`quartus_map`）读到的内容与原来一样**，VQM 才不变，锁定和时序才有效。
- 综合入口 `elinx/afdx_all.v` 只是 `include` 了 `rtl/*.v`，不用改它。

## 目标与思路

让 ModelSim 编译到声明前移的版本，而 `quartus_map` 读到的文本保持原样。建议先试这两种做法，按结果选：

1. **只给 ModelSim 看的预处理分支**：ModelSim 会自动定义宏 `MODEL_TECH`。每处改成
   - 在第一次使用之前：`` `ifdef MODEL_TECH `` 声明（位宽、属性与原声明相同） `` `endif ``；
   - 原声明处：`` `ifndef MODEL_TECH `` 原声明 `` `endif ``。
   - 带初始化的 wire 用同样的思路处理，保证 `quartus_map` 看到的完全是原文本。
   - 先确认 eLinx 的 Run Behavioral Simulation 和 `tools/eda.py sim` 走的确实是 ModelSim，确实会定义 `MODEL_TECH`。
2. **编译选项**：查 `verror 2730`，看它是否可以降级（`-suppress 2730` 之类）。如果可以，并且编译出的仿真行为正确，就只改仿真入口（`.do`、`eda.py`、eLinx 仿真设置），完全不动 RTL。

`$fatal` 和 `$finish_and_return` 这两类（只影响 yosys 辅助网表和仿真）**优先级低**：只有在 VQM 仍不变时才保留，否则放弃并记录。

## 步骤

1. **逐类二分**：每次只加入一类改动，跑一次官方综合（只到 `synth_1` 出 VQM，不布线），与基准 VQM 比较：
   - 基准：`E:/2026_Embedded_FPGA/worktrees/active/c3_frag1030/out/build1030/AFDX_top_1030/20261102_212626_064390/project/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm`（SHA256 `3cd8f5f8…`，只读）。
   - 判定：逐字节相同，或者去掉 `//` 注释行后逐行相同（**不排序**），记录属于哪一种。只是排序后相同不算。
   - 先确认原样 RTL 在本工作区重新综合，结果与基准相同；如果原样重综合就和基准不同，先停下回报。
2. 选出能让 VQM 不变的写法，覆盖全部 21 处。
3. **编译验收**：
   - ModelSim `vlog -vlog01compat` 编译整顶层，0 错误；
   - iverilog `-g2001` 编译，0 错误；
   - 警告逐条列出，不要求为 0。
4. **布线确认**：VQM 不变时，跑一次 `tools/build_1030.py --route --pres 1.30`（默认加载 tiles_1030.edc），要求结果与原来相同：11,044 个簇全部落位、0 偏差；布线 setup +0.029 / hold +0.604 ns，0/96,142 失败；P0 管脚不变。
5. **仿真确认**：直接用原样源码（不走 T75 的仿真副本变换），在 ModelSim 下跑 `tb_elinx`、`tb_fragmentation`、`tb_sys_basic`、`tb_rx_basic`、`tb_tx_basic`。检查数要与 T75 的结果相同（见 `E:/2026_Embedded_FPGA/worktrees/active/c3_frag1030/docs/evidence/t75_frag1030/summary.md`）。
6. 文档：写清 ModelSim 下怎么编译（如果用了宏分支，就说明它的作用），写进 `README.md` 的仿真说明，并放在 `docs/evidence/t77_rtl_compat/`。

## 资源（机器已满载）

- 机器 6 个物理核，T75、T76 已经占满。**本卡最多 1 个 eLinx、1 个 ModelSim 同时运行**，综合依次串行跑，不并行。
- 空闲内存 ≥ 3 GiB、E 盘 ≥ 8 GiB 才启动新作业。
- 不结束、不挂起别人的进程。

## 允许和禁止改动的范围

- 允许改：`rtl/` 中 `declaration_order_errors.json` 列出的那 7 个文件，只做第“目标与思路”节的预处理分支，或那三类改动中经过验证不改变 VQM 的部分；`sim/`（不含 `sim/wave/png/`）、`tools/eda.py` 的仿真入口、`README.md`；新建 `docs/evidence/t77_rtl_compat/`。
- 禁止改：任何电路逻辑、`elinx/afdx_all.v`、`elinx/*.edc`、`elinx/*.sdc`、`elinx/*.epr`、eLinx 设置、`docs/design/`、`docs/test/`、`sim/wave/png/`、`submission/`、`setup_pack/`。

## 验收

1. VQM 与基准逐字节相同，或者去掉注释行后逐行相同（不排序）。
2. 布线确认结果与原来相同（第 4 步）。
3. 原样 RTL 在 ModelSim 和 iverilog 下编译 0 错误；第 5 步的 5 项仿真全部 PASS，检查数与 T75 相同。
4. 在 `t77` 上本地提交，提交信息写明 VQM 比对结果和时序。不 push、不合并、不 amend。

## 停止条件，以及要先回报 Claude 的情况

- 原样重综合就与基准不同。
- 所有写法都会让 VQM 变化：停止，列出每种写法的差异和原因，不布线。
- 布线结果与原来不一致。

## 执行

- Codex gpt-6.1-sol，推理强度 max。不派子代理；不建 heartbeat、定时任务或定时续接。长作业后台运行并带超时（综合 30 分钟、布线 60 分钟、每项仿真 2 小时），进程身份写进证据。
- 环境：`AFDX_PYTHON=E:/anaconda3/python.exe`、`MODELSIM_HOME=E:/Verilog/ModelSim/setup_pack/win64`、`ELINX_HOME=E:/2026_Embedded_FPGA/setup_pack`、`AFDX_CE_DIV=2`、`AFDX_MEM_FLOOR_GB=3`。
- 报告时间用 UTC+8，不标时区。文件里不写人名、邮箱、账号。
- 总时间上限 5 小时；预计 2～3 小时（每次综合约 5～10 分钟，布线约 25 分钟）。
