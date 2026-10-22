# zcode.z.ai /remote/v4 登录机制逆向报告

Case: 20261020-213606-zcode-remote-v4-web | 2026-10-20 | 被动抓取 + 静态分析 (scope: granted, GET-only)

## 结论 (TL;DR)
"需要登录"不是 cookie 壳,是 v4 代远控把 **Z.ai OAuth 账号体系**做成了 relay 硬门槛:
页面无 JWT → 前端渲染 auth-required 登录卡 → chat.z.ai OAuth 授权码换 zcode.z.ai 自家 JWT → 全部 relay API/WS 校验该 JWT。sid/mid 只是设备标识,不再等于授权。

## Evidence → Finding

### E1 page.html + headers.txt (HTTP 200, 无服务端重定向)
- F1: 登录门槛在前端 JS 与 API 层,不在 HTTP 路由层。SPA 为 Vite+React,资源按版本目录 `/remote/v4/3.16.2/assets/`。

### E2 index-U4xP7eLz.js (6.8MB 入口 bundle)
- F2 OAuth 配置 (明文): `VITE_ZAI_OAUTH_CLIENT_ID=client_P8X5CMWmlaRO9gyO-KSqtg`, `VITE_ZAI_OAUTH_ORIGIN=https://chat.z.ai`, BigModel 通道 `https://bigmodel.cn/login` (appId=zcode)。
- F3 授权码流: `GET https://chat.z.ai/api/oauth/authorize?redirect_uri=<origin>/remote/v4&response_type=code&client_id=...&state=base64url({nonce,app_return_to})`;state 仅 base64url(JSON),非加密,防篡改靠 localStorage `oauth_pending_logins` 的 nonce 比对(代码报错文案「OAuth CSRF 检测失败」)。无 PKCE。
- F4 换票: `POST /api/v1/oauth/token` (同源) body `{provider,code,redirect_uri,state}` → 返回 `{zaiAccessToken|accessToken, zcodeJwtToken, userInfo}`。
- F5 凭据全在 localStorage: `oauth:active_provider` / `zcodejwttoken` / `oauth:zai:access_token` / `oauth:zai:user_info` / `oauth:bigmodel:access_token` / `oauth:bigmodel:user_info`;`loadCachedSessionState()` 判 JWT 过期→`clearAll`+`reauthentication-required`。
- F6 登录门渲染: status `auth-required` → `data-testid=web-remote-control-auth-required` 卡片 + `webRemoteControl.authRequired.login` 按钮 → `startLogin()`,回跳 URL 白名单只保留 `app_version,sid,mid,name` 四参数。

### E3 src-BUN5Psaz.js 导出 io (REST 端点表)
- F7: register POST `/api/v1/remote/device`;list GET `/api/v1/remote/device`;delete POST `/api/v1/remote/device/delete`;token POST `/api/v1/remote/token` (body `{role:"terminal"}`,响应 zod 校验 `{accessToken,tokenType:"Bearer",expiresIn,expiresAt}`)。

### E4 validation-ZIynZ72X.js
- F8 WS 端点: `relayWsUrl = <origin>/api/v1/remote/ws2` (http→ws, https→wss)。
- F9 版本路由: `remoteUrl=/remote/{semver>=3.4.0?'v4':'v3'}` (阈值常量 `wd='3.4.0'`);同文件给出全 URL 表: apiBaseUrl `/api/v1`、webRemoteCallbackUrl `/remote/v4`、zcode-plan billing `/api/v1/zcode-plan/billing/*`。

### E5 index bundle I9n relay WS 客户端
- F10 握手: URL 追加 `?token=<短时terminal-token>&mid=<mid>` (token 由 JWT 经 POST /api/v1/remote/token {role:terminal} 换得, web 端 getToken 链);open 后发 `{"type":"auth_init","device_sid":"<sid>","meta":{"platform":"web","version":"<app_version>","name":"mobile-browser"},"client_ts":<unix秒>}`;心跳 pair-status 查询,指数退避重连 500ms→10s+jitter;服务端响应包裹 `{code:0,data:...}`。

### E6 实测 (curl, 无凭据)
- F11: `/api/v1/remote/device` GET → 401;`/api/v1/remote/token` POST → 401;`/api/v1/remote/ws2` GET → 401;`/remote/v3` → 307 → `/cn/remote/v3` → **404**(v3 页面已下线)。

## 推断 (标注为推断)
- "以前不用登录"之所以成立,推测旧代 relay(ws/v3)以 sid 配对即授权;v4+ws2 改为账号-JWT 绑定,设备必须归属已登录账号。
- 旧桌面端 (<3.4.0) 会打开 /remote/v3,现已 404 → 旧版被迫升级。

## 边界
未做且不做:登录绕过、凭据盗用、压测、截图。state 非加密但 nonce 比对可防 CSRF;未测 nonce 熵源外的进一步攻击面(超 scope)。
