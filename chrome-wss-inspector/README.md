# ZCode WSS 抓包分析器 (Chrome 扩展)

捕获 `zcode.z.ai` 远程页面 (`/remote/v4?...`) 的 WebSocket 帧, **自动解码 `dataBase64` 字段里的 RPC 二进制协议**, 提供可视化日志面板与筛选。

## 安装 (开发者模式加载)

1. Chrome 打开 `chrome://extensions`
2. 右上角打开「开发者模式」
3. 点「加载已解压的扩展程序」→ 选择本目录 (`chrome-wss-inspector/`)

## 使用

1. 打开要抓包的页面 (如 `https://zcode.z.ai/remote/v4?sid=...`), **也可以先开始抓包再打开页面**
2. 点浏览器工具栏的本扩展图标 → 「开始抓包」
   - 默认勾选「开始后自动刷新页面」: 刷新后从 `auth_init` 握手开始完整抓取 (推荐)
   - 抓包期间页面顶部会出现「正在调试此浏览器」提示条, 属 chrome.debugger 正常行为
3. 点「打开日志面板」进入独立日志页 (可长期挂着, 实时滚动)

## 功能

| 功能 | 说明 |
|------|------|
| 实时帧列表 | 时间 / 方向(↑发送 ↓接收) / 类型徽章 / `channel.method` / 摘要 / 大小 |
| **dataBase64 自动解码** | rpc-frame 的 base64 → varint+tag 二进制协议 (移植自 `lib/core/relay/rpc_codec.dart`), 直接显示 `REQ/LISTEN/UNSUB/INIT/OK/ERR/EVENT`、RPC id、`channel.method` 与完整 body JSON 树 |
| 分片自动重组 | 大帧 (如 786KB+ 全量快照) 按 `messageSeq` + `fragmentIndex/Count` 切片, 自动收齐拼接后解码; 超时未收齐会标记「分片未收齐」 |
| base64 字段智能预览 | body/payload 里任何疑似 base64 的长字符串 (如 `attachmentChunkV4.data`、`attachmentReadV4.bytes`、`exportSkillsArchive.archive`) 自动尝试解码并预览文本/hex |
| 筛选 | 关键字 (支持正则) / 方向 / 帧类型 (请求·订阅·响应·事件·错误·认证·数据层·系统) / 多标签页 / 隐藏未完成分片 |
| 详情面板 | 元信息表 + 可折叠 JSON 树 + RPC 原始字节 hex dump + WS 原始文本, 一键复制 |
| 其他 | 暂停渲染、自动滚动、清空、导出筛选结果为 NDJSON (最多 2000 条)、环形缓冲 8000 条 |

## 原理

- `chrome.debugger` (CDP) 附加到目标标签页, 监听 `Network.webSocketCreated / webSocketFrameSent / webSocketFrameReceived / webSocketClosed`
- 后台 Service Worker 解析 + 分片重组 + RPC 解码, 存环形缓冲 (8000 条 / 150MB 文本上限), 经长连接推给日志面板
- 抓包期间通过 keepalive 防止 SW 休眠丢日志; SW 意外重启时 debugger 附加状态会自动恢复 (但重启瞬间的日志缓冲会丢)

## 协议速查

外层 (WS 文本帧 JSON):

```
{type:'data', payload:{zcode_type:'rpc-frame', bridgeSessionId, messageSeq,
  fragmentIndex, fragmentCount, messageBytes, checksum, dataBase64}, client_ts}
```

`dataBase64` 解码后 = `[header][body]` 两个 varint+tag 值:
`header = [typeCode, id, channel?, method?]`

| typeCode | 含义 | 方向 |
|---------|------|------|
| 100 | PromiseRequest 请求 | C→S |
| 102 / 103 | EventListen / EventUnlisten | C→S |
| 200 | Init (bridge 就绪) | S→C |
| 201 | OK 响应 | S→C |
| 202 / 203 | Error / ErrorObject | S→C |
| 204 | EventFire 事件推送 | S→C |

完整协议见 `../docs/v4-API协议规格.md` 与 `../lib/core/relay/rpc_codec.dart`。

## 限制与注意

- `chrome://`、Web Store 等浏览器内置页面无法附加; 目标页已打开 DevTools 时会附加失败 (二者互斥)
- 同一 `device_sid` 只允许一个终端连接, 浏览器抓包会和 App 抢连接导致互相踢下线 — 抓包请用独立的 sid/hash
- 日志包含认证凭据 (proof/cookie 等), 不要把导出文件发给不可信的人
