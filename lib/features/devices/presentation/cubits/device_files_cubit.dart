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
import '../../../../core/storage/app_paths.dart';
import '../../../../core/storage/external_volume_browser.dart';
import '../../../../core/storage/media_library_service.dart';
import '../../../../core/storage/storage_root.dart';
import '../../../../core/storage/storage_volumes.dart';
import '../../../../core/storage/windows_sensitive_paths.dart';
import '../../../preview/gallery_launcher.dart';
import '../../application/file_browse_facade.dart';

/// 文件页访问方式：媒体墙 / 目录树（定案）。
enum BrowseAccessMode { mediaWall, directoryTree }

/// 目录树锚点：共享根 / 某卷内 / 磁盘列表。
enum DirectoryTreeAnchor { shareRoot, volume, volumePicker }

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
    this.accessMode = BrowseAccessMode.mediaWall,
    this.treeAnchor = DirectoryTreeAnchor.shareRoot,
    this.externalVolumes = const [],
    this.externalVolumePath,
    this.gridMode = true,
    this.selectionMode = false,
    this.selected = const {},
    this.hasMore = false,
    this.total = 0,
    this.error,
    this.busy = false,
    this.blockedDirectoryMessage,
    this.shareAbsolutePath,
  });

  final bool loading;
  final bool loadingMore;
  final List<FileEntry> entries;
  final String rootId;
  final String rootDisplayName;
  final String path;
  final FileCategoryFilter category;
  final ShareSourceFilter source;
  final BrowseAccessMode accessMode;
  final DirectoryTreeAnchor treeAnchor;
  final List<StorageVolumeInfo> externalVolumes;
  final String? externalVolumePath;
  final bool gridMode;
  final bool selectionMode;
  final Set<String> selected;
  final bool hasMore;
  final int total;
  final String? error;
  final bool busy;
  final String? blockedDirectoryMessage;
  /// 当前共享根绝对路径（从共享根顶上退到盘内父目录）。
  final String? shareAbsolutePath;

  bool get isDirectoryTree => accessMode == BrowseAccessMode.directoryTree;

  bool get isMediaWall => accessMode == BrowseAccessMode.mediaWall;

  bool get isVolumePicker =>
      isDirectoryTree && treeAnchor == DirectoryTreeAnchor.volumePicker;

  bool get isOnVolume =>
      isDirectoryTree && treeAnchor == DirectoryTreeAnchor.volume;

  bool get volumesLookWindowsLike =>
      externalVolumes.any((v) => RegExp(r'^[A-Za-z]:').hasMatch(v.path));

  /// 系统返回是否应消费「上一级」。仅磁盘列表为最终闸口。
  bool get canGoUpInTree {
    if (!isDirectoryTree) return path.isNotEmpty;
    if (path.isNotEmpty) return true;
    if (treeAnchor == DirectoryTreeAnchor.volumePicker) return false;
    if (treeAnchor == DirectoryTreeAnchor.volume) return true;
    return shareAbsolutePath != null && shareAbsolutePath!.isNotEmpty;
  }

  List<StorageVolumeInfo> get otgVolumes =>
      externalVolumes.where((v) => !v.isPrimary).toList(growable: false);

  /// 目录树始终展示「根目录|OTG」；Windows 盘符场景 OTG 不可用。
  bool get otgAvailable =>
      isDirectoryTree && !volumesLookWindowsLike && otgVolumes.isNotEmpty;

  List<FileEntry> get mediaEntries => entries
      .where((e) => !e.isDirectory && (e.isImage || e.isVideo))
      .toList(growable: false);

  List<String> get breadcrumbSegments =>
      path.isEmpty ? const [] : path.split('/').where((s) => s.isNotEmpty).toList();

  /// 目录树不过滤分类；媒体墙按分类。
  List<FileEntry> get visibleEntries => isDirectoryTree
      ? entries
      : entries.where(category.matches).toList();

  /// 目录树路径行文案（纯展示，不是切换段）。
  String get directoryTreePathLabel {
    if (treeAnchor == DirectoryTreeAnchor.volumePicker) {
      return '选择磁盘';
    }
    final root = rootDisplayName.isEmpty
        ? (treeAnchor == DirectoryTreeAnchor.shareRoot ? '共享根' : '存储')
        : rootDisplayName;
    if (path.isEmpty) return root;
    return '$root / ${breadcrumbSegments.join(' / ')}';
  }

  DeviceFilesState copyWith({
    bool? loading,
    bool? loadingMore,
    List<FileEntry>? entries,
    String? rootId,
    String? rootDisplayName,
    String? path,
    FileCategoryFilter? category,
    ShareSourceFilter? source,
    BrowseAccessMode? accessMode,
    DirectoryTreeAnchor? treeAnchor,
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
    Object? blockedDirectoryMessage = _sentinel,
    Object? shareAbsolutePath = _sentinel,
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
        accessMode: accessMode ?? this.accessMode,
        treeAnchor: treeAnchor ?? this.treeAnchor,
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
        blockedDirectoryMessage:
            identical(blockedDirectoryMessage, _sentinel)
                ? this.blockedDirectoryMessage
                : blockedDirectoryMessage as String?,
        shareAbsolutePath: identical(shareAbsolutePath, _sentinel)
            ? this.shareAbsolutePath
            : shareAbsolutePath as String?,
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
      AppLogger.logVerbose(
        'openMediaPreview video',
        scope: 'video_diag',
        details: {
          'isSelf': isSelf,
          'peerId': peerId ?? '',
          'name': entry.name,
          'rootId': entry.rootId,
          'path': entry.relativePath,
          'absolutePath': entry.absolutePath ?? '',
          'accessMode': state.accessMode.name,
          'treeAnchor': state.treeAnchor.name,
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
      if (state.isDirectoryTree) {
        await _probeBrowsableVolumes(allowFallback: true);
        await _refreshDirectoryTree();
      } else if (isSelf) {
        try {
          await _probeBrowsableVolumes(allowFallback: false);
        } catch (_) {}
        await _refreshLocal(reset: true);
      } else {
        await _refreshRemote(reset: true);
        try {
          await _probeBrowsableVolumes(allowFallback: false);
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

  Future<void> _probeBrowsableVolumes({required bool allowFallback}) async {
    AppLogger.logVerbose(
      'probeBrowsableVolumes start',
      scope: 'extvol_diag',
      details: {
        'isSelf': isSelf,
        'peerId': peerId ?? '',
        'prevSelected': state.externalVolumePath ?? '',
        'treeAnchor': state.treeAnchor.name,
      },
    );
    final vols = isSelf
        ? await _externalBrowser.listBrowsableVolumes()
        : await _listRemoteBrowsableVolumes();
    AppLogger.logVerbose(
      'probeBrowsableVolumes done',
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
    if (!allowFallback || !state.isDirectoryTree) return;
    final selected = state.externalVolumePath;
    if (selected != null &&
        selected.isNotEmpty &&
        state.treeAnchor == DirectoryTreeAnchor.volume &&
        !vols.any((v) => _externalBrowser.isSameVolumePath(v.path, selected))) {
      AppLogger.log(
        'probeBrowsableVolumes selected missing → shareRoot',
        scope: 'extvol_diag',
        details: {
          'selected': selected,
          'available': [for (final v in vols) v.path],
        },
      );
      emit(
        state.copyWith(
          treeAnchor: DirectoryTreeAnchor.shareRoot,
          externalVolumePath: null,
          path: '',
          rootId: '',
          error: '存储卷已移除，已回到共享根',
        ),
      );
    }
  }

  Future<List<StorageVolumeInfo>> _listRemoteBrowsableVolumes() async {
    final id = peerId;
    if (id == null || id.isEmpty) {
      AppLogger.logVerbose(
        'listRemoteBrowsableVolumes skip empty peerId',
        scope: 'extvol_diag',
      );
      return const [];
    }
    AppLogger.logVerbose(
      'listRemoteBrowsableVolumes GET /storage/volumes',
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
        'listRemoteBrowsableVolumes HTTP fail',
        scope: 'extvol_diag',
        details: {
          'status': response?.statusCode,
          'nullResponse': response == null,
        },
      );
      throw Exception(
        response?.statusCode == 503
            ? '对端未开启 NAS'
            : '无法获取对端存储卷（请确认对端已更新）',
      );
    }
    final data = response.data;
    final map = data is Map
        ? Map<String, dynamic>.from(data)
        : <String, dynamic>{};
    final items = map['items'] as List<dynamic>? ?? const [];
    final raw = items.whereType<Map>().toList(growable: false);
    // 定案：客户端不再过滤 !isPrimary，展示服务端下发的全部可浏览卷。
    final filtered = raw
        .map((e) => StorageVolumeInfo.fromMap(e))
        .where((v) => v.path.isNotEmpty)
        .toList(growable: false);
    AppLogger.logVerbose(
      'listRemoteBrowsableVolumes parsed',
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

  Future<void> setAccessMode(BrowseAccessMode mode) async {
    if (mode == BrowseAccessMode.directoryTree) {
      AppLogger.logVerbose(
        'setAccessMode → directoryTree',
        scope: 'extvol_diag',
        details: {'isSelf': isSelf, 'peerId': peerId ?? ''},
      );
      try {
        await _probeBrowsableVolumes(allowFallback: false);
      } catch (e) {
        AppLogger.log(
          'setAccessMode probe failed',
          scope: 'extvol_diag',
          error: e,
        );
        // 目录树仍进入共享根，即使卷列表失败。
      }
      emit(
        state.copyWith(
          accessMode: BrowseAccessMode.directoryTree,
          treeAnchor: DirectoryTreeAnchor.shareRoot,
          externalVolumePath: null,
          path: '',
          rootId: '',
          rootDisplayName: '',
          selectionMode: false,
          selected: {},
          hasMore: false,
          clearError: true,
          blockedDirectoryMessage: null,
        ),
      );
    } else {
      emit(
        state.copyWith(
          accessMode: BrowseAccessMode.mediaWall,
          treeAnchor: DirectoryTreeAnchor.shareRoot,
          externalVolumePath: null,
          path: '',
          rootId: '',
          category: FileCategoryFilter.photo,
          selectionMode: false,
          selected: {},
          hasMore: false,
          clearError: true,
          blockedDirectoryMessage: null,
        ),
      );
    }
    await refresh();
  }

  /// 「根目录」：Windows = 各磁盘列表；清空卷内路径。
  Future<void> goToVolumeRoot() async {
    if (!state.isDirectoryTree) return;
    AppLogger.logVerbose(
      'goToVolumeRoot → volumePicker',
      scope: 'extvol_diag',
      details: {'isSelf': isSelf, 'vols': state.externalVolumes.length},
    );
    try {
      await _probeBrowsableVolumes(allowFallback: false);
    } catch (e) {
      emit(state.copyWith(error: '$e'));
    }
    emit(
      state.copyWith(
        accessMode: BrowseAccessMode.directoryTree,
        treeAnchor: DirectoryTreeAnchor.volumePicker,
        externalVolumePath: null,
        path: '',
        rootId: '',
        rootDisplayName: '各磁盘',
        selectionMode: false,
        selected: {},
        hasMore: false,
        clearError: true,
        blockedDirectoryMessage: null,
      ),
    );
    await refresh();
  }

  /// 「OTG」：进入对端可移动卷（本机 Windows 通常 otgAvailable=false）。
  Future<void> goToOtg() async {
    if (!state.isDirectoryTree || !state.otgAvailable) return;
    final otg = state.otgVolumes;
    if (otg.isEmpty) {
      emit(state.copyWith(error: '未检测到 OTG / 可移动存储'));
      return;
    }
    if (otg.length == 1) {
      await selectExternalVolume(otg.first);
      return;
    }
    emit(
      state.copyWith(
        accessMode: BrowseAccessMode.directoryTree,
        treeAnchor: DirectoryTreeAnchor.volumePicker,
        externalVolumePath: null,
        path: '',
        rootId: '',
        rootDisplayName: 'OTG',
        selectionMode: false,
        selected: {},
        hasMore: false,
        clearError: true,
        blockedDirectoryMessage: null,
      ),
    );
    await refresh();
  }

  Future<void> selectExternalVolume(StorageVolumeInfo volume) async {
    final volPath = ExternalVolumeBrowser.normalizePath(volume.path);
    final rootId = volume.rootId.isNotEmpty
        ? volume.rootId
        : _externalBrowser.rootIdFor(volPath);
    AppLogger.logVerbose(
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
        accessMode: BrowseAccessMode.directoryTree,
        treeAnchor: DirectoryTreeAnchor.volume,
        externalVolumePath: volPath,
        path: '',
        rootId: rootId,
        rootDisplayName:
            volume.description.isEmpty ? '存储' : volume.description,
        selectionMode: false,
        selected: {},
        hasMore: false,
        clearError: true,
        blockedDirectoryMessage: null,
      ),
    );
    await refresh();
  }

  void clearBlockedDirectoryMessage() {
    if (state.blockedDirectoryMessage == null) return;
    emit(state.copyWith(blockedDirectoryMessage: null));
  }

  Future<void> _refreshDirectoryTree() async {
    switch (state.treeAnchor) {
      case DirectoryTreeAnchor.shareRoot:
        await _refreshDirectoryTreeShareRoot();
      case DirectoryTreeAnchor.volumePicker:
        await _refreshDirectoryTreeVolumePicker();
      case DirectoryTreeAnchor.volume:
        await _refreshDirectoryTreeVolume();
    }
  }

  Future<void> _refreshDirectoryTreeShareRoot() async {
    final List<FileEntry> entries;
    String rootId;
    String label;
    String? shareAbs = state.shareAbsolutePath;
    if (isSelf) {
      final local = _provider as LocalFileProvider;
      final current = await local.ensureCurrent();
      rootId = current.id;
      label = current.displayName.isEmpty ? '共享根' : current.displayName;
      shareAbs = AppPaths.portable(current.uriOrPath);
      entries = await local.list(rootId: rootId, path: state.path);
    } else {
      final remote = _provider as RemotePeerFileProvider;
      rootId = 'fs';
      label = '共享根';
      final page = await remote.listPage(
        rootId: rootId,
        path: state.path,
        limit: 0,
      );
      entries = page.items;
      if (entries.isNotEmpty && entries.first.rootDisplayName.isNotEmpty) {
        label = entries.first.rootDisplayName;
      }
      if (page.rootId.isNotEmpty) rootId = page.rootId;
      if (page.rootAbsolutePath != null &&
          page.rootAbsolutePath!.trim().isNotEmpty) {
        shareAbs = AppPaths.portable(page.rootAbsolutePath!);
      }
    }
    emit(
      state.copyWith(
        loading: false,
        loadingMore: false,
        entries: entries,
        rootId: rootId,
        rootDisplayName: label,
        treeAnchor: DirectoryTreeAnchor.shareRoot,
        externalVolumePath: null,
        shareAbsolutePath: shareAbs,
        hasMore: false,
        total: entries.length,
        clearError: true,
      ),
    );
  }

  Future<void> _refreshDirectoryTreeVolumePicker() async {
    final vols = state.externalVolumes;
    final volumeEntries = [
      for (final v in vols)
        FileEntry(
          name: v.description.isEmpty ? v.path : v.description,
          relativePath: '',
          rootId: v.rootId.isNotEmpty
              ? v.rootId
              : _externalBrowser.rootIdFor(v.path),
          rootDisplayName: '各磁盘',
          isDirectory: true,
          sizeBytes: 0,
          modifiedAtMs: 0,
          absolutePath: v.path,
        ),
    ];
    AppLogger.logVerbose(
      '_refreshDirectoryTree volumePicker',
      scope: 'extvol_diag',
      details: {
        'count': volumeEntries.length,
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
        rootDisplayName: '各磁盘',
        externalVolumePath: null,
        hasMore: false,
        total: volumeEntries.length,
        clearError: true,
      ),
    );
  }

  Future<void> _refreshDirectoryTreeVolume() async {
    final vols = state.externalVolumes;
    var volPath = state.externalVolumePath;
    if (volPath == null || volPath.isEmpty) {
      await _refreshDirectoryTreeVolumePicker();
      return;
    }
    AppLogger.logVerbose(
      '_refreshDirectoryTree volume',
      scope: 'extvol_diag',
      details: {
        'volPath': volPath,
        'statePath': state.path,
        'volsCount': vols.length,
        'isSelf': isSelf,
      },
    );
    if (isSelf && !await _externalBrowser.isVolumeMounted(volPath)) {
      emit(
        state.copyWith(
          loading: false,
          entries: const [],
          treeAnchor: DirectoryTreeAnchor.shareRoot,
          externalVolumePath: null,
          path: '',
          error: '存储卷已移除，已回到共享根',
        ),
      );
      await _refreshDirectoryTreeShareRoot();
      return;
    }

    final resolvedVolPath = volPath;
    final label = vols
        .firstWhere(
          (v) => _externalBrowser.isSameVolumePath(v.path, resolvedVolPath),
          orElse: () => StorageVolumeInfo(
            path: resolvedVolPath,
            description: '存储',
            isPrimary: false,
            isRemovable: false,
            writable: true,
          ),
        )
        .description;

    final List<FileEntry> entries;
    final requestRootId = _externalBrowser.rootIdFor(resolvedVolPath);
    if (isSelf) {
      entries = await _externalBrowser.listDirectory(
        volumePath: resolvedVolPath,
        volumeLabel: label.isEmpty ? '存储' : label,
        relativePath: state.path,
      );
    } else {
      final remote = _provider as RemotePeerFileProvider;
      final page = await remote.listPage(
        rootId: requestRootId,
        path: state.path,
        limit: 0,
      );
      entries = page.items;
    }
    emit(
      state.copyWith(
        loading: false,
        loadingMore: false,
        entries: entries,
        rootId: requestRootId,
        rootDisplayName: label.isEmpty ? '存储' : label,
        externalVolumePath: resolvedVolPath,
        treeAnchor: DirectoryTreeAnchor.volume,
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
    // 目录树允许多选文件夹；媒体墙仍只选文件。
    if (entry.isDirectory && !state.isDirectoryTree) return;
    if (entry.isDirectory &&
        state.treeAnchor == DirectoryTreeAnchor.volumePicker) {
      return;
    }
    final key = '${entry.rootId}|${entry.relativePath}';
    if (state.selected.contains(key)) return;
    emit(state.copyWith(selected: {...state.selected, key}));
  }

  void toggleSelect(FileEntry entry) {
    if (entry.isDirectory && !state.isDirectoryTree) return;
    if (entry.isDirectory &&
        state.treeAnchor == DirectoryTreeAnchor.volumePicker) {
      return;
    }
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

    // 磁盘列表点入某一盘。
    if (state.isDirectoryTree &&
        state.treeAnchor == DirectoryTreeAnchor.volumePicker) {
      final volPath = _externalBrowser.volumePathFromRootId(entry.rootId) ??
          entry.absolutePath;
      if (volPath == null || volPath.isEmpty) return;
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
      await selectExternalVolume(vol);
      return;
    }

    // Windows 敏感目录：本机或对端 Windows 盘列表可显示，禁止进入。
    if (state.isDirectoryTree &&
        (state.volumesLookWindowsLike ||
            defaultTargetPlatform == TargetPlatform.windows) &&
        isWindowsSensitiveDirectory(
          name: entry.name,
          absolutePath: entry.absolutePath,
        )) {
      final msg = '系统保护目录，无法进入：${entry.name}';
      emit(
        state.copyWith(
          blockedDirectoryMessage: msg,
          error: msg,
        ),
      );
      return;
    }

    AppLogger.logVerbose(
      'openEntry → refresh with entry path',
      scope: 'extvol_diag',
      details: {
        'rootId': entry.rootId,
        'path': entry.relativePath,
        'accessMode': state.accessMode.name,
        'treeAnchor': state.treeAnchor.name,
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
        blockedDirectoryMessage: null,
      ),
    );
    await refresh();
  }

  /// 上一级：退 path；共享根顶→盘内父目录；盘根→磁盘列表；仅磁盘列表为闸。
  Future<bool> goUp() async {
    if (state.path.isNotEmpty) {
      final parts = state.breadcrumbSegments;
      final parent = parts.length <= 1
          ? ''
          : parts.sublist(0, parts.length - 1).join('/');
      emit(
        state.copyWith(
          path: parent,
          selectionMode: false,
          selected: {},
          hasMore: false,
        ),
      );
      await refresh();
      return true;
    }

    if (!state.isDirectoryTree) return false;

    if (state.treeAnchor == DirectoryTreeAnchor.volumePicker) {
      return false;
    }

    if (state.treeAnchor == DirectoryTreeAnchor.volume) {
      await goToVolumeRoot();
      return true;
    }

    if (state.treeAnchor == DirectoryTreeAnchor.shareRoot) {
      return _goUpFromShareRootTop();
    }
    return false;
  }

  Future<bool> _goUpFromShareRootTop() async {
    var abs = state.shareAbsolutePath?.trim();
    if ((abs == null || abs.isEmpty) && isSelf) {
      try {
        final local = _provider as LocalFileProvider;
        abs = AppPaths.portable((await local.ensureCurrent()).uriOrPath);
      } catch (_) {}
    }
    if (abs == null || abs.isEmpty) return false;

    if (state.externalVolumes.isEmpty) {
      try {
        await _probeBrowsableVolumes(allowFallback: false);
      } catch (_) {}
    }

    final sharePortable = AppPaths.portable(abs);
    StorageVolumeInfo? best;
    var bestLen = -1;
    for (final v in state.externalVolumes) {
      final vp = AppPaths.portable(v.path);
      if (vp.isEmpty) continue;
      final shareLower = sharePortable.toLowerCase();
      final volLower = vp.toLowerCase();
      final under = shareLower == volLower ||
          shareLower.startsWith(volLower.endsWith('/') ? volLower : '$volLower/');
      if (!under) continue;
      if (vp.length > bestLen) {
        best = v;
        bestLen = vp.length;
      }
    }
    if (best == null) {
      await goToVolumeRoot();
      return true;
    }

    final volPath = AppPaths.portable(best.path);
    final shareLower = sharePortable.toLowerCase();
    final volLower = volPath.toLowerCase();
    if (shareLower == volLower) {
      await goToVolumeRoot();
      return true;
    }
    var rel = sharePortable;
    if (shareLower.startsWith(volLower.endsWith('/') ? volLower : '$volLower/')) {
      rel = sharePortable.substring(
        volPath.endsWith('/') ? volPath.length : volPath.length + 1,
      );
    }
    final segs = AppPaths.portable(rel)
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    final parentRel =
        segs.length <= 1 ? '' : segs.sublist(0, segs.length - 1).join('/');

    final rootId = best.rootId.isNotEmpty
        ? best.rootId
        : _externalBrowser.rootIdFor(volPath);
    emit(
      state.copyWith(
        accessMode: BrowseAccessMode.directoryTree,
        treeAnchor: DirectoryTreeAnchor.volume,
        externalVolumePath: volPath,
        path: parentRel,
        rootId: rootId,
        rootDisplayName:
            best.description.isEmpty ? '存储' : best.description,
        selectionMode: false,
        selected: {},
        hasMore: false,
        clearError: true,
        blockedDirectoryMessage: null,
      ),
    );
    await refresh();
    return true;
  }

  Future<void> goBreadcrumb(int index) async {
    if (index < 0) {
      if (state.isDirectoryTree &&
          state.treeAnchor == DirectoryTreeAnchor.volume) {
        await goToVolumeRoot();
        return;
      }
      emit(
        state.copyWith(
          path: '',
          selectionMode: false,
          selected: {},
          hasMore: false,
        ),
      );
    } else {
      final parts = state.breadcrumbSegments.take(index + 1).join('/');
      emit(
        state.copyWith(
          path: parts,
          selectionMode: false,
          selected: {},
          hasMore: false,
        ),
      );
    }
    await refresh();
  }

  Future<bool> deleteEntry(FileEntry entry) async {
    // 目录树可删文件夹；媒体墙仍拒目录。
    if (entry.isDirectory && !state.isDirectoryTree) return false;
    if (entry.isDirectory &&
        state.treeAnchor == DirectoryTreeAnchor.volumePicker) {
      return false;
    }
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

  /// 目录树当前 cwd 下新建文件夹。
  Future<bool> createFolder(String name) async {
    if (!state.isDirectoryTree) return false;
    if (state.treeAnchor == DirectoryTreeAnchor.volumePicker) return false;
    final folderName = name.trim();
    if (folderName.isEmpty) return false;
    emit(state.copyWith(busy: true, clearError: true));
    try {
      final rootId = state.rootId.isNotEmpty
          ? state.rootId
          : (state.isOnVolume && state.externalVolumePath != null
              ? _externalBrowser.rootIdFor(state.externalVolumePath!)
              : 'fs');
      if (isSelf &&
          state.isOnVolume &&
          rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix)) {
        final vol = _externalBrowser.volumePathFromRootId(rootId) ??
            state.externalVolumePath;
        if (vol == null) {
          emit(state.copyWith(busy: false, error: '卷不可用'));
          return false;
        }
        final result = await _externalBrowser.createDirectory(
          volumePath: vol,
          parentRelativePath: state.path,
          name: folderName,
        );
        emit(state.copyWith(busy: false));
        if (!result.ok) {
          emit(state.copyWith(
            error: result.error == 'exists' ? '同名已存在' : (result.error ?? '创建失败'),
          ));
          return false;
        }
        await refresh();
        return true;
      }
      final created = await _provider.mkdir(
        rootId: rootId,
        path: state.path,
        name: folderName,
      );
      emit(state.copyWith(busy: false));
      if (created == null) {
        emit(state.copyWith(error: '创建失败'));
        return false;
      }
      await refresh();
      return true;
    } on StateError catch (e) {
      emit(state.copyWith(
        busy: false,
        error: e.message == 'exists' ? '同名已存在' : '$e',
      ));
      return false;
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
        state.isOnVolume &&
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
      final onVolume = state.isOnVolume &&
          state.externalVolumePath != null &&
          state.externalVolumePath!.isNotEmpty;
      final onShareTree = state.isDirectoryTree &&
          state.treeAnchor == DirectoryTreeAnchor.shareRoot;
      for (final f in files) {
        await nas.enqueueUpload(
          peerFingerprint: peerId!,
          localPath: f.path,
          fileName: f.name,
          sizeBytes: f.size,
          rootId: onVolume
              ? _externalBrowser.rootIdFor(state.externalVolumePath!)
              : (onShareTree ? 'fs' : null),
          directory: (onVolume || onShareTree) ? state.path : '',
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
