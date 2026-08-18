import '../../../providers/chat_provider.dart';

bool isSameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}


bool isPlanTool(ToolActivity a) {
  final n = a.toolName.toLowerCase();
  return n == 'exitplanmode' || n == 'switch_mode' || n == 'switchmode';
}

/// 判断工具活动是否是 TodoWrite (已由 PlanList 单独展示, 从工具卡片排除)
bool isTodoTool(ToolActivity a) {
  final n = a.toolName.toLowerCase();
  return n == 'todowrite' || n == 'todo_write' || n == 'todowritetool';
}

/// 判断工具活动是否是文件操作 (写/编辑/创建/删除文件)
bool isFileActivity(ToolActivity a) {
  final n = a.toolName.toLowerCase();
  return n.contains('edit') ||
      n.contains('write') ||
      n.contains('create') ||
      n.contains('str_replace') ||
      n.contains('file') ||
      n.contains('delete') ||
      n.contains('remove');
}

/// 工具结果正则扫描记忆化: 流式期间 ChangedFilesSummary 每 tick 重建,
/// 完成态工具的 input/result 字符串实例来自缓存 row、稳定不变, 按身份校验复用。
final Map<String, FilePathMemo> filePathMemo = {};
final Map<String, (int, int)> diffMemo = {};
const int toolMemoMax = 64;
final RegExp pathRe = RegExp(r'[/\w]+\.\w+');
final RegExp addCountRe = RegExp(r'\+(\d+)');
final RegExp delCountRe = RegExp(r'-(\d+)');
final RegExp mdLeadRe = RegExp(r'^[#*\-\d.\s]+');

class FilePathMemo {
  final Object? input;
  final Object? result;
  final String? path;
  const FilePathMemo(this.input, this.result, this.path);
}

/// 从工具活动中提取变更的文件路径
/// 优先从 input 中取 path/file_path, 回退到 result 中搜索路径模式
String? extractFilePath(ToolActivity a) {
  final memo = filePathMemo[a.toolCallId];
  if (memo != null &&
      identical(memo.input, a.input) &&
      identical(memo.result, a.result)) {
    return memo.path;
  }
  final path = computeFilePath(a);
  if (filePathMemo.length >= toolMemoMax) {
    filePathMemo.remove(filePathMemo.keys.first);
  }
  filePathMemo[a.toolCallId] = FilePathMemo(a.input, a.result, path);
  return path;
}

String? computeFilePath(ToolActivity a) {
  final input = a.input;
  if (input != null) {
    for (final key in ['file_path', 'path', 'filename', 'file']) {
      final v = input[key];
      if (v is String && v.isNotEmpty) return v;
    }
  }
  // 回退: 从 result 中提取文件路径 (形如 /path/to/file.ext)
  final result = a.result ?? '';
  return pathRe.firstMatch(result)?.group(0);
}

/// 从工具 result 刮取 (+N, -M) 增删行数 (按内容记忆化, String hashCode 有缓存)
(int, int) extractDiffCounts(String result) {
  final hit = diffMemo[result];
  if (hit != null) return hit;
  final add = int.tryParse(addCountRe.firstMatch(result)?.group(1) ?? '') ?? 0;
  final del = int.tryParse(delCountRe.firstMatch(result)?.group(1) ?? '') ?? 0;
  final out = (add, del);
  if (diffMemo.length >= toolMemoMax) {
    diffMemo.remove(diffMemo.keys.first);
  }
  diffMemo[result] = out;
  return out;
}

/// 计划卡片 — ExitPlanMode 工具产出的 plan markdown (网页端 g3e 同款)。
/// 显示标题"计划" + markdown 正文 (可折叠)。
