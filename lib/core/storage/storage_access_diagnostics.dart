import 'dart:io';

import '../common/app_logger.dart';
import 'storage_volumes.dart';

/// 存储 / 卷访问诊断：只读探测。
abstract final class StorageAccessDiagnostics {
  static Future<Map<String, Object?>> logSnapshot(String reason) async {
    final snap = await collect(reason: reason);
    AppLogger.log(
      'storage access snapshot',
      scope: 'storage_perm',
      details: snap,
    );
    return snap;
  }

  static Future<Map<String, Object?>> collect({String reason = ''}) async {
    final volumes = <Map<String, Object?>>[];
    var volumeListError = '';
    try {
      final list = await StorageVolumes().list();
      for (final v in list) {
        final probe = await _probePathReadable(v.path);
        volumes.add({
          'path': v.path,
          'description': v.description,
          'isPrimary': v.isPrimary,
          'isRemovable': v.isRemovable,
          'writable': v.writable,
          'state': v.state,
          'dirExists': probe.exists,
          'listOk': probe.listOk,
          'listError': probe.listError,
          'sampleCount': probe.sampleCount,
        });
      }
    } catch (e) {
      volumeListError = '$e';
    }

    return {
      'reason': reason,
      'platform': Platform.operatingSystem,
      'volumeCount': volumes.length,
      'volumes': volumes,
      if (volumeListError.isNotEmpty) 'volumeListError': volumeListError,
    };
  }

  static Future<({bool exists, bool listOk, String listError, int sampleCount})>
      _probePathReadable(String path) async {
    if (path.isEmpty) {
      return (
        exists: false,
        listOk: false,
        listError: 'empty_path',
        sampleCount: 0,
      );
    }
    final dir = Directory(path);
    try {
      final exists = await dir.exists();
      if (!exists) {
        return (
          exists: false,
          listOk: false,
          listError: 'not_exists',
          sampleCount: 0,
        );
      }
      var n = 0;
      await for (final _ in dir.list(followLinks: false).take(5)) {
        n++;
      }
      return (exists: true, listOk: true, listError: '', sampleCount: n);
    } catch (e) {
      return (
        exists: true,
        listOk: false,
        listError: '$e',
        sampleCount: 0,
      );
    }
  }
}
