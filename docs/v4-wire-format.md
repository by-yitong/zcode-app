# V4 Wire 格式实测验证 (probe_v4.dart)

> 2026-07-31 通过 dart probe 脚本连接真实服务器验证

## rpc-frame 传输格式 (V4 必须)

```json
{
  "zcode_type": "rpc-frame",
  "bridgeSessionId": "bridge_xxx",
  "bridgeGeneration": 1,
  "seq": 1,
  "messageSeq": 1,
  "fragmentIndex": 0,
  "fragmentCount": 1,
  "messageBytes": 42,
  "checksum": {"algorithm": "crc32", "value": "a1b2c3d4"},
  "dataBase64": "..."
}
```

**关键：**
- `checksum` 是对象 `{algorithm, value}`，不是字符串！
- 缺少 messageSeq/fragmentIndex/fragmentCount/messageBytes/checksum → `rpc-transport-fault`
- `recoveryId` 不需要（bridge-ready 响应里也没有返回）

## 双向 ack 机制

客户端收到服务端的 rpc-frame 后，**必须发 rpc-frame-ack 回去**：
```json
{
  "zcode_type": "rpc-frame-ack",
  "bridgeSessionId": "bridge_xxx",
  "bridgeGeneration": 1,
  "ackMessageSeq": 2
}
```
不发 ack → 服务端超时后 `bridge-degraded: rpc-transport-fault`。

## EventListen body 格式 ★★★（最关键发现）

`encodeListen` 的 args 参数必须是**单个 JSON object (tag=5)**，不是 array (tag=4)！

```dart
// ✗ 错误 (tag=4 list) — 服务端静默忽略, 不推事件
encodeListen(id, channel, event, [{workspacePath: "..."}])

// ✓ 正确 (tag=5 JSON) — 服务端注册成功, 推 type=204 事件
encodeListen(id, channel, event, {workspacePath: "..."})
```

## V4 连接流程

```
1. WebSocket 连接 + HMAC 认证 (不变)
2. bootstrap-request → 获取 workspace + task 列表
3. workspace-bridge-open → bridge-ready + RPC Init (type=200)
4. helloConversationV4() → {connectionId, clientMode, deliveryProfile, serverTime, capabilities}
5. initializeConversationV4({kind:"clientHello", protocolVersion:3, clientId, appVersion, clientKind})
6. onDynamicConversationFrame (EventListen, {workspacePath}) ← 注意: 单个 object
7. subscribeConversationV4({workspacePath, sessionId}) → {ack:{subscriptionId, mode:"snapshot", logEpoch}}
8. sendConversationCommandV4({workspacePath, envelope})
```

顺序: listen (step 6) 在 subscribe (step 7) 之前或之后都可以，但必须在 sendText (step 8) 之前。

## sendConversationCommandV4 envelope 格式

```typescript
{
  workspacePath: string,
  workspaceIdentity?: string,
  envelope: {
    kind: "input",              // ★ 固定值, 不是 commandType
    type: "sendText",           // ★ 命令类型 (Zod 验证)
    payload: {                  // ★ 命令 payload (嵌套对象)
      text: string,
    },
    commandId: string,          // ★ 必填! 唯一命令 ID
    clientId: string,           // ★ 必填! 必须与 initialize 的 clientId 一致
    issuedAt: number,           // ★ 必填! 毫秒时间戳
    sessionId?: string,         // 已有会话时必填
  }
}
```

## 命令类型清单 (从 Zod schema 逆向)

| type | payload | 用途 |
|------|---------|------|
| `sendText` | `{text, attachments?, heldQueueDisposition?, expectedHeldQueueItemIds?}` | 发送文本消息 |
| `sendGoalCommand` | `{text, displayText?}` | 发送目标命令 |
| `createSession` | `{workspaceId, firstInput}` | 创建新会话 |
| `createSelectionSideSession` | - | 创建侧边会话 |
| `stop` | - | 停止 AI 响应 |
| `compact` | - | 压缩上下文 |
| `forkAssistant` | - | 分叉 AI 回复 |
| `applyFileRewind` | - | 回退文件 |
| `editUserQuery` | - | 编辑用户消息 |
| `retryTurn` | - | 重试 |
| `setAssistantFeedback` | - | 设置反馈 (赞/踩) |
| `sendQueuedNow` | - | 立即发送队列 |
| `editQueueItem` | - | 编辑队列项 |
| `reorderQueueItem` | - | 重排队列 |
| `deleteQueueItem` | - | 删除队列项 |
| `setAutoDrain` | - | 设置自动排空 |
| `resolveInteraction` | - | 回答权限/交互请求 |
| `snoozeInteractionAutoResolution` | - | 延迟交互自动解决 |
| `switchModelConfig` | - | 切换模型 |
| `switchCollaborationMode` | - | 切换模式 (build/edit/yolo/plan) |
| `setFollowupMode` | - | 设置后续模式 |
| `pauseGoal` | - | 暂停目标 |
| `resumeGoal` | - | 恢复目标 |
| `cancelBackgroundWork` | - | 取消后台工作 |
| `renameSession` | - | 重命名会话 |
| `deleteSession` | - | 删除会话 |

## sendConversationCommandV4 响应

```typescript
// 成功
{commandId: "cmd_xxx", status: "accepted", revisionAtDecision: 442}

// 重复 (同一个 commandId 发了两次)
{commandId: "cmd_xxx", status: "duplicate", revisionAtDecision: 442}

// 拒绝 (参数错误)
{commandId: "", status: "rejected", reasonCode: "proto.invalidPayload", message: "..."}

// 客户端不匹配 (clientId 与 initialize 不一致)
// type=202 error: "fault.command.clientMismatch"
```

## V4 事件帧 (type=204 EventFire)

通过 `onDynamicConversationFrame` listen 推送：

```typescript
{
  wireVersion: 3,
  kind: "complete",              // "complete" = 完整帧
  deliveryKind: "initial",       // "initial" = subscribe 后的首帧; "online" = 后续帧
  logicalFrameId: "sub-xxx-lf-82",
  logicalFrameOrdinal: 1,
  topic: "conversation/sess_xxx",
  subscriptionId: "sub-xxx",
  frame: {
    topic: "conversation/sess_xxx",
    // snapshot 或 deltas
  }
}
```

## getTaskSnapshotWithEtag

返回 v3 格式的 `snapshot.messages[]`（不是 v4 的 `rows[]`）。
snapshot.meta 包含: taskId, title, workspacePath, mode, model, thoughtLevel, provider, status。

## CAS 命令 (需要 baseRevision + baseLogEpoch)

switchModelConfig、switchCollaborationMode 等命令是 CAS (Compare-And-Swap)：
- envelope 必须包含 `baseRevision` 和 `baseLogEpoch`
- 从上一次操作的 `revisionAtDecision` 获取
- 从 subscribe 的 snapshot 获取初始 `revision` 和 `logEpoch`
- 如果 revision 过期 → `status: "stale", reasonCode: "proto.staleRevision"`
- revision 在 AI 流式回复期间持续递增

## createSession

```typescript
envelope: {
  kind: "input",
  type: "createSession",
  payload: {workspaceId: string, firstInput: {text: string}},
  commandId: string,
  clientId: string,
  issuedAt: number,
  sessionId: null,              // ★ null (不是空字符串!)
  baseRevision: number,         // CAS
  baseLogEpoch: string,
}
```

响应：
```typescript
{status: "accepted", result: {type: "createSession", sessionId: "sess_xxx"}}
```

## switchModelConfig

```typescript
payload: {provider: "glm", model: "builtin:zai/GLM-5.2", thought: "max"}
```

## switchCollaborationMode

```typescript
payload: {mode: "build" | "edit" | "yolo" | "plan"}
```

| channel | method | 参数 | 用途 |
|---------|--------|------|------|
| zcode-agent | helloConversationV4 | [] | V4 握手 |
| zcode-agent | initializeConversationV4 | {kind, protocolVersion, clientId, appVersion, clientKind} | 初始化 |
| zcode-agent | subscribeConversationV4 | {workspacePath, sessionId} | 订阅 |
| zcode-agent | unsubscribeConversationV4 | {subscriptionId} | 取消订阅 |
| zcode-agent | onDynamicConversationFrame | {workspacePath} (单个object!) | EventListen |
| zcode-agent | sendConversationCommandV4 | {workspacePath, envelope} | 发命令 |
| zcode-task | getTaskSnapshotWithEtag | {taskId, workspacePath, messageLimit, byteBudget, clientMode} | 获取历史 |
| model-provider | getAll | [] | 获取模型列表 |
| skills | list | {workspacePath, provider} | 获取技能列表 |

## CRC32

```dart
String _crc32(Uint8List data) {
  int crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc >>> 1) ^ (0xEDB88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
}
```
