# 3.16+ 账号登录适配设计（契约冻结）

> 背景: 桌面端 3.16+ 后 relay 强制账号认证。旧链路 (URL sid/hash + `/ws` HMAC) 对 3.16+ 桌面端失效。
> 逆向证据: `work/20261020-213606-zcode-remote-v4-web/`（3.16.2 web bundle 静态分析）。
> 本文档为两张任务卡的共享契约，一经发卡不得单方面变更。

## 1. 协议事实（来自 3.16.2 bundle 逆向）

### 1.1 OAuth（chat.z.ai 账号）
```
authorize: GET https://chat.z.ai/api/oauth/authorize
           ?redirect_uri=https://zcode.z.ai/remote/v4&response_type=code
           &client_id=client_P8X5CMWmlaRO9gyO-KSqtg&state=<base64url(json{nonce})>
回调:      https://zcode.z.ai/remote/v4?code=...&state=...
换票:      POST https://zcode.z.ai/api/v1/oauth/token
           body {provider:"zai", code, redirect_uri:"https://zcode.z.ai/remote/v4", state}
           → zcodeJwtToken + zaiAccessToken + userInfo
```
- state = base64url(JSON{nonce})，nonce 由客户端生成并在回调时比对（CSRF 防护）。
- app 用 WebView 拦截回调 URL 提取 code，不加载回调页。

### 1.2 设备与短时 token（REST，Bearer zcodejwttoken）
```
GET  /api/v1/remote/device            → {code:0, msg, data:[Device]}
POST /api/v1/remote/token             body {role:"terminal"}
                                        → {code:0, msg, data:{token, expires_in}}
```
- 统一包装: `{code:0,msg,data}` 成功 / `{code:≠0,msg}` 失败（zod `W(e)` 契约）。
- Device: `{device_sid: string, device_mid: string?, online: bool, created_at: ?, meta: {platform, version, name}}`
- terminal token: `^[A-Za-z0-9_-]{21}[AQgw]$`（22 字符），短时（expires_in 秒）。

### 1.3 WebSocket（ws2）
```
wss://zcode.z.ai/api/v1/remote/ws2?token=<terminal-token>&mid=<device_mid>
open 后发: {"type":"auth_init","device_sid":"<sid>",
            "meta":{"platform":"web","version":"<app_version>","name":"mobile-browser"},
            "client_ts":<unix秒>}
等 auth_ack: pair_status=="matched" → 就绪
```
- **无 auth_challenge/HMAC**（旧 `/ws` 的 4 步握手在 ws2 不存在）。
- auth_init **不带 role 字段**（web 3.16.2 实测形态）。
- zcode_type 消息层（bootstrap/bridge/rpc-frame）与旧链路相同，**不改**。
- token 过期/401 → 重新 POST /api/v1/remote/token 换新再重连。

## 2. 代码契约（卡1 产出，卡2 消费）

### 2.1 新文件 `lib/core/network/zcode_account_api.dart`
```dart
class ZcodeAccountApi {
  ZcodeAccountApi({String? origin});            // 默认 https://zcode.z.ai
  Uri buildAuthorizeUrl(String state);
  Future<ZcodeTokenSet> exchangeToken({required String code, required String state});
  Future<List<RemoteDevice>> listDevices({String? jwtOverride});
  Future<TerminalToken> issueTerminalToken({String? jwtOverride});
}
class ZcodeTokenSet { String zcodeJwtToken; String? zaiAccessToken; Map<String,dynamic> userInfo; }
class RemoteDevice  { String deviceSid; String? deviceMid; bool online; DateTime? createdAt; Map<String,dynamic>? meta; String get displayName; }
class TerminalToken { String token; int expiresIn; DateTime? expiresAt; }
class AccountAuthExpiredException implements Exception {}   // 401 时抛
```
- 用 dio。`_unwrap` 兼容 {code,msg,data} 包装与裸对象；code≠0 抛 `Exception(msg)`。
- exchangeToken 响应形状宽松解析：顶层或 data 嵌套递归找 `zcodeJwtToken`/`zaiAccessToken|accessToken`/`userInfo|user_info`。

### 2.2 RelayClient（`lib/core/relay/relay_client.dart`）
- `RelayAuthMode { legacyHash, accountJwt }`
- RelayConfig 增: `authMode`、`Future<String?> Function()? jwtProvider`；`passHash/cookie` 改为可空（legacy 必填校验放构造 assert）。
- 工厂: `RelayConfig.forAccount({deviceSid, mid, deviceName, appVersion, jwtProvider})` → wsUrl=`wss://zcode.z.ai/api/v1/remote/ws2`。
- `_doConnect` 分流: accountJwt 时先 `POST token(role:terminal)` 拿短时 token，URL 追加 `?token=&mid=`，auth_init 不带 role、不走 HMAC；401 抛 AccountAuthExpiredException。
- 旧 legacy 路径行为保持不变（回归保障）。

### 2.3 存储/模型
- `ZcodeSession` 增 `authMode`（默认 legacyHash）+ `appVersion` 字段（fromUrl 解析 URL `app_version`，缺省沿用 '3.7.7'→改为读到的值）。
- SecureStorage 增 key: `zcode_account_jwt` / `zcode_account_user`；AuthRepository 增 `restoreAccount/saveAccount/clearAccount`（`ZcodeAccount{jwt, userInfo}`）。

## 3. UI 契约（卡2）
- `AccountLoginScreen`: webview_flutter（主 agent 已批准新增此依赖）加载 authorize URL，拦截 `host==zcode.z.ai && path==/remote/v4 && query 含 code` → exchangeToken → 存 account → 设备页。
- `DevicePickerScreen`: listDevices 列表（displayName/online/mid），选中 → ZcodeSession(authMode: accountJwt, deviceSid, mid, name=meta.name, appVersion=meta.version) → 现有 splash 连接流程。
- LoginScreen 增「账号登录 (3.16+)」入口；旧扫码/粘贴链路保留。

## 4. 验收
- `flutter analyze` 0 error；`flutter test` 全绿（含新增单测：api 解包/token 解析/relay config 构造）。
- 旧链路（legacyHash）现有测试不回归。
