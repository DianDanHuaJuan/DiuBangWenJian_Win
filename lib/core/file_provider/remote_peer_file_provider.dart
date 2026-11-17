import 'dart:convert';

import '../common/app_logger.dart';
import '../common/nas_peer_limit_exception.dart';
import '../network/peer_api_client.dart';
import '../protocol/nas_api_paths.dart';
import '../storage/media_library_service.dart';
import '../storage/storage_root.dart';
import 'file_entry.dart';
import 'file_provider.dart';

/// 远程列表分页结果。
class RemoteFilePage {
  const RemoteFilePage({
    required this.rootId,
    required this.items,
    required this.total,
    required this.hasMore,
    required this.offset,
    required this.limit,
    this.rootAbsolutePath,
  });

  final String rootId;
  final List<FileEntry> items;
  final int total;
  final bool hasMore;
  final int offset;
  final int limit;

  /// 共享根绝对路径（目录树从共享根上退到盘内父目录时用）。
  final String? rootAbsolutePath;
}

class RemotePeerFileProvider implements FileProvider {
  RemotePeerFileProvider({
    required this.peerFingerprint,
    required PeerApiClient api,
  }) : _api = api;

  final String peerFingerprint;
  final PeerApiClient _api;

  @override
  bool get isRemote => true;

  @override
  bool get canUpload => true;

  @override
  bool get canDownload => true;

  @override
  bool get canDelete => true;

  @override
  Future<List<StorageRoot>> roots({bool includeHistory = true}) async {
    // 远程根从第一次 list 的 rootId/display 推断；此处返回空，由 Cubit 用 list 结果补全。
    return const [];
  }

  @override
  Future<List<FileEntry>> list({
    required String rootId,
    String path = '',
  }) async {
    final page = await listPage(rootId: rootId, path: path);
    return page.items;
  }

  /// 分页列表；[limit]≤0 时对端返回全量（兼容）。
  Future<RemoteFilePage> listPage({
    required String rootId,
    String path = '',
    int offset = 0,
    int limit = 120,
  }) =>
      _fetch(
        rootId: rootId,
        path: path,
        offset: offset,
        limit: limit,
      );

  /// 首次进入可不传 rootId。
  Future<({String rootId, List<FileEntry> items})> listDefault({
    String path = '',
  }) async {
    final page = await _fetch(rootId: '', path: path);
    return (rootId: page.rootId, items: page.items);
  }

  Future<RemoteFilePage> _fetch({
    required String rootId,
    required String path,
    int offset = 0,
    int limit = 0,
  }) async {
    final isExtvol = rootId.startsWith('extvol:');
    if (isExtvol) {
      AppLogger.log(
        'RemotePeerFileProvider GET /files',
        scope: 'extvol_diag',
        details: {
          'peer': peerFingerprint.length > 12
              ? '${peerFingerprint.substring(0, 12)}…'
              : peerFingerprint,
          'rootId': rootId,
          'path': path,
          'offset': offset,
          'limit': limit,
        },
      );
    }
    final response = await _api.get(
      peerFingerprint,
      NasApiPaths.files,
      query: {
        if (rootId.isNotEmpty) 'rootId': rootId,
        if (path.isNotEmpty) 'path': path,
        if (offset > 0) 'offset': '$offset',
        if (limit > 0) 'limit': '$limit',
      },
      // MediaStore 全量列举可能较慢，避免 12s 默认超时误报不可达。
      receiveTimeout: const Duration(seconds: 60),
    );
    if (response == null) {
      if (isExtvol) {
        AppLogger.log(
          'RemotePeerFileProvider /files unreachable',
          scope: 'extvol_diag',
          details: {'rootId': rootId, 'path': path},
        );
      }
      throw Exception('对端不可达（拨号失败或超时）');
    }
    if (response.statusCode == 503) {
      _throwIfPeerLimit(response.statusCode, response.data);
      throw Exception('对端未开启 NAS');
    }
    if (response.statusCode == 401) {
      throw Exception('对端拒绝访问，请重新配对');
    }
    if (response.statusCode != 200) {
      if (isExtvol) {
        AppLogger.log(
          'RemotePeerFileProvider /files HTTP error',
          scope: 'extvol_diag',
          details: {
            'status': response.statusCode,
            'rootId': rootId,
            'path': path,
          },
        );
      }
      throw Exception('对端返回错误 HTTP ${response.statusCode}');
    }
    final map = _asMap(response.data);
    final resolvedRoot = map['rootId'] as String? ?? rootId;
    final items = (map['items'] as List<dynamic>? ?? const []);
    final entries = items.map((raw) {
      final m = Map<String, dynamic>.from(raw as Map);
      var mediaKind = m['mediaKind'] as String?;
      // 旧对端无 mediaKind 时：library + path 过滤可推断。
      if ((mediaKind == null || mediaKind.isEmpty) &&
          (resolvedRoot == MediaLibraryService.rootId || rootId == 'library')) {
        if (path == 'image' || path == 'video' || path == 'audio') {
          mediaKind = path;
        }
      }
      return FileEntry(
        name: m['name'] as String? ?? '',
        relativePath:
            m['relativePath'] as String? ?? m['name'] as String? ?? '',
        rootId: m['rootId'] as String? ?? resolvedRoot,
        rootDisplayName: m['rootDisplayName'] as String? ?? '',
        isDirectory: m['isDirectory'] == true,
        sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
        modifiedAtMs: (m['modifiedAtMs'] as num?)?.toInt() ?? 0,
        contentUri: m['contentUri'] as String?,
        mediaKind: mediaKind,
      );
    }).toList();
    final total = (map['total'] as num?)?.toInt() ?? entries.length;
    final hasMore = map['hasMore'] == true ||
        (limit > 0 && offset + entries.length < total);
    if (isExtvol) {
      AppLogger.log(
        'RemotePeerFileProvider /files ok',
        scope: 'extvol_diag',
        details: {
          'rootId': resolvedRoot,
          'path': path,
          'count': entries.length,
          'total': total,
        },
      );
    }
    final rootAbs = (map['rootAbsolutePath'] as String?)?.trim();
    return RemoteFilePage(
      rootId: resolvedRoot,
      items: entries,
      total: total,
      hasMore: hasMore,
      offset: (map['offset'] as num?)?.toInt() ?? offset,
      limit: (map['limit'] as num?)?.toInt() ?? (limit > 0 ? limit : entries.length),
      rootAbsolutePath:
          (rootAbs != null && rootAbs.isNotEmpty) ? rootAbs : null,
    );
  }

  @override
  Future<bool> delete({
    required String rootId,
    required String relativePath,
  }) async {
    final response = await _api.post(
      peerFingerprint,
      NasApiPaths.filesBatchDelete,
      body: {
        'items': [
          {'rootId': rootId, 'relativePath': relativePath, 'name': relativePath},
        ],
      },
    );
    if (response == null) return false;
    _throwIfPeerLimit(response.statusCode, response.data);
    if (response.statusCode != 200) return false;
    final map = _asMap(response.data);
    return ((map['deleted'] as num?)?.toInt() ?? 0) > 0;
  }

  @override
  Future<String?> mkdir({
    required String rootId,
    required String path,
    required String name,
  }) async {
    final response = await _api.post(
      peerFingerprint,
      NasApiPaths.filesMkdir,
      body: {
        'rootId': rootId,
        'path': path,
        'name': name,
      },
    );
    if (response == null) {
      throw Exception('对端不可达（拨号失败或超时）');
    }
    _throwIfPeerLimit(response.statusCode, response.data);
    if (response.statusCode == 409) {
      throw StateError('exists');
    }
    if (response.statusCode != 200) {
      throw Exception('新建文件夹失败 HTTP ${response.statusCode}');
    }
    final map = _asMap(response.data);
    return map['relativePath'] as String? ??
        (path.isEmpty ? name : '$path/$name');
  }

  void _throwIfPeerLimit(int statusCode, Object? data) {
    if (statusCode != 503) return;
    try {
      final map = _asMap(data);
      if (map['code'] == NasApiErrorCodes.peerLimit) {
        final limit = (map['limit'] as num?)?.toInt();
        throw NasPeerLimitException(limit: limit);
      }
    } catch (e) {
      if (e is NasPeerLimitException) rethrow;
    }
  }

  Map<String, dynamic> _asMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) return jsonDecode(data) as Map<String, dynamic>;
    throw Exception('unexpected payload');
  }
}
