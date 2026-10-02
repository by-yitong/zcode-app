# 通知提示音设计 (zcode-app 移动端)

日期: 2026-10-02
状态: 已与用户对齐 (音源/触发事件/设置开关/设计四节均确认)

## 1. 背景与目标

桌面端在任务需要注意时 (任务完成/AskUserQuestion/权限请求) 有提示音
(实测机制: `showTaskNotification` 在窗口失焦时弹系统通知并播
`task-notification-pop.mp3`, 由 通知开关+声音开关 两个偏好门控)。
App 对齐此行为: 同类事件发生时播放系统提示音。

音源 (用户选定): `SystemSound.play(SystemSoundType.alert)` 系统提示音,
**零新增依赖**。设置里可关闭 (用户新增要求)。

## 2. 行为定义

三类事件触发, fire-and-forget, 异常静默 (不响不崩):

| 事件 | 触发语义 | 代码锚点 |
|---|---|---|
| 任务完成 | 一轮回复结束: isResponding true→false, 且非用户主动停止、非出错中断 | chat_provider 回复完成判定处 (实现时定位) |

任务完成判定指引: 依赖现有状态区分 —— 出错中断时 error 字段非空, 用户主动
停止走 stop 动作路径; 若现有代码无区分信号, 以「回复正常收尾」为准, 并在
交付报告里写明判定依据 (不得为区分而重构状态机)。
| AI 提问 | AskUserQuestion 行到达、提问弹窗弹出 | askQuestionFromInteractions 弹出处 |
| 权限请求 | 权限审批请求到达 | 权限请求处理处 (实现时定位) |

边界 (v1 明确不做):
- App 后台不响 (Flutter 引擎暂停, 无音频播放依赖; 桌面端「失焦才响」
  在手机上的等价场景就是切走 App, 切走即无法播, 故前台一律响)。
- 后台系统通知通道的提示音不在本期。
- 悬浮窗 (PIP) 监视会话的事件不触发提示音。

## 3. 架构

- 新增 `lib/core/feedback/notification_sound.dart`:
  `NotificationSound`(单例) + `Future<void> play()`。
  流程: 读开关 (`shared_preferences`, key `notification_sound_enabled`,
  默认 true) → 开则 `SystemSound.play(SystemSoundType.alert)`。
  `SystemSound.play` 通过可注入函数持有 (测试缝): 构造可传
  `Future<void> Function(SystemSoundType)`, 默认绑静态调用。
- 触发点: chat_provider 三处调用 `notificationSound.play()`, 不 await。
- 设置页: 新增「提示音」SwitchTile, key `notification_sound_enabled`,
  即时生效, 默认开; 照设置页现有开关实现模式。

## 4. 测试

- NotificationSound 单测: 注入假 player, 断言 开→播/关→不播。
- 设置 toggle: 改偏好后 service 行为跟随 (共享同一 key)。
- 触发点: chat_provider 单测注入假 NotificationSound, 断言
  「回复结束帧 / 提问行 / 权限请求」三场景各调用一次; 用户主动停止不调用。
- 真机验收: 三类事件各一次出声; 设置关闭后静默; 重启 App 后开关状态保持。

## 5. 任务拆分

单卡交付: service + 设置项 + 三处接线 + 测试 (frontend-flutter) →
reviewer 评审 → 合并。

禁止事项: 新增依赖; 改 relay 协议; 触碰并行会话 WIP 文件
(chat_screen.dart / history_drawer.dart / reveal_drawer* / drawer_swipe*);
不动 Git 工具代码。
