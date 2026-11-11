import 'file_entry.dart';

/// 从共享根往下收集某一分类的文件（不含目录，不读系统媒体库）。
///
/// 深度和目录数有上限，避免把整个外置盘扫穿。
Future<List<FileEntry>> collectShareCategoryFiles({
  required Future<List<FileEntry>> Function(String relativePath) listDirectory,
  required bool Function(FileEntry entry) include,
  String startPath = '',
}) async {
  const maxDirs = 120;
  const maxDepth = 8;
  final files = <FileEntry>[];
  final pending = <(String, int)>[(startPath, 0)];
  final seenDirs = <String>{startPath};
  var walked = 0;
  while (pending.isNotEmpty && walked < maxDirs) {
    final (path, depth) = pending.removeAt(0);
    walked++;
    final entries = await listDirectory(path);
    for (final entry in entries) {
      if (entry.isDirectory) {
        if (depth >= maxDepth) continue;
        final next = entry.relativePath;
        if (next.isEmpty || !seenDirs.add(next)) continue;
        pending.add((next, depth + 1));
        continue;
      }
      if (include(entry)) files.add(entry);
    }
  }
  files.sort((a, b) => b.modifiedAtMs.compareTo(a.modifiedAtMs));
  return files;
}
