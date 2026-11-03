# 报告配图工具

调用 Inkscape 或运行 `docs/design/fig/mk2.sh`、`svg2pdf.sh` 前，先读取 `docs/README.md` 的“macOS 执行环境”，按其中规则选择执行环境。

## Agent skills

### Issue tracker

需求和任务使用本地 Markdown，存放在 `.scratch/<feature-slug>/`。
规则见 `docs/agents/issue-tracker.md`。

### Triage labels

使用五个默认任务状态，通过任务文件顶部的 `Status:` 记录。
映射见 `docs/agents/triage-labels.md`。

### Domain docs

采用 single-context 布局：根目录 `GLOSSARY.md` 和 `docs/adr/`。
读取规则见 `docs/agents/domain.md`。
