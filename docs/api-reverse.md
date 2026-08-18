# 桌面端 ZCode LLM API 逆向笔记

> 来源：`ZCode-3.7.7-linux-x64` AppImage 的 `app.asar` 静态分析（2026-08-17）。
> 提取产物在 `/tmp/zcode_extract/out/`（host/index.js 为核心，约 1.7MB 混淆 ESM）。
> 函数名经 `i(fn,"原名")` 保留，可按原名 grep。

## 1. 架构

Electron 应用（`@zcode/desktop`），主进程入口 `out/main/index.js`，Agent 宿主在 `out/host/index.js`（基于 OpenCode 架构 + Vercel AI SDK 风格的 provider 抽象），另有 `out/scheduler/index.js`。**LLM 推理调用全部在 host 进程**，渲染层只做 UI/OAuth/远程控制。

## 2. LLM API：Anthropic Messages 协议

所有预置供应商统一走 Anthropic 兼容协议，路径 `POST {baseURL}/v1/messages`，SSE 流式（AI SDK anthropic driver）。

### 预置供应商目录（`Kk`，host/index.js ~offset 1107900）

| providerId | 名称 | baseURL | 模型 |
|---|---|---|---|
| `bigmodel` | BigModel - API Key | `https://open.bigmodel.cn/api/anthropic` | GLM-5.2, GLM-5-Turbo（另支持 openai 格式） |
| `zai` | Z.ai - API Key | `https://api.z.ai/api/anthropic`（国内 `api.chatglm.site`） | 同上 |
| `zaiStartPlan` | Z.ai - Coding Plan | `https://zcode.z.ai/api/v1/zcode-plan/anthropic` | GLM-5.2, GLM-5-Turbo（仅 anthropic 格式） |
| `bigmodelStartPlan` | BigModel - Coding Plan | 同上 | 同上 |
| `zapi` | ZAPI（内部） | `http://192.168.6.166:8080` | 动态 |

模型别名映射（`F$`）：claude haiku/sonnet → `GLM-5-Turbo`，opus/reasoning → `GLM-5.2`；另有 `glm-5.3` 特判（reasoning level max/high）。

### 请求头（`buildAnthropicConnectivityAuthHeaders` 等）

```
POST /v1/messages
content-type: application/json
Authorization: Bearer <apiKey>
x-api-key: <apiKey>
anthropic-version: 2023-06-01
```

请求体为标准 Anthropic Messages：`model / max_tokens / temperature(0.2) / stream / messages / tools / system`，reasoning 走 anthropic `thinking` 参数（`mL(...,"anthropic")`）。

### 完整请求头（以 `POST https://open.bigmodel.cn/api/anthropic/v1/messages` 为例）

基础头（所有供应商都带，`TR` + `buildAnthropicConnectivityAuthHeaders` + anthropic driver）：

```
Content-Type: application/json
Authorization: Bearer <apiKey>        # coding plan 为 {apiKeyId}.{secretKey}；API Key 通道为普通 key
x-api-key: <apiKey>                   # 与 Authorization 同值，双头同发
anthropic-version: 2023-06-01
User-Agent: ZCode/<appVersion>
HTTP-Referer: https://zcode.z.ai
X-Title: Z Code@electron
```

附加源信息头（`buildZCodeSourceHeadersFromContext` / `buildZCodeSourceHeaders`，对 zcode 自有端点/bigmodel 端点启用）：

```
X-ZCode-App-Version: <version>
X-Platform: linux-x64
X-Release-Channel: <stable等>
X-Client-Language: <locale>
X-Client-Timezone: <IANA时区>
X-Os-Category: <linux等>
X-Os-Version: <内核版本>
X-Device-Mid: <telemetry-state.json 里的设备ID>
X-ZCode-Agent: glm                    # 仅部分链路（connectivity 检测）追加
x-request-id: <uuid>                  # 通用请求追踪，apiClient 统一注入
```

> 服务端鉴权只依赖 `Authorization`/`x-api-key`（任一即可，客户端两个都发）；`User-Agent`/`HTTP-Referer`/`X-Title` 是 OpenRouter 风格的来源标识，非必需。用标准 Anthropic SDK 直调时只需前四个头。

## 3. 认证链（Coding Plan 关键流程）

OAuth 适配器两个：`bigmodel`（`De`）和 `zai`（`$G` 配置）。

### 3.1 Z.ai 登录链

1. OAuth 授权：`https://chat.z.ai/api/oauth/authorize`，clientId `client_P8X5CMWmlaRO9gyO-KSqtg`，redirect `zcode://oauth/callback`
2. 换 token：`POST https://zcode.z.ai/api/v1/oauth/token`
3. 业务 token：`POST https://api.z.ai/api/auth/z/login` body `{"token": <oauth access_token>}` → `data.access_token`（`ZaiBusinessTokenResolver`，缓存 expires_in）

### 3.2 Coding Plan API Key 自动签发（`resolveBizApiKey`，host/index.js ~1103k 附近 `cv` 类）

用 Bearer（bigmodel 用本地 `zcodejwttoken` 凭据，zai 用上一步业务 token）依次请求：

1. `GET {origin}/api/biz/customer/getCustomerInfo` → organizationId / projectId
   - origin：bigmodel 用 `https://bigmodel.cn`（dev 构建 `dev.bigmodel.cn`），zai 用 `https://api.z.ai`
2. `GET {origin}/api/biz/v1/organization/{org}/projects/{proj}/api_keys` → 找名为 **`zcode-api-key`** 的 key
3. 没有则 `POST .../api_keys` body `{"name":"zcode-api-key"}` 创建
4. `GET .../api_keys/copy/{apiKey}` → `secretKey`
5. 最终 API Key = **`{apiKey}.{secretKey}`**

该 key 以 `Authorization: Bearer` + `x-api-key` 双头发给上表 baseURL。

### 3.3 Off-Peak（闲时计划）通道

- 取票：`/api/v1/off-peak/ticket`（+ `/availability`、`/status`）
- 推理端点：`{zcode origin}/api/v1/off-peak/anthropic/v1/messages`
- 请求头：`Authorization: Bearer <jwt>`、`X-Coding-Plan-Api-Key: <codingPlanApiKey>`、`X-Off-Peak-Ticket-ID: <ticketId>`

## 4. 其他相关端点

- 订阅/账单：`/api/v1/zcode-plan/billing/current`、`/billing/balance`、`/api/biz/subscription/list`
- 配额：bigmodel `{origin}/api/monitor/usage/quota/limit`；zai `/api/monitor/usage/quota/limit`
- OAuth user info：`https://chat.z.ai/api/oauth/userinfo`
- 远程控制（手机端用的）：`https://zcode.z.ai/remote/v4`（WSS relay `/ws`），API `/api/remote-control/windows/*`
- 遥测：`/api/v1/event/report`

## 5. 对 zocde-app 的意义

- 如果目标是大模型直连：**`https://open.bigmodel.cn/api/anthropic/v1/messages` 是标准 Anthropic 兼容端点**，持有 coding-plan 的 `{apiKey}.{secretKey}`（或用户在 bigmodel 控制台生成的普通 API Key）即可用任意 Anthropic SDK 调 GLM-5.2/GLM-5-Turbo，流式 SSE 标准。
- StartPlan（订阅）流量走 `zcode.z.ai/api/v1/zcode-plan/anthropic` 代理，鉴权同 Bearer + x-api-key。
- 环境变量可覆盖：生产判定 `FP(env)`，base URL 均有 `ZCODE_*`/`ZAI_*` env 覆盖入口（`Dn(e,"ZAI_OAUTH_AUTHORIZE_URL")` 等）。

## 附：分析物料位置

- AppImage: `~/Applications/ZCode-3.7.7-linux-x64_*.AppImage`
- asar: `/tmp/zcode_asar_probe/app.asar`；提取物 `/tmp/zcode_extract/out/{host,main,scheduler,preload}`
- 渲染层旧提取：`~/zcode_analysis/`；remote v4 抓包：`~/下载/zcode-wss-*.ndjson`
