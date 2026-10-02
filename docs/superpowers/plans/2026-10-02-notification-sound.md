# 通知提示音 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App 在任务完成/AI 提问/权限请求时播放系统提示音, 设置页可关。

**Architecture:** `NotificationSound` 单例 (注入测试缝) + chat_provider 三处触发 + 设置页开关, 零新依赖。Spec: `docs/superpowers/specs/2026-10-02-notification-sound-design.md`。

**Tech Stack:** Flutter + flutter/services SystemSound + shared_preferences。

## Global Constraints

- 禁止新增 pub 依赖; 禁止动 relay 协议与 zcode-agent 通道代码。
- 禁止触碰工作区另一会话的未提交 WIP 文件: `lib/features/chat/screens/chat_screen.dart`、`lib/features/chat/widgets/history_drawer.dart`、`lib/shared/widgets/reveal_drawer*`、`test/drawer_swipe_test.dart`、`demos/`。
- 不动 Git 工具代码 (lib/features/git/**、lib/core/relay/git_api.dart)。
- 中文注释/文案; analyze 触碰文件零新增告警。

---

### Task 1: NotificationSound 服务 + 设置开关 + 三处接线 + 测试

**Files:**
- Create: `lib/core/feedback/notification_sound.dart`
- Modify: `lib/providers/chat_provider.dart` (三处触发 + 假 service 注入缝)
- Modify: `lib/features/settings/screens/settings_screen.dart` (开关行)
- Modify: `lib/providers/app_providers.dart` (soundOnProvider)
- Test: `test/notification_sound_test.dart`

**Interfaces:**
- Produces:
  - `final notificationSound = NotificationSound();` (顶层单例, lib/core/feedback/notification_sound.dart)
  - `class NotificationSound { NotificationSound({Future<void> Function()? playOverride, Future<SharedPreferences?> Function()? prefsOverride}); Future<void> play(); }` — play(): 开关关/prefs 异常 → 静默返回; 开 → 执行 player (默认 `SystemSound.play(SystemSoundType.alert)`, 异常吞)
  - `final soundOnProvider = StateProvider<bool>((ref) => true);` (app_providers.dart, 键 `notification_sound_enabled`)
  - chat_provider 测试缝: `@visibleForTesting void setNotificationSoundForTest(Future<void> Function()? fn)` 或等价可注入字段 — 三个触发点经此调用

- [ ] **Step 1: 写失败测试 (service + 触发点)**

`test/notification_sound_test.dart`:
1. 默认 (无偏好文件) → play() 调用了注入 player
2. 预写 `notification_sound_enabled=false` → 不调用
3. player 抛异常 → play() 不抛
4. (触发点) chat_provider: 构造 notifier 注入假 sound 记录器; 模拟 control patch 从 running→非 running 走完 500ms 防抖 (`tester.pump(600ms)` 或等价) → 假 sound 被调 1 次
5. 用户主动停止 (stop 路径) → 不调用
6. 提问行到达 (pendingQuestion 置位场景) → 调用 1 次
7. pendingPermissions 从空到非空 → 调用 1 次; 保持非空再刷新 → 不重复调用

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/notification_sound_test.dart`
Expected: FAIL (notification_sound.dart 不存在)

- [ ] **Step 3: 实现 service**

```dart
// lib/core/feedback/notification_sound.dart
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 任务事件提示音 (对齐桌面端 task-notification-sound; 音源为系统 alert)。
/// 设置键 notification_sound_enabled, 默认开; 任何异常静默吞 (不响不崩)。
final notificationSound = NotificationSound();

class NotificationSound {
  NotificationSound({Future<void> Function()? playOverride, this.prefsOverride})
    : _playOverride = playOverride;

  final Future<void> Function()? _playOverride;
  final Future<SharedPreferences?> Function()? prefsOverride;

  Future<void> play() async {
    try {
      final prefs = prefsOverride != null
          ? await prefsOverride!()
          : await SharedPreferences.getInstance();
      if (prefs.getBool('notification_sound_enabled') == false) return;
      final play = _playOverride ?? () => SystemSound.play(SystemSoundType.alert);
      await play();
    } catch (_) {}
  }
}
```

- [ ] **Step 4: 三处接线 (chat_provider.dart)**

- 字段: `Future<void> Function()? _onNotificationSound;` + `@visibleForTesting void setNotificationSoundForTest(Future<void> Function()? fn) => _onNotificationSound = fn;` + 私有 `void _playSound() { final f = _onNotificationSound ?? (p) => notificationSound.play(); unawaited(f().catchError((_) {})); }` (按编译器反馈微调, 语义不变)
- 完成点: `_respondingFallTimer` 回调内 `state = state.copyWith(isResponding: false)` 之后 (`_refreshTurnMetadata` 旁, 约 :1893) → `_playSound()`。其余 isResponding:false 落点 (stop 路径/错误路径/提问置位 :1604) 不加。
- 提问点: `state = state.copyWith(pendingQuestion: question, isResponding: false)` (约 :1604) 之后 → `_playSound()`。
- 权限点: pendingPermissions 进入 state 的快照/patch 更新处 (约 :1537 附近的 projection 落 state), 仅当「之前为空、现在非空」时 `_playSound()` (比较旧 state 长度)。

- [ ] **Step 5: 设置开关**

- app_providers.dart: `final soundOnProvider = StateProvider<bool>((ref) => true);`
- settings_screen.dart: 在「屏幕常亮」行后插入同款 `_SettingsRow` (icon `Icons.music_note_outlined`, title '提示音', subtitle '任务完成/AI 提问/权限请求时响铃'), Switch value 读 `soundOnProvider`, onChanged: 写 provider + `SharedPreferences.getInstance().setBool('notification_sound_enabled', v)`; initState 时读一次偏好回填 provider (照 keepScreenOn 的回填方式, 若该模式是异步 init 就照抄)。

- [ ] **Step 6: 跑测试 + analyze 全绿**

Run: `flutter test test/notification_sound_test.dart && flutter analyze lib/core/feedback lib/providers/chat_provider.dart lib/features/settings/screens/settings_screen.dart lib/providers/app_providers.dart`
Expected: 全 PASS, 触碰文件零新增告警; 回归 `flutter test test/git_provider_test.dart test/git_screen_test.dart` 不变绿。

- [ ] **Step 7: Commit**

```bash
git add lib/core/feedback/notification_sound.dart lib/providers/chat_provider.dart lib/providers/app_providers.dart lib/features/settings/screens/settings_screen.dart test/notification_sound_test.dart
git commit -m "feat: 任务事件提示音 (完成/提问/权限) + 设置开关"
```

---

## 真机验收 (用户执行)

1. 发一条消息等回复结束 → 响一声; AI 提问 → 响一声; 触发权限请求 → 响一声
2. 设置关「提示音」→ 三类事件均静默; 重启 App 开关保持
3. 用户点停止 → 不响
