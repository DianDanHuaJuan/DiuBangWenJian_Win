import 'dart:convert';
import 'dart:io';

import '../../../core/network/peer_api_client.dart';
import '../../../core/protocol/nas_api_paths.dart';
import '../../../core/storage/backup_category.dart';

/// 备份对端 API 客户端。
class BackupRemoteClient {
  BackupRemoteClient({required PeerApiClient api}) : _api = api;

  final PeerApiClient _api;

  Future<({bool ok, int? freeBytes, String? error})> preflightSpace({
    required String peerFingerprint,
    required int needBytes,
  }) async {
    final response = await _api.post(
      peerFingerprint,
      NasApiPaths.backupPreflight,
      body: {'needBytes': needBytes},
    );
    if (response == null) {
      return (ok: false, freeBytes: null, error: '对端不可达');
    }
    if (response.statusCode == 503) {
      return (ok: false, freeBytes: null, error: '对端未开启 NAS');
    }
    if (response.statusCode != 200) {
      return (ok: false, freeBytes: null, error: '空间预检失败 HTTP ${response.statusCode}');
    }
    final map = _asMap(response.data);
    final free = (map['freeBytes'] as num?)?.toInt();
    // freeBytes 探测失败时放行（与 ShareWriter 一致），由实际上传兜底。
    final ok = map['ok'] == true || free == null;
    return (
      ok: ok,
      freeBytes: free,
      error: ok ? null : '对端存储空间不足',
    );
  }

  Future<bool> fileExists({
    required String peerFingerprint,
    required BackupCategory category,
    required String fileName,
  }) async {
    final response = await _api.post(
      peerFingerprint,
      NasApiPaths.backupExists,
      body: {
        'category': category.apiName,
        'fileName': fileName,
      },
    );
    if (response == null || response.statusCode != 200) return false;
    final map = _asMap(response.data);
    return map['exists'] == true;
  }

  Future<({bool ok, String? storedName, String? error})> uploadFile({
    required String peerFingerprint,
    required BackupCategory category,
    required String fileName,
    required File file,
  }) async {
    final length = await file.length();
    final response = await _api.putStream(
      peerFingerprint,
      NasApiPaths.backupUpload,
      stream: file.openRead(),
      contentLength: length,
      query: {
        'category': category.apiName,
        'name': fileName,
      },
    );
    if (response == null) {
      return (ok: false, storedName: null, error: '上传失败或对端不可达');
    }
    if (response.statusCode == 503) {
      return (ok: false, storedName: null, error: '对端未开启 NAS');
    }
    if (response.statusCode == 507) {
      return (ok: false, storedName: null, error: '对端存储空间不足');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return (
        ok: false,
        storedName: null,
        error: '上传失败 HTTP ${response.statusCode}',
      );
    }
    final map = _asMap(response.data);
    return (
      ok: true,
      storedName: map['storedName'] as String? ?? fileName,
      error: null,
    );
  }

  Map<String, dynamic> _asMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    return const {};
  }
}
