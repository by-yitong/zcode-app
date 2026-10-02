# Git 工具复刻设计 (zcode-app 移动端)

日期: 2026-10-02
状态: 已与用户对齐 (范围/入口/形态/设计五节均确认)

## 1. 背景与目标

网页端 (zcode.z.ai/remote/v4) 有 Git 工具面板: 查看代码更改、分支、提交、推送。
本设计把它全量复刻到移动端 App。

已验证的协议事实 (来源: 网页端 3.14.4 bundle + 本机桌面端 3.14.4 asar 解包):

- 远程管道通道无关: rpc-frame 头部 `[typeCode, id, channel, method]`,
  桌面 main 进程 `routePayload → relayProtocol.acceptPayload → processInbound`
  按帧头 channel 通用分发, 不限于 `zcode-agent`。
- 通道名共享枚举原文: `Git:"git"`, `GitCheckpoint:"git-checkpoint"`,
  `ZCodeAgent:"zcode-agent"`, `File:"file"` 等。
- git 服务端实现在桌面 host 进程, 18 个方法全部存在 (见 §4)。
- App 现有 `relay_client._rpcCall(channel, method, args)` 天然支持任意通道,
  **零后端改动**。

## 2. 范围

v1 交付 (用户确认全量复刻):

- 更改: 未暂存/已暂存两段列表, 状态/±行数, diff 查看, 暂存/取消暂存/丢弃
- 分支: 列表/切换/新建并切换
- 历史: 提交列表 (分页加载)
- 提交: 文件勾选 / 仅已暂存 / AI 生成提交信息 / 提交
- 推送: 当前分支 push (无 upstream 自动 --set-upstream, 服务端行为)

明确排除 (YAGNI, 后续按需):

- 提交图 lane 渲染 (网页有 gitGraphDiagram; v1 用平铺列表)
- 分支对比 (getBranchComparison)、ignored paths (getIgnoredPaths)
- git-checkpoint 通道
- 后台变更推送/轮询 (v1: 进入页面 + 下拉 + 写操作后刷新)
- getWorkspaceRepositoryInfo (v1 用 getRepositorySummary 判空态)

## 3. 用户交互流程

入口: 聊天页顶栏 (chat_floating_header 三胶囊区) 新增 git 图标 →
`GitPage`, 入参 `workspacePath` + `workspaceIdentity` (取自当前会话 chatRef)。

GitPage 结构: 头部常驻 (当前分支名 + ahead/behind 徽标 + 刷新按钮) +
TabBar 三 Tab (更改 / 分支 / 历史)。

### 3.1 更改 Tab
- 两段列表: 未暂存 (含 untracked/冲突) / 已暂存; 空段显示占位文案。
- 文件行: kind 色点 (modified 橙 / added 绿 / deleted 红 / conflicted 红) +
  相对路径 (workspaceRelativePath) + `+n −m`。
- 行内操作: 未暂存行 → 暂存 / 丢弃; 已暂存行 → 取消暂存 / 丢弃。
  丢弃必须确认弹窗 (明示不可恢复, discardPaths 无回收站)。
- 点文件行 → diff 详情页 (自绘 unified patch: `+` 行绿底 / `-` 行红底 /
  `@@` 行蓝字 / 文件头灰字), 底部复用同款行内操作。
- 右上角「提交」→ 提交底部弹窗 (见 3.4)。

### 3.2 分支 Tab
- 当前行高亮 + tracking 分支名; 其余行点击 → 确认弹窗 (提示未提交更改将
  保留在工作区, 切换可能因冲突失败) → switchBranch。
- 「新建分支」按钮 → 输入名 (可选起点, 默认当前 HEAD) → createBranchAndSwitch。
- detached HEAD: 列表顶部提示条, 禁用 push 相关入口。

### 3.3 历史 Tab
- 列表项: 短 hash / 标题 / 作者 / 相对时间 / refs 装饰标签 (branch/tag)。
- 上滑触底加载更多 (maxCount=50, skip 递增, hasMore=false 停)。
- 点提交项 v1 无详情页 (排除项), 预留点击复制 hash。

### 3.4 提交弹窗 (底部)
- 文件勾选列表 (默认全选全部变更), 或「仅提交已暂存」开关 (开=stagedOnly, 不传 paths)。
- message 多行输入 + 「AI 生成」按钮 → generateCommitMessage(locale=系统语言)
  成功后填入输入框 (可改); 生成中按钮转圈且提交禁用。
- 「提交后推送」勾选框 (默认关)。
- 提交成功: 弹窗关闭, 若勾选推送则继续 push, 结果 SnackBar (含服务端错误原文)。

### 3.5 状态与错误
- 空态: getRepositorySummary 返回的 `branchName` 为空 → 非 git 仓库或 git
  不可用 → 全页引导文案, 不显示 Tab 内容; `headRefType ≠ "branch"` →
  detached HEAD 提示条 (分支 Tab 顶部)。
- 加载态: 首屏骨架; 写操作行级/按钮级 busy, 全页不阻塞。
- 错误: SnackBar 展示服务端错误原文; 网络断开走现有 relay 重连机制。
- 刷新: 进入页面、下拉刷新、任何写操作成功后刷新 summary+changes;
  切到分支/历史 Tab 时按需拉取 (懒加载, 不重复拉)。

## 4. API 契约 (channel `git`, 已从桌面端实现逆向核实)

| 方法 | 请求参数 | 响应 | v1 |
|---|---|---|---|
| getRepositorySummary | `{workspacePath}` | `summary` (见下) | ✅ |
| refresh | `{workspacePath, includeIdentity?, includeBranchComparison?}` | summary(+identity/comparison) | ✅ (简用) |
| getChanges | `{workspacePath, sourceId: "unstaged"\|"staged"\|"branch"}` | `change[]` (见下) | ✅ |
| getDiff | `{workspacePath, path, sourceId}` | `{patch?, summary?}` | ✅ |
| getLocalBranches | `{workspacePath}` | `{headRefType, currentBranchName, branches[]}` | ✅ |
| switchBranch | `{workspacePath, targetBranchName}` | 结果对象 (实现期核对键名) | ✅ |
| createBranchAndSwitch | `{workspacePath, branchName, startPoint}` | 结果对象 (实现期核对键名) | ✅ |
| getCommitGraph | `{workspacePath, maxCount, skip}` | `{commits[], hasMore}` | ✅ |
| stagePaths | `{workspacePath, paths[]}` | void | ✅ |
| unstagePaths | `{workspacePath, paths[]}` | void | ✅ |
| discardPaths | `{workspacePath, paths[], staged?}` | void | ✅ |
| generateCommitMessage | `{workspacePath, workspaceIdentity?, includeUnstaged?, currentSessionFilePaths?, locale?, conversationContext?}` | 生成结果 (含 message) | ✅ (简参) |
| commit | `{workspacePath, message, paths?, stagedOnly?}` | `{commitHash, summary}` | ✅ |
| push | `{workspacePath}` | 结果对象 (实现期核对键名) | ✅ |
| getIdentity | `{workspacePath}` | `{userName, userEmail, nameSource?, emailSource?}` | ❌ (预留) |
| getIgnoredPaths | `{workspacePath, paths[]}` | — | ❌ |
| getBranchComparison | `{workspacePath}` | `{baseRef, headRef, comparisonLabel, changes[]}` | ❌ |
| getWorkspaceRepositoryInfo | `{workspacePath}` | — | ❌ |

关键 wire 字段 (桌面端源码核实):

- `summary`: `{branchName, trackingBranchName, headRefType, ahead, behind, entries}`
  (headRefType `"branch"` 才可 push; detached 为其他值)
- `change`: `{path, repoRelativePath, workspaceRelativePath, x, y, kind, section,
  added, removed, isStaged, isUntracked, isConflicted}`
  (kind: modified/added/deleted…; section: unstaged/staged/untracked/conflicted)
- `commit` 条目: git log `%H %P %an %at %s %D` 解析 → hash/parents/author/
  authorTimestampUnix/subject/refs
- `branches[]` 条目: for-each-ref `refname:short/upstream:short/objectname/
  committerdate:unix` → name/upstream/hash/committerDateUnix (实现期以
  service 返回键名为准核对)
- checksum/strict 校验教训沿用: 服务端 zod 严格校验, 多传字段可能被拒,
  客户端按上表字段发, 不多传。

实施要求: T1 完成后把本表同步进 `docs/v4-API协议规格.md` 新增「Git 通道」章节
(全局规则: API 文档与代码同步)。

## 5. 数据模型与状态

无新表、无持久化, 纯内存 Riverpod:

- `gitControllerProvider.family(workspaceKey)`: state = 
  `{phase: idle/loading/empty/error, summary?, unstaged[], staged[], 
  branches?, commits[]+hasMore+skip, busyOp: Set<String>, error?}`
- 写操作: 先置 busyOp (按钮/行禁用) → RPC → 成功后局部刷新 (summary+changes;
  分支操作额外刷 branches; commit 后清空勾选) → 失败回滚 busy + SnackBar。
- relay_client 新增 `git*` 方法族 (~15 个 typed 包装), 复用 `_rpcCall('git', …)`,
  风格对齐现有 attachment*V4 方法 (含错误向上抛、超时默认 30s)。

## 6. 测试策略

- T1 契约单测: mock RPC 层断言 channel/method/参数字段逐个正确
  (参照 attachment_checksum_test 的 wire 契约测试风格)。
- Controller 单测: 加载/空态/写操作刷新/错误回滚。
- Widget 测试: 三 Tab 渲染、丢弃确认弹窗、提交弹窗勾选逻辑。
- 真机验收: 用户连接桌面端实测查看/暂存/提交/推送/切分支全链路。

## 7. 任务拆分 (契约冻结后派发)

| # | 任务 | 依赖 | 执行者 |
|---|---|---|---|
| T1 | relay_client git 通道 typed 包装 + 契约单测 + API 文档同步 | 无 | frontend-flutter 子代理 |
| T2 | gitControllerProvider + GitPage 三 Tab 骨架 (更改 Tab 全操作 + 分支/历史 Tab) | T1 | frontend-flutter 子代理 |
| T3 | diff 详情页 + 提交底部弹窗 (AI 生成/勾选/推送开关) | T1, T2 接口 | frontend-flutter 子代理 |
| T4 | 顶栏 git 图标入口 + 路由接线 | T2 | 主 agent (小改动) |
| T5 | qa: 单测/Widget 测试补全 + 验收 | T2, T3 | qa 子代理 |

禁止事项 (全部子任务): 不改 relay 现有方法行为、不改既有路由结构、
不引入新依赖、不动 zcode-agent 通道代码。
