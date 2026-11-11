import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'local_system_stats.dart';
import 'storage_volumes.dart';

/// Windows 本机内存 / 各盘符容量（对齐旧 NAS 服务端 `SystemInfoService`：
/// `GlobalMemoryStatusEx` + `GetDiskFreeSpaceEx`）。
abstract final class WindowsSystemStats {
  static Future<LocalSystemStats> read({StorageVolumes? volumes}) async {
    final mem = _memory();
    final disks = await _allDisks(volumes ?? StorageVolumes());
    final systemRoot = _volumeRoot(
      Platform.environment['SystemDrive'] ?? Directory.current.path,
    );
    VolumeDiskStats? primary;
    for (final d in disks) {
      if (_volumeRoot(d.path).toUpperCase() == systemRoot.toUpperCase()) {
        primary = d;
        break;
      }
    }
    primary ??= disks.isEmpty ? null : disks.first;

    return LocalSystemStats(
      memTotalBytes: mem.$1,
      memAvailBytes: mem.$2,
      storageTotalBytes: primary?.totalBytes ?? 0,
      storageAvailBytes: primary?.availBytes ?? 0,
      volumes: disks,
      batteryPercent: 0,
      isCharging: false,
    );
  }

  static Future<int?> freeBytesForPath(String dirPath) async {
    final disk = _diskForPath(dirPath);
    if (disk.$2 <= 0) return null;
    return disk.$2;
  }

  static (int total, int avail) _memory() {
    final status = calloc<MEMORYSTATUSEX>();
    try {
      status.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
      if (GlobalMemoryStatusEx(status) == 0) return (0, 0);
      return (
        status.ref.ullTotalPhys.toInt(),
        status.ref.ullAvailPhys.toInt(),
      );
    } finally {
      calloc.free(status);
    }
  }

  /// 与旧仓一致：used = total − totalFreeBytes（卷级空闲）。
  static (int total, int avail) _diskForPath(String path) {
    if (path.isEmpty) return (0, 0);
    final root = _volumeRoot(path);
    final freeBytesAvailable = calloc<Uint64>();
    final totalBytes = calloc<Uint64>();
    final totalFreeBytes = calloc<Uint64>();
    final rootPtr = root.toNativeUtf16();
    try {
      final ok = GetDiskFreeSpaceEx(
        rootPtr,
        freeBytesAvailable,
        totalBytes,
        totalFreeBytes,
      );
      if (ok == 0) return (0, 0);
      return (totalBytes.value.toInt(), totalFreeBytes.value.toInt());
    } finally {
      calloc.free(freeBytesAvailable);
      calloc.free(totalBytes);
      calloc.free(totalFreeBytes);
      calloc.free(rootPtr);
    }
  }

  static String _volumeRoot(String path) {
    final normalized = path.replaceAll('/', '\\').trim();
    if (normalized.length >= 2 && normalized[1] == ':') {
      return '${normalized[0].toUpperCase()}:\\';
    }
    return normalized;
  }

  static Future<List<VolumeDiskStats>> _allDisks(StorageVolumes volumes) async {
    final out = <VolumeDiskStats>[];
    try {
      final list = await volumes.list();
      for (final v in list) {
        final disk = _diskForPath(v.path);
        if (disk.$1 <= 0) continue;
        final root = _volumeRoot(v.path);
        final letter = root.length >= 2 ? root[0].toUpperCase() : '?';
        out.add(
          VolumeDiskStats(
            letter: letter,
            path: root,
            label: '$letter 盘',
            totalBytes: disk.$1,
            availBytes: disk.$2,
          ),
        );
      }
    } catch (_) {}
    out.sort((a, b) => a.letter.compareTo(b.letter));
    return List.unmodifiable(out);
  }
}
