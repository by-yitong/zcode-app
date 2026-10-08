# 项目文件树设计(移动端对齐网页端 WorkspaceFileTree)

> 日期: 2026-10-08 · 状态: 已与用户对齐(范围=与网页端一致;入口=顶栏更多菜单)
> 证据来源: 网页端主 bundle `index-B-ilXaCQ.js`(zcode.z.ai/remote/v4/latest, 桌面端 3.14.5)静态逆向, 2026-10-08 抓取; 下载物 `/tmp/zcode_web_bundle/`。

## 1 背景与目标

网页端有 **WorkspaceFileTree**(workspaceFileTree.* i18n 键, 75 处 FileTree 引用): 侧边栏里的只读项目文件树, 与任务列表互相切换。移动端目前只能靠输入框 `@` 提及(全量文件平铺列表)访问项目文件, 没有目录结构视图。

**目标**: 移动端提供与网页端远程模式等价的**只读项目文件树**全量能力: 浏览、变更/全部过滤、树内搜索、git 状态角标、复制路径、加入对话、文件预览、目录变化自动刷新 + 手动刷新。

**非目标**(网页端同样没有, 或桌面端专属):
- 任何写操作(新建/重命名/删除/上传)——网页端 fileService 全部调用中无任何写方法;
- `openWith`(选本机 IDE 打开)、`openInBrowser`、`revealInFileManager`——桌面端专属动作;
- DirectoryBrowser(那是"打开工作区"的目录选择器, 只列文件夹, 与本功能无关);
- 全局文件搜索(命令面板 Ctrl+K 的文件 tab, 走 `listWorkspaceFiles` 全列表, 与树内搜索是两回事, 后续可加)。

## 2 范围

| 能力 | 网页端证据 | 移动端做法 |
|------|-----------|-----------|
| 目录树懒加载浏览 | `readdir {path, includeHidden:true}`, 展开才加载 | 同款 RPC, `ExpansionTile` 式自研行(不用 ExpansionTile, 用统一 FileRow) |
| 忽略文件过滤 | readdir 后调 `git.getIgnoredPaths` 过滤 | 同款; 非 git 项目不过滤(与网页一致) |
| git 状态角标 | `gitStatusByPath` + 目录聚合 `directoryGitStatuses`, 标签 git.kind.* / git.section.untracked | 复用已有 `git.getChanges` 封装, 客户端按路径前缀聚合目录角标 |
| 仅变更/全部过滤 | `showChangedFiles` / `showAllFiles` 切换 | 工具行切换钮; 非 git 项目隐藏此钮(始终全部) |
| 树内搜索 | searchPlaceholder / clearSearch / noResults | 客户端过滤已加载节点(与网页树一致, 不做全库搜索) |
| 复制路径 | 右键菜单 `fileActions.copyAbsolutePath` / `copyRelativePath` | 长按条目底部菜单两项 |
| 加入对话 addToChat | CustomEvent `zcode:add-workspace-file-to-chat` | pop 回聊天页 + `_insertAtCursor('@相对路径 ')`(chat_screen.dart:1843 已存在) |
| 文件预览 | onOpenPreview → readTextFile 预览 | 跳现有 FilePreviewScreen |
| 目录变化自动刷新 | fileWatcherService watch/unwatch + onDynamicChange | file-watcher 探测接入, 失败自动降级手动刷新(见 §4) |
| 手动刷新 | refresh 键 | 工具行刷新钮(始终显示) |
| 空态/错误态 | empty / readFailed / noResults | 复用 AppEmptyState 三态 |

## 3 用户交互流程

1. 聊天页顶栏右圆钮"更多"菜单(ChatFloatingHeader sheet, 现有项: 新对话/悬浮窗/设置)新增 **"文件树"** 项, 置于"新对话"之后。任何项目可用, 无门控。
2. 进入 `FileTreeScreen`(`CapsPageHeader` 全屏页骨架, 标题"文件树"): 标题栏下方工具行 = 搜索框(可清空) + 「仅变更/全部」过滤切换(非 git 项目隐藏) + 刷新钮。
3. 树列表: 点文件夹展开/收起(懒加载 readdir, 展开中显示 loading; 符号链接文件夹显示专属图标); 点文件 → FilePreviewScreen(现有路由)。
4. 长按条目 → 底部菜单:
   - 文件: 复制绝对路径 / 复制相对路径 / 加入对话 / 打开预览
   - 文件夹: 复制绝对路径 / 复制相对路径
5. "加入对话": pop 回聊天页, 在输入框光标处插入 `@<相对路径> ` 并聚焦输入框(与 composer `@` 提及的 insertText 同构, composer.dart:317)。
6. 状态与异常:
   - 根目录加载中: 列表骨架; 目录展开加载中: 行内 spinner;
   - 空目录: AppEmptyState("空目录");
   - 读取失败: AppEmptyState(错误信息 + 重试按钮, 对应网页 readFailed);
   - 搜索无结果: AppEmptyState("无匹配文件");
   - 非 git 项目: 无角标、无过滤切换, 其余功能完整。
7. watcher 生效时, 已展开目录内容变化 → 该目录自动重载(本地态, 无弹窗打扰); watcher 不可用时手动刷新兜底。

## 4 API 契约

### 4.1 file 通道(已核实, 冻结)

```
readdir  {path: string, includeHidden: true}
  → entries: [{name: string, path: string,
               type: 'directory'|'file',
               isSymbolicLink?: bool}]        // bundle 实测消费 type/isSymbolicLink(文件夹符号链接专属图标);
                                                // 若实际响应无 isSymbolicLink 字段按 false 处理
```

### 4.2 git 通道(部分已封装)

```
getIgnoredPaths {workspacePath: string, paths: string[]}
  → {paths: string[]}                            // 协议文档 §git channel 已载; app 未封装, 本次新增
getChanges {workspacePath, sourceId}             // app 已封装(GitController 在用), 复用
  → 合并 unstaged+staged → statusByPath: Map<相对路径, 状态(M/A/D/R/U/untracked)>
```

### 4.3 fileWatcher 通道(方法签名已核实, 通道名待运行时探测)

```
watch   {path: string, recursive?: bool}  → {id: string}
unwatch {id: string}
动态变更事件: {changedPath: string}       // bundle 实测 WNt/UNt 消费 changedPath
```

- 通道字符串在网页端主 bundle 中不可见(v4 通道映射不在客户端静态可查)。探测顺序(**冻结的是探测顺序与降级行为, 不是通道名**):
  1. `file-watcher`(推断: 外围域 kebab 命名规律, 同 mcp-sync/model-provider)
  2. `file` 通道上的 `watch`/`unwatch` 方法(兜底: FileWatcher 与 File 在桌面通道表相邻)
- 探测/调用任一步失败 → **本次会话永久降级为手动刷新**, 不重试、不报错、不影响其余功能。

### 4.4 内部契约(app 侧)

- `FileTreeRef {workspacePath, workspaceIdentity}` 作 family key(仿 `GitRef`);
- `fileApiProvider`(Provider 缝, 包装 RelayClient.readdir/watch/unwatch)供测试 override, 仿 `gitApiProvider`(git_provider.dart:354);
- 加入对话文本格式: `@` + 相对路径 + 空格。

## 5 数据模型与状态

```dart
class FileTreeNode {
  FileEntry entry;            // name/path/type/isSymbolicLink
  bool expanded;  bool loading;  Object? error;
  Map<String, FileTreeNode> children;   // key = path
}

class FileTreeState {
  Map<String, FileTreeNode> roots;      // 根层
  Set<String> expandedPaths;
  bool filterChangedOnly;               // 默认 true(与网页一致: 默认仅变更)
  String searchQuery;
  Map<String, String> statusByPath;     // 相对路径 → git 状态
  Set<String> ignoredPaths;
  bool watcherAvailable;                // 探测结果, false = 已降级
  bool rootLoading;  Object? rootError;
}
```

- `FileTreeController extends StateNotifier<FileTreeState>`, `StateNotifierProvider.autoDispose.family`, 离开页面自动 unwatch 全部目录并释放缓存;
- 排序: 目录(含符号链接目录)先, 名称 case-insensitive 本地化序;
- 目录角标 = statusByPath 中以该目录路径为前缀的条目聚合(客户端计算, 无额外 RPC);
- 「仅变更」过滤 = 仅显示命中 statusByPath 的文件及其祖先链;
- 搜索 = 对已加载节点按名称客户端过滤(命中文件保留祖先链)。

## 6 测试策略(仿现有惯例, 不跑 golden)

- **单测** `test/file_tree_provider_test.dart`(新): 假 file/git API(`ProviderContainer` + overrides)驱动: 懒加载展开、忽略过滤、变更过滤、watcher 探测成功自动重载、探测失败降级、长按排序、错误态落盘;
- **纯函数** `test/file_tree_logic_test.dart`(新): 排序比较器、相对路径计算、目录角标前缀聚合、搜索过滤保祖先链;
- **widget** `test/chat_floating_header_test.dart`(扩): 更多菜单含"文件树"项且回调触发; `test/file_tree_screen_test.dart`(新): 三态空态、过滤切换在非 git 项目隐藏、长按菜单项齐全。

## 7 任务拆分(契约冻结后依序派发, 每卡自足)

| 卡 | 内容 | 主要文件 | 依赖 |
|----|------|---------|------|
| A 数据层 | RelayClient.readdir 封装、git.getIgnoredPaths 封装、fileApiProvider 缝、FileTreeController(含 watcher 探测降级)、单测 | `lib/core/relay/relay_client.dart`、`lib/providers/file_tree_provider.dart`(新)、`test/file_tree_provider_test.dart`(新)、`test/file_tree_logic_test.dart`(新) | 无 |
| B 树 UI | FileTreeScreen 全量 UI + 三态 + 长按菜单 + widget 测试 | `lib/features/files/screens/file_tree_screen.dart`(新)、`lib/features/files/widgets/`(新, FileRow 等)、`test/file_tree_screen_test.dart`(新) | A |
| C 接线 | 更多菜单加"文件树"项(onOpenFileTree 可空回调)、chat_screen 接线跳页 + onAddToChat(pop + _insertAtCursor) | `lib/features/chat/widgets/chat_floating_header.dart`、`lib/features/chat/screens/chat_screen.dart`、`test/chat_floating_header_test.dart` | B |

**验收**: `flutter analyze` 与 `flutter test` 全绿; 手测: 打开树/展开懒加载/角标/仅变更过滤/搜索/长按复制/加入对话落输入框/文件预览/watcher 生效(桌面端改动文件, 手机侧已展开目录自动更新)/降级路径(断 watcher 时手动刷新可用)。

## 8 风险与开放问题

- **watcher 通道名未定**: 探测 + 降级兜底(§4.3), 最坏情况=只有手动刷新, 主功能不受损;
- **readdir 字段漂移**: isSymbolicLink 缺失时按 false, 仅影响图标;
- **大目录性能**: 非 git 项目无忽略过滤, node_modules 类目录可能很大——与网页行为一致, 不特判, 上线后观察;
- **预览自动 reload**(网页端打开的预览随源变化自动刷新)列为可选增强, v1 不做; 若做, 复用同一 watcher 探测结果, 降级时一并取消。
