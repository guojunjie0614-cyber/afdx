# ModelSim 声明兼容、综合等价与锁定布线复现记录

本目录记录为兼容 eLinx 自带 ModelSim (`-vlog01compat`) 声明前置要求所做的条件宏改造、综合输入与 VQM 结构等价性核验，以及锁定布局布线的两次独立复现结果。eLinx 图形界面行为仿真截图见 [63 VL 验证汇总](../vl63_full_load/summary.md#elinx-界面仿真验证)。

## 1. `MODEL_TECH` 编译兼容与文本等价

- **改动范围**：仅在 7 份 RTL 的 21 处变量声明添加 `` `ifdef MODEL_TECH `` 分支，对带初始化的 `wire` 在 ModelSim 分支拆分为提前声明与原位置连续赋值；位宽、初始化表达式、电路逻辑与 `$fatal`/`$finish_and_return` 断言完全保持不变（总计 `+89` 行）。
- **综合输入保序 token 等价**：在不定义 `MODEL_TECH` 的条件下运行 `iverilog -g2001 -E` 展开 `elinx/afdx_all.v`（共 `99,689` 个 token），7 份改动文件与完整综合入口展开后的 token 序列与去空行原始字节与修改前逐 token 一致。`quartus_map` 读入的 34 份用户 RTL 清单与 `afdx_all.v` 的 42 个设计单元一一匹配。
- **双工具编译与直接 RTL 复核**：ModelSim `vlog -vlog01compat` 与 Icarus `iverilog -g2001 -s AFDX_top` 整顶层编译均为 0 错误、0 警告；5 项直接 RTL 仿真自检数与改造前完全一致：

| 测试 | 结果 | 自检数 | 独立核对项 | 仿真耗时 s |
|---|---|---:|---:|---:|
| `tb_elinx` | PASS | 9,238 | — | 18.578 |
| `tb_fragmentation` | PASS | 33 | 9 | 45.657 |
| `tb_sys_basic` | PASS | 5,159,270 | 2,930 | 18.937 |
| `tb_rx_basic` | PASS | 9,960,369 | 123,855 | 14.359 |
| `tb_tx_basic` | PASS | 662,983 | 8,008 | 4.625 |

仿真入口针对 ModelSim 下 `$finish_and_return` 未定义（`vsim-PLI-3003`）及 `raw_write_data`/`next_limit` 默认模式未连接可选输入采用精确白名单识别（详见 [warning_policy_proof.json](../vl63_full_load/warning_policy_proof.json)），任何 `[RX_ASSERT]`、`RAMCOLL`、Error、Fatal 或未知警告均直接判失败。

## 2. VQM 结构等价性与综合排列排查

多轮独立综合导出的 `.vqm` 文件大小均为 `115,027,164 bytes`，包含完全同构的 `65,255` 个同名单元（`62,274` 个 lcell、`2,981` 个 RAM 段）、`134` 条连续赋值与完全相同的顶层端口及连接关系（名称呈恒等映射），仅存在同构节点导出文本枚举顺序的微小重排（不同轮次间约 `2,729`–`2,739` 行次序差异；包括设置 `NUM_PARALLEL_PROCESSORS=1` 后亦然）：

| 综合产物标识 | VQM SHA256 | 说明 |
|---|---|---|
| `baseline` | `3cd8f5f8456c9881d083fe67dd7a60ed9c6779909ee1cb10dbf9367dc9729b6e` | 分片交付基线综合 VQM |
| `v1_original` | `e9e1734c570b8344c3666e02ebf1152dd45bd7a74e801d93c73de3a1126839b4` | 兼容改造前原样对照 VQM |
| `v2_guarded` | `53cdae1284079171cc3d0554bd32e51a7ad8c7b1f1afaf8e6e6ffafea2affd23` | 添加 `MODEL_TECH` 分支后综合 VQM |
| `gui_original` | `0219980118e6d6932f9a56c065840cc1bd4c5ba2209f0b607ea4719fd45e1a4f` | eLinx GUI 工程直接导出 VQM |
| `e2e_processors_1` | `96d14e2f8ae99c72f3145f14a17f8606c16d98f7e039befe6359eb25c471e3b4` | `NUM_PARALLEL_PROCESSORS=1` 端到端最终 VQM |

## 3. 两次独立锁定布线与静态时序复现

分别通过三条路径复现了打包、物理锁定约束（`elinx/tiles_1030.edc` + `elinx/multicycle_spec.json` 中的 P0 引脚约束 + `elinx/timing_only.sdc` + `--pres 1.30`）与布线静态时序：
- **R1（冻结 VQM 重导入）**：直接导入 `v1_original` 网表运行官方打包与锁定布线（详见 [route_R1.json](route_R1.json)）。
- **E2E（端到端全流程构建）**：从兼容改造后 RTL 经 `python tools/build_1030.py --route --pres 1.30` 从头完成综合、打包与锁定布线（详见 [frag1030_delivery/timing.json](../frag1030_delivery/timing.json)）。

| 验证路径 | 锁定簇保留 / 预期 | 缺失/新增/偏移 | Worst Setup (ps) | Worst Hold (ps) | 违例端点数 | P0 引脚核对 |  wall-clock (s) | LUT / FF | CLB / Memory | Pins / DSP / PLL |
|---|---|---|---:|---:|---|---|---:|---|---|---|
| `R1` | `11044 / 11044` | `0 / 0 / 0` | `+29` | `+604` | Setup `0/96142`, Hold `0/96142` | `172/172` 一致 | `610.25` | `62274 / 35597` | `10230 / 814` | `172 / 0 / 0` |
| `E2E` | `11044 / 11044` | `0 / 0 / 0` | `+29` | `+604` | Setup `0/96142`, Hold `0/96142` | `172/172` 一致 | `898.50` | `62274 / 35597` | `10230 / 814` | `172 / 0 / 0` |

两条流程导出的 `.place` 物理落位（全部 `11,044` 个 CLB/M4K 簇 X/Y/Z 坐标与 `172` 个 I/O pad）完全逐字节一致，静态时序在含 `0.30 ns` 时钟不确定度下精确回到 `+29 ps` setup / `+604 ps` hold、零违例端点。

## 4. 复现命令参考

- **从源码端到端重新综合并布线**（设置 `AFDX_MODELSIM_DECL_ORDER=0` 以使用标准综合顺序）：

```bash
python tools/build_1030.py --route --pres 1.30
```

- **导入已有 VQM 直接执行锁定布局布线**：使用 [tools/route_1030_frozen.py](../../../tools/route_1030_frozen.py) 与 [tools/official_impl.py](../../../tools/official_impl.py)。
