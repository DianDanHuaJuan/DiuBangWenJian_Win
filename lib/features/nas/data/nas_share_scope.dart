import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/common/key_value_store.dart';
import '../../../core/storage/app_paths.dart';

/// 本机作为 NAS 时，对端能读到的范围。
///
/// 默认不记录文件夹，读入口走原路径。自定义时只允许已选文件夹（含子目录）。
/// 与接收落盘目录无关。
class NasShareScope {
  NasShareScope({
    required KeyValueStore keyValueStore,
    this.onPersisted,
  }) : _store = keyValueStore;

  static const modeKey = 'nas.share_scope_mode';
  static const foldersKey = 'nas.share_scope_folders';
  static const _custom = 'custom';

  final KeyValueStore _store;

  /// 共享范围已落盘后回调（冷总线 commit）。
  Future<void> Function()? onPersisted;

  bool get isCustom => _store.getString(modeKey) == _custom;

  /// 已选绝对路径，按添加顺序。自定义以外调用方应忽略。
  List<String> get folders {
    final raw = _store.getString(foldersKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is String && item.trim().isNotEmpty) p.normalize(item.trim()),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 默认状态下恒为 true。自定义时路径须落在某个已选文件夹内。
  bool allows(String absolutePath) {
    if (!isCustom) return true;
    final target = p.normalize(absolutePath);
    for (final folder in folders) {
      if (target == folder || p.isWithin(folder, target)) return true;
    }
    return false;
  }

  /// 该目录整体都在某个已选文件夹内（用于判断下载目录是否已被盖住）。
  bool coversDirectory(String absolutePath) {
    if (!isCustom) return false;
    final target = p.normalize(absolutePath.trim());
    if (target.isEmpty) return false;
    for (final folder in folders) {
      if (target == folder || p.isWithin(folder, target)) return true;
    }
    return false;
  }

  /// 追加一个已存在的目录。已被现有文件夹盖住时不重复添加。
  /// 新目录盖住旧目录时，去掉被盖住的项。
  Future<bool> addFolder(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return false;
    final type = await FileSystemEntity.type(trimmed, followLinks: false);
    if (type != FileSystemEntityType.directory) return false;
    final normalized = p.normalize(trimmed);
    final current = [...folders];
    for (final existing in current) {
      if (normalized == existing || p.isWithin(existing, normalized)) {
        await _save(current);
        return true;
      }
    }
    final kept = [
      for (final existing in current)
        if (existing != normalized && !p.isWithin(normalized, existing)) existing,
    ];
    kept.add(normalized);
    await _save(kept);
    return true;
  }

  Future<void> removeAt(int index) async {
    final next = [...folders];
    if (index < 0 || index >= next.length) return;
    next.removeAt(index);
    await _save(next);
  }

  Future<void> restoreDefault() async {
    await _store.remove(modeKey);
    await _store.remove(foldersKey);
    await onPersisted?.call();
  }

  /// `s0`、`s0/a/b` → 已选文件夹下的绝对路径。无法对应时返回 null。
  String? absoluteFor(String relativePath) {
    final parsed = _parseSlot(relativePath);
    if (parsed == null) return null;
    final dirs = folders;
    if (parsed.index < 0 || parsed.index >= dirs.length) return null;
    final root = dirs[parsed.index];
    if (parsed.rest.isEmpty) return root;
    final abs = p.normalize(p.join(root, parsed.rest));
    if (abs != root && !p.isWithin(root, abs)) return null;
    return abs;
  }

  File? resolveFile(String relativePath) {
    final parsed = _parseSlot(relativePath);
    if (parsed == null || parsed.rest.isEmpty) return null;
    final abs = absoluteFor(relativePath);
    if (abs == null || !allows(abs)) return null;
    return File(abs);
  }

  /// 列出槽位目录的直接子项。空路径返回每个仍存在的已选文件夹。
  Future<List<NasScopeNode>> list(String relativePath) async {
    final rel = AppPaths.portable(relativePath);
    if (rel.isEmpty) {
      final dirs = folders;
      final out = <NasScopeNode>[];
      for (var i = 0; i < dirs.length; i++) {
        final dir = Directory(dirs[i]);
        if (!await dir.exists()) continue;
        final stat = await dir.stat();
        out.add(
          NasScopeNode(
            name: p.basename(dirs[i]),
            relativePath: 's$i',
            isDirectory: true,
            sizeBytes: 0,
            modifiedAtMs: stat.modified.millisecondsSinceEpoch,
          ),
        );
      }
      return out;
    }

    final abs = absoluteFor(rel);
    if (abs == null || !allows(abs)) return const [];
    final dir = Directory(abs);
    if (!await dir.exists()) return const [];
    final parsed = _parseSlot(rel)!;
    final out = <NasScopeNode>[];
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      if (entity is! File && entity is! Directory) continue;
      final isDir = entity is Directory;
      final childRel = parsed.rest.isEmpty
          ? 's${parsed.index}/$name'
          : 's${parsed.index}/${parsed.rest}/$name';
      final stat = await entity.stat();
      out.add(
        NasScopeNode(
          name: name,
          relativePath: AppPaths.portable(childRel),
          isDirectory: isDir,
          sizeBytes: isDir ? 0 : stat.size,
          modifiedAtMs: stat.modified.millisecondsSinceEpoch,
        ),
      );
    }
    out.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return b.modifiedAtMs.compareTo(a.modifiedAtMs);
    });
    return out;
  }

  /// 删除槽位下的文件或子目录。不删除已选文件夹本身。
  Future<bool> deleteRelative(String relativePath) async {
    final parsed = _parseSlot(relativePath);
    if (parsed == null || parsed.rest.isEmpty) return false;
    final abs = absoluteFor(relativePath);
    if (abs == null || !allows(abs)) return false;
    final type = await FileSystemEntity.type(abs, followLinks: false);
    if (type == FileSystemEntityType.file) {
      await File(abs).delete();
      return true;
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(abs).delete(recursive: true);
      return true;
    }
    return false;
  }

  Future<void> _save(List<String> paths) async {
    await _store.setString(modeKey, _custom);
    await _store.setString(foldersKey, jsonEncode(paths));
    await onPersisted?.call();
  }

  ({int index, String rest})? _parseSlot(String relativePath) {
    final rel = AppPaths.portable(relativePath);
    final match = RegExp(r'^s(\d+)(?:/(.*))?$').firstMatch(rel);
    if (match == null) return null;
    final rest = match.group(2) ?? '';
    if (rest.contains('..') || rest.startsWith('/')) return null;
    return (index: int.parse(match.group(1)!), rest: rest);
  }
}

class NasScopeNode {
  const NasScopeNode({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    required this.sizeBytes,
    required this.modifiedAtMs,
  });

  final String name;
  final String relativePath;
  final bool isDirectory;
  final int sizeBytes;
  final int modifiedAtMs;
}
