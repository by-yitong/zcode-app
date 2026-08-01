# UI 设计规范

ZCode App 的视觉与交互规范。**应用规则,不是 token 表的重复** —— token 的源码在 `lib/shared/theme/app_design_tokens.dart`,本文件讲"什么时候用哪个、怎么用"。

HTML 可交互预览:`design/ui_preview.html`(浏览器直开)。

---

## 基调

**Linear 深色 + 电光蓝,精炼版开发者工具气质。** 深色优先(`AppColors.darkBg = #08090A`),浅色完整可用。

三个气质关键词:**精确**(开发者工具,密度友好)·**代码优先**(等宽字给元信息当签名)·**克制**(半透明叠加做空气感,不堆阴影)。

---

## 签名动作

这些是拉开和默认 Material app 距离的具体手法,新组件要延续:

1. **消息流非对称** —— 助手消息**全宽文档式**左对齐(非对称圆角,右下小尾);用户消息**电光蓝胶囊**右对齐。不用两个对称圆角气泡(AI 味)。
2. **mono 专司元信息** —— JetBrains Mono 只给元信息用:时间戳、模型名、Token 用量、耗时、路径、进度%、SID、步骤号。**不当装饰**。正文用 Inter。
3. **工具调用 = 折叠式执行日志** —— 工具名 + 状态点 + mono 耗时,默认折叠,像终端 `git log`。
4. **Todo 浮动面板** —— 右下角悬浮卡(SVG 进度环 + 清单),不挤在消息流里。
5. **Plan 左强调线折叠卡** —— 左边 2px 电光蓝竖条,折叠预览。
6. **豆包式语音** —— 点 🎤 切语音态,整个输入区变"按住说话",上滑取消。

---

## 三条硬规矩

### ① 禁止内联魔法数字

间距用 `AppSpacing`,圆角用 `AppRadius`,字号用 `AppTextSizes`,触摸目标用 `AppTouch`。

```dart
// ❌
SizedBox(height: 32),
fontSize: 13,
BorderRadius.circular(16),

// ✅
SizedBox(height: AppSpacing.xxl),
fontSize: AppTextSizes.bodySm,
BorderRadius.circular(AppRadius.lg),
```

文字尺寸阶梯(`AppTextSizes`):

| token | 值 | 用途 |
|---|---|---|
| `display` | 28 | 大标题(工作区名/页头) |
| `headline` | 24 | 屏幕标题 |
| `title` | 18 | 卡片标题 |
| `titleSm` | 16 | 小标题 / ListTile 标题 |
| `body` | 15 | 正文(消息/默认) |
| `bodySm` | 13 | 次要正文 / 副标题 |
| `label` | 12 | 标签 / 按钮 |
| `caption` | 11 | 时间戳/计数/元信息(最小) |
| `mono` / `monoSm` / `monoXs` | 13/12/11 | 等宽元信息(比同档 UI 字小 1px) |

### ② 动效只用 transform/opacity,时长走 AppDur,曲线走 AppEase

```dart
// ❌ 动布局属性 / 裸用 ease
AnimatedContainer(duration: Duration(milliseconds: 300), curve: Curves.ease, ...)

// ✅ 只动 transform/opacity, token 化
AnimatedOpacity(duration: AppDur.base, curve: AppEase.out, ...)
```

三档时长够用,别造新档:`AppDur.fast`(140ms 反馈)·`AppDur.base`(220ms 默认)·`AppDur.slow`(360ms 页面)。曲线:`AppEase.out`(进场/默认)·`AppEase.inOut`(切换)·`AppEase.in_`(退场)。禁止裸用 `Curves.ease`。

`prefers-reduced-motion` 下所有动效坍缩为 ≤150ms 透明度淡入淡出。

### ③ 状态色走 AppColors + Container 变体,不内联 hex

```dart
// ❌ 绕过 token 的硬编码
Color(0xFFF59E0B)
AppColors.danger.withValues(alpha: 0.15)

// ✅ 用 token
AppColors.warning
AppColors.dangerContainer   // ~12% alpha 填充, 已预调
```

状态色三档:`AppColors.success/warning/danger`(实色,图标/文字) + `successContainer/warningContainer/dangerContainer`(低透明填充,背景/胶囊)。用量阈值配色:≥70% 转 warning,≥90% 转 danger。

---

## 色彩体系

深色优先。深色表面用**半透明白叠加**(`darkSurface = 白@3%`、`darkSurfaceHigh = 白@6%`、`darkSurfaceHighest = 白@9%`),不用实色灰 —— 在深色背景上有空气感。边框同理(`darkBorder = 白@8%`)。

文字用 **Apple alpha 标签体系**(`rgba(235,235,245, alpha)`):主文字近白,次要/弱/最弱靠 alpha 递减,在任何背景上自适应。不用实色灰文字。

强调色电光蓝 `#3B82F6`,三态:`accent`(默认)·`accentHover`(略亮)·`accentPressed`(略暗)。

---

## 组件约定

- **半透明分组卡(tile-group)** —— iOS 设置组式样:多元素放一张 `surface` 卡里,元素间 `borderSubtle` 细分割,不逐个独立卡。见 `AppTileGroup`。
- **分区标题(section header)** —— mono、`caption` 字号、大写、字间距 0.06em,色 `inkMuted`。见 `AppSectionHeader`。
- **空/错态** —— 图标在圆角方块里 + 标题 + 副标题 + 可选行动按钮,居中。见 `AppEmptyState`。不要每个屏自己拼。
- **悬浮元素** —— 用真毛玻璃(`BackdropFilter` + blur),见 `GlassAppBar`。不要用半透明 `Container` 假装。
- **代码块** —— 走 `CodeHighlightView`,GitHub 配色,语言自动别名。

---

## 反 AI-slop 清单(这些不做)

- 无斜体标题(标题永远 roman;正文段内可用 `<em>` 强调)
- 无虚假指标(没给的真实数字,不编 "+47% 转化")
- 无 Material 默认 outline 图标堆(`work_outline`/`auto_awesome`/`person_outline` 那套)
- 无庆祝式 toast(成功用静默更新 + 可撤销,不用弹窗庆祝)
- 动效能砍则砍 —— 去掉一个动画不丢信息就去掉

---

## token 速查

完整定义见 `lib/shared/theme/app_design_tokens.dart`。新增 token 加在那,组件主题加在 `lib/shared/theme/app_theme.dart`。本文件只讲应用规则。
