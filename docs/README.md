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

## macOS 执行环境

Inkscape 导出会初始化 macOS 图形会话。该 Mac 上已确认：在 Codex 的 seatbelt 沙箱内启动会于应用注册阶段触发 SIGABRT，并弹出“意外退出”；正常系统环境导出成功。

自动化调用 Inkscape 时，直接使用已批准的沙箱外执行方式（`exec_command` 的 `sandbox_permissions: "require_escalated"`）。设计图导出入口 `mk2.sh` 和 `svg2pdf.sh` 共用 `inkscape_env.sh` 检查环境；遇到 `CODEX_SANDBOX=seatbelt` 时，在生成文件和启动 Inkscape 前以状态码 2 退出，提示使用正确环境。导出错误保留在标准错误输出中。

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
