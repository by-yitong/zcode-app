# ZCode API 协议规格 (实测验证)

> 通过 WebSocket 实际连接 zcode.z.ai 验证,非推测
> 最后更新: probe 18/21/23 实测 (2026-06-15)

## 一、连接

```
WebSocket: wss://zcode.z.ai/ws?mid={mid}&t={timestamp}
Headers:
  Cookie: acw_tc=...; _c_WBKFRo=...; (从浏览器获取)
  Origin: https://zcode.z.ai
  User-Agent: Mozilla/5.0 ...
```

- `mid` 是设备 ID,从 URL 参数获取
- `t` 是当前毫秒时间戳 (可选,用于 URL 缓存控制)
- Cookie 是会话认证,必须携带
- **Cookie 易过期 (实测 probe23, 2026-06-15)** — `acw_tc` 由服务端 `Set-Cookie` 下发但 `Max-Age=1800` (30 分钟)；页面 JS 另会种 `_c_WBKFRo` 反爬 cookie (脚本/服务端请求拿不到)。仅凭 HTTP 取到的新鲜 `acw_tc` 连 WS，服务器**不发** `auth_challenge` (静默丢弃)；早期 probe 硬编码的整套 `sid/hash/mid+cookie` 现已整体失效。结论：APP 不能缓存凭据长期复用，必须持有有效会话 (浏览器实时 cookie 或重新走登录态)。
- **无 REST API 端点** — zcode.z.ai 是 Next.js 前端,所有业务只走 WebSocket

## 二、认证流程 (4 步握手)

### Step 1: 客户端 → auth_init
```json
{
  "type": "auth_init",
  "role": "terminal",
  "device_sid": "d_xxxxx",
  "meta": {
    "platform": "web",
    "version": "3.0.1",
    "name": "mobile-browser"
  },
  "client_ts": 1781500000000
}
```

### Step 2: 服务器 → auth_challenge
```json
{
  "type": "auth_challenge",
  "server_ts": 1781500000,
  "nonce": "随机字符串"
}
```

### Step 3: 客户端 → auth_response
```json
{
  "type": "auth_response",
  "device_sid": "d_xxxxx",
  "proof": "base64url编码的HMAC",
  "client_ts": 1781500000000
}
```

**proof 计算公式 (已验证正确):**
```
key  = UTF8(passHash)                        // passHash = URL hash 参数 URL-decode 后
data = UTF8("{nonce}|terminal|{device_sid}") // 注意分隔符是 |
proof = base64url(HMAC-SHA256(key, data))     // base64url: 无 padding, +→-, /→_
```

### Step 4: 服务器 → auth_ack
```json
{
  "type": "auth_ack",
  "server_ts": 1781500000,
  "device_sid": "d_xxxxx",
  "terminal_sid": "t_xxxxx",    // 服务端分配的终端会话ID
  "pair_status": "matched"
}
```

## 三、数据通信层

认证后的所有消息通过 `data` 类型包裹:

```json
{
  "type": "data",
  "server_ts": 1781500000,     // 服务器回传时带
  "payload": {
    "zcode_type": "xxx-request",
    "requestId": "唯一ID",
    ...其他字段
  },
  "client_ts": 1781500000000   // 客户端发送时带
}
```

请求/响应通过 `requestId` 配对。

## 四、已验证的 API 消息

### 4.1 Bootstrap — 获取工作区和任务列表 ✅

请求:
```json
{
  "zcode_type": "bootstrap-request",
  "requestId": "boot_001"
}
```

响应:
```json
{
  "zcode_type": "bootstrap-response",
  "requestId": "boot_001",
  "success": true,
  "result": {
    "workspaces": [
      {
        "kind": "local",
        "label": "项目名",
        "workspacePath": "/path/to/project"
      }
    ],
    "tasks": [
      {
        "taskId": "sess_xuid",
        "title": "任务标题",
        "displayStatus": "completed",
        "provider": "glm",
        "workspacePath": "/path/to/project",
        "workspaceLabel": "项目名",
        "workspaceKind": "local",
        "createdAt": 1781400000000,
        "updatedAt": 1781400000000
      }
    ],
    "mobileViewState": {
      "activeTaskId": "sess_xuid",
      "activeWorkspaceKey": "/path/to/project",
      "updatedAt": 1781400000000
    },
    "windowControlSessionId": "d_xxxxx"
  }
}
```

### 4.2 Workspace List — 刷新工作区列表 ✅

请求:
```json
{
  "zcode_type": "workspace-list-request",
  "requestId": "ws_list_001"
}
```

响应格式同 bootstrap-response 的 result。

### 4.3 Workspace Bridge — 桥接远程桌面 ⚠️

Bridge 是核心通信通道,连接 ZCode 桌面端的 host process。
**前提条件**: ZCode 桌面端必须在线 (浏览器打开 remote 页面显示正常)。

#### 4.3.1 打开 Bridge

请求:
```json
{
  "zcode_type": "workspace-bridge-open",
  "requestId": "wb_001",
  "bridgeSessionId": "bridge_xxx",     // 客户端生成的唯一 ID
  "bridgeGeneration": 1,                // 递增计数器,从 1 开始
  "workspaceKey": "/path/to/project",
  "taskId": "sess_xuid"                // 可选,指定初始任务
}
```

成功响应:
```json
{
  "zcode_type": "workspace-bridge-ready",
  "requestId": "wb_001",
  "bridgeSessionId": "bridge_xxx",
  "bridgeGeneration": 1,
  "bridge": {
    "bridgeSessionId": "bridge_xxx",
    "bridgeGeneration": 1,
    "workspaceKey": "/path/to/project",
    "workspacePath": "/path/to/project",
    "initialTaskId": "sess_xuid",
    "kind": "local"
  }
}
```

失败响应 (桌面端离线):
```json
{
  "zcode_type": "workspace-bridge-error",
  "requestId": "wb_001",
  "bridgeSessionId": "bridge_xxx",
  "bridgeGeneration": 1,
  "reason": "desktop-disconnected",
  "error": "未找到桌面窗口 host process，windowId=1"
}
```

降级通知:
```json
{
  "zcode_type": "bridge-degraded",
  "bridgeSessionId": "bridge_xxx",
  "bridgeGeneration": 1,
  "reason": "buffer-timeout",
  "droppedCount": 2
}
```

**注意事项:**
- bridge 依赖 ZCode 桌面端 host process 在线
- 探测脚本的 WS 连接和桌面端共用 `device_sid`,可能冲突导致 bridge 断开
- 建议 APP 使用独立的 `device_sid` 避免踢掉桌面端

#### 4.3.2 RPC Init — Bridge 就绪后自动推送

Bridge 连接成功后,服务端自动推送一个 RPC Init 帧:
```
rpc-frame: type=200 (Init), data=null
```
收到此帧后才能发 RPC 请求。

### 4.4 Mobile View State — 更新移动端视图 ✅

请求 (fire-and-forget,无响应):
```json
{
  "zcode_type": "mobile-view-state-update",
  "activeTaskId": "sess_xuid",
  "activeWorkspaceKey": "/path/to/project",
  "navigationIntent": "chat"
}
```

### 4.5 RPC Frame — 二进制 RPC 协议 ⚠️

这是 **ZCode 内部 IPC 协议**,不是简单的二进制帧头。
rpc-frame 的 `dataBase64` 字段包含自描述的序列化数据。

#### 4.5.1 JSON 包裹格式

```json
{
  "zcode_type": "rpc-frame",
  "bridgeSessionId": "bridge_xxx",
  "bridgeGeneration": 1,
  "seq": 1,
  "dataBase64": "base64编码的序列化数据"
}
```

`seq` 每次发帧递增,服务端响应也带 `seq`。

#### 4.5.2 二进制序列化格式 (自描述 varint 编码)

**每个值** = type-tag (1 byte) + 数据:

| type-tag | 类型 | 编码 |
|----------|------|------|
| 0x00 | null | 无额外数据 |
| 0x01 | string | varint(长度) + UTF-8 字节 |
| 0x02 | bytes (u8) | varint(长度) + 原始字节 |
| 0x03 | bytes | 同 0x02 |
| 0x04 | array | varint(元素数) + 逐个序列化元素 |
| 0x05 | JSON object | varint(长度) + UTF-8 编码的 JSON 字符串 |
| 0x06 | integer (varint) | varint 编码的无符号整数 |

**Varint 编码** (protobuf 兼容): 每字节低 7 位为数据,最高位为继续标志。

#### 4.5.3 RPC 消息类型

RPC 帧解码后是 `[type, id, channel, method]` (header) + `args` (body):

| type | 名称 | 说明 |
|------|------|------|
| 100 | PromiseRequest | 客户端 RPC 调用请求 |
| 102 | EventListen | 客户端订阅事件流 |
| 200 | Init | 服务端 RPC 就绪通知 (bridge open 后自动推送) |
| 201 | OK | PromiseRequest 的成功响应 |
| 202 | Error | PromiseRequest 的错误响应 (简单错误) |
| 203 | ErrorObject | PromiseRequest 的错误响应 (带 stack trace) |
| 204 | EventFire | 服务端推送的事件 |

#### 4.5.4 发送 RPC 请求 (PromiseRequest, type=100)

编码结构:
```
[100, requestId, "channel", "method"]  // header (array of 4 elements)
args                                     // body (any type)
```

**Dart 编码示例:**
```dart
Uint8List encodeRpcRequest(int id, String channel, String method, dynamic args) {
  final w = <int>[];
  // header
  serialize(w, [100, id, channel, method]);
  // body
  serialize(w, args);
  return Uint8List.fromList(w);
}
```

#### 4.5.5 订阅事件 (EventListen, type=102)

编码结构:
```
[102, requestId, "channel", "eventName"]  // header
args                                       // body (可选)
```

#### 4.5.6 RPC 响应

OK 响应:
```
[201, requestId]   // header
responseData       // body
```

错误响应:
```
[202/203, requestId]  // header
{message: "...", name: "...", stack: [...]}  // body (JSON object)
```

事件推送:
```
[204, requestId]  // header (requestId = 之前 EventListen 的 id)
eventData        // body (结构取决于事件类型)
```

## 五、RPC Channel 和方法 (Playwright 实测 2026-06-15)

> 通过 Playwright 驱动真实浏览器加载 zcode, 抓取 110+ 初始化事件 + 49 发送事件。
> **以下方法名和参数全部来自真实通信, 非推测。**

### 5.1 APP 核心方法 (已实测可用)

#### 发送消息 ★ — `zcode-task.enqueueTaskCommand`

```
header: [100, requestId, "zcode-task", "enqueueTaskCommand"]
body: [{
  "workspacePath": "/path/to/project",
  "taskId": "sess_xxx",
  "commandId": "queued_{毫秒时间戳}_{4位随机}",   // 客户端生成
  "traceId": "{uuid}",
  "queryId": "{uuid}",
  "type": "send_prompt",                            // 命令类型
  "content": "用户输入的文字",
  "clientId": "renderer:{uuid}",
  "clientLabel": "当前设备"
}]
```
响应 (立即返回, 表示已入队):
```json
{"accepted":true, "command":{"commandId":"...","taskId":"...","traceId":"...","queryId":"..."}}
```
**真正的 AI 回复通过事件订阅推送 (见 5.2)。**

#### 加载历史消息 ★ — `zcode-task.getTaskSnapshotWithEtag`

```
header: [100, requestId, "zcode-task", "getTaskSnapshotWithEtag"]
body: [{
  "taskId": "sess_xxx",
  "workspacePath": "/path/to/project",
  "messageLimit": 10,           // 返回最近 N 条消息
  "byteBudget": 204800,         // 字节预算
  "clientMode": "web-remote-replayable"
}]
```
响应: `{snapshot, etag, notModified}` (snapshot 见 5.3 消息结构)
带 etag 增量: 二次请求若数据未变, 返回 `{snapshot:null, notModified:true, etag:"..."}`

#### 任务列表 — `zcode-task.listTaskList` / `listWorkspaceTaskLists`

```
body: [{"kind":"pinned","workspaceScopes":[{"workspacePath":"..."}]}]
body: [{"workspaceScopes":[{"workspacePath":"..."}]}]
```

#### 读取会话详情 — `zcode-session.readSession`

```
body: [{"workspacePath":"...","sessionId":"sess_xxx","messageLimit":1}]
```
返回完整 session + settings + projection + runtime + messages (结构见 5.3)

### 5.2 事件订阅 ★ — AI 流式回复机制

#### 订阅事件 — `zcode-session.onDynamicSessionEvent` (type=102)

```
header: [102, requestId, "zcode-session", "onDynamicSessionEvent"]
body: [{"workspacePath":"...", ...}]
```
订阅后, 服务器持续推送 `type=204 (EventFire)` 帧, 每帧 body:
```json
{
  "type": "session.event",
  "event": {
    "eventId": "{uuid}",
    "sessionId": "sess_xxx",
    "turnId": "turn_xxx",          // 同一次提问共享 turnId
    "seq": 1723,                   // 单调递增的事件序号
    "traceId": "{uuid}",
    "timestamp": 1781510585833,
    "deliveryKind": "web-remote-replayable",
    "type": "tool.updated",        // ← 事件类型 (见下表)
    "payload": { ... }             // ← 类型相关
  }
}
```

#### 已实测的事件 type (event.type)

| event.type | payload 示例 | 说明 |
|-----------|--------------|------|
| `tool.updated` | `{toolCallId, toolName:"Bash", kind:"progress", elapsedMs, stdoutBytes, ...}` | 工具调用进度 |
| _(text 流式)_ | _(本次抓包 AI 一直在跑 Bash, 未出文本流; 推测为 `text.delta`/`text.done`, 待再抓)_ | 文本块流式 |

> ⚠️ 本次抓包的两次 sendPrompt, AI 都选择调 Bash 工具而非直接回文字,
> 所以没抓到文本流事件。但机制已确认: 所有 AI 输出都是 `session.event`,
> 只是 `event.type` 不同。需再抓一次让 AI 直接回文字的场景。

### 5.3 数据模型 (实测 schema)

#### Message (历史消息, 来自 getTaskSnapshotWithEtag)

```typescript
interface Message {
  id: string;              // "msg_" + 短码 + uuid
  role: "user" | "assistant";
  content: string;         // 完整文本 (markdown)
  timestamp: number;       // 毫秒
  model: string;           // "{providerId}/{modelId}", 如 ".../glm-5.2"
  turnIndex: number;       // 第几轮对话
  // assistant 额外字段:
  thought?: string;        // 思考过程 (thinking)
  durationMs?: number;     // 耗时
  parts?: Part[];          // 结构化分块
}

interface Part {
  type: "thought" | "content" | ...;   // thought=思考, content=正文
  content: string;
}
```

#### Task Meta (任务元数据, 来自 snapshot.meta)

```typescript
interface TaskMeta {
  taskId: string;          // "sess_" + uuid
  traceId: string;
  title: string;           // 任务标题 (取首条输入)
  workspacePath: string;
  createdAt: number;
  updatedAt: number;
  mode: "build";           // 代理模式
  model: string;           // "{providerId}/{modelId}"
  thoughtLevel: "max" | "nothink";
  provider: "glm";
  status: "running" | "completed" | "error";
  target: null;
}
```

#### Session (来自 readSession)

```typescript
interface Session {
  protocol: {name:"ZCode Protocol", version:1};
  session: {sessionId, workspace, traceId, sessionKind, title, mode, status, model, ...};
  settings: {
    model: {current:{providerId, modelId}, available:[...], lastUsed:{...}},
    thoughtLevel: {enabled, current, available:[...]},
    mode: {current:"yolo"|"build"},
    permission: {mode:"yolo"}
  };
  projection: {turnCount, totalTokenCount, contextUsed, contextWindow:1000000, currentTurnId, activeToolCalls, ...};
  runtime: {eventSeq, stateRevision, activeTurnId, contextUsage:{used,size,breakdown:[...]}, ...};
  messages: Message[];
}
```

### 5.4 其他实测方法 (init 阶段抓到的完整目录)

| channel | 方法 | 用途 |
|---------|------|------|
| `zcode-task` | `getTaskTokenUsage` | Token 用量 |
| `zcode-task` | `getTaskNativeSessionLogFile` | 原生日志文件路径 |
| `zcode-task` | `getTaskSessionFilePath` | 会话文件路径 |
| `zcode-task` | `getWorkspaceProviderConfigFile` | 工作区模型配置 |
| `zcode-task` | `resumeTask` | 恢复任务 |
| `zcode-session` | `readSession` | 读会话 (见 5.1) |
| `zcode-session` | `onDynamicSessionEvent` | 订阅事件 (见 5.2) |
| `model-provider` | `getAll` / `getAllCached` / `getDisplayOrder` | 模型列表 |
| `skills` | `list` | 技能列表 |
| `subagents` | `list` | 子代理列表 |
| `feedback` | `list` | 反馈列表 |
| `git` | `refresh` | git 状态刷新 |
| `setting` | `get` | 读设置 |
| `settings-sync` | `getFirstRunPromptState` | 首次运行状态 |
| `oauth` | `restoreCachedSession` | 恢复 OAuth 会话 (模型供应商) |
| `coding-plan-subscription` | `getBillingDiscount` / `getCaptchaConfig` | 订阅/验证码 |
| `broadcast` | `onMessage` | 广播消息订阅 |

> 注: 旧 probe (14-22) 报告的 `zcode-agent.sendPrompt`、`zcode-task.getTaskSnapshot`(无 WithEtag)、
> `zcode-agent.taskStream` 等**都是错的** —— 真实方法是 `zcode-task.enqueueTaskCommand` +
> `zcode-task.getTaskSnapshotWithEtag` + `zcode-session.onDynamicSessionEvent`。

### 5.6 GLM Coding Plan 余量 (走外部直连, 不走 relay)

> **⚠️ 架构说明**: GLM coding plan 余量查询**不经过** relay/RPC, 而是直连智谱开放平台的 quota endpoint。
> 原因: relay 后端未暴露 quota 方法 (coding-plan-subscription channel 只记录了 getBillingDiscount / getCaptchaConfig),
> 故参照 cc-switch (`src-tauri/src/services/coding_plan.rs`) 的智谱段直连实现。

**协议 (移植自 cc-switch, 2026-06 实测):**
```
GET https://open.bigmodel.cn/api/monitor/usage/quota/limit   # CN (open.bigmodel.cn)
GET https://api.z.ai/api/monitor/usage/quota/limit           # 国际站 (api.z.ai)
Headers:
  Authorization: {api_key}        # ⚠️ 不加 Bearer 前缀, 直接裸 key
  Content-Type: application/json
  Accept-Language: en-US,en
```

**响应分类逻辑** (`data.limits[]`, 筛 `type=="TOKENS_LIMIT"`):
| `unit` | 窗口 | 字段 |
|--------|------|------|
| `3` | 5 小时滚动窗口 | `percentage`(已用%), `nextResetTime`(ms epoch) |
| `6` | 每周窗口 | 同上 |

**关键陷阱 (cc-switch issue #3036)**: 周期末尾每周桶可能比 5h 桶更早重置, 不能按 `nextResetTime` 排序判定窗口类型, **必须以 `unit` 字段为准**。老套餐 (2026-02-12 前订阅) 只回 1 条 TOKENS_LIMIT, 自然降级为仅 5h 窗口。

**实现位置**:
- 服务: `lib/core/services/glm_quota_service.dart` (`GlmQuotaService.fetch`)
- 模型: `lib/data/models/glm_quota.dart` (`GlmQuota` / `GlmQuotaTier`)
- 凭据: `SecureStorageService.saveGlmCredential/getGlmCredential` (key `glm_credential`, 与 session 同级保护)
- Provider: `glmCredentialProvider` + `glmQuotaProvider` (`lib/providers/app_providers.dart`)
- UI: 设置页用户卡片摘要 + 'GLM 用量' 分区卡片 (含凭据编辑 sheet)


## 六、Workspace 数据模型 (实测)

```typescript
interface Workspace {
  kind: "local" | "remote";
  label: string;              // 项目名 (文件夹名)
  workspacePath: string;      // 完整路径
}

interface Task {
  taskId: string;             // "sess_" + UUID
  title: string;
  displayStatus: "completed" | "running" | "error";
  provider: "glm";            // AI 模型供应商
  workspacePath: string;
  workspaceLabel: string;
  workspaceKind: "local" | "remote";
  createdAt: number;          // 毫秒时间戳
  updatedAt: number;
}

interface MobileViewState {
  activeTaskId: string;
  activeWorkspaceKey: string;
  updatedAt: number;
}
```

## 七、URL 参数 → 认证凭据映射

zcode 客户端 JS (`index-DMg1tzSS.js`) 实测：URL query 存在**两条互斥的认证入口**，由 `remoteControlToken` 是否存在分派：

```js
// 客户端分派逻辑 (实测自 bundle)
const params = new URLSearchParams(window.location.search);
if (params.has('remoteControlToken')) → 走 REST 路径 (LWt)
else                                   → 走 WebSocket 路径 (本文档二~四节描述的)
```

### 7.1 WebSocket 路径 (本会话所用)

```
https://zcode.z.ai/remote/v3?
  sid=d_xxx        → device_sid (HMAC 认证用)
  hash=xxx         → passHash (URL decode 后, HMAC key)
  mid=xxx          → WebSocket URL 的 mid 参数
  name=xxx         → 设备名 (meta.name)
  app_version=3.0.1
  t=1781506241728  → 时间戳 (可选,URL 缓存控制)
```
- 认证：4 步 HMAC 握手 (第二节)。⚠️ **仅需 HTTP GET 该 URL 拿到的 acw_tc cookie** (2026-06-16 实测订正: `_c_WBKFRo` 非必需, 旧 probe23 "acw_tc 不足"结论是漏发 auth_init 的 bug, 见 §9 #8/#10)
- 本会话属此类

### 7.2 REST 路径 (token 直连,APP 更友好)

```
https://zcode.z.ai/web-remote?     ← 注意路径不同,不是 /remote/v3
  remoteControlToken=xxx   → 路径参数 token (拼进 URL path, 不是 HMAC)
  relayOrigin=xxx          → relay 服务器 (默认 window.location.origin)
```
- **无需 cookie / HMAC** —— token 直接拼进 URL path 调 REST
- 端点 (实测自 bundle, `e.token` = remoteControlToken)：
  ```
  GET  ${relayOrigin}/api/remote-control/windows/bootstrap/${token}        # 工作区列表
  POST ${relayOrigin}/api/remote-control/platform/${token}                 # 平台 RPC
       body: {method, args}
  POST ${relayOrigin}/api/remote-control/windows/${token}/workspace-bridge # 桥接
  POST ${relayOrigin}/api/remote-control/windows/${token}/mobile-view-state # 移动端视图
  ```
- ⚠️ **未亲测联通**：本会话只有 sid/hash/mid，无 remoteControlToken；用 sid/mid/hash 当 token 调上述端点全部 404 (2026-06-15 实测)。需要从一次真实 web-remote 会话抓 `remoteControlToken` 才能验证此路径。
- ✅ 对 APP 的意义：若此路径可用，可彻底绕开 cookie 过期 / JS 挑战问题，是更优解

### 7.3 OAuth 与 relay 认证无关 (订正静态分析)

`/api/v1/oauth/token` 端点真实存在 (POST 返回 `{"code":3001,"msg":"parameter error"}`)，但**用途被 `API逆向分析.md` 误描述**。实测 bundle 配置：

```js
tokenUrl:   `/api/v1/oauth/token`
clientId:   client_P8X5CMWmlaRO9gyO-KSqtg
authorizeUrl: <VITE_ZAI_OAUTH_ORIGIN>  // chat.z.ai
```

代码中 OAuth 全部绑在**模型供应商授权**上 (`oauth_provider_inactive` / `zai-auth→z.ai` / `oauth→bigmodel` / `BigModel 账号未注册`) —— 它是用户登录智谱账号拿 API key 调 GLM 的流程，**不是**获取 remoteControlToken / relayOrigin 的设备登录。静态分析文档第二节"OAuth 认证 - 用于获取 access_token"和"remoteControlToken/relayOrigin 通过 OAuth 流程获取"的描述是错的，应以此处为准。

## 八、完整的连接时序

```
客户端                                    Relay 服务器                    ZCode 桌面端
  │                                           │                              │
  ├─ WebSocket connect ──────────────────────→│                              │
  ├─ auth_init ──────────────────────────────→│                              │
  │←── auth_challenge (nonce) ───────────────┤                              │
  ├─ auth_response (HMAC proof) ────────────→│                              │
  │←── auth_ack (terminal_sid) ──────────────┤                              │
  │                                           │                              │
  ├─ bootstrap-request ─────────────────────→│                              │
  │←── bootstrap-response (workspaces+tasks) ─┤                              │
  │                                           │                              │
  ├─ workspace-bridge-open ─────────────────→│── RPC 转发 ─────────────────→│
  │                                           │←── bridge-ready ─────────────┤
  │←── workspace-bridge-ready ─────────────────┤                              │
  │                                           │                              │
  │←── rpc-frame (RPC Init, type=200) ─────────┤←── IPC response ────────────┤
  │                                           │                              │
  ├─ rpc-frame (RPC Request) ───────────────→│── RPC 转发 ─────────────────→│
  │←── rpc-frame (RPC Response/Event) ─────────┤←── IPC response/event ──────┤
  │                                           │                              │
  ├─ rpc-frame (sendPrompt) ────────────────→│── RPC 转发 ─────────────────→│
  │                                           │                              │
  │   (桌面端执行 AI agent,处理文件等)         │                              │
  │                                           │                              │
  │←── rpc-frame (EventFire: 消息块) ─────────┤←── IPC event ───────────────┤
  │←── rpc-frame (EventFire: 思考块) ─────────┤←── IPC event ───────────────┤
  │←── rpc-frame (EventFire: diff) ───────────┤←── IPC event ───────────────┤
  │←── rpc-frame (OK: 完成) ─────────────────┤←── IPC response ────────────┤
```

## 九、关键发现和注意事项

1. **没有 HTTP REST API** — 所有业务操作 (发消息、获取历史等) 只能通过 WebSocket + RPC bridge
2. **Bridge 依赖桌面端在线** — ZCode 桌面端 host process 必须运行并连接到 relay
3. **device_sid 冲突** — 多个客户端共用同一 device_sid 会互相踢掉,APP 应使用独立 device_sid
4. **RPC 方法注册在桌面端** — 方法存在性取决于 ZCode 桌面端版本,错误来自桌面端 JS (index.js)
5. **sendPrompt 可能不直接返回** — 需要通过 EventListen 订阅流式事件来接收 AI 响应
6. **zcode-task.getTaskSnapshot** 需要 model 参数 — 具体格式待进一步探测
7. **消息历史不在 zcode-task.getMessages** — 该方法不存在,消息可能通过其他方法或事件获取
8. **凭据保鲜 (订正)** — 旧 probe23 结论"光有 acw_tc 触发不了 auth_challenge"**是错的**: 真因是 probe23 没发 `auth_init`。2026-06-16 probe_rpc 实测: HTTP GET `/remote/v3` 拿到的**仅 acw_tc** (cookie 长度 69, 无 `_c_WBKFRo`), WS 连上 + 发 `auth_init` 后, 服务器正常回 `auth_challenge`, `auth_ack pair_status=matched` 认证成功。→ **`loginFromUrl` 那套 cookie 抓取足够认证** (app 可用)。残余问题只是 acw_tc 30 分钟过期 + 仍需用户导入实时 sid/hash/mid URL (凭据保鲜长期方案见开发方案.md §7.2)。
9. **Bridge 单会话独占** (2026-06-16 实测) — 一个会话 (sid) **同时只允许一个 workspace bridge**。若用户的 zcode 桌面/web 客户端正持有桥接, 另一终端的 `workspace-bridge-open` 立即返回 `"error":"Workspace bridge request was superseded."` (所有工作区都失败, 与具体 workspace 无关, 是 session 级独占)。→ APP 会与桌面客户端**抢桥接**, 需做 reconnect-on-supersede。探针要 RPC 探测时, 用户须先关掉 zcode 客户端窗口腾出桥接 (host 进程保留)。
10. **认证只需 auth_init + acw_tc** — WS 连上后**必须先发 `auth_init`** 才会收到 `auth_challenge`; 不发则服务器静默不回 (probe25/probe_rpc 首版都栽在这)。
11. **无文件 RPC / mode 可热改** — 见 §5.5 订正: 没有文件列举 RPC (移动端做不了真 @文件); `session/setMode`、`session/setModel` 存在, 已有会话能改模式/模型。

## 十、待验证 (Phase 2)

- [ ] RPC 方法参数正确格式 (特别是 getTaskSnapshot 的 model 字段)
- [ ] sendPrompt 的流式事件接收 (需要先建立 EventListen)
- [ ] 加载任务历史消息的正确方法名
- [ ] 创建新任务的 API
- [ ] workspace-reconnect-request 重连流程
- [ ] 事件订阅的完整事件类型列表
- [ ] 独立 device_sid 的注册方式 (避免和桌面端冲突)
- [ ] **凭据保鲜方案** — acw_tc 30 分钟过期；需确定 APP 如何在无浏览器的情况下获得/刷新有效会话 (⚠️ 已订正: 仅 acw_tc + auth_init 即可认证, 见 §9 #8; probe23 "acw_tc 不足"是漏发 auth_init 的 bug)
