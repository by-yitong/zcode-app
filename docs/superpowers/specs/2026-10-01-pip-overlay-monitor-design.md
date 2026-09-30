# ZCode 悬浮窗进度监视器（画中画）设计

日期: 2026-10-01
状态: 已确认（用户拍板: 系统级 + 可滑动 → 真·系统悬浮窗方案）

## 背景与目标

AI 会话任务动辄运行数分钟。用户希望在使用其他 App 时持续观察 ZCode 各会话的
AI 输出进度：从会话页点"画中画"按钮 → 弹出系统级悬浮小窗（悬浮在所有 App 之上、
可拖动）→ 左右滑动切换其他正在工作的会话 → 小窗显示每个会话最新 AI 输出的尾部
若干行（行数在设置里可配）。

## 非目标

- 不做系统 PiP（窗口收不到触摸事件，无法滑动切换，已否决）。
- 不做 iOS / Linux 桌面端（`flutter_overlay_window` 仅 Android；入口按钮在
  非 Android 平台隐藏）。
- 小窗内不做输入/发消息（只读监视器）。
- 不做自动轮播。

## 交互流程

1. 会话页顶栏出现画中画图标按钮（仅 `Platform.isAndroid` 时显示）。
2. 点击：
   - 未授权"显示在其他应用上层" → 调 `requestPermission()` 跳系统设置，
     SnackBar 提示"请开启悬浮窗权限后重试"；返回 App 后再点即进入。
   - 已授权 → 弹出悬浮窗。初始页 = 当前会话；页面集合 = 运行中会话
     （`allTasksProvider` 中 `status == running`，按 `updatedAt` 倒序）∪ 当前会话。
3. 悬浮窗内容（每页一个会话）：
   - 标题行：会话标题（超长省略）+ 运行状态点（运行中呼吸点/绿点完成/红点出错）
     + 右上 X（关闭悬浮窗）。**标题栏同时是拖动手柄**（按住可移动窗口）。
   - 正文：可上下滚动的纯文本历史区——推送该会话最新 AI 输出尾部缓冲
     （至多 60 行），视口高度 = N 行（设置可配 1–10，默认 4），初始停在最底部；
     向上滑看历史，新内容到达时若在底部则自动跟随、翻历史中则保持位置。
     单行超 40 字符截断。
   - 页码指示：`当前页/总页数`。
   - 左右滑动切换会话（PageView；与上下滚动手势按方向天然区分）。
   - 轻点（非拖动/滑动）某一页 → 关悬浮窗 + ZCode 回前台并打开该会话。
4. 悬浮窗拖动：`enableDrag: false`（原生拖动会与内容手势冲突），改为标题栏
   手柄 `onPanUpdate` 累积位移 → `FlutterOverlayWindow.moveOverlay`；
   松手吸附左右边缘（`positionGravity: auto`）。
5. 关闭悬浮窗后 ZCode 任务继续跑（已有前台服务保活）。

### 尾部行提取规则

从该会话 `chatProvider(chatRef)` 状态取最新 assistant 消息文本（parts 路径拼接
TextPart / 旧路径 content），按行切分取尾部至多 60 行（缓冲常量 `pipBufferLines`）；
不足时向前一条 assistant 消息补足，最多跨 3 条消息。无任何 AI 文本时显示状态行
（"思考中…"/"运行中…"）。视口行数 N 只决定小窗高度，滚动可看全部缓冲。

## 技术方案

### 依赖

新增 `flutter_overlay_window: ^0.5.0`（Android-only，MIT，pub.dev）。
用户已批准。风险兜底见文末。

### Android 侧（卡A，主 agent 实现）

- `AndroidManifest.xml`：
  - `<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW"/>`
  - 声明插件的 `OverlayService`（`specialUse` 类型 + property 说明，见包 README）。
- `MainActivity.kt`：新增 `app/pip` MethodChannel（仿现有 `app/updater`）：
  - `bringToForeground`：以 `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_SINGLE_TOP`
    启动 launcher intent，把 App 提到前台（悬浮窗轻点跳回会话用）。

### Flutter 侧（卡B，frontend-flutter 子 agent）

- `lib/core/services/pip_service.dart`：`flutter_overlay_window` 封装
  （权限查询/申请、show/close/resize、shareData 收发）+ IPC 契约模型。
- `lib/providers/pip_providers.dart`：
  - `pipLinesProvider`：行数设置（SharedPreferences 持久化，key `pip.lines`，
    默认 4；与 kThemeModePrefKey 同款 bootstrap 恢复模式）。
  - `pipOverlayActiveProvider`：悬浮窗是否打开。
  - `pipMonitorProvider`：悬浮窗打开期间存活（非 autoDispose）。对页面集合内
    每个会话 `ref.listen(chatProvider(chatRef))` 保活并聚合 tail，节流 500ms
    `shareData` 推快照；会话集合变化立即推。关闭悬浮窗时 dispose，
    各 chatProvider 随之自动销毁。
- `main.dart`：`@pragma("vm:entry-point") void overlayMain()` —— 悬浮窗独立
  引擎入口，独立 `ProviderScope`，固定深色主题（悬浮在任意 App 上深色卡
  可读性最好，且不依赖跨引擎主题同步）。
- `lib/shared/widgets/pip_overlay_card.dart`：悬浮窗 UI（overlay 引擎侧）：
  PageView + 状态点 + 尾部行 + 页码 + X 关闭 + onTap 回传 open 动作。
- `lib/features/settings/screens/settings_screen.dart`：新增"悬浮窗行数"设置项
  （交互仿主题选择：点击弹底部表选 1–10，改后即时生效 → resizeOverlay + 重推）。
- `lib/features/chat/screens/chat_screen.dart`：GlassAppBar actions 加画中画
  IconButton → 权限检查 → `pipOverlayActive` 置位 → showOverlay。
- 主 App 侧监听 `overlayListener`：收到 `{"action":"open","key":...}` →
  `app/pip` 通道 `bringToForeground` + `goRouter.go('${AppRoutes.chat}?workspace=...')`
  （与 history_drawer 跳会话同款）。

### IPC 契约（冻结）

`shareData` 双向均传 **JSON 字符串**（跨引擎 codec 兼容性最稳）。

主 App → 悬浮窗（快照，节流 500ms / 集合变化即时）：

```json
{
  "v": 1,
  "index": 0,
  "sessions": [
    {
      "key": "/workspace/abs/path",
      "title": "重构登录模块",
      "running": true,
      "error": false,
      "lines": ["尾部缓冲行（至多 60 行，最后一行最新）"]
    }
  ]
}
```

悬浮窗 → 主 App：

```json
{"action": "refresh"}                      // 悬浮窗启动时拉一次最新快照 (防白屏)
{"action": "open", "key": "/workspace/abs/path"}   // 轻点某页
```

## 数据模型

无表变更。仅内存 provider + 一个 SharedPreferences int（`pip.lines`）。

## 边界与异常

- 非 Android 平台 / 包判定的不支持环境 → 按钮隐藏。
- 悬浮窗打开中再点按钮 → 幂等（show 前查 `isActive`，已开则忽略）。
- 页面集合变化（任务完成移出 running）→ 当前 index 夹紧到合法范围；
  进入时的当前会话即使已完成也保留为页（用户主动钉的）。
- 全部会话结束 → 显示"暂无进行中会话"页，悬浮窗保留，用户手动关闭。
- 行数设置为空/损坏 → 回落默认 4。
- `showOverlay` 抛异常 → SnackBar 报错，状态回滚。

## 任务拆分

- 卡A（主 agent 直做，小）：Manifest + `app/pip` 通道 `bringToForeground`。
- 卡B（frontend-flutter）：上述 Flutter 全套 + widget 测试
  （`pip_overlay_card` 渲染：多会话滑动 / tail 行数 / 完成态 / 空态）。
- 验收：`flutter analyze` 零新增告警；widget test 过；真机（API 26+）
  全流程：按钮 → 授权 → 弹窗 → 其他 App 上观察流式更新 → 滑动切会话 →
  改行数设置即时生效 → 轻点回跳会话 → X 关闭。

## 风险与兜底

- `flutter_overlay_window` 约 17 个月未发版，可能与新 AGP/Gradle 不兼容。
  构建失败时兜底：保留 IPC 契约与 UI 不变，以自写 ~150 行 WindowManager
  前台服务悬浮窗通道替换该包（契约冻结的意义所在）。
- 部分国产 ROM 权限入口深 → 卡B在 SnackBar 引导文案中写明设置路径。
- 独立引擎内存开销 → 悬浮窗为纯文本小卡，无图片无 Markdown 渲染。
