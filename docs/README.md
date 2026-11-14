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

源码使用 Times New Roman、Songti SC、Heiti SC、Menlo；楷体可用时使用 Kaiti SC。

## macOS 执行环境

Inkscape 导出会初始化 macOS 图形会话，需要在正常系统环境中运行；在受限沙箱内启动会于应用注册阶段触发 SIGABRT。

设计图导出入口 `mk2.sh` 和 `svg2pdf.sh` 共用 `inkscape_env.sh` 检查环境；检测到受限沙箱时，在生成文件和启动 Inkscape 前以状态码 2 退出并给出提示。导出错误保留在标准错误输出中。

## 重建设计报告配图

在上述 macOS 执行环境中运行：

```sh
sh docs/design/fig/mk2.sh
# 只重建指定图：
sh docs/design/fig/mk2.sh f19_txbuf f13_decide
```

`figs.py` 是统一入口；系统、帧格式与接口时序在该文件中，发送、接收、服务与配置机制分别位于 `tx_figures.py`、`rx_figures.py`、`service_figures.py`。`jssc.py` 提供共用图元和样式：主体黑框 1.4 pt，主数据路径 1.6 pt，浅色填充与黑色粗体标签。完整结构、具体算例和状态变化按各图的机制组织。

硬件机制图优先使用 MUX、带时钟标记的寄存器、RAM 地址与端口、FIFO 槽位、比较器、加减器和门控连线。图元必须对应实际功能，不用椭圆或泛化流程图符号代替尚未展开的硬件。调度适合时间轴，流水适合时空图和波形，协议适合交互时序；只有需要并列核对的数值才使用表格，不统一套用“模块框＋大表”的版式。

紧凑布局参考 `f13_decide` 与 `f24_rxeng`：通过重排模块、就近接线和收紧分区间距减少留白，保持既定字号与线宽。门、运算器和 MUX 按端口数量确定比例，寄存器按字段长度定宽；反馈和选择控制线优先在所属模块附近闭合。协议和波形保留必要节距，不以整图缩放代替布局调整。

输出为 `docs/design/fig/v2/*.svg`、`*.png` 和 `fig/pdf/*.pdf`。SVG 使用印刷 pt 坐标并包含 1.5 pt 页边留白，按页面导出，报告以原尺寸插入；全宽图连同留白为 453 pt，避免按内容裁切改变字号或切掉边缘文字。获认可的双网图 `f13_decide` 直接复用 `proposals/dual_rx_mechanism/draw.py` 的绘图源，保留其字形与比例；该图需要本机已安装的 Matplotlib，其余图使用 SVG 图元。统一入口支持两种绘图源，均输出可编辑 SVG 和矢量 PDF。

重建后运行 `python3 docs/design/fig/make_preview.py`，可按报告引用顺序生成带图号书签的 `docs/design/fig/配图审阅.pdf`，用于逐张检查。该步骤使用本机已有的 PyMuPDF。

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
