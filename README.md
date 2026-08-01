# ZCode App

> ZCode AI 编程助手的 Flutter 移动客户端（瘦客户端 / Thin Client）

[![Flutter](https://img.shields.io/badge/Flutter-3.44.2-02569B?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.12-0175C2?logo=dart)](https://dart.dev)
[![Platform](https://img.shields.io/badge/Platform-Android-3DDC84?logo=android)](https://www.android.com)
[![iOS](https://img.shields.io/badge/iOS-未测试-lightgrey?logo=apple)](#-环境要求)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

ZCode（zcode.z.ai）是智谱 AI（bigmodel）的 AI 编程助手。本仓库是它的**原生移动端**：APP 不做任何 AI 推理或文件 I/O，而是通过逆向工程的 WebSocket + RPC 协议接入 ZCode 的 **Relay 中继架构**，把命令转发到一台**在线的桌面端 Host 进程**，再以流式方式渲染结果。

所有协议均为**逆向实测**（非官方文档），`docs/` 是协议规格，`tool/` 是产生这些规格的探针脚本——这两处是线上协议的权威来源。

---

## ✨ 功能特性

| 模块 | 能力 |
|------|------|
| 🔐 **登录** | 粘贴连接地址 **或** 扫码，从桌面端会话导入**实时** `remote/v3` URL；Cookie 由 APP 自动 HTTP 拉取，无需手动输入 |
| 🗂️ **工作区** | 工作区 / 任务列表（`bootstrap-request`），本地缓存支持离线查看 |
| 💬 **对话** | 流式 AI 回复（`model.streaming` 增量合并）、**模式热切换**（变更前确认 / 自动）、`/` 命令面板、模型选择、质量档位 |
| 🎨 **Markdown / 代码** | `flutter_markdown` + 自研 `flutter_highlight` 代码高亮 |
| 🧩 **技能管理** | 查看 / 启用 ZCode skills |
| 📊 **用量统计** | GLM Coding Plan 配额与分档展示 |
| 🔍 **全局搜索** | 命令面板式快速跳转 |
| ⚙️ **设置** | 主题模式（浅 / 深 / 跟随系统，默认深色）、首选模型 |

---

## 🏗️ 架构

四层分层（详见 `docs/开发方案.md §4.1`）：

```
UI (features/*/screens)
        ↓
Riverpod providers (providers/)        ← 手写 Provider, 无 build_runner codegen
        ↓
Repositories (data/repositories/)
        ↓
RelayClient (WebSocket)  +  ZcodeApiClient (HTTP)  +  SecureStorage
```

### 目录结构

```
lib/
├── main.dart                    # 入口: ProviderScope + 恢复主题
├── core/
│   ├── relay/                   # ★ 核心: WebSocket + RPC 二进制协议
│   │   ├── relay_client.dart    # 连接生命周期 + 4 步 HMAC 握手 + 异步分发
│   │   ├── rpc_codec.dart       # 自描述二进制帧编解码 (tag + varint)
│   │   ├── relay_protocol.dart  # 数据层请求/响应
│   │   └── relay_events.dart    # 会话事件类型
│   ├── config/  network/  storage/  services/
├── data/
│   ├── models/                  # 手写纯 Dart 模型 (未启用 freezed)
│   └── repositories/
├── features/                    # 按业务域切分
│   ├── auth/    workspace/   chat/
│   ├── settings/  skills/    search/
├── providers/                   # app_providers.dart + chat_provider.dart
└── shared/
    ├── theme/                   # 设计令牌 + 路由 + 主题
    └── widgets/
```

### 状态管理

- **Riverpod 2.x，纯手写 Provider**（无 `@riverpod` 注解、无 codegen）。
- `relayClientProvider` 由持久化的 `ZcodeSession` 派生 `RelayClient`；其下游 `workspaceRepositoryProvider`、`chatProvider` 仅在会话有效时可用。
- 路由：`go_router`，聊天页通过查询参数打开：`/chat?workspace=<path>&task=<id>`。

---

## 🔌 Relay 协议（APP 的心脏）

连接生命周期（`relay_client.dart`）：

1. **WebSocket 连接** `wss://zcode.z.ai/ws?mid={mid}`，携带 `Cookie` + `Origin` 头。
2. **4 步 HMAC 握手**：`auth_init` → 服务端 `auth_challenge(nonce)` → 客户端 `auth_response`，其中 `proof = base64url(HMAC-SHA256(passHash, "{nonce}|terminal|{deviceSid}"))` → 服务端 `auth_ack`。
3. **数据层请求**（JSON，按 `requestId` 匹配）：`bootstrap-request`、`workspace-bridge-open`。
4. **Workspace Bridge** 打开通往桌面 Host 的通道；服务端自动推送 **RPC Init**（type=200），`_rpcReady` 置位后方可发起 RPC。
5. **RPC 帧**承载真实业务调用，使用**自描述二进制格式**。

二进制帧（`rpc_codec.dart`）：每个值 = `tag 字节 + varint(LEB128)`（tag：0=null, 1=string, 2/3=bytes, 4=list, 5=JSON, 6=int）；帧 = `[typeCode, id, channel, method/event] + body`。RPC 类型码：100=PromiseRequest、102=EventListen、200=Init、201=OK、202/203=Error、204=EventFire。

### 一次对话的流转（`chat_provider.dart`）

```
sendMessage
  → (新会话先 createSession)
  → subscribeSessionEvents(sessionId)
  → enqueueTaskCommand                # 立即返回, 回复经事件流回传
        ↓
session.event 帧 (按 kind 区分阶段):
  snapshot → state.updated → turn.started
  → model.streaming (重复, payload.delta 增量文本; 内层 kind: text_delta / reasoning_delta)
  → session.updated → turn.completed
```

`ChatNotifier._onSessionEvent` 把增量合并到最后一条 assistant 消息，在 `turn.completed` 时定稿。

> 完整权威规格见 `docs/API协议规格.md`（含所有 RPC 方法表，随探针实测持续订正）。

---

## 🚀 快速开始

### 环境要求

- Flutter 3.44.2 / Dart 3.12（参见 `.metadata`）
- Android 设备或模拟器
- 一台在线的 ZCode 桌面端 Host（用于实际 AI 推理）

> ℹ️ **关于 iOS**：项目未配置 iOS target，也未在 iOS 上测试过。理论上 Flutter 跨平台、依赖也未声明 iOS 不兼容，**但能否正常运行未经确认**——可自行 `flutter create -i ios .` 补全 iOS 工程后实测，欢迎反馈。

### 安装与运行

```bash
flutter pub get          # 安装依赖
flutter run              # 在已连接的设备 / 模拟器上运行
flutter analyze          # lint + 静态分析 (flutter_lints)
flutter test             # 跑全部 widget / 单元测试
```

### 生成应用图标

```bash
dart run flutter_launcher_icons
```

### 探针脚本（调试协议）

```bash
# 对线上会话 URL 跑最新一轮端到端探针（登录→订阅→发送→打印事件）
dart run tool/probe25.dart "<zcode-url>"
```

> ⚠️ `tool/session*.json` 与 `tool/captures/` 含真实 cookie / token，**已被 gitignore，严禁提交**。

---

## 🔑 使用方式

1. 在桌面端 ZCode 中打开「远程控制」，复制（或生成二维码）连接地址：`/remote/v3?sid=...&hash=...&mid=...&name=...`。
2. 打开 APP，**粘贴地址**或**扫码**登录。
3. 进入工作区列表 → 选择工作区 → 打开聊天 → 与 AI 对话。
4. 通过 `/` 命令面板、模式选择器、模型选择器控制行为。

---

## ⚠️ 关键约束 / 注意事项

- **Cookie 过期是独立使用场景的头号障碍。** `acw_tc`（服务端 `Set-Cookie`，`Max-Age=1800`/30 分钟）+ `_c_WBKFRo`（JS 挑战 cookie，脚本拿不到）共同保证 WS 握手。仅凭 HTTP 拉到的新鲜 `acw_tc` **不会**触发 `auth_challenge`（probe23 实测）。**凭据无法长期缓存复用**——APP 必须依赖用户从桌面端导入**实时** URL。长期刷新机制仍是开放问题（`docs/开发方案.md §7.2`）。
- **没有 REST API（路径 B）。** 所有业务操作（发消息、拉历史…）都走 WebSocket + RPC Bridge。`ZcodeApiClient` / `remoteControlApiPrefix` 仅供未经验证的「路径 A」使用，不要假设那些 REST 端点可用。
- **OAuth 用于模型提供商鉴权，而非设备登录。** `/api/v1/oauth/token` 授权智谱 / bigmodel 账号调用 GLM，**不会**签发 `remoteControlToken` / relay 凭据（详见 `docs/API协议规格.md §7.3`）。
- **桌面 Host 必须在线**，否则任何 Bridge / RPC 都无法工作。`workspace-bridge-error` 且 `reason: "desktop-disconnected"` 即代表 Host 未连 Relay。
- **device_sid 冲突会互相踢线**。APP 应使用独立 device_sid，避免把桌面 Host 顶掉。
- **`workspaceKey` == `workspacePath`**（已验证），`Workspace.fromJson` 会把两者赋同值。

---

## 📚 文档

| 文件 | 内容 |
|------|------|
| `docs/API协议规格.md` | **权威协议规格**（实测，含 RPC 方法表） |
| `docs/开发方案.md` | 整体架构 / 技术选型 / 路线图 |
| `docs/API逆向分析.md` | 早期逆向分析（部分已被规格文档订正） |
| `docs/ui-optimization.md` | UI 优化记录 |
| `docs/ui-style-guide.md` | **UI 设计规范**（基调 / 签名动作 / 三条硬规矩 / 反 AI-slop 清单） |
| `CLAUDE.md` | 给 AI 协作者的项目导览 |
| `tool/probe*.dart` | 产生协议规格的探针脚本 |

---

## 📝 协议逆向工作流

`docs/` 中的协议是增量逆向得到的，**后续订正覆盖早期结论**（每份文档都带探针日期引用）。修改协议相关代码时：

- `tool/probe*.dart` 是独立可 `dart run` 的脚本，用于对线上会话验证行为。`probe25.dart` 是最新端到端探针。`rpc_codec.dart` 的编解码辅助在探针中保持同步。
- 用探针验证 / 修改协议行为后，**同步更新 `docs/API协议规格.md` 对应章节**——它是 APP 代码遵循的规范基线。

---

## 📄 许可

[MIT License](./LICENSE) — Copyright © 2026 zcode-app contributors。

ZCode、智谱 AI、GLM 等名称版权归相应所有方所有。本项目与官方无任何关联，协议实现均为独立逆向研究成果。
