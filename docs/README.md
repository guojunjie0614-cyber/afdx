# 设计与测试报告

| 文档 | PDF | LaTeX 源码 |
|---|---|---|
| 设计报告 | [AFDX 端系统 FPGA 设计文档](design/AFDX端系统FPGA设计文档.pdf) | [主文件](design/AFDX端系统FPGA设计文档.tex) |
| 测试报告 | [AFDX 端系统 FPGA 测试报告](test/AFDX端系统FPGA测试报告.pdf) | [主文件](test/AFDX端系统FPGA测试报告.tex) |

## 编译报告

在仓库根目录执行：

```sh
tectonic --keep-logs docs/design/AFDX端系统FPGA设计文档.tex
tectonic --keep-logs docs/test/AFDX端系统FPGA测试报告.tex
```

两份报告共用 `docs/design/numbers.tex` 的测试与综合数字。章节位于各报告的 `chapters/`，插图 PDF 已随源码提交，编译报告可直接使用。

源码使用 Times New Roman、Songti SC、Heiti SC、Menlo；楷体可用时使用 Kaiti SC。

## 重建测试报告配图

配图源位于 `docs/test/fig/`。重建需要 Python 3、librsvg 的 `rsvg-convert`，以及 Arial、Arial Narrow 字体。在仓库根目录执行：

```sh
sh docs/test/fig/mk.sh
```

在命令末尾指定图名可只重建相应插图，例如 `sh docs/test/fig/mk.sh t20_thru`。输出为 `fig/pdf/*.pdf` 和 `fig/v2/` 下的 SVG、PNG。

- `gen_jssc_figures.py`：平台、判据和性能图。
- `trace_waveforms.py` 与 `src/wave_traces.json`：RTL 信号时序图及观察窗口记录。
- `protocol_waveforms.py` 与 `t15_w_615a.json5`、`t16_w_rtc.json5`：TFTP、SNTP 协议示意。两份 WaveJSON 源使用标准 JSON 格式，由 Python 标准库读取。
- `src/t01_platform.svg`：测试平台图源。
- `sim/wave/png/`：报告采用的原始 ModelSim 截图。

绘图代码复用 `docs/design/fig/` 中的绘图元素。
