# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

`zcode_app` is a **Flutter mobile client for ZCode** (智谱AI's AI coding assistant at zcode.z.ai). It is a **thin client** over ZCode's *Relay* remote-control architecture: the app speaks ZCode's private WebSocket protocol to the relay server, which forwards RPC to a **ZCode desktop host process** that runs the actual AI agent and filesystem. The app only sends commands and renders streaming results — it does no AI inference or file I/O itself.

The entire ZCode protocol is **reverse-engineered** (not officially documented). `docs/` holds the protocol spec; `tool/` holds the probe scripts that produced it. Treat those two directories as the source of truth for the wire protocol — they are more authoritative than assumptions from similar products.

## Commands

```bash
flutter pub get                      # install/refresh deps
flutter run                          # run on attached device/emulator (Android only — no iOS target configured)
flutter analyze                      # lint + static analysis (flutter_lints)
flutter test                         # run all widget/unit tests
flutter test test/widget_test.dart   # run a single test file
dart run tool/probe25.dart "<zcode-url>"   # run the latest protocol probe against a live session URL
```

Toolchain: Flutter 3.44.2 / Dart 3.12 (see `.metadata`). The flutter/dart binaries live at `~/.local/bin/`.

**No code generation is currently active.** `freezed`, `json_serializable`, and `riverpod_generator` are declared in `pubspec.yaml` but **not used** — models (`lib/data/models/`) and providers (`lib/providers/`) are hand-written plain Dart. If you add `@freezed`/`@riverpod` annotations, run `dart run build_runner watch --delete-conflicting-outputs`.

## Architecture

Four layers (see `docs/开发方案.md §4.1`):

```
UI (features/*/screens)  →  Riverpod providers (providers/)  →  Repositories (data/repositories/)  →  RelayClient (WS) + ZcodeApiClient (HTTP) + SecureStorage
```

- **State management: Riverpod 2.x, hand-written providers** (no codegen). All providers live in `lib/providers/app_providers.dart` (infra/session/relay/repositories) and `lib/providers/chat_provider.dart`. `relayClientProvider` derives a `RelayClient` from the stored `ZcodeSession`; everything downstream (`workspaceRepositoryProvider`, `chatProvider`) becomes available only once a valid session exists.
- **Routing: go_router**, declared as a global `goRouterProvider` in `lib/shared/theme/app_router.dart`. Chat screen is opened via query params `/chat?workspace=<path>&task=<id>`.
- **Entry: `lib/main.dart`** wraps the app in `ProviderScope`; theme defaults to **dark** (`themeMode: ThemeMode.dark`, a dev setting).

### The Relay protocol — `lib/core/relay/` (the heart of the app)

This is the most important code to understand. Connection lifecycle in `relay_client.dart`:

1. **WebSocket connect** to `wss://zcode.z.ai/ws?mid={mid}` with `Cookie` + `Origin` headers.
2. **4-step HMAC auth handshake**: `auth_init` → server `auth_challenge(nonce)` → client `auth_response` with `proof = base64url(HMAC-SHA256(passHash, "{nonce}|terminal|{deviceSid}"))` → server `auth_ack`.
3. **data-layer requests** (JSON, matched by `requestId`): `bootstrap-request` (workspaces + tasks), `workspace-bridge-open`.
4. **Workspace Bridge** opens a channel to the desktop host; server auto-pushes an **RPC Init** frame (type=200). `_rpcReady` must be true before any RPC call.
5. **RPC frames** carry the actual business calls, encoded in a **self-describing binary format**.

Two pairing maps drive async dispatch in `RelayClient`: `_pending` (data-layer `requestId` → completer) and `_pendingRpc` (RPC `id` → completer). RPC event subscriptions (type=204) route to both a per-subscription controller and the global `onSessionEvent` stream.

`rpc_codec.dart` implements the **binary wire format**: tag-byte + varint(LEB128) per value (tag 0=null, 1=string, 2/3=bytes, 4=list, 5=JSON, 6=int). Frame = `[header] + [body]` where header is `[typeCode, id, channel, method/event]`. RPC type codes: 100=PromiseRequest, 102=EventListen, 200=Init, 201=OK, 202/203=Error, 204=EventFire.

Key RPC methods (all reverse-engineered, see `docs/API协议规格.md §5`): `zcode-task.enqueueTaskCommand` (send a message — returns immediately, reply comes via events), `zcode-task.getTaskSnapshotWithEtag` (history), `zcode-session.createSession`, `zcode-session.onDynamicSessionEvent` (subscribe to AI streaming).

### How a chat turn flows (`chat_provider.dart`)

`sendMessage` → (new chat: `createSession` first) → `subscribeSessionEvents(sessionId)` → `enqueueTaskCommand`. The AI's streaming reply arrives as `session.event` frames whose `kind` field (NOT `type`) identifies the stage: `snapshot` → `state.updated` → `turn.started` → `model.streaming` (repeated, with `payload.delta` = incremental text; inner `payload.kind` = `text_delta` vs `reasoning_delta`) → `session.updated` → `turn.completed`. `ChatNotifier._onSessionEvent` appends deltas to the last assistant message and finalizes on `turn.completed`. **Note:** the older `AgentEvent*` types in `relay_events.dart` were speculative and are largely superseded by `SessionEvent`; `model.streaming`/`kind` is what the real server sends.

## Critical constraints & gotchas

- **Cookie expiry is the #1 blocker for standalone app use.** `acw_tc` (server-set, `Max-Age=1800`/30 min) plus `_c_WBKFRo` (a JS-challenge cookie scripts can't obtain) are required for the WS handshake. A freshly HTTP-fetched `acw_tc` alone does **not** trigger `auth_challenge` (verified probe23). Sessions cannot be cached and reused long-term — the app relies on the user importing a **live** `/remote/v3?sid=...&hash=...&mid=...&name=...` URL (paste or QR) from a desktop session, via `AuthRepository.loginFromUrl`. Long-term credential-refresh is an open problem (`docs/开发方案.md §7.2`).
- **No REST API on path B.** Every business operation (send message, load history, …) goes over WebSocket + RPC bridge. `ZcodeApiClient`/`AppConfig.remoteControlApiPrefix` exist for the unvalidated REST "path A" (`/web-remote?remoteControlToken=...`) — do not assume those REST endpoints work; they 404 without a real `remoteControlToken`.
- **OAuth is for model-provider auth, NOT device login.** `/api/v1/oauth/token` authorizes 智谱/bigmodel accounts to call GLM; it does not mint `remoteControlToken`/relay credentials. The earlier `API逆向分析.md` description here was wrong and is corrected in `API协议规格.md §7.3`.
- **The desktop host must be online** for any bridge/RPC work. `workspace-bridge-error` with `reason: "desktop-disconnected"` means the host process isn't connected to the relay.
- **device_sid conflicts kick each other off.** The probe's WS connection and the desktop host share a device_sid; the app should generate/use an independent device_sid to avoid disconnecting the desktop (see `API协议规格.md §9`).
- **`workspaceKey` == `workspacePath`** in this protocol (verified). `Workspace.fromJson` sets `workspaceKey = workspacePath`.

## Reverse-engineering workflow

The protocol in `docs/` was reverse-engineered incrementally; later corrections supersede earlier claims (each doc carries dated probe references). When working on protocol code:

- `tool/probe*.dart` are standalone `dart run` scripts that drive a live session to capture/verify protocol behavior. `tool/probe25.dart` is the latest end-to-end probe (login → subscribe → send → print events). The `ws_probe*.dart` files are older WebSocket probes. RPC encode/decode helpers in probes are intentionally kept in sync with `rpc_codec.dart`.
- `tool/session.example.json` is the template for probe input; **real `tool/session*.json` and `tool/captures/` are gitignored** (they contain live cookies/tokens — never commit them).
- Capture artifacts (`sample_init_events.json`, `sample_send_events.json`) came from Playwright-driven browser captures and seeded the documented RPC method list.

When you verify or change protocol behavior via a probe, update the corresponding section in `docs/API协议规格.md` (it is the canonical spec the app code follows).

## UI / Design conventions

**Read `docs/ui-style-guide.md` before writing any UI.** It defines the app's visual rules — Linear-dark + electric-blue dev-tool tone, signature interactions (mono-for-metadata, foldable tool-call logs, floating Todo panel, douban-style press-to-talk voice), and three hard rules:

1. No inline magic numbers — use `AppSpacing`/`AppRadius`/`AppTextSizes`/`AppTouch` tokens (defined in `lib/shared/theme/app_design_tokens.dart`).
2. Motion only animates `transform`/`opacity`; durations via `AppDur`, curves via `AppEase`. Never bare `Curves.ease`.
3. Status colors via `AppColors` + `*Container` variants, never inline hex.

An interactive HTML preview lives at `design/ui_preview.html` (open in a browser). Shared reusable widgets are being added under `lib/shared/widgets/` (`AppEmptyState`, `AppTileGroup`, `AppSectionHeader`).
