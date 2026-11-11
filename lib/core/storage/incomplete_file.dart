import 'dart:io';

/// 删除未完成接收文件（失败 / 取消 / 中断）。不抛错。
Future<void> discardIncompleteFile(String? absolutePath) async {
  final path = absolutePath?.trim() ?? '';
  if (path.isEmpty) return;
  try {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  } catch (_) {}
}
