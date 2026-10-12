# T26b：界面网表默认输入补全与进位问题

- 结论：输入补全恢复了 `byte_en`，但初始化计数仍不正确；已定位到下一处网表与模型不兼容，按卡停止，没有继续修补整份网表。
- 基线 `0b93997b`；原网表为 `elinx/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm`，只对 `out/t26b/AFDX_EndSystem_defaults.vqm` 仿真副本操作。
- 原网表 SHA256：`3d98d1b93be02287d2a058ec349dd745a3e368e361ea923def7ae9de181c57eb`。旧脚本拒绝其 `defparam` 格式，故在 `out/t26b/adapt_defaults.py` 做最小格式适配。
- 下表依据均来自 eLinx 安装目录：组件声明是 `bin/Passkey/libraries/vhdl/wysiwyg/stratix_components.vhd`；模型是 `Simulation/elinx_lib/stratix_atoms.v`，原文件与副本摘要均保留。

| 单元和省略的输入 | 仿真副本补值 | 厂商依据 |
|---|---|---|
| lcell：dataa、datab、datac、datad、ena | 1 | 组件声明 552–556 行；数据输入按厂商声明补 1，与旧脚本填 0 的做法有别。 |
| lcell：aclr、aload、cin、clk、inverta、regcascin、sclr、sload | 0 | 组件声明 546–549、557–561 行。 |
| lcell：cin0、cin1 | 0，仅固定未启用端 | 模型 406–409、665–699 行：两路进位默认未启用；原网表也没有 cin0/cin1、cout0/cout1 连接，固定值不进入有效输出。 |
| lcell：devclrn、devpor | 1 | 模型 1012–1013 行 `tri1`。 |
| RAM：ena0、ena1、devclrn、devpor | 1 | 模型 3132–3137 行 `tri1`。 |
| RAM：clk1、clr0、clr1、portbdatain | 0 | 模型 3119、3126–3130 行 `tri0`；数据按参数位宽补零。 |
| RAM：portabyteenamasks、portbbyteenamasks | 全 1 | 模型 3114、3123 行 `tri1`；按掩码参数位宽补齐。 |

- 共处理 32846 个 lcell、538 个 RAM，补 427486 个输入连接；未接输出仅显式留空。逐实例核对原有连接、LUT 和全部参数均未变，未补进位使用参数。
- `tb_elinx` 用原样测试和厂商模型、`-voptargs=+acc` 编译及展开，Error/Fatal/Warning 均为 0；运行 406.219 秒后因原因已定位而主动停止（exit=15），没有最终 PASS/FAIL，不记为测试超时。
- 整顶层与同激励 RTL 短程对照：cycle=16/32/48 时，两端 `byte_en` 均为 1；RTL 收发初始化地址为 8/24/40，网表对应的逐位信号均为 0（没有把未驱动的同名总线当作地址值）。
- 下一原因：3679 个算术单元接了 `cin` 却全未设置 `cin_used`；原网表 38433 行的初始化计数第 1 位就是实例。模型 979、1037、692–698 行默认并传递 `false`，因此计算时改用 `inverta`，忽略真实进位。
- 提取该实例独立验证：a=0、cin=1 时原参数输出 0；只在诊断对照实例设 `cin_used="true"` 后输出 1，四组输入全部符合该差异。此参数修改没有应用到整网表；RTL 的递增语句见 `rtl/afdx_tx_engine.v:236`、`rtl/afdx_rx_engine.v:190`。
- 第一步未取得 PASS，未运行五功能 `tb_net_services` 及外部记录比对，未增加评委入口或 README 通过步骤。
- 原生命令、日志和目录见 `out/t26b/step1.json`、`carry_probe.json`、`observations.json`；逐位对照见 `top_comparison.json`，默认输入数量见 `AFDX_EndSystem_defaults.defaults.json`。独立单元目录可重跑 `vsim -c -t 1ps -voptargs=+acc work.tb_carry_probe -do "do run.do"`。
- 156 个已有受版本控制文件及原网表、厂商模型摘要未变，任务卡原样保留；未重新综合、未推送、未触碰其他工作区，只终止记录在 `out/t26b/step1_stop.json` 中的本次仿真进程。本次只提交本报告。
