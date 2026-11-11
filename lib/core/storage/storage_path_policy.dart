import 'package:flutter/foundation.dart';

import '../platform/app_platform.dart';
import 'storage_volumes.dart';

/// 路径是否为某存储介质的根目录（内置盘 / SD / OTG 卷根）。
///
/// 共享写根禁止落在卷根：否则会把整盘当 inbox。
Future<bool> isStorageVolumeRoot(
  String absolutePath, {
  StorageVolumes? volumes,
}) async {
  final norm = _normalizeAbs(absolutePath);
  if (norm.isEmpty || norm == '/') return true;

  const knownRoots = <String>{
    '/storage/emulated/0',
    '/sdcard',
    '/mnt/sdcard',
    '/storage/self/primary',
  };
  if (knownRoots.contains(norm)) return true;

  // Windows 盘符根：C: / C:/
  if (!kIsWeb && AppPlatform.isWindows) {
    if (RegExp(r'^[a-z]:/?$').hasMatch(norm)) return true;
  }

  if (!kIsWeb && AppPlatform.isWindows) {
    final list = await (volumes ?? StorageVolumes()).list();
    for (final v in list) {
      final vp = _normalizeAbs(v.path);
      if (vp.isNotEmpty && vp == norm) return true;
    }
  }

  // /storage/<id>（如 OTG UUID），且再无子路径。
  final match = RegExp(r'^/storage/([^/]+)$').firstMatch(norm);
  if (match != null) {
    final seg = match.group(1)!;
    if (seg != 'emulated' && seg != 'self') return true;
  }
  return false;
}

/// 路径是否落在可移动外置卷（OTG / 外置 SD）上。
///
/// 定案：外置内容不得登记进系统媒体库。
Future<bool> isRemovableStoragePath(
  String absolutePath, {
  StorageVolumes? volumes,
}) async {
  final norm = _norm(absolutePath);
  if (norm.isEmpty) return false;

  // 内置模拟盘明确排除。
  if (norm.contains('/storage/emulated/') ||
      norm.contains('/data/user/') ||
      norm.contains('/data/data/')) {
    return false;
  }

  return false;
}

String _normalizeAbs(String path) => path
    .trim()
    .replaceAll('\\', '/')
    .replaceAll(RegExp(r'/+'), '/')
    .replaceAll(RegExp(r'/+$'), '')
    .toLowerCase();

/// 写入后是否允许通知系统媒体库收录。
Future<bool> shouldScanIntoMediaStore(
  String absolutePath, {
  StorageVolumes? volumes,
}) async {
  if (await isRemovableStoragePath(absolutePath, volumes: volumes)) {
    return false;
  }
  return true;
}

String _norm(String path) =>
    path.trim().replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/');
