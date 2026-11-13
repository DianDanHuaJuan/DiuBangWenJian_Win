import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/common/app_logger.dart';
import '../../../../core/file_provider/file_entry.dart';
import '../../../../core/storage/storage_root_store.dart';
import '../../../../core/file_provider/file_provider.dart';
import '../../../../core/file_provider/file_thumbnail_loader.dart';
import '../../../../core/file_provider/local_file_provider.dart';
import '../../../../core/file_provider/remote_peer_file_provider.dart';
import '../../../../core/file_provider/share_category_files.dart';
import '../../../../core/protocol/nas_api_paths.dart';
import '../../../../core/storage/external_volume_browser.dart';
import '../../../../core/storage/media_library_service.dart';
import '../../../../core/storage/storage_root.dart';
import '../../../../core/storage/storage_volumes.dart';
import '../../../preview/gallery_launcher.dart';
import '../../application/file_browse_facade.dart';

/// 本机文件页视角：系统媒体库（+共享区文档） / 外置文件夹。
enum LocalBrowseSurface { local, external }

class DeviceFilesState {
  const DeviceFilesState({
    this.loading = true,
    this.loadingMore = false,
    this.entries = const [],
    this.rootId = '',
    this.rootDisplayName = '',
    this.path = '',
    this.category = FileCategoryFilter.photo,
    this.source = ShareSourceFilter.current,
    this.surface = LocalBrowseSurface.local,
    this.externalVolumes = const [],
    this.externalVolumePath,
    this.gridMode = true,
    this.selectionMode = false,
    this.selected = const {},
    this.hasMore = false,
    this.total = 0,
    this.error,
    this.busy = false,
  });

  final bool loading;
  final bool loadingMore;
  final List<FileEntry> entries;
  final String rootId;
  final String rootDisplayName;
  final String path;
  final FileCategoryFilter category;
  final ShareSourceFilter source;
  final LocalBrowseSurface surface;
  final List<StorageVolumeInfo> externalVolumes;
  final String? externalVolumePath;
  final bool gridMode;
  final bool selectionMode;
  final Set<String> selected;
  final bool hasMore;
  final int total;
  final String? error;
  final bool busy;

  bool get isExternalSurface => surface == LocalBrowseSurface.external;

  List<FileEntry> get mediaEntries => entries
      .where((e) => !e.isDirectory && (e.isImage || e.isVideo))
      .toList(growable: false);

  List<String> get breadcrumbSegments =>
      path.isEmpty ? const [] : path.split('/').where((s) => s.isNotEmpty).toList();

  /// 外置模式不过滤分类；本机仍按分类。
  List<FileEntry> get visibleEntries => isExternalSurface
      ? entries
      : entries.where(category.matches).toList();

  DeviceFilesState copyWith({
    bool? loading,
    bool? loadingMore,
    List<FileEntry>? entries,
    String? rootId,
    String? rootDisplayName,
    String? path,
    FileCategoryFilter? category,
    ShareSourceFilter? source,
    LocalBrowseSurface? surface,
    List<StorageVolumeInfo>? externalVolumes,
    Object? externalVolumePath = _sentinel,
    bool? gridMode,
    bool? selectionMode,
    Set<String>? selected,
    bool? hasMore,
    int? total,
    String? error,
    bool clearError = false,
    bool? busy,
  }) =>
      DeviceFilesState(
        loading: loading ?? this.loading,
        loadingMore: loadingMore ?? this.loadingMore,
        entries: entries ?? this.entries,
        rootId: rootId ?? this.rootId,
        rootDisplayName: rootDisplayName ?? this.rootDisplayName,
        path: path ?? this.path,
        category: category ?? this.category,
        source: source ?? this.source,
        surface: surface ?? this.surface,
        externalVolumes: externalVolumes ?? this.externalVolumes,
        externalVolumePath: identical(externalVolumePath, _sentinel)
            ? this.externalVolumePath
            : externalVolumePath as String?,
        gridMode: gridMode ?? this.gridMode,
        selectionMode: selectionMode ?? this.selectionMode,
        selected: selected ?? this.selected,
        hasMore: hasMore ?? this.hasMore,
        total: total ?? this.total,
        error: clearError ? null : (error ?? this.error),
        busy: busy ?? this.busy,
      );
}

const Object _sentinel = Object();

class DeviceFilesCubit extends Cubit<DeviceFilesState>
    implements FileBrowseFacade {
  DeviceFilesCubit({
    required this.isSelf,
    this.peerId,
    this.peerTitle,
  }) : super(const DeviceFilesState());

  static const pageSize = 120;

  final bool isSelf;
  final String? peerId;
  final String? peerTitle;

  late final FileProvider _provider;
  List<StorageRoot> _localRoots = const [];
  final ExternalVolumeBrowser _externalBrowser = ExternalVolumeBrowser();
  String? _loadedPeerName;

  /// AppBar 标题：本机固定；对端用设备名（存储面由拨码切换，不进标题）。
  String get appBarTitle {
    if (isSelf) {
      return '本机文件';
    }
    final name = peerTitle?.trim().isNotEmpty == true
        ? peerTitle!.trim()
        : (_loadedPeerName?.trim().isNotEmpty == true
            ? _loadedPeerName!.trim()
            : null);
    return name ?? '设备';
  }

  @override
  Listenable get thumbCacheListenable => FileThumbnailLoader.instance.cache;

  @override
  void requestVisibleThumbs({
    required List<FileEntry> entries,
    required int firstIndex,
    required int lastIndex,
    bool allowPreload = true,
    int scrollBias = 0,
  }) {
    FileThumbnailLoader.instance.requestVisibleRange(
      entries: entries,
      firstIndex: firstIndex,
      lastIndex: lastIndex,
      isSelf: isSelf,
      peerFingerprint: peerId,
      allowPreload: allowPreload,
      scrollBias: scrollBias,
    );
  }

  @override
  Stream<void> watchThumb(FileEntry entry) {
    return FileThumbnailLoader.instance.watch(
      entry,
      isSelf: isSelf,
      peerFingerprint: peerId,
    );
  }

  @override
  Uint8List? peekThumb(FileEntry entry) {
    return FileThumbnailLoader.instance.peek(
      entry,
      isSelf: isSelf,
      peerFingerprint: peerId,
    );
  }

  @override
  Map<String, Uint8List> seedThumbnailsFor(FileEntry entry) {
    final seed = <String, Uint8List>{};
    final cached = peekThumb(entry);
    if (cached != null && cached.isNotEmpty) {
      seed['${entry.rootId}|${entry.relativePath}'] = cached;
      seed[entry.relativePath] = cached;
    }
    return seed;
  }

  /// 打开媒体画廊；非媒体返回 false（由 Page 提示）。
  Future<bool> openMediaPreview(BuildContext context, FileEntry entry) async {
    if (entry.isDirectory || (!entry.isImage && !entry.isVideo)) {
      return false;
    }
    if (entry.isVideo) {
      AppLogger.log(
        'openMediaPreview video',
        scope: 'video_diag',
        details: {
          'isSelf': isSelf,
          'peerId': peerId ?? '',
          'name': entry.name,
          'rootId': entry.rootId,
          'path': entry.relativePath,
          'absolutePath': entry.absolutePath ?? '',
          'surface': state.surface.name,
          'externalVolumePath': state.externalVolumePath ?? '',
        },
      );
    }
    var media = state.mediaEntries;
    if (media.isEmpty) {
      media = state.visibleEntries
          .where((e) => !e.isDirectory && (e.isImage || e.isVideo))
          .toList(growable: false);
    }
    if (media.isEmpty) {
      media = [entry];
    } else if (!media.any(
      (e) =>
          e.rootId == entry.rootId && e.relativePath == entry.relativePath,
    )) {
      media = [entry, ...media];
    }
    await openGalleryPreview(
      context: context,
      mediaFiles: media,
      current: entry,
      isSelf: isSelf,
      peerFingerprint: peerId,
      thumbnails: seedThumbnailsFor(entry),
    );
    return true;
  }

  Future<void> start() async {
    if (isSelf) {
      _provider = LocalFileProvider(
        shareReader: serviceLocator.shareReader(),
        rootStore: serviceLocator.storageRootStore(),
      );
    } else {
      final id = peerId;
      if (id == null || id.isEmpty) {
        emit(state.copyWith(loading: false, error: '缺少对端指纹'));
        return;
      }
      _provider = RemotePeerFileProvider(
        peerFingerprint: id,
        api: serviceLocator.peerApiClient(),
      );
      try {
        final repo = await serviceLocator.peerRepository();
        final peer = await repo.findByFingerprint(id);
        _loadedPeerName = peer?.name;
        // 触发重建，使 AppBar 立刻显示设备名。
        emit(state.copyWith());
      } catch (_) {}
      // 与聊天同等：进入对端文件页即建立/保活业务 WS；并挂上全局收包管道。
      try {
        await serviceLocator.ensureTransferStack();
        await serviceLocator.offerAcceptService();
        await serviceLocator.peerWsSession().enter(id);
      } catch (_) {}
    }
    await refresh();
  }

  Future<void> refresh() async {
    emit(
      state.copyWith(
        loading: true,
        loadingMore: false,
        hasMore: false,
        total: 0,
        clearError: true,
      ),
    );
    try {
      if (state.isExternalSurface) {
        await _probeExternalVolumes();
        await _refreshExternal();
      } else if (isSelf) {
        await _probeExternalVolumes();
        await _refreshLocal(reset: true);
      } else {
        await _refreshRemote(reset: true);
        // 探测外置卷供拨码置灰（失败则视为无外置）。
        try {
          await _probeExternalVolumes();
        } catch (_) {
          if (!isClosed) {
            emit(state.copyWith(externalVolumes: const []));
          }
        }
      }
    } catch (e) {
      emit(state.copyWith(loading: false, loadingMore: false, error: '$e'));
    }
  }

  Future<void> _probeExternalVolumes() async {
    AppLogger.log(
      'probeExternalVolumes start',
      scope: 'extvol_diag',
      details: {
        'isSelf': isSelf,
        'peerId': peerId ?? '',
        'prevSelected': state.externalVolumePath ?? '',
      },
    );
    final vols = isSelf
        ? await _externalBrowser.listExternalVolumes()
        : await _listRemoteExternalVolumes();
    AppLogger.log(
      'probeExternalVolumes done',
      scope: 'extvol_diag',
      details: {
        'count': vols.length,
        'vols': [
          for (final v in vols)
            {
              'path': v.path,
              'rootId': v.rootId.isNotEmpty
                  ? v.rootId
                  : _externalBrowser.rootIdFor(v.path),
              'desc': v.description,
              'primary': v.isPrimary,
            },
        ],
      },
    );
    emit(state.copyWith(externalVolumes: vols));
    final selected = state.externalVolumePath;
    if (selected != null &&
        selected.isNotEmpty &&
        !vols.any((v) => _externalBrowser.isSameVolumePath(v.path, selected))) {
      AppLogger.log(
        'probeExternalVolumes selected missing → fallback local',
        scope: 'extvol_diag',
        details: {
          'selected': selected,
          'available': [for (final v in vols) v.path],
        },
      );
      // 拔盘：退回系统存储。
      emit(
        state.copyWith(
          surface: LocalBrowseSurface.local,
          externalVolumePath: null,
          path: '',
          rootId: '',
          error: vols.isEmpty ? '外置存储已移除' : null,
        ),
      );
    }
  }

  Future<List<StorageVolumeInfo>> _listRemoteExternalVolumes() async {
    final id = peerId;
    if (id == null || id.isEmpty) {
      AppLogger.log(
        'listRemoteExternalVolumes skip empty peerId',
        scope: 'extvol_diag',
      );
      return const [];
    }
    AppLogger.log(
      'listRemoteExternalVolumes GET /storage/volumes',
      scope: 'extvol_diag',
      details: {'peerId': id},
    );
    final response = await serviceLocator.peerApiClient().get(
          id,
          NasApiPaths.storageVolumes,
          receiveTimeout: const Duration(seconds: 20),
        );
    if (response == null || response.statusCode != 200) {
      AppLogger.log(
        'listRemoteExternalVolumes HTTP fail',
        scope: 'extvol_diag',
        details: {
          'status': response?.statusCode,
          'nullResponse': response == null,
        },
      );
      throw Exception(
        response?.statusCode == 503
            ? '对端未开启 NAS'
            : '无法获取对端外置存储（请确认对端已更新）',
      );
    }
    final data = response.data;
    final map = data is Map
        ? Map<String, dynamic>.from(data)
        : <String, dynamic>{};
    final items = map['items'] as List<dynamic>? ?? const [];
    final raw = items.whereType<Map>().toList(growable: false);
    final filtered = raw
        .map((e) => StorageVolumeInfo.fromMap(e))
        .where((v) => v.path.isNotEmpty && !v.isPrimary)
        .toList(growable: false);
    AppLogger.log(
      'listRemoteExternalVolumes parsed',
      scope: 'extvol_diag',
      details: {
        'httpCount': map['count'],
        'rawItems': [
          for (final e in raw)
            {
              'path': e['path'],
              'rootId': e['rootId'],
              'isPrimary': e['isPrimary'],
              'description': e['description'],
            },
        ],
        'filteredCount': filtered.length,
        'filtered': [
          for (final v in filtered)
            {
              'path': v.path,
              'rootId': v.rootId,
              'clientRootId': _externalBrowser.rootIdFor(v.path),
              'desc': v.description,
            },
        ],
      },
    );
    return filtered;
  }

  Future<void> setSurface(LocalBrowseSurface surface) async {
    if (surface == LocalBrowseSurface.external) {
      AppLogger.log(
        'setSurface → external',
        scope: 'extvol_diag',
        details: {'isSelf': isSelf, 'peerId': peerId ?? ''},
      );
      if (isSelf) {
        // 列外置卷通常需要全部文件访问。
        try {
          await serviceLocator.permissionService().requestAllStorageForNas();
        } catch (_) {}
      }
      try {
        await _probeExternalVolumes();
      } catch (e) {
        AppLogger.log(
          'setSurface probe failed',
          scope: 'extvol_diag',
          error: e,
        );
        emit(state.copyWith(error: '$e'));
        return;
      }
      if (state.externalVolumes.isEmpty) {
        AppLogger.log(
          'setSurface external empty volumes',
          scope: 'extvol_diag',
          details: {'isSelf': isSelf},
        );
        emit(
          state.copyWith(
            error: isSelf
                ? '未检测到外置存储。请插入 OTG U 盘，并确认已授予「所有文件访问」后点刷新。'
                : '对端未检测到外置存储。请确认对端已插入 OTG 并授予文件访问权限。',
          ),
        );
        return;
      }
      final vols = state.externalVolumes;
      if (vols.length == 1) {
        final only = vols.first;
        final rootId = only.rootId.isNotEmpty
            ? only.rootId
            : _externalBrowser.rootIdFor(only.path);
        AppLogger.log(
          'setSurface single volume → enter',
          scope: 'extvol_diag',
          details: {
            'path': only.path,
            'rootId': rootId,
            'desc': only.description,
          },
        );
        emit(
          state.copyWith(
            surface: LocalBrowseSurface.external,
            externalVolumePath: only.path,
            path: '',
            rootId: rootId,
            rootDisplayName:
                only.description.isEmpty ? '外置存储' : only.description,
            selectionMode: false,
            selected: {},
            hasMore: false,
            clearError: true,
          ),
        );
      } else {
        // 多卷：先列卷，再点入。
        AppLogger.log(
          'setSurface multi volume → volume list',
          scope: 'extvol_diag',
          details: {
            'count': vols.length,
            'paths': [for (final v in vols) v.path],
            'rootIds': [
              for (final v in vols)
                v.rootId.isNotEmpty
                    ? v.rootId
                    : _externalBrowser.rootIdFor(v.path),
            ],
          },
        );
        emit(
          state.copyWith(
            surface: LocalBrowseSurface.external,
            externalVolumePath: null,
            path: '',
            rootId: '',
            rootDisplayName: '外置存储',
            selectionMode: false,
            selected: {},
            hasMore: false,
            clearError: true,
          ),
        );
      }
    } else {
      emit(
        state.copyWith(
          surface: LocalBrowseSurface.local,
          externalVolumePath: null,
          path: '',
          rootId: '',
          selectionMode: false,
          selected: {},
          hasMore: false,
          clearError: true,
        ),
      );
    }
    await refresh();
  }

  Future<void> selectExternalVolume(StorageVolumeInfo volume) async {
    final volPath = ExternalVolumeBrowser.normalizePath(volume.path);
    final rootId = volume.rootId.isNotEmpty
        ? volume.rootId
        : _externalBrowser.rootIdFor(volPath);
    AppLogger.log(
      'selectExternalVolume',
      scope: 'extvol_diag',
      details: {
        'rawPath': volume.path,
        'volPath': volPath,
        'rootId': rootId,
        'desc': volume.description,
        'isSelf': isSelf,
      },
    );
    emit(
      state.copyWith(
        surface: LocalBrowseSurface.external,
        externalVolumePath: volPath,
        path: '',
        rootId: rootId,
        rootDisplayName:
            volume.description.isEmpty ? '外置存储' : volume.description,
        selectionMode: false,
        selected: {},
        hasMore: false,
        clearError: true,
      ),
    );
    await refresh();
  }

  Future<void> _refreshExternal() async {
    final vols = state.externalVolumes;
    if (vols.isEmpty) {
      AppLogger.log('_refreshExternal empty volumes', scope: 'extvol_diag');
      emit(
        state.copyWith(
          loading: false,
          entries: const [],
          surface: LocalBrowseSurface.local,
          externalVolumePath: null,
          error: '外置存储已移除',
        ),
      );
      return;
    }

    var volPath = state.externalVolumePath;
    if (volPath == null || volPath.isEmpty) {
      volPath = vols.first.path;
    }
    AppLogger.log(
      '_refreshExternal enter',
      scope: 'extvol_diag',
      details: {
        'volPath': volPath,
        'stateExternalVolumePath': state.externalVolumePath ?? '',
        'statePath': state.path,
        'stateRootId': state.rootId,
        'volsCount': vols.length,
        'isSelf': isSelf,
      },
    );
    if (isSelf && !await _externalBrowser.isVolumeMounted(volPath)) {
      AppLogger.log(
        '_refreshExternal not mounted',
        scope: 'extvol_diag',
        details: {'volPath': volPath},
      );
      emit(
        state.copyWith(
          loading: false,
          entries: const [],
          surface: LocalBrowseSurface.local,
          externalVolumePath: null,
          error: '外置存储已移除',
        ),
      );
      return;
    }

    final label = vols
        .firstWhere(
          (v) => _externalBrowser.isSameVolumePath(v.path, volPath!),
          orElse: () => vols.first,
        )
        .description;

    // 多卷且尚未进入具体路径：根层列出各卷，便于选择。
    if (vols.length > 1 &&
        state.path.isEmpty &&
        (state.externalVolumePath == null ||
            state.externalVolumePath!.isEmpty)) {
      final volumeEntries = [
        for (final v in vols)
          FileEntry(
            name: v.description.isEmpty ? v.path : v.description,
            relativePath: '',
            rootId: v.rootId.isNotEmpty
                ? v.rootId
                : _externalBrowser.rootIdFor(v.path),
            rootDisplayName: '外置存储',
            isDirectory: true,
            sizeBytes: 0,
            modifiedAtMs: 0,
            absolutePath: v.path,
          ),
      ];
      AppLogger.log(
        '_refreshExternal show volume picker',
        scope: 'extvol_diag',
        details: {
          'entries': [
            for (final e in volumeEntries)
              {
                'name': e.name,
                'rootId': e.rootId,
                'absolutePath': e.absolutePath,
              },
          ],
        },
      );
      emit(
        state.copyWith(
          loading: false,
          loadingMore: false,
          entries: volumeEntries,
          rootId: '',
          rootDisplayName: '外置存储',
          externalVolumePath: null,
          hasMore: false,
          total: volumeEntries.length,
          clearError: true,
        ),
      );
      return;
    }

    final List<FileEntry> entries;
    final requestRootId = _externalBrowser.rootIdFor(volPath);
    if (isSelf) {
      AppLogger.log(
        '_refreshExternal local listDirectory',
        scope: 'extvol_diag',
        details: {
          'volPath': volPath,
          'rel': state.path,
          'rootId': requestRootId,
        },
      );
      entries = await _externalBrowser.listDirectory(
        volumePath: volPath,
        volumeLabel: label.isEmpty ? '外置存储' : label,
        relativePath: state.path,
      );
    } else {
      final remote = _provider as RemotePeerFileProvider;
      AppLogger.log(
        '_refreshExternal remote GET /files',
        scope: 'extvol_diag',
        details: {
          'rootId': requestRootId,
          'path': state.path,
          'volPath': volPath,
          'peerId': peerId ?? '',
        },
      );
      final page = await remote.listPage(
        rootId: requestRootId,
        path: state.path,
        limit: 0,
      );
      entries = page.items;
      AppLogger.log(
        '_refreshExternal remote /files ok',
        scope: 'extvol_diag',
        details: {'rootId': page.rootId, 'count': entries.length},
      );
    }
    emit(
      state.copyWith(
        loading: false,
        loadingMore: false,
        entries: entries,
        rootId: requestRootId,
        rootDisplayName: label.isEmpty ? '外置存储' : label,
        externalVolumePath: volPath,
        hasMore: false,
        total: entries.length,
        clearError: true,
      ),
    );
  }

  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    if (!state.category.isMediaLibraryCategory) return;
    emit(state.copyWith(loadingMore: true, clearError: true));
    try {
      if (isSelf) {
        await _emitLibraryEntries(append: true);
      } else {
        await _refreshRemoteLibrary(append: true);
      }
    } catch (e) {
      emit(state.copyWith(loadingMore: false, error: '$e'));
    }
  }

  Future<void> _refreshLocal({required bool reset}) async {
    if (state.category.isMediaLibraryCategory) {
      await _emitLibraryEntries(forceRefresh: true, append: false);
      return;
    }

    final local = _provider as LocalFileProvider;
    _localRoots = await local.roots(includeHistory: true);
    final current = await local.ensureCurrent();
    final roots = switch (state.source) {
      ShareSourceFilter.current => [current],
      ShareSourceFilter.history => [
          _localRoots.firstWhere(
            (r) => r.id != current.id,
            orElse: () => current,
          ),
        ],
      ShareSourceFilter.all => _localRoots,
    };
    final entries = <FileEntry>[];
    for (final root in roots) {
      entries.addAll(
        await collectShareCategoryFiles(
          listDirectory: (path) => local.list(rootId: root.id, path: path),
          include: state.category.matches,
        ),
      );
    }
    entries.sort((a, b) => b.modifiedAtMs.compareTo(a.modifiedAtMs));
    final label = state.source == ShareSourceFilter.all
        ? '全部来源'
        : (roots.first.displayName.isEmpty ? '共享区' : roots.first.displayName);
    emit(
      state.copyWith(
        loading: false,
        loadingMore: false,
        entries: entries,
        rootId: roots.first.id,
        rootDisplayName: label,
        path: '',
        hasMore: false,
        total: entries.length,
        clearError: true,
      ),
    );
  }

  Future<void> _refreshRemote({required bool reset}) async {
    if (state.category.isMediaLibraryCategory) {
      await _refreshRemoteLibrary(append: false);
      return;
    }

    final remote = _provider as RemotePeerFileProvider;
    final entries = await collectShareCategoryFiles(
      listDirectory: (path) => remote.list(rootId: 'fs', path: path),
      include: state.category.matches,
    );
    emit(
      state.copyWith(
        loading: false,
        loadingMore: false,
        entries: entries,
        rootId: entries.isNotEmpty ? entries.first.rootId : 'fs',
        rootDisplayName: entries.isNotEmpty &&
                entries.first.rootDisplayName.isNotEmpty
            ? entries.first.rootDisplayName
            : '共享区',
        path: '',
        hasMore: false,
        total: entries.length,
        clearError: true,
      ),
    );
  }

  Future<void> _refreshRemoteLibrary({required bool append}) async {
    final remote = _provider as RemotePeerFileProvider;
    final kind =
        state.category == FileCategoryFilter.photo ? 'image' : 'video';
    final offset = append ? state.entries.length : 0;
    final page = await remote.listPage(
      rootId: MediaLibraryService.rootId,
      path: kind,
      offset: offset,
      limit: pageSize,
    );
    final next = append ? [...state.entries, ...page.items] : page.items;
    emit(
      state.copyWith(
        loading: false,
        loadingMore: false,
        entries: next,
        rootId: MediaLibraryService.rootId,
        rootDisplayName: MediaLibraryService.rootDisplayName,
        hasMore: page.hasMore,
        total: page.total,
        clearError: true,
      ),
    );
  }

  Future<void> _emitLibraryEntries({
    bool forceRefresh = false,
    bool append = false,
  }) async {
    final kind =
        state.category == FileCategoryFilter.photo ? 'image' : 'video';
    final offset = append ? state.entries.length : 0;
    final page = await serviceLocator.mediaLibraryService().listPage(
          path: kind,
          offset: offset,
          limit: pageSize,
          forceRefresh: forceRefresh && !append,
        );
    final mapped = [for (final a in page.items) a.toFileEntry()];
    final next = append ? [...state.entries, ...mapped] : mapped;
    emit(
      state.copyWith(
        loading: false,
        loadingMore: false,
        entries: next,
        rootId: MediaLibraryService.rootId,
        rootDisplayName: MediaLibraryService.rootDisplayName,
        hasMore: page.hasMore,
        total: page.total,
        clearError: true,
      ),
    );
  }

  Future<void> setCategory(FileCategoryFilter category) async {
    final wasMedia = state.category.isMediaLibraryCategory;
    final isMedia = category.isMediaLibraryCategory;
    emit(
      state.copyWith(
        loading: true,
        category: category,
        entries: const [],
        path: wasMedia != isMedia ? '' : state.path,
        rootId: wasMedia != isMedia ? '' : state.rootId,
        selectionMode: false,
        selected: {},
        hasMore: false,
        total: 0,
        clearError: true,
      ),
    );
    await refresh();
  }

  Future<void> setSource(ShareSourceFilter source) async {
    emit(
      state.copyWith(
        loading: true,
        source: source,
        entries: const [],
        path: '',
        rootId: '',
        selectionMode: false,
        selected: {},
        hasMore: false,
        total: 0,
        clearError: true,
      ),
    );
    await refresh();
  }

  void toggleGridMode() {
    emit(state.copyWith(gridMode: !state.gridMode));
  }

  void applyDragSelection(Set<String> keys) {
    if (state.selectionMode &&
        state.selected.length == keys.length &&
        state.selected.containsAll(keys)) {
      return;
    }
    emit(state.copyWith(selectionMode: true, selected: keys));
  }

  void enterSelection() {
    emit(state.copyWith(selectionMode: true, selected: {}));
  }

  void exitSelection() {
    emit(state.copyWith(selectionMode: false, selected: {}));
  }

  void selectEntry(FileEntry entry) {
    if (entry.isDirectory) return;
    final key = '${entry.rootId}|${entry.relativePath}';
    if (state.selected.contains(key)) return;
    emit(state.copyWith(selected: {...state.selected, key}));
  }

  void toggleSelect(FileEntry entry) {
    if (entry.isDirectory) return;
    final key = '${entry.rootId}|${entry.relativePath}';
    final next = Set<String>.from(state.selected);
    if (next.contains(key)) {
      next.remove(key);
    } else {
      next.add(key);
    }
    emit(state.copyWith(selected: next));
  }

  bool isSelected(FileEntry entry) =>
      state.selected.contains('${entry.rootId}|${entry.relativePath}');

  Future<void> openEntry(FileEntry entry) async {
    if (!entry.isDirectory) return;
    if (state.isExternalSurface) {
      final volPath = _externalBrowser.volumePathFromRootId(entry.rootId);
      final matchRows = [
        for (final v in state.externalVolumes)
          {
            'v.path': v.path,
            'eq_strict': v.path == volPath,
            'eq_same': volPath != null &&
                _externalBrowser.isSameVolumePath(v.path, volPath),
          },
      ];
      AppLogger.log(
        'openEntry external',
        scope: 'extvol_diag',
        details: {
          'entry.name': entry.name,
          'entry.rootId': entry.rootId,
          'entry.relativePath': entry.relativePath,
          'entry.absolutePath': entry.absolutePath ?? '',
          'decodedVolPath': volPath ?? '',
          'state.externalVolumePath': state.externalVolumePath ?? '',
          'willTryVolumePick': volPath != null &&
              entry.relativePath.isEmpty &&
              state.externalVolumePath == null,
          'volumeMatch': matchRows,
        },
      );
      // 多卷列表点入某一卷（路径比较兼容 C:\ / C:/）。
      if (volPath != null &&
          entry.relativePath.isEmpty &&
          state.externalVolumePath == null) {
        StorageVolumeInfo? vol;
        for (final v in state.externalVolumes) {
          if (_externalBrowser.isSameVolumePath(v.path, volPath)) {
            vol = v;
            break;
          }
        }
        vol ??= StorageVolumeInfo(
          path: volPath,
          description: entry.name,
          isPrimary: false,
          isRemovable: false,
          writable: true,
        );
        AppLogger.log(
          'openEntry volume pick → selectExternalVolume',
          scope: 'extvol_diag',
          details: {
            'matchedFromList': matchRows.any((m) => m['eq_same'] == true),
            'selectedPath': vol.path,
          },
        );
        await selectExternalVolume(vol);
        return;
      }
    }
    AppLogger.log(
      'openEntry fallback → refresh with entry path',
      scope: 'extvol_diag',
      details: {
        'rootId': entry.rootId,
        'path': entry.relativePath,
        'isExternal': state.isExternalSurface,
      },
    );
    emit(
      state.copyWith(
        rootId: entry.rootId,
        rootDisplayName: entry.rootDisplayName,
        path: entry.relativePath,
        selectionMode: false,
        selected: {},
        hasMore: false,
      ),
    );
    await refresh();
  }

  Future<void> goUp() async {
    if (state.path.isEmpty) {
      // 外置多卷：在卷根再返回 → 卷列表。
      if (state.isExternalSurface &&
          state.externalVolumePath != null &&
          state.externalVolumes.length > 1) {
        emit(
          state.copyWith(
            externalVolumePath: null,
            path: '',
            rootId: '',
            rootDisplayName: '外置存储',
            selectionMode: false,
            selected: {},
            hasMore: false,
          ),
        );
        await refresh();
      }
      return;
    }
    final parts = state.breadcrumbSegments;
    final parent = parts.length <= 1
        ? ''
        : parts.sublist(0, parts.length - 1).join('/');
    emit(state.copyWith(path: parent, selectionMode: false, selected: {}, hasMore: false));
    await refresh();
  }

  Future<void> goBreadcrumb(int index) async {
    if (index < 0) {
      if (state.isExternalSurface && state.externalVolumes.length > 1) {
        emit(
          state.copyWith(
            externalVolumePath: null,
            path: '',
            rootId: '',
            rootDisplayName: '外置存储',
            selectionMode: false,
            selected: {},
            hasMore: false,
          ),
        );
      } else {
        emit(
          state.copyWith(
            path: '',
            selectionMode: false,
            selected: {},
            hasMore: false,
          ),
        );
      }
    } else {
      final parts = state.breadcrumbSegments.take(index + 1).join('/');
      emit(state.copyWith(path: parts, selectionMode: false, selected: {}, hasMore: false));
    }
    await refresh();
  }

  Future<bool> deleteEntry(FileEntry entry) async {
    if (entry.isDirectory) return false;
    emit(state.copyWith(busy: true, clearError: true));
    try {
      final ok = await _deleteKey(entry.rootId, entry.relativePath);
      emit(state.copyWith(busy: false));
      if (ok) await refresh();
      return ok;
    } catch (e) {
      emit(state.copyWith(busy: false, error: '$e'));
      return false;
    }
  }

  Future<int> deleteSelected() async {
    final keys = state.selected.toList();
    if (keys.isEmpty) return 0;
    emit(state.copyWith(busy: true, clearError: true));
    var n = 0;
    try {
      for (final key in keys) {
        final parts = key.split('|');
        if (parts.length < 2) continue;
        final rootId = parts.first;
        final rel = parts.sublist(1).join('|');
        final ok = await _deleteKey(rootId, rel);
        if (ok) n++;
      }
      emit(state.copyWith(busy: false, selectionMode: false, selected: {}));
      await refresh();
      return n;
    } catch (e) {
      emit(state.copyWith(busy: false, error: '$e'));
      return n;
    }
  }

  Future<bool> _deleteKey(String rootId, String rel) async {
    if (isSelf && rootId == MediaLibraryService.rootId) {
      return serviceLocator.mediaLibraryService().deleteByRelativePath(rel);
    }
    if (isSelf &&
        state.isExternalSurface &&
        rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix)) {
      final vol = _externalBrowser.volumePathFromRootId(rootId) ??
          state.externalVolumePath;
      if (vol == null) return false;
      return _externalBrowser.deleteEntry(volumePath: vol, relativePath: rel);
    }
    return _provider.delete(rootId: rootId, relativePath: rel);
  }

  List<FileEntry> selectedEntries() {
    final map = {
      for (final e in state.entries) '${e.rootId}|${e.relativePath}': e,
    };
    return [
      for (final k in state.selected)
        if (map[k] != null) map[k]!,
    ];
  }

  bool get canUpload => !isSelf && peerId != null && peerId!.isNotEmpty;

  bool get canDownload => !isSelf && peerId != null && peerId!.isNotEmpty;

  bool get canDelete => true;

  Future<bool> downloadEntry(FileEntry entry) async {
    if (!canDownload || entry.isDirectory) return false;
    try {
      await serviceLocator.nasTransferService().enqueueDownload(
        peerFingerprint: peerId!,
        rootId: entry.rootId,
        relativePath: entry.relativePath,
        fileName: entry.name,
        sizeBytes: entry.sizeBytes,
      );
      return true;
    } catch (e) {
      emit(state.copyWith(error: '$e'));
      return false;
    }
  }

  Future<int> downloadSelected() async {
    if (!canDownload) return 0;
    final entries = selectedEntries().where((e) => !e.isDirectory).toList();
    if (entries.isEmpty) return 0;
    emit(state.copyWith(busy: true, clearError: true));
    var n = 0;
    try {
      // 开下前只申请一次公共目录权限，避免并发任务各自 request 撞车。
      await ensureShareStorageReady();
      for (final entry in entries) {
        if (await downloadEntry(entry)) n++;
      }
      emit(state.copyWith(busy: false, selectionMode: false, selected: {}));
      return n;
    } catch (e) {
      emit(state.copyWith(busy: false, error: '$e'));
      return n;
    }
  }

  Future<int> uploadPicked(
    List<({String path, String name, int size})> files,
  ) async {
    if (!canUpload || files.isEmpty) return 0;
    emit(state.copyWith(busy: true));
    var n = 0;
    try {
      final nas = serviceLocator.nasTransferService();
      final onExternal = state.isExternalSurface &&
          state.externalVolumePath != null &&
          state.externalVolumePath!.isNotEmpty;
      for (final f in files) {
        await nas.enqueueUpload(
          peerFingerprint: peerId!,
          localPath: f.path,
          fileName: f.name,
          sizeBytes: f.size,
          rootId: onExternal
              ? _externalBrowser.rootIdFor(state.externalVolumePath!)
              : null,
          directory: onExternal ? state.path : '',
        );
        n++;
      }
      emit(state.copyWith(busy: false));
      return n;
    } catch (e) {
      emit(state.copyWith(busy: false, error: '$e'));
      return n;
    }
  }
}
