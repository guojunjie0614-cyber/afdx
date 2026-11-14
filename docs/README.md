# 技术、设计与测试报告

| 文档 | PDF | LaTeX 源码 |
|---|---|---|
| 技术报告 | [AFDX 端系统 FPGA 技术文档报告](report/AFDX端系统FPGA技术文档报告.pdf) | [主文件](report/AFDX端系统FPGA技术文档报告.tex) |
| 设计报告 | [AFDX 端系统 FPGA 设计文档](design/AFDX端系统FPGA设计文档.pdf) | [主文件](design/AFDX端系统FPGA设计文档.tex) |
| 测试报告 | [AFDX 端系统 FPGA 测试报告](test/AFDX端系统FPGA测试报告.pdf) | [主文件](test/AFDX端系统FPGA测试报告.tex) |

## 编译报告

在仓库根目录执行：

```sh
tectonic --keep-logs docs/report/AFDX端系统FPGA技术文档报告.tex
tectonic --keep-logs docs/design/AFDX端系统FPGA设计文档.tex
tectonic --keep-logs docs/test/AFDX端系统FPGA测试报告.tex
```

三份报告共用 `docs/design/numbers.tex` 的测试与综合数字。技术报告章节位于 `report/sections/`，设计和测试报告章节位于各自的 `chapters/`，插图 PDF 已随源码提交，编译报告可直接使用。

源码使用 Times New Roman、Songti SC、Heiti SC、Menlo；楷体可用时使用 Kaiti SC。报告正文引用的矢量插图（`design/fig/pdf/*.pdf`、`test/fig/pdf/*.pdf`）及 ModelSim 原始波形截图（`sim/wave/png/`）均已随仓归档。
