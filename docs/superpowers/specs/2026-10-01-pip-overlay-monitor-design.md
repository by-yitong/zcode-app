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
4. 悬浮窗拖动（真机联调终版）：插件已 vendor 至 `third_party/flutter_overlay_window`
   并打了三处补丁（标记 "ZCode 补丁"）——
   - `setFitsSystemWindows(false)`：原版导致部分 ROM relayout 时窗口被系统栏顶偏；
   - `setDragEnabled` 通道：只翻拖动标志、零 relayout（走 resizeOverlay 换开关
     会触发 relayout）；
   - onTouch 基准：DOWN 恒记录触点基准 + 开关中途打开时首个 MOVE 只重置基准
     （原版旧基准差值 → 拖动起跳 + 固定错位，真机确诊的最后一根病根）。
   交互：默认 `enableDrag: false`（保护正文手势）；标题栏按下瞬间 Dart 切
   `setDragEnabled(true)` → 原生层零通道往返直接搬窗口（官方同款丝滑）；
   松手切回 false 并把窗口钳制回屏内（TOP|LEFT 绝对锚点，屏幕尺寸经快照
   `sw/sh` 带给悬浮窗引擎）。`positionGravity: none`（不做松手吸边）。
5. 关闭悬浮窗后 ZCode 任务继续跑（已有前台服务保活）。
6. 胶囊↔面板丝滑变形（v6，灵动岛式）：窗口原生本就透明，变形动画全部在
   悬浮窗引擎的 Flutter 内容层做，四周透明。
   - **展开**（点胶囊）：主 App 一步 resize+move 把窗口换到目标面板框
     （窗口左上锚定胶囊左上，钳制面板整体在屏内）——在 resize 完成→快照
     到达的 IPC 间隙里，旧胶囊子树渲染在新窗口左上角 = 胶囊原位，视觉
     不动。随后推快照 `mo='expand'` + `tw/th`，悬浮窗侧胶囊从 (0,0,108,44)
     变形到 (0,0,tw,th) 的面板（~260ms，圆角 18→面板圆角，胶囊内容淡出、
     面板内容淡入），完成后正常面板渲染。
   - **收拢**（最小化钮/拖出屏）：先推快照 `mo='collapse'` + `fx/fy`
     （胶囊目标 = 面板顶水平居中），悬浮窗侧面板变形缩到窗口内
     (fx, fy, 108, 44) 的胶囊（动画在窗口不动的条件下进行，无 resize 间隙
     闪烁）；主 App 等 340ms（动画 260ms + 余量）后裁剪窗口——
     resize(108,44) + move(胶囊绝对位)，胶囊视觉不动、裁掉的只是透明区；
     最后用原生动画 move（逐帧只改位置不 resize，无 surface 重分配）把
     胶囊 glide 到记忆位（~200ms，无记忆则顶部居中）。
   - 变形目标尺寸/坐标一律显式随快照传（resize 后悬浮窗引擎 MediaQuery
     可能不刷新，不得读窗口尺寸做动画目标）；`mo` 只在翻转沿启动一次变形，
     动画期间到达的流式快照（不带 `mo`）只更新数据不重启动画。
   - 串行守卫：展开/收拢序列进行中（`pipMorphBusyProvider`）到达的
     expand/minimize/collapse 动作直接丢弃，防时序交错出半变形状态。

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
- 主 App 侧轮询 `pip.action` 信箱（见 IPC 契约 v2）：收到 `{"action":"open","key":...}` →
  `app/pip` 通道 `bringToForeground` + `goRouter.go('${AppRoutes.chat}?workspace=...')`
  （与 history_drawer 跳会话同款）。

### IPC 契约（冻结，v6 — 胶囊↔面板丝滑变形；动作集与 v5 一致）

`flutter_overlay_window` 0.5.0 的 `x-slayer/overlay_messenger` 通道每个引擎只有
一个 handler 槽位，且主引擎槽位被 Dart 侧 `overlayListener` 占用后，原生转发器
失效（消息回声到本引擎，永远到不了对端）。因此双向通信机制改为：

- **主 App → 悬浮窗**：`FlutterOverlayWindow.shareData(json)`（走原生 Java 转发器）。
  **主 App 一律不得访问 `overlayListener`**（会抢掉原生槽位导致推送失效）。
- **悬浮窗 → 主 App**：SharedPreferences 信箱，key `pip.action`（JSON 字符串）。
  两引擎同进程共享同一 SharedPreferences 实例，写后立即可见；主 App 仅在悬浮窗
  打开期间以 300ms 轮询读取，取走即清空。动作七类（v5，v6 不变）：

```json
{"action": "open", "key": "task-uuid"}   // home 钮（有会话）回 app 跳会话
{"action": "home"}                       // home 钮（空态）仅回前台
{"action": "size"}                       // 双击正文循环尺寸档位（仅展开态）
{"action": "collapse"}                   // 窗口中心拖出屏外 → 收拢为胶囊
{"action": "minimize"}                   // 最小化钮 → 收拢为胶囊（同 collapse）
{"action": "expand"}                     // 点胶囊 → 胶囊位原地展开
{"action": "pillMoved","x":..,"y":..}    // 胶囊拖拽松手 → 记忆胶囊位置（dp）
```

- **防白屏**：不再用 refresh 动作；主 App 在 showOverlay 成功后立即主动推一次
  快照，此后快照变化节流 500ms 推送。
- **后台兜底轮询**：真机实测 app 后台化后 Riverpod 懒加载 Provider 不再重算
  （listenManual 收不到通知），事件驱动推送在后台失效。因此悬浮窗打开期间
  由 push scheduler 以 500ms 周期主动 `read` 快照（强制重算），内容有变化才推
  （与上次推送 JSON 对比去重）。前台事件驱动路径保留作为快路径。
- **串行守卫（v6）**：展开/收拢变形序列进行中（`pipMorphBusyProvider`）到达的
  `expand`/`minimize`/`collapse` 动作直接丢弃并落日志，防时序交错。

主 App → 悬浮窗快照结构（v6：v3 快照结构不变，新增可选变形字段；纯可选、
不 bump `v`，老载荷缺省即 v5 行为）：

```json
{
  "v": 1,
  "index": 0,
  "sessions": [
    {
      "key": "task-uuid",
      "title": "重构登录模块",
      "running": true,
      "error": false,
      "text": "尾部原文（markdown 源文本，≤60 逻辑行 / ≤4000 字符，含最后一行最新流式内容）"
    }
  ],
  "sw": 1080, "sh": 2400,          // 屏幕物理 px（可选；松手钳制回屏用）
  "co": true,                      // 收拢标志（可选，v4.1；true 才发）
  "mo": "expand",                  // 变形方向（可选，v6）：'expand' | 'collapse'
  "tw": 320.6, "th": 160.0,        // 仅 expand：目标面板尺寸 dp（显式传，不读窗口）
  "fx": 106.3, "fy": 0             // 仅 collapse：胶囊目标左上角窗口内局部坐标 dp
}
```

- 变形字段语义（v6，键名 `mo`/`fx`/`fy`/`tw`/`th`）：仅展开/收拢例程的翻转沿
  一次性携带；流式快照一律不带。`mo` 缺省 null = 无变形，悬浮窗瞬时切换子树
  （v5 行为，向后兼容）。解码防御式解析：`mo` 非法值、坐标对残缺
  （expand 缺 `tw`/`th`、collapse 缺 `fx`/`fy`）、坐标非 num → 一律回落 null。
  悬浮窗侧 `mo` 只在翻转沿（且当前无进行中动画）启动一次变形，动画期间到达的
  快照只更新数据，不中断不重启。
- `text` 语义：该会话尾部 AI 输出的 markdown **源文本**（跨最多 3 条 assistant
  消息拼接，尾部 60 行 / 4000 字符截断），悬浮窗侧用 Markdown 渲染（深色小号，
  复用 AiMarkdown minimal 语义；行内代码/代码块按悬浮窗深色令牌渲染）。
  无任何 AI 文本时为状态占位（"思考中…"/"运行中…"）。
- 视口行数 `pip.lines`（1–10，默认 4）继续决定小窗高度，滚动区可看全部尾部缓冲。

`key` 语义：`Task.id`（路由跳会话需要 taskId）。悬浮窗把它当不透明串原样回传，
主 App 收到 `open` 后经 `allTasksProvider` 反查 workspace；反查不到（如任务列表
未加载完）则放弃跳转。

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
