import 'dart:io';

import 'package:path/path.dart' as p;

import '../common/app_exception.dart';
import 'storage_constants.dart';
import 'storage_path_policy.dart';
import 'storage_root.dart';
import 'storage_root_store.dart';
import 'storage_volumes.dart';

/// 将共享写根切到某文件系统目录（含 OTG 路径根；SAF 另议）。
class SwitchShareRoot {
  SwitchShareRoot({
    required StorageRootStore rootStore,
    StorageVolumes? volumes,
  })  : _roots = rootStore,
        _volumes = volumes ?? StorageVolumes();

  final StorageRootStore _roots;
  final StorageVolumes _volumes;

  /// 用户点选卷内子目录或任意目录后调用。
  ///
  /// 直接以所选路径为写根，不再套 `diubangfiles`。
  /// 若所选为某存储介质根目录则拒绝（避免整盘当 inbox）。
  Future<StorageRoot> toDirectory(
    String selectedPath, {
    String? displayName,
  }) async {
    final trimmed = selectedPath.trim();
    if (trimmed.isEmpty) {
      throw const AppException(
        code: 'storage_path_empty',
        message: '未选择目录',
      );
    }
    if (isAppPrivateStoragePath(trimmed)) {
      throw const AppException(
        code: 'storage_private_forbidden',
        message: '禁止使用应用私有目录作为落盘位置',
      );
    }
    if (await isStorageVolumeRoot(trimmed, volumes: _volumes)) {
      throw const AppException(
        code: 'storage_volume_root',
        message: '不能将存储介质的根目录设为存储位置，请选择根目录下的子文件夹。',
      );
    }

    final target = await resolveWritableShareDir(trimmed);
    final now = DateTime.now().millisecondsSinceEpoch;
    final name = displayName?.trim().isNotEmpty == true
        ? displayName!.trim()
        : await _suggestDisplayName(target.path);

    // 同一绝对路径复用已有根 id，避免历史里堆重复项。
    final existing = await _findByPath(target.path);
    final root = StorageRoot(
      id: existing?.id ?? 'path_$now',
      kind: StorageRootKind.path,
      uriOrPath: target.path,
      displayName: name,
      addedAtMs: existing?.addedAtMs ?? now,
    );
    await _roots.setCurrent(root);
    return root;
  }

  /// 把已在列表中的历史根重新设为当前写根（先做可写探测）。
  Future<StorageRoot> toExisting(StorageRoot root) async {
    if (root.revoked) {
      throw const AppException(
        code: 'storage_revoked',
        message: '该位置已失效，请重新选择',
      );
    }
    if (root.kind != StorageRootKind.path) {
      throw const AppException(
        code: 'storage_kind_unsupported',
        message: '当前仅支持文件夹路径共享根',
      );
    }
    if (isAppPrivateStoragePath(root.uriOrPath)) {
      throw const AppException(
        code: 'storage_private_forbidden',
        message: '禁止使用应用私有目录作为落盘位置',
      );
    }
    if (await isStorageVolumeRoot(root.uriOrPath, volumes: _volumes)) {
      throw const AppException(
        code: 'storage_volume_root',
        message: '不能将存储介质的根目录设为存储位置，请选择根目录下的子文件夹。',
      );
    }
    await resolveWritableShareDir(root.uriOrPath);
    await _roots.setCurrent(root);
    return root;
  }

  Future<List<StorageVolumeInfo>> listVolumes() => _volumes.list();

  Future<StorageRoot?> _findByPath(String absolutePath) async {
    final normalized = _norm(absolutePath);
    for (final r in await _roots.listRoots()) {
      if (r.kind == StorageRootKind.path && _norm(r.uriOrPath) == normalized) {
        return r;
      }
    }
    return null;
  }

  Future<String> _suggestDisplayName(String absolutePath) async {
    final normalized = _norm(absolutePath);
    if (normalized.endsWith('/download/${StorageConstants.folderName}') ||
        normalized.endsWith('/downloads/${StorageConstants.folderName}')) {
      return StorageConstants.displayPathLabel;
    }

    final volumes = await _volumes.list();
    for (final vol in volumes) {
      final vp = _norm(vol.path);
      if (normalized == vp || normalized.startsWith('$vp/')) {
        final label = vol.description.trim().isEmpty
            ? (vol.isExternal ? '外置存储' : '本机存储')
            : vol.description.trim();
        final leaf = p.basename(absolutePath);
        if (leaf == StorageConstants.folderName) {
          return vol.isExternal ? 'U盘/$leaf' : '$label/$leaf';
        }
        return vol.isExternal ? 'U盘/$leaf' : '$label/$leaf';
      }
    }

    final parent = p.basename(p.dirname(absolutePath));
    final leaf = p.basename(absolutePath);
    if (parent.isEmpty || parent == '.' || parent == '/') {
      return leaf;
    }
    return '$parent/$leaf';
  }
}

/// 解析并探测可写共享目录（直接使用所选路径，不套子目录）。
Future<Directory> resolveWritableShareDir(String selectedPath) async {
  var path = selectedPath.trim().replaceAll('\\', '/');
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.isEmpty) {
    throw const AppException(
      code: 'storage_path_empty',
      message: '未选择目录',
    );
  }

  final dir = Directory(path);
  if (isAppPrivateStoragePath(dir.path)) {
    throw const AppException(
      code: 'storage_private_forbidden',
      message: '禁止使用应用私有目录作为落盘位置',
    );
  }

  try {
    await dir.create(recursive: true);
    final probe = File(p.join(dir.path, '.write_probe'));
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
  } on FileSystemException catch (e) {
    throw AppException(
      code: 'storage_not_writable',
      message: '目录不可写：${dir.path}',
      originalError: e,
    );
  }

  return dir;
}

String _norm(String path) =>
    path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase();
