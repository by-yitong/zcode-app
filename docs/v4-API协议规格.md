# ZCode Web Remote v4 API 协议规格

> 从 `https://zcode.z.ai/remote/v4/assets/index-BdDWMeL9.js` (4.5MB) 逆向提取
> 抓取日期: 2026-07-31
> 桌面端版本: app_version=3.5.3

## ★ v3 → v4 核心变化

| v3 | v4 | 说明 |
|----|-----|------|
| `zcode-task.enqueueTaskCommand` | `zcode-agent.sendConversationCommandV4` | 发消息 |
| `zcode-task.getTaskSnapshotWithEtag` | `zcode-task.getTaskSnapshotWithEtag` (不变) | 历史快照 (channel 不变) |
| `zcode-task.respondPermission` | `zcode-agent.sendConversationCommandV4(resolveInteraction)` | 权限回应 (合入 command) |
| `zcode-session.onDynamicSessionEvent` | `zcode-agent.onDynamicConversationFrame` | 流式事件订阅 |
| `zcode-session.createSession` | `zcode-agent.sendConversationCommandV4(createSession)` | 创建会话 (合入 command) |
| `zcode-session.setModel` | `zcode-agent.sendConversationCommandV4(switchModelConfig)` | 热切换模型 (合入 command) |
| `zcode-session.setThoughtLevel` | `zcode-agent.sendConversationCommandV4(switchModelConfig)` | 思考级别 (合入 model 切换) |
| `zcode-session.setMode` | `zcode-agent.sendConversationCommandV4(switchCollaborationMode)` | 代理模式 (合入 command) |
| `zcode-session.compact` | `zcode-agent.sendConversationCommandV4(compact)` | 压缩对话 (合入 command) |
| `zcode-session.stop` | `zcode-agent.sendConversationCommandV4(stop)` | 停止生成 (合入 command) |
| `zcode-session.rewind` | `zcode-agent.sendConversationCommandV4(applyFileRewind)` | 回退 (合入 command) |

**核心架构变化**: v4 把几乎所有会话操作统一为 `sendConversationCommandV4`，通过 `envelope.kind` 区分命令类型。只有 `subscribeConversationV4` (订阅事件流) 和 `getTaskSnapshotWithEtag` (快照) 是独立方法。

**Channel 变化**: 整个对话协议从 `zcode-task`/`zcode-session` 迁移到 **`zcode-agent`** channel。
**注意**: `getTaskSnapshotWithEtag` 仍在 **`zcode-task`** channel 上。

## v4 连接握手 (3步)

```
1. helloConversationV4() → 服务器返回 {kind:"hello", protocolVersion:3, connectionId, clientMode, deliveryProfile, serverTime, capabilities, auth}
2. initializeConversationV4({kind:"clientHello", protocolVersion:3, clientId, appVersion}) → 初始化
3. subscribeConversationV4({workspacePath, sessionId, base?, visibility?}) → 订阅会话事件流
```

### clientHello 参数
```typescript
{
  kind: "clientHello",
  protocolVersion: 3,
  clientId: string,       // 客户端生成的唯一ID
  clientKind?: "desktop" | "web" | "mobileRemote" | "mobileApp",
  appVersion: string
}
```

### hello 响应
```typescript
{
  kind: "hello",
  protocolVersion: 3,
  connectionId: string,
  clientMode: "desktop-continuous" | "web-remote-replayable",
  deliveryProfile: "continuous" | "replayable",
  serverTime: number,  // timestamp
  capabilities: object,
  auth: { userId?: string }
}
```

## ★ 核心 V4 方法 (全部在 zcode-agent channel)

### 订阅/取消订阅

#### subscribeConversationV4
订阅单个会话的事件流 (消息流、状态更新等)。
```typescript
channel: "zcode-agent"
method: "subscribeConversationV4"
args: [{
  workspacePath: string,
  workspaceIdentity?: string,
  sessionId: string,
  base?: { logEpoch: string, seq: number },  // 断线重连时传入
  visibility?: "foreground" | "background"
}]
→ ack: { subscriptionId: string, mode: "snapshot" | "resume", logEpoch: string }
```

#### unsubscribeConversationV4
```typescript
args: [{ workspacePath, workspaceIdentity?, subscriptionId }]
```

#### resyncConversationV4
强制重新同步 (bridge 重连后用)。
```typescript
args: [{
  workspacePath, workspaceIdentity?,
  subscriptionId,
  base?: { logEpoch, seq },
  forceSnapshot?: boolean
}]
```

#### subscribeSessionsIndexV4
订阅工作区会话列表变更。
```typescript
args: [{
  workspacePath, workspaceIdentity?,
  base?: { logEpoch, seq },
  visibility?: "foreground" | "background"
}]
```

#### subscribeWorkspaceConfigV4
订阅工作区配置变更 (模型选项、slash commands 等)。
(同上参数结构)

### 发送命令

#### sendConversationCommandV4 ★★★
**v4 核心方法** — 替代了 v3 的 enqueueTaskCommand + respondPermission + createSession + setModel 等。

```typescript
channel: "zcode-agent"
method: "sendConversationCommandV4"
args: [{
  workspacePath: string,
  workspaceIdentity?: string,
  envelope: CommandEnvelope  // 见下文
}]
→ { commandId: string, status: "accepted"|"rejected"|"stale"|"duplicate"|"noop"|"failed", ... }
```

##### CommandEnvelope 结构
```typescript
{
  sourceCommandId: string,   // UUID
  queueItemId: string,       // UUID
  clientId: string,          // 客户端ID
  kind: "sendText" | "sendGoalCommand" | "compact",
  text: string,              // 用户输入文本
  attachments: Attachment[], // 附件数组
  delivery: {
    requested: "auto" | "startNow" | "queue" | "guide",
    admitted: "startNow" | "queue" | "guide",
    fallbackReasonCode?: string
  },
  order: {
    admissionSeq: number,
    queuePosition?: number
  },
  steer?: {
    state: "notRequested" | "submitting" | "steering" | "guided" | "fellBack",
    reasonCode?: string
  },
  dispatch?: {
    state: "admitted" | "queued" | "reserved" | "promoting" | "drained",
    reservationId?: string
  }
}
```

**注意**: envelope 是通用容器，但实际发送时很多字段由服务器填充。客户端主要提供 `kind`, `text`, `attachments`。

##### 所有命令类型 (通过 sendConversationCommandV4)

| 命令类型 | 参数 | 说明 |
|---------|------|------|
| `createSession` | `{workspaceId, firstInput?:{text,attachments}, config?, runtimeModel?, mcpServers?}` | 创建新会话 |
| `createSelectionSideSession` | `{}` | 创建侧边选择会话 |
| `sendText` | `{text, attachments?, heldQueueDisposition?, expectedHeldQueueItemIds?, automationId?, toolDisallowlist?}` | 发送文本消息 |
| `sendGoalCommand` | `{text, displayText?, heldQueueDisposition?, ...}` | 发送 Goal 命令 |
| `stop` | `{expectedForegroundExecutionId?}` | 停止生成 |
| `compact` | `{}` | 压缩对话 |
| `forkAssistant` | `{target}` | 分叉助手 |
| `applyFileRewind` | `{target}` | 回退文件变更 |
| `editUserQuery` | `{target, newText, attachments?, workspaceMode?}` | 编辑用户消息 |
| `retryTurn` | `{target}` | 重试轮次 |
| `setAssistantFeedback` | `{target, feedback: "like"\|"dislike"\|null}` | 赞/踩 |
| `sendQueuedNow` | `{queueItemId}` | 立即发送排队项 |
| `editQueueItem` | `{queueItemId, newText}` | 编辑排队项 |
| `reorderQueueItem` | `{queueItemId, beforeQueueItemId}` | 重排队列 |
| `deleteQueueItem` | `{queueItemId}` | 删除排队项 |
| `setAutoDrain` | `{autoDrain: boolean}` | 自动排空队列 |
| **resolveInteraction** ★ | `{interactionId, answer:{optionId?, freeText?, action?, content?}}` | **权限回应** (替代 respondPermission) |
| `snoozeInteractionAutoResolution` | `{interactionId}` | 延迟交互自动解决 |
| **switchModelConfig** ★ | `{provider, model, thought, runtimeModel?}` | **切换模型+思考级别** |
| **switchCollaborationMode** ★ | `{mode: "build"\|"edit"\|"plan"\|"yolo"}` | **切换代理模式** |
| `setFollowupMode` | `{mode: "queue"\|"guide"}` | 设置追问模式 |
| `pauseGoal` | `{}` | 暂停 Goal |
| `resumeGoal` | `{}` | 恢复 Goal |
| `cancelBackgroundWork` | `{workId}` | 取消后台工作 |
| `renameSession` | `{title}` | 重命名会话 |
| `deleteSession` | `{}` | 删除会话 |

**注意**: v4 的 `switchCollaborationMode` 只有 4 种 mode: `build|edit|plan|yolo` (没有 v3 的 `auto`)。

### 权限交互 (resolveInteraction)

v4 的权限回应通过 `sendConversationCommandV4(resolveInteraction)` 实现：

```typescript
envelope: {
  ...commandBase,
  kind: 不走 envelope.kind 路径,
  // 实际是通过 command type "resolveInteraction":
}
// sendConversationCommandV4 的 envelope 结构:
{
  sourceCommandId, queueItemId, clientId,
  // command payload:
  resolveInteraction: {
    interactionId: string,
    answer: {
      optionId?: string,        // 选中的 option ID
      freeText?: string,        // 自由文本回答
      action?: "accept" | "decline" | "cancel",
      content?: string | object // 附加内容
    }
  }
}
```

**权限选项 kind**: `allowOnce | allowAlways | deny | custom`
- `allowOnce` → 允许一次
- `allowAlways` → 始终允许
- `deny` → 拒绝
- `custom` → 自定义

### 查询/分页

#### queryConversationCommandsV4
查询命令状态。
```typescript
args: [{ workspacePath, workspaceIdentity?, commands: [{sessionId, commandId}[]] }]
→ { results: [{key, result: {commandId, status, reasonCode?, result?}}] }
```

#### conversationRowsRangeV4
分页加载历史消息 (rows)。
```typescript
args: [{
  workspacePath, workspaceIdentity?,
  sessionId,
  beforeRowId?: number,  // 向上翻页
  limit: number
}]
```

#### conversationPlansV4
获取会话计划。
```typescript
args: [{ workspacePath, workspaceIdentity?, sessionId }]
```

#### conversationFileChangesV4
获取文件变更。
```typescript
args: [{
  workspacePath, workspaceIdentity?,
  sessionId, target,
  baseRevision, baseLogEpoch
}]
```

#### conversationFileRewindPreviewV4
预览文件回退。
```typescript
args: [{ workspacePath, workspaceIdentity?, sessionId, target, baseRevision, baseLogEpoch }]
```

#### getTaskSnapshotWithEtag
获取快照 (支持 etag 缓存)。
```typescript
channel: "zcode-task"  // 注意: 仍在 zcode-task channel!
method: "getTaskSnapshotWithEtag"
args: [{ workspacePath, workspaceIdentity?, taskId, ifNoneMatch?: string }]
→ { snapshot: ConversationSnapshot, etag: string }
或 { notModified: true } (etag 未变时)
```

### 附件上传 (V4 Attachment)

4步上传流程:

```typescript
// 1. 开始上传
attachmentBeginV4({ workspacePath, sessionId, uploadId, fileName, mime, totalBytes, totalChunks, checksum })
→ { state: "awaitingChunks"|"committed", nextChunkIndex?, ref? }

// 2. 上传分块
attachmentChunkV4({ workspacePath, uploadId, chunkIndex, data: base64, checksum? })
→ { nextChunkIndex: number }

// 3. 提交
attachmentCommitV4({ workspacePath, uploadId })
→ { ref: string }

// 4. (可选) 取消
attachmentAbortV4({ workspacePath, uploadId })
```

### 附件读取

```typescript
attachmentReadV4({ workspacePath, sessionId, ref, offset, limit })
→ { bytes: base64, nextOffset?: number, mediaType?: string }
```

### 运行时模型解析

```typescript
resolveRuntimeModelForV4({
  workspacePath, workspaceIdentity?,
  sessionId?,
  model: "provider/model",
  thoughtLevel?: string,
  modelProviderFamilySelectedKeys?: string[]
})
```

### 事件监听

#### onDynamicConversationFrame ★★★
订阅对话帧事件 (流式消息、状态更新等)。这是 v4 的核心事件流。

```typescript
channel: "zcode-agent"
method: "onDynamicConversationFrame"  // listen (type=102)
args: [workspacePath, workspaceIdentity?]
→ Stream<Frame>
```

#### onDynamicConversationTelemetryFact
遥测事件。
```typescript
method: "onDynamicConversationTelemetryFact"  // listen
```

#### onAgentRuntimeRestarted
Agent 运行时重启通知。
```typescript
method: "onAgentRuntimeRestarted"  // listen
→ { workspaceKey }
```

## ★ V4 Frame (事件帧) 结构

### Frame 顶层结构
```typescript
{
  topic: string,            // "conversation/{sessionId}" | "sessions-index/{id}" | "workspace-config/{id}"
  subscriptionId: string,
  fromSeq: number,
  toSeq: number,
  sentAt: number,           // timestamp
  payload: SnapshotPayload | DeltaPayload
}
```

### payload 类型 1: snapshot (完整快照)
```typescript
{
  kind: "snapshot",
  snapshot: ConversationSnapshot  // 见下文
}
```

### payload 类型 2: deltas (增量更新)
```typescript
{
  kind: "deltas",
  deltas: Delta[]  // 见下文
}
```

## ★ ConversationSnapshot 结构

```typescript
{
  protocolVersion: 1,
  sessionId: string,
  logEpoch: string,
  seq: number,
  revision: number,
  
  control: {
    phase: "draft" | "prewarming" | "running" | "completedSuccess" | "completedInterrupted" | "error",
    sessionEnded: boolean,
    canStop: boolean,
    stopState: "idle" | "stoppable" | "stopping",
    stopTargetKind: "assistant" | "tool" | "subagent" | "compact" | "goalVerifier" | "goalContinuation" | "turnSteer" | "mixed" | "unknown",
    activeWorks: BackgroundWork[],
    lastError: { message, name, stack? } | null,
    apiRetry: { ... } | null
  },
  
  availability: {
    fork: { allowed: boolean, reasonCode?: string },
    compact: { allowed: boolean, reasonCode?: string },
    switchModelConfig: { allowed: boolean, reasonCode?: string },
    setFollowupMode: { allowed: boolean, reasonCode?: string },
    queueEdit: { allowed: boolean, reasonCode?: string },
    sendQueuedNow: { allowed: boolean, reasonCode?: string },
    pauseGoal: { allowed: boolean, reasonCode?: string },
    resumeGoal: { allowed: boolean, reasonCode?: string }
  },
  
  inputRouting: {
    mode: "startNow" | "enqueue" | "guide" | "reject" | "choice",
    reasonCode?: string
  },
  
  meta: {
    title: string,
    titleSource: "default" | "generated" | "custom"
  },
  
  config: {
    provider: string,
    model: string,
    thought: string,                        // "max" | "medium" | "nothink"
    thoughtLevels: string[],                // 可用的思考级别
    followupMode: "queue" | "guide",
    mode: string                            // "build" | "edit" | "plan" | "yolo"
  },
  
  usage: {
    contextWindow: {
      usedTokens: number,
      maxTokens: number,
      autoCompactThresholdTokens: number | null,
      cache?: object,
      breakdown?: object
    } | null,
    cumulative: {
      inputTokens: number,
      outputTokens: number,
      ...
    }
  },
  
  queue: {
    items: Envelope[],
    autoDrain: boolean,
    pauseReason?: "stopped" | "manual"
  },
  
  pendingInteractions: PendingInteraction[],   // 权限/用户输入请求
  pendingCommands: PendingCommand[],
  backgroundWorks: BackgroundWork[],
  subagents?: {
    revision: number,
    childSessionIds: string[],
    running: object[],
    endedTotal: number
  },
  
  goal: {
    targetId: string,
    objective: string,
    summaryTitle: string | null,
    timeUsedSeconds: number,
    activeRunStartedAtMs: number | null,
    status: "active" | "paused" | "verifying" | "verified" | "notSatisfied" | "failed",
    iteration: number
  } | null,
  
  plan: {
    items: [{
      id: string,
      content: string,
      status: "pending" | "inProgress" | "completed"
    }],
    updatedAt: number
  } | null,
  
  rows: {
    window: Row[],          // 消息行数组
    totalCount: number,
    firstRowId: number | null
  }
}
```

## ★ Row (消息行) 类型

Row 是 v4 的核心显示单元，替代了 v3 的 `messages[]`。每行有 `kind` 字段区分类型。

所有 Row 类型共享基础字段 (VE):
```typescript
{
  rowId: number,
  turnId: string,
  revision: number,
  // ... 其他公共字段
}
```

### Row 类型列表

| kind | 说明 | 特有字段 |
|------|------|---------|
| `turnHeader` | 轮次标题 | origin, executionKind, state |
| `userInput` | 用户消息 | text, origin, originMeta |
| `assistantText` | AI 正文 | text, state, model, feedback |
| `reasoning` | AI 思考 | text, state, durationMs |
| `toolCall` | 工具调用 | toolCallId, toolName, status, inputText, input, output, error |
| `subagent` | 子代理 | parentToolCallId, subagentType, status, summaryText, childSessionId |
| `timelineMarker` | 时间线标记 | sourceCommandId, lane, marker |

### Row 详细结构

#### userInput
```typescript
{
  kind: "userInput",
  rowId, turnId, revision,
  text: string,
  origin: "realUser" | "backgroundResult" | "goalContinuation" | "mailbox" | "synthetic",
  originMeta?: { backgroundSource?: "bash"|"subagent", workId?: string },
  backgroundSource?: string,
  workId?: string
}
```

#### assistantText ★
```typescript
{
  kind: "assistantText",
  rowId, turnId, revision,
  text: string,                       // 正文内容 (流式追加)
  state: "streaming" | "complete" | "interrupted" | "failed",
  model?: string,
  feedback?: "like" | "dislike"
}
```

#### reasoning
```typescript
{
  kind: "reasoning",
  rowId, turnId, revision,
  text: string,                       // 思考内容 (流式追加)
  state: "streaming" | "complete" | "interrupted",
  durationMs?: number
}
```

#### toolCall ★
```typescript
{
  kind: "toolCall",
  rowId, turnId, revision,
  toolCallId: string,
  toolName: string,
  status: "inputStreaming" | "pendingApproval" | "running" | "success" | "error" | "cancelled",
  inputText: string,                  // 工具输入参数 (流式追加)
  input?: object,                     // 解析后的输入
  output?: {
    text: string,                     // 输出文本
    truncated?: { totalBytes, ref }   // 截断信息
  },
  error?: { message, name, stack? }
}
```

**★ toolCall.status = "pendingApproval" 就是权限请求！**
不需要单独的 permission 事件，权限请求是 toolCall 的一个状态。

### 子代理行
```typescript
{
  kind: "subagent",
  rowId, turnId, revision,
  parentToolCallId?: string,
  subagentType: string,
  status: "running" | "success" | "failed" | "cancelled",
  summaryText: string,
  childSessionId?: string,
  backgrounded?: boolean
}
```

## ★ Delta 操作类型

帧的 `payload.deltas[]` 数组中每个 delta 是以下之一:

```typescript
// 1. 追加新行
{ op: "row.appended", row: Row }

// 2. 更新已有行 (替换)
{ op: "row.upserted", row: Row }

// 3. 删除行
{ op: "row.removed", fromRowId: number }

// 4. 行增量 (流式追加文本) ★
{ op: "row.delta", rowId: number, path: DeltaPath, append: string }

// 5. 状态更新 (patch)
{ op: "state.updated", patch: Partial<ConversationSnapshot> }
```

### DeltaPath (row.delta 的 path 字段)

`row.delta` 的 `path` 指定追加文本到哪个字段:

| path | 说明 | 适用 Row kind |
|------|------|--------------|
| `text` | 正文/文本追加 | assistantText, reasoning |
| `inputText` | 工具输入追加 | toolCall |
| `output.text` | 工具输出追加 | toolCall |
| `summaryText` | 摘要追加 | subagent |

**流式渲染**: 收到 `row.delta` 时，找到 `rowId` 对应的行，把 `append` 文本追加到 `path` 指定的字段。

## ★ PendingInteraction (权限/用户输入请求)

```typescript
{
  interactionId: string,
  kind: "permission" | "userInput",
  anchorRowId: number | null,
  createdAt: number,
  autoResolution?: { state: "snoozed", snoozedAt: number, startedAt: number, deadlineAt: number },
  
  // kind="permission" 时:
  payload?: {
    kind: "permission",
    toolCallId: string,
    toolName: string,
    summary: string,
    detail: object,
    origin?: string,
    options: [{
      optionId: string,
      label: string,
      kind: "allowOnce" | "allowAlways" | "deny" | "custom",
      response?: object
    }]
  },
  
  // kind="userInput" 时:
  payload?: {
    kind: "userInput",
    prompt: string,
    freeText: boolean,
    options?: [{ optionId: string, label: string }],
    sensitive?: boolean,
    toolName?: string,
    toolCallId?: string,
    traceId?: string,
    input?: object,
    schema?: object,
    questions?: [{
      question: string,
      header: string,
      options: [{ value: string, label: string, description?: string, preview?: string }],
      multiSelect?: boolean
    }],
    currentQuestionIndex?: number,
    answerDrafts?: object,
    origin?: string
  }
}
```

**★ v4 权限与 v3 的区别**:
- v3: `permission.requested` 独立事件 + `respondPermission` RPC
- v4: 权限请求在 `snapshot.pendingInteractions[]` 中，回应通过 `sendConversationCommandV4(resolveInteraction)`
- v4 的权限选项 kind: `allowOnce | allowAlways | deny | custom` (v3 是 `allow_once | allow_always | deny`)

## ★ Sessions-Index Snapshot (会话列表)

```typescript
{
  protocolVersion: 1,
  workspaceId: string,
  logEpoch: string,
  sessions: [{
    sessionId: string,
    workspaceId: string,
    parentSessionId?: string,
    title: string,
    titleSource: "default" | "generated" | "custom",
    phase: "draft" | "prewarming" | "running" | "completedSuccess" | "completedInterrupted" | "error",
    sessionEnded: boolean,
    hasBackgroundWork: boolean,
    pendingInteraction?: { interactionId, kind, toolName?, autoResolution? },
    pendingInteractionSummary?: { ... },
    goalStatus?: "active" | "paused" | "verifying" | "verified" | "notSatisfied" | "failed",
    lastActivityAt: number,
    lastAssistantPreview?: string,
    createdAt: number
  }]
}
```

Sessions-Index Delta:
```typescript
{ op: "session.upserted", session: Session }
{ op: "session.removed", sessionId: string }
```

## ★ Workspace-Config Snapshot

```typescript
{
  protocolVersion: 1,
  workspaceId: string,
  logEpoch: string,
  config: {
    configOptions: [{
      id: string,
      name: string,
      description?: string,
      category?: string,
      type: "select" | "boolean",
      currentValue?: string,
      ...
    }],
    slashCommands: [{
      ...
    }]
  }
}
```

Workspace-Config Delta:
```typescript
{ op: "config.updated", config: Config }
```

## 其他 Channel 方法 (非 V4)

### zcode-task channel (任务管理)
| 方法 | 参数 | 说明 |
|------|------|------|
| `listTaskList` | `{workspaceScopes, kind?, limit?, search?, sortBy?}` | 列出任务 |
| `listPinnedTasks` | `{workspacePath, workspaceIdentity?}` | 置顶任务 |
| `listGroupedTaskViewStructure` | `{workspaceScopes}` | 分组视图 |
| `createTask` | `{workspacePath, workspaceIdentity?, provider, mcpServers}` | 创建任务 |
| `deleteTask` | `{workspacePath, taskId, workspaceIdentity?}` | 删除任务 |
| `archiveTask` | `{workspacePath, taskId, workspaceIdentity?}` | 归档任务 |
| `unarchiveTask` | `{workspacePath, taskId, workspaceIdentity?}` | 取消归档 |
| `renameTask` | `{workspacePath, taskId, title, workspaceIdentity?}` | 重命名 |
| `setTaskPinned` | `{workspacePath, taskId, pinned, workspaceIdentity?}` | 设置置顶 |
| `setTaskUnread` | `{workspacePath, taskId, unread, workspaceIdentity?}` | 设置未读 |
| `createTaskGroup` | `{workspaceScopes, ...}` | 创建分组 |
| `deleteTaskGroup` | `{groupId, workspaceScopes}` | 删除分组 |
| `renameTaskGroup` | `{groupId, title, workspaceScopes}` | 重命名分组 |
| `updateTaskGroupColor` | `{groupId, ..., workspaceScopes}` | 更新颜色 |
| `applyGroupedTaskViewOrder` | `{workspaceScopes, ...}` | 排序 |
| `onDynamicWorkspaceEvent` | `{workspacePath, workspaceIdentity?}` | 工作区事件 (listen) |
| `restartWorkspaceProcess` | `{workspacePath, provider, resumeTaskId?, bumpRuntimeEpoch?, workspaceIdentity?}` | 重启工作区进程 |
| `releaseWorkspacePreparation` | `{workspacePath, provider, workspaceIdentity?}` | 释放预热 |
| `setWorkspacePreferredModel` | `{workspacePath, provider, modelId, modelRef, workspaceIdentity?}` | 工作区首选模型 |

### zcode-session channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `createSession` | `{workspacePath, mode, model?, persistence?, workspaceIdentity?}` | 创建会话 (旧接口,仍可用) |
| `readSession` | `{workspacePath, sessionId, messageLimit?, workspaceIdentity?}` | 读取会话 |
| `readWorkspaceState` | `{workspacePath, workspaceIdentity?}` | 工作区状态 |
| `closeSession` | `{workspacePath, sessionId, workspaceIdentity?}` | 关闭会话 |
| `setModel` | `{workspacePath, sessionId, model, workspaceIdentity?}` | 设置模型 (旧接口) |
| `setThoughtLevel` | `{workspacePath, sessionId, thoughtLevel, workspaceIdentity?}` | 思考级别 (旧接口) |
| `setWorkspaceDefaultModel` | `{workspacePath, model, workspaceIdentity?}` | 工作区默认模型 |
| `setWorkspaceDefaultThoughtLevel` | `{workspacePath, thoughtLevel, workspaceIdentity?}` | 工作区默认思考 |
| `respondProviderRuntimeHeaders` | `{workspacePath, sessionId, requestId, response?, runtimeProviderHeaders?, errorMessage?, workspaceIdentity?}` | Provider runtime headers |
| `onDynamicProviderRuntimeHeadersRequest` | `{workspacePath, sessionId, workspaceIdentity?}` | (listen) |
| `getWorkspaceRuntimeIdentity` | `{workspacePath, workspaceIdentity?}` | 运行时身份 |

### zcode-agent channel (V4 对话 + 插件)
| 方法 | 参数 | 说明 |
|------|------|------|
| 所有 V4 方法 (见上文) | — | 对话核心 |
| `getPluginsOverview` | `{workspacePath}` | 插件概览 |
| `listPlugins` | `{workspacePath}` | 插件列表 |
| `installPlugin` | `{marketplace, pluginName, operationId, scope}` | 安装插件 |
| `uninstallPlugin` | `{pluginId, removeCache}` | 卸载插件 |
| `updatePlugin` | `{pluginId}` | 更新插件 |
| `cancelPluginOperation` | `{operationId}` | 取消插件操作 |
| `restoreBuiltinPlugin` | `{pluginId}` | 恢复内置插件 |
| `addPluginMarketplace` | `{source, workspaceIdentity?, workspacePath?}` | 添加插件市场 |
| `updatePluginMarketplace` | `{marketplace, workspaceIdentity?, workspacePath?}` | 更新插件市场 |
| `removePluginMarketplace` | `{marketplace, workspaceIdentity?, workspacePath?}` | 移除插件市场 |
| `describePlugin` | `{marketplace, pluginName, workspaceIdentity?, workspacePath?}` | 描述插件 |
| `validatePlugin` | `{source, workspaceIdentity?, workspacePath?}` | 验证插件 |
| `configurePlugin` | `{pluginId, options}` | 配置插件 |

### model-provider channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `getAll` | — | 全部模型列表 |
| `getAllCached` | — | 缓存模型列表 |
| `getDisplayOrder` | — | 显示顺序 (通常空) |
| `save` | `{...}` | 保存配置 |
| `onDidChangeProviderRegistry` | — | (listen) 注册表变更 |
| `refreshCodingPlanApiKey` | `{...}` | 刷新 API key |
| `resolveWorkspaceModelSelection` | `{...}` | 解析工作区模型选择 |

### file channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `listWorkspaceFiles` | `{rootPath}` | 列出工作区文件 |
| `readdir` | `{path, includeHidden?}` | 目录列表 |
| `stat` | `{path}` | 文件信息 |
| `readTextFile` | `{path, offset?, length?}` | 读取文本 |
| `resolvePath` | `{path}` | 解析路径 |
| `readMediaPreview` | `{path}` | 读取媒体预览 |
| `createScratchWorkspace` | `{name}` | 创建临时工作区 |
| `ensureConversationWorkspace` | — | 确保对话工作区 |
| `copyPath` | `{path}` | 复制路径 |
| `revealInFileManager` | `{path, deleted?, kind?}` | 在文件管理器中显示 |
| `canRevealInFileManager` | `{path}` | 是否可显示 |

### git channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `getChanges` | `{workspacePath, sourceId}` | 获取变更 |
| `refresh` | `{workspacePath, includeBranchComparison?, includeIdentity?}` | 刷新 |
| `getIdentity` | — | Git 身份 |
| `getDiff` | `{workspacePath, path, sourceId}` | 获取 diff |
| `getLocalBranches` | `{workspacePath}` | 本地分支 |
| `createBranchAndSwitch` | `{workspacePath, branchName}` | 创建并切换分支 |
| `switchBranch` | `{workspacePath, targetBranchName}` | 切换分支 |
| `generateCommitMessage` | `{workspacePath, workspaceIdentity?, includeUnstaged?, locale?, conversationContext?, currentSessionFilePaths?}` | 生成提交消息 |
| `getCommitGraph` | `{workspacePath, maxCount?, skip?}` | 提交图 |
| `getIgnoredPaths` | `{workspacePath, paths}` | 忽略路径 |
| `stagePaths` | `{workspacePath, paths}` | 暂存 |
| `commit` | `{workspacePath, message}` | 提交 |

### system channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `info` | — | 系统信息 |
| `listIntegratedTerminalShells` | — | 终端 shell 列表 |

### setting channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `get` | `(key: string)` | 获取设置 |
| `update` | `({...settings})` | 更新设置 |
| `updateDataBaseDir` | `(path)` | 更新数据目录 |

### credential channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `save` | `(credential)` | 保存凭据 |
| `delete` | `(key)` | 删除凭据 |

### oauth channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `getActiveProvider` | — | 当前 provider |
| `handleCallback` | `(callback)` | 处理回调 |
| `logout` | `(target)` | 登出 |
| `restoreCachedSession` | — | 恢复缓存会话 |

### skills channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `list` | `{workspacePath, workspaceIdentity?, provider}` | 技能列表 |
| `setEnabled` | `{workspacePath, skillId, enabled, scope?, provider, workspaceIdentity?}` | 启用/禁用 |

### plugins channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `setPluginEnabled` | `{workspacePath, pluginId, enabled, workspaceIdentity?}` | 启用/禁用插件 |

### subagents channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `createAgent` | `{provider, config}` | 创建 agent |
| `updateAgent` | `{provider, agentId, config, oldFilePath}` | 更新 agent |
| `deleteAgent` | `{agentId, filePath}` | 删除 agent |
| `setEnabled` | `{agentId, enabled}` | 启用/禁用 |

### commands channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `getPrimaryUserCommandsDirectory` | — | 用户命令目录 |

### hooks channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `loadHooks` | `{workspacePath, workspaceIdentity?}` | 加载 hooks |
| `saveHooks` | `{workspacePath, hooks, workspaceIdentity?}` | 保存 hooks |

### usage-stats channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `getEntitlementSnapshot` | `{includeSubscription?, preferredProviderId?, ...}` | 额度快照 |
| `getAppUsageSnapshot` | `{range, timeZone}` | 应用用量 |
| `getCodingPlanUsageSnapshot` | `{range, timeZone, organizationId?, projectId?, preferredProviderId?}` | 编码计划用量 |

### coding-plan-subscription channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `getEnterprisePricing` | `{authenticated}` | 企业定价 |

### feedback channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `create` | — | 创建反馈 |
| `cancelCreate` | — | 取消创建 |
| `comment` | — | 评论 |
| `uploadAttachmentData` | — | 上传附件 |
| `cancelUpload` | — | 取消上传 |

### repo-wiki channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `getOverview` | `{workspacePath, workspaceIdentity?}` | Wiki 概览 |
| `readSummary` | `{workspacePath, workspaceIdentity?}` | 读取摘要 |

### broadcast channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `onMessage` | — | (listen) 广播消息 |

### file-watcher channel
(方法待确认)

### settings-sync channel
(方法待确认)

### output-style channel
(方法待确认)

### memory channel
(方法待确认)

### bots channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `saveBot` | `{bot, credentialValue}` | 保存 Bot |
| `createBindCode` | `{botId, allowedWorkspaces, ttlMs}` | 创建绑定码 |

### terminal channel
| 方法 | 参数 | 说明 |
|------|------|------|
| `resize` | — | 调整终端大小 |

## Channel 枚举全表 (v4, 32个)

| 枚举键 | Channel 名 | 用途 |
|--------|-----------|------|
| File | `file` | 文件操作 |
| Git | `git` | Git 操作 |
| GitCheckpoint | `git-checkpoint` | Git 检查点 |
| System | `system` | 系统 |
| Terminal | `terminal` | 终端 |
| Setting | `setting` | 设置 |
| Credential | `credential` | 凭据 |
| Broadcast | `broadcast` | 广播 |
| ZCodeTask | `zcode-task` | 任务管理 |
| **ZCodeAgent** | **`zcode-agent`** | **AI 对话 (V4 核心)** |
| ZCodeSession | `zcode-session` | 会话管理 (旧接口) |
| Bots | `bots` | Bots |
| Hooks | `hooks` | 钩子 |
| Memory | `memory` | 记忆 |
| OutputStyle | `output-style` | 输出样式 |
| FileWatcher | `file-watcher` | 文件监听 |
| OAuth | `oauth` | OAuth |
| ModelProvider | `model-provider` | 模型提供商 |
| UsageStats | `usage-stats` | 用量统计 |
| CodingPlanSubscription | `coding-plan-subscription` | 编码计划订阅 |
| Skills | `skills` | 技能 |
| SkillSync | `skill-sync` | 技能同步 |
| McpSync | `mcp-sync` | MCP 同步 |
| PluginSync | `plugin-sync` | 插件同步 |
| Plugins | `plugins` | 插件 |
| PluginManagement | `plugin-management` | 插件管理 |
| Subagents | `subagents` | 子代理 |
| Commands | `commands` | 命令 |
| SettingsSync | `settings-sync` | 设置同步 |
| Feedback | `feedback` | 反馈 |
| RepoWiki | `repo-wiki` | 仓库 Wiki |
| PromptAttachmentTransfer | `prompt-attachment-transfer` | 附件传输 |

**v4 新增 Channel**: `SkillSync`, `McpSync`, `PluginSync`, `PluginManagement`, `PromptAttachmentTransfer`

## 订阅模型对比

### v3 (旧)
```
onDynamicSessionEvent(sessionId) → 
  snapshot → state.updated → turn.started → model.streaming(多条) → session.updated → turn.completed
```

### v4 (新)
```
subscribeConversationV4(sessionId) →
  Frame{payload:{kind:"snapshot", snapshot:{...rows}}} →     // 初始快照
  Frame{payload:{kind:"deltas", deltas:[                      // 增量流
    {op:"row.appended", row:{kind:"turnHeader", ...}},
    {op:"row.appended", row:{kind:"userInput", text:"..."}},
    {op:"row.appended", row:{kind:"assistantText", text:"", state:"streaming"}},
    {op:"row.delta", rowId:N, path:"text", append:"Hello"},  // 流式追加
    {op:"row.delta", rowId:N, path:"text", append:" world"},
    {op:"row.upserted", row:{kind:"assistantText", text:"Hello world", state:"complete"}},
    {op:"row.appended", row:{kind:"toolCall", ...}},
    {op:"state.updated", patch:{control:{phase:"completedSuccess"}}}
  ]}}
```

## 流式消息渲染流程 (v4)

1. 收到 snapshot → 初始化所有 rows + state
2. 收到 `row.appended` (assistantText, state=streaming) → 新建消息气泡
3. 收到 `row.delta` (path=text) → 追加文本到消息气泡
4. 收到 `row.upserted` (state=complete) → 标记消息完成
5. 收到 `row.appended` (toolCall, status=pendingApproval) → 显示权限确认 UI
6. 用户确认 → sendConversationCommandV4(resolveInteraction)
7. 收到 `row.upserted` (status=running) → 工具执行中
8. 收到 `row.delta` (path=output.text) → 追加工具输出
9. 收到 `row.upserted` (status=success) → 工具完成
10. 收到 `state.updated` (control.phase=completedSuccess) → 轮次结束

## 已废弃的 v3 方法 (v4 中不存在)

| v3 方法 | 状态 | v4 替代 |
|--------|------|---------|
| `zcode-task.enqueueTaskCommand` | ❌ 不存在 | `zcode-agent.sendConversationCommandV4(sendText)` |
| `zcode-task.respondPermission` | ❌ 不存在 | `zcode-agent.sendConversationCommandV4(resolveInteraction)` |
| `zcode-session.onDynamicSessionEvent` | ❌ 不存在 | `zcode-agent.onDynamicConversationFrame` |
| `zcode-session.setMode` | ❌ 不存在 | `zcode-agent.sendConversationCommandV4(switchCollaborationMode)` |
| `zcode-session.compact` | ❌ 不存在 | `zcode-agent.sendConversationCommandV4(compact)` |
| `zcode-session.stop` | ❌ 不存在 | `zcode-agent.sendConversationCommandV4(stop)` |
| `zcode-session.rewind` | ❌ 不存在 | `zcode-agent.sendConversationCommandV4(applyFileRewind)` |
| `zcode-session.messages` | ❌ 不存在 | `zcode-agent.conversationRowsRangeV4` |
| `zcode-agent.sendPrompt` | ❌ 不存在 | `zcode-agent.sendConversationCommandV4` |

## 仍保留的 v3 方法

| 方法 | 说明 |
|------|------|
| `getTaskSnapshotWithEtag` | 快照 (仍在 zcode-task channel) |
| `model-provider.getAll` | 模型列表 |
| `skills.list` / `skills.setEnabled` | 技能管理 |
| `file.listWorkspaceFiles` 等 | 文件操作 |
| `zcode-task.listTaskList` 等 | 任务列表管理 |
| `zcode-session.createSession` | 创建会话 (但 V4 推荐 createSession command) |
| `zcode-session.readSession` | 读取会话详情 |
| `zcode-session.setModel` / `setThoughtLevel` | 旧接口 (仍可用,但 V4 推荐 switchModelConfig) |
