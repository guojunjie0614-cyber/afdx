# Issue tracker: Local Markdown

本项目的需求、规格和任务使用 `.scratch/` 下的 Markdown 文件。

## 文件约定

- 每个功能一个目录：`.scratch/<feature-slug>/`。
- 规格文件：`.scratch/<feature-slug>/spec.md`。
- 每个实施任务单独一个文件：
  `.scratch/<feature-slug>/issues/<NN>-<slug>.md`。
- 编号从 `01` 开始，不将所有任务合并成一个文件。
- 分诊状态写在任务文件顶部的 `Status:` 行，
  状态名称见 `docs/agents/triage-labels.md`。
- 评论和讨论历史追加到文件底部的 `## Comments` 下。

## 技能操作

- “发布到任务系统”：在上述目录创建相应 Markdown 文件。
- “获取相关任务”：读取给定路径的文件；
  仅给编号时，在当前功能目录定位对应任务。

## Wayfinding 操作

- 工作地图：`.scratch/<effort>/map.md`，
  记录 Notes、Decisions-so-far 和 Fog。
- 子任务：`.scratch/<effort>/issues/NN-<slug>.md`，
  编号从 `01` 开始，正文记录需要解决的问题。
- `Type:` 记录 research、prototype、grilling 或 task。
- 此工作流使用 `Status: open`、`claimed`、`resolved`
  表示执行阶段；这些不是五个分诊角色的替代名称。
- `Blocked by: NN, NN` 记录依赖；
  所有依赖任务都 resolved 后才可执行。
- 按编号选择第一个 open、未被认领且无阻塞的任务。
- 开始工作前先写入 `Status: claimed`。
- 完成时在 `## Answer` 下追加结果，设置 `Status: resolved`，
  并在 map.md 的 Decisions-so-far 中追加摘要及链接。
