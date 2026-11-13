import 'dart:async';
import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/common/app_logger.dart';
import '../../../../core/file_provider/file_entry.dart';
import '../../../../core/protocol/nas_api_paths.dart';
import '../../../../core/storage/external_volume_browser.dart';
import '../../../../core/storage/media_library_service.dart';
import '../../application/load_preview_use_case.dart';
import '../../application/view_original_use_case.dart';
import '../cubit/gallery_cubit.dart';
import '../cubit/gallery_original_download_state.dart';
import '../widgets/nas_video_session.dart';

/// 全屏媒体画廊（对齐原 DiuBangNASClient：预览 / 查看原图 / 下载原图 / 视频在线播）。
///
/// 对外请用 [openGalleryPreview]（`gallery_launcher.dart`），勿从其它 feature 直接依赖本页细节。
class GalleryPage extends StatelessWidget {
  const GalleryPage({
    super.key,
    required this.mediaFiles,
    required this.initialIndex,
    required this.isSelf,
    this.peerFingerprint,
    this.thumbnails = const {},
  });

  final List<FileEntry> mediaFiles;
  final int initialIndex;
  final bool isSelf;
  final String? peerFingerprint;
  final Map<String, Uint8List> thumbnails;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) {
        final cubit = GalleryCubit(
          mediaFiles: mediaFiles,
          initialIndex: initialIndex,
          isSelf: isSelf,
          peerFingerprint: peerFingerprint,
        );
        cubit.prefetchAround(cubit.state.currentIndex);
        return cubit;
      },
      child: _GalleryScaffold(thumbnails: thumbnails),
    );
  }
}

class _GalleryScaffold extends StatefulWidget {
  const _GalleryScaffold({required this.thumbnails});

  final Map<String, Uint8List> thumbnails;

  @override
  State<_GalleryScaffold> createState() => _GalleryScaffoldState();
}

class _GalleryScaffoldState extends State<_GalleryScaffold> {
  static const _overlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.black,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.black,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Colors.black,
  );

  late final ExtendedPageController _pageController;
  bool _updatingFs = false;

  @override
  void initState() {
    super.initState();
    final index = context.read<GalleryCubit>().state.currentIndex;
    _pageController = ExtendedPageController(initialPage: index);
    // 保持 edgeToEdge，仅着色系统栏；勿切 immersive（退出会抬壳底栏）。
    MediaKit.ensureInitialized();
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSize = 40;
    cache.maximumSizeBytes = 80 << 20;
  }

  @override
  void dispose() {
    clearGestureDetailsCache();
    _pageController.dispose();
    PaintingBinding.instance.imageCache.clear();
    unawaited(
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]),
    );
    super.dispose();
  }

  void _close() {
    final cubit = context.read<GalleryCubit>();
    if (cubit.state.isVideoFullscreen) {
      unawaited(_setVideoFullscreen(false));
      return;
    }
    Navigator.of(context, rootNavigator: true).maybePop();
  }

  Future<void> _setVideoFullscreen(bool value) async {
    final cubit = context.read<GalleryCubit>();
    if (_updatingFs || cubit.state.isVideoFullscreen == value) return;
    _updatingFs = true;
    cubit.setVideoFullscreen(value);
    try {
      if (value) {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        await SystemChrome.setPreferredOrientations(const []);
      }
    } finally {
      _updatingFs = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<GalleryCubit>();
    final files = cubit.mediaFiles;
    if (files.isEmpty) {
      return const AnnotatedRegion<SystemUiOverlayStyle>(
        value: _overlayStyle,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Text('无可预览媒体', style: TextStyle(color: Colors.white70)),
          ),
        ),
      );
    }

    final currentIndex = cubit.state.currentIndex;
    final isVideoFullscreen = cubit.state.isVideoFullscreen;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _overlayStyle,
      child: PopScope(
        canPop: !isVideoFullscreen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && isVideoFullscreen) {
            unawaited(_setVideoFullscreen(false));
          }
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ExtendedImageSlidePage(
                  slidePageBackgroundHandler: (offset, pageSize) =>
                      defaultSlidePageBackgroundHandler(
                        offset: offset,
                        pageSize: pageSize,
                        color: Colors.black,
                        pageGestureAxis: SlideAxis.both,
                      ),
                  child: ExtendedImageGesturePageView.builder(
                    controller: _pageController,
                    itemCount: files.length,
                    onPageChanged: cubit.setIndex,
                    itemBuilder: (context, index) {
                      final file = files[index];
                      final thumb = widget.thumbnails[file.relativePath] ??
                          widget.thumbnails[
                              '${file.rootId}|${file.relativePath}'];
                      return ColoredBox(
                        color: Colors.black,
                        child: _GalleryMediaPage(
                          key: ValueKey(
                            '${file.rootId}|${file.relativePath}',
                          ),
                          entry: file,
                          isActive: index == currentIndex,
                          isSelf: cubit.isSelf,
                          peerFingerprint: cubit.peerFingerprint,
                          thumbnail: thumb,
                          isVideoFullscreen:
                              isVideoFullscreen && index == currentIndex,
                          onFullscreenChanged: _setVideoFullscreen,
                        ),
                      );
                    },
                  ),
                ),
                if (!isVideoFullscreen)
                  Positioned(
                    top: MediaQuery.paddingOf(context).top + 8,
                    right: 8,
                    child: IconButton(
                      onPressed: _close,
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GalleryMediaPage extends StatefulWidget {
  const _GalleryMediaPage({
    super.key,
    required this.entry,
    required this.isActive,
    required this.isSelf,
    required this.peerFingerprint,
    required this.thumbnail,
    required this.isVideoFullscreen,
    required this.onFullscreenChanged,
  });

  final FileEntry entry;
  final bool isActive;
  final bool isSelf;
  final String? peerFingerprint;
  final Uint8List? thumbnail;
  final bool isVideoFullscreen;
  final Future<void> Function(bool) onFullscreenChanged;

  @override
  State<_GalleryMediaPage> createState() => _GalleryMediaPageState();
}

class _GalleryMediaPageState extends State<_GalleryMediaPage> {
  Uint8List? _previewBytes;
  String? _previewPath;
  var _previewFailed = false;
  bool _loading = true;
  String? _error;
  final NasVideoSession _video = NasVideoSession();
  GalleryOriginalDownloadState _original =
      GalleryOriginalDownloadState.idle;
  bool _originalFrameReady = false;
  static const _loadPreview = LoadPreviewUseCase();
  static const _viewOriginalUc = ViewOriginalUseCase();
  final _saveOriginalUc = SaveOriginalUseCase();

  @override
  void initState() {
    super.initState();
    // 仅激活页解析；邻页靠 Gallery ±2 磁盘预取，禁止 KeepAlive 全量常驻。
    if (widget.isActive || widget.entry.isImage) {
      unawaited(_resolve());
    } else {
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(covariant _GalleryMediaPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive && widget.entry.isVideo) {
      if (widget.isActive) {
        unawaited(_ensureVideo());
      } else {
        unawaited(_disposeVideo());
      }
    }
  }

  @override
  void dispose() {
    unawaited(_disposeVideo());
    _video.disposeNotifiers();
    super.dispose();
  }

  Future<void> _resolve() async {
    try {
      if (widget.entry.isImage) {
        await _resolveImagePreview();
      } else if (widget.entry.isVideo) {
        if (widget.isActive) {
          await _ensureVideo();
        } else {
          if (mounted) setState(() => _loading = false);
        }
      } else {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = '不支持的类型';
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 预览层：磁盘缓存 → 大缩略图；本机有路径时可直开文件。
  ///
  /// 外置卷（`extvol:`）单独策略：跳过 preview 档，直接打开/下载原图；
  /// 内部相册与共享根仍走原 preview →「查看原图」路径。
  Future<void> _resolveImagePreview() async {
    if (widget.isSelf) {
      final path = widget.entry.absolutePath;
      if (path != null && path.isNotEmpty && await File(path).exists()) {
        if (!mounted) return;
        setState(() {
          _previewPath = path;
          _original = GalleryOriginalDownloadState(localPath: path);
          _loading = false;
        });
        return;
      }
    }

    final isExternalVolume =
        widget.entry.rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix);
    if (isExternalVolume) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _previewFailed = false;
      });
      await _viewOriginal();
      if (!mounted) return;
      if (!_original.isOriginalReady) {
        setState(() {
          _error = _original.errorMessage ?? '无法加载原图';
        });
      }
      return;
    }

    final preview = await _loadPreview(
      entry: widget.entry,
      isSelf: widget.isSelf,
      peerFingerprint: widget.peerFingerprint,
    );
    if (!mounted) return;
    if (preview != null && preview.isNotEmpty) {
      setState(() {
        _previewBytes = preview;
        _previewFailed = false;
        _loading = false;
      });
      return;
    }

    if (widget.isSelf) {
      if (widget.entry.rootId == MediaLibraryService.rootId ||
          (widget.entry.contentUri != null &&
              widget.entry.contentUri!.isNotEmpty)) {
        final lib = serviceLocator.mediaLibraryService();
        final asset =
            await lib.findByRelativePath(widget.entry.relativePath);
        if (asset != null &&
            asset.absolutePath != null &&
            asset.absolutePath!.isNotEmpty &&
            await File(asset.absolutePath!).exists()) {
          if (!mounted) return;
          setState(() {
            _previewPath = asset.absolutePath;
            _original =
                GalleryOriginalDownloadState(localPath: asset.absolutePath);
            _loading = false;
          });
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '图片不可用';
      });
      return;
    }

    // 远端内部存储：preview 失败不升级为原图；保留 grid 占位与「查看原图」。
    if (!mounted) return;
    setState(() {
      _loading = false;
      _previewFailed = true;
    });
  }

  Future<void> _viewOriginal() async {
    if (_original.isDownloading || _original.isSaving) return;
    if (_original.isOriginalReady) {
      await _saveOriginal();
      return;
    }
    setState(() {
      _original = const GalleryOriginalDownloadState(
        isDownloading: true,
        progress: 0,
      );
    });
    try {
      final next = await _viewOriginalUc(
        entry: widget.entry,
        isSelf: widget.isSelf,
        peerFingerprint: widget.peerFingerprint,
        knownLocalPath: _previewPath,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _original = _original.copyWith(
              isDownloading: true,
              progress: p,
            );
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _original = next;
        _originalFrameReady = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _original = GalleryOriginalDownloadState(errorMessage: '$e');
      });
    }
  }

  Future<void> _saveOriginal() async {
    if (!_original.hasLocalPath || _original.isSaving) return;
    setState(() {
      _original = _original.copyWith(isSaving: true, errorMessage: null);
    });
    final next = await _saveOriginalUc(
      current: _original,
      displayName: widget.entry.name,
    );
    if (!mounted) return;
    setState(() => _original = next);
  }

  Future<void> _ensureVideo() async {
    if (_video.isReady) {
      AppLogger.log(
        '_ensureVideo already ready → play',
        scope: 'video_diag',
        details: {
          'name': widget.entry.name,
          'rootId': widget.entry.rootId,
          'isActive': widget.isActive,
        },
      );
      if (widget.isActive) await _video.play();
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    AppLogger.log(
      '_ensureVideo start',
      scope: 'video_diag',
      details: {
        'isSelf': widget.isSelf,
        'peer': widget.peerFingerprint == null
            ? ''
            : (widget.peerFingerprint!.length > 12
                ? '${widget.peerFingerprint!.substring(0, 12)}…'
                : widget.peerFingerprint!),
        'name': widget.entry.name,
        'rootId': widget.entry.rootId,
        'path': widget.entry.relativePath,
        'absolutePath': widget.entry.absolutePath ?? '',
        'isActive': widget.isActive,
        'isExtvol': widget.entry.rootId
            .startsWith(ExternalVolumeBrowser.rootIdPrefix),
      },
    );

    try {
      if (widget.isSelf) {
        String? path = widget.entry.absolutePath;
        if ((path == null || path.isEmpty) &&
            widget.entry.rootId == MediaLibraryService.rootId) {
          final asset = await serviceLocator
              .mediaLibraryService()
              .findByRelativePath(widget.entry.relativePath);
          if (asset != null) {
            final dir = await getTemporaryDirectory();
            final file = await serviceLocator
                .mediaLibraryService()
                .materializeTemp(asset, dir);
            path = file?.path;
          }
        }
        if (path == null || path.isEmpty) {
          throw Exception('本地视频不可用');
        }
        AppLogger.log(
          '_ensureVideo openLocal',
          scope: 'video_diag',
          details: {'path': path},
        );
        await _video.openLocal(path, play: widget.isActive);
      } else {
        final fp = widget.peerFingerprint;
        if (fp == null) throw Exception('缺少对端');
        final target =
            await serviceLocator.peerApiClient().authenticatedGetTarget(
                  fp,
                  NasApiPaths.filesContent,
                  query: {
                    'rootId': widget.entry.rootId,
                    'path': widget.entry.relativePath,
                  },
                );
        if (target == null) {
          AppLogger.log(
            '_ensureVideo authenticatedGetTarget null',
            scope: 'video_diag',
            details: {
              'rootId': widget.entry.rootId,
              'path': widget.entry.relativePath,
            },
          );
          throw Exception('无法解析播放地址');
        }
        AppLogger.log(
          '_ensureVideo openRemote',
          scope: 'video_diag',
          details: {
            'url': target.url,
            'headerKeys': target.headers.keys.toList(growable: false),
            'hasAuthorization': target.headers.keys.any(
              (k) => k.toLowerCase() == 'authorization',
            ),
            'hasPeerFingerprint': target.headers.keys.any(
              (k) => k.toLowerCase() == 'x-peer-fingerprint',
            ),
          },
        );
        await _video.openRemote(
          url: target.url,
          headers: target.headers,
          play: widget.isActive,
        );
      }

      if (!mounted) {
        await _video.dispose();
        return;
      }
      AppLogger.log(
        '_ensureVideo ok',
        scope: 'video_diag',
        details: {
          'name': widget.entry.name,
          'rootId': widget.entry.rootId,
        },
      );
      setState(() {
        _loading = false;
      });
    } catch (e, st) {
      AppLogger.log(
        '_ensureVideo failed',
        scope: 'video_diag',
        error: e,
        stackTrace: st,
        details: {
          'name': widget.entry.name,
          'rootId': widget.entry.rootId,
          'path': widget.entry.relativePath,
        },
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _disposeVideo() async {
    await _video.dispose();
  }


  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: Colors.white70)),
      );
    }

    final bottomSafe = MediaQuery.paddingOf(context).bottom;

    if (widget.entry.isVideo) {
      final controller = _video.controller;
      final theme = _video.buildControlsTheme(
        trailing: [
          IconButton(
            onPressed: () =>
                widget.onFullscreenChanged(!widget.isVideoFullscreen),
            color: Colors.white,
            icon: Icon(
              widget.isVideoFullscreen
                  ? Icons.fullscreen_exit
                  : Icons.fullscreen,
            ),
          ),
        ],
      );
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (controller != null)
              MaterialVideoControlsTheme(
                normal: theme,
                fullscreen: theme,
                child: Video(
                  controller: controller,
                  controls: MaterialVideoControls,
                  fill: Colors.black,
                ),
              )
            else
              _buildPlaceholder(showSpinner: _loading),
            // 本机文件已在设备上，无需「下载原视频」。
            if (!widget.isSelf)
              Positioned(
                bottom: 48 + bottomSafe,
                right: 16,
                child: _VideoDownloadButton(
                  state: _original,
                  onTap: () {
                    if (_original.isOriginalReady) {
                      unawaited(_saveOriginal());
                    } else {
                      unawaited(_viewOriginal());
                    }
                  },
                ),
              ),
          ],
        ),
      );
    }

    final originalFile = _original.localPath != null
        ? File(_original.localPath!)
        : null;
    final showOriginal = _original.isOriginalReady &&
        originalFile != null &&
        originalFile.existsSync() &&
        originalFile.lengthSync() > 0;

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildImagePreviewLayer(),
          if (showOriginal)
            IgnorePointer(
              ignoring: !_originalFrameReady,
              child: AnimatedOpacity(
                opacity: _originalFrameReady ? 1 : 0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                child: ExtendedImage.file(
                  originalFile,
                  fit: BoxFit.contain,
                  enableLoadState: true,
                  mode: ExtendedImageMode.gesture,
                  initGestureConfigHandler: (_) => GestureConfig(
                    minScale: 1,
                    maxScale: 4,
                    animationMinScale: 0.8,
                    animationMaxScale: 4.5,
                    inPageView: true,
                  ),
                  loadStateChanged: (state) {
                    if (state.extendedImageLoadState == LoadState.completed &&
                        !_originalFrameReady) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          setState(() => _originalFrameReady = true);
                        }
                      });
                    }
                    return null;
                  },
                ),
              ),
            )
          else if (_previewPath == null &&
              _previewBytes == null &&
              widget.thumbnail == null)
            _buildPlaceholder(showSpinner: _loading),
          if (_previewFailed && !showOriginal)
            Positioned(
              bottom: 88 + bottomSafe,
              left: 16,
              right: 16,
              child: const Text(
                '预览加载失败',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          // 本机文件已在设备上，无需「查看/下载原图」。
          if (!widget.isSelf)
            Positioned(
              bottom: 32 + bottomSafe,
              left: 0,
              right: 0,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: _OriginalActionButton(
                  fileSize: widget.entry.sizeBytes,
                  state: _original,
                  onTapViewOriginal: () => unawaited(_viewOriginal()),
                  onTapSaveOriginal: () => unawaited(_saveOriginal()),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildImagePreviewLayer() {
    if (_previewPath != null) {
      return ExtendedImage.file(
        File(_previewPath!),
        fit: BoxFit.contain,
        mode: ExtendedImageMode.gesture,
        initGestureConfigHandler: (_) => GestureConfig(
          minScale: 1,
          maxScale: 4,
          animationMinScale: 0.8,
          animationMaxScale: 4.5,
          inPageView: true,
        ),
      );
    }
    if (_previewBytes != null) {
      return ExtendedImage.memory(
        _previewBytes!,
        fit: BoxFit.contain,
        mode: ExtendedImageMode.gesture,
        initGestureConfigHandler: (_) => GestureConfig(
          minScale: 1,
          maxScale: 4,
          animationMinScale: 0.8,
          animationMaxScale: 4.5,
          inPageView: true,
        ),
      );
    }
    if (widget.thumbnail != null) {
      return Image.memory(widget.thumbnail!, fit: BoxFit.contain);
    }
    return const SizedBox.shrink();
  }

  Widget _buildPlaceholder({required bool showSpinner}) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.thumbnail != null)
            Image.memory(widget.thumbnail!, fit: BoxFit.contain),
          if (showSpinner)
            const Center(
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 3,
              ),
            )
          else if (widget.thumbnail == null)
            const Center(
              child: Icon(Icons.play_circle_outline,
                  color: Colors.white54, size: 64),
            ),
        ],
      ),
    );
  }
}

class _OriginalActionButton extends StatelessWidget {
  const _OriginalActionButton({
    required this.fileSize,
    required this.state,
    required this.onTapViewOriginal,
    required this.onTapSaveOriginal,
  });

  final int fileSize;
  final GalleryOriginalDownloadState state;
  final VoidCallback onTapViewOriginal;
  final VoidCallback onTapSaveOriginal;

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    if (state.isSaved) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(24),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 18),
            SizedBox(width: 8),
            Text('已下载', style: TextStyle(color: Colors.green, fontSize: 14)),
          ],
        ),
      );
    }

    if (state.isOriginalReady) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: state.isSaving ? null : onTapSaveOriginal,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state.isSaving)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                else
                  const Icon(Icons.download_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(
                  state.isSaving ? '保存中...' : '下载原图',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final size = _formatSize(fileSize);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: state.isDownloading || state.isSaving ? null : onTapViewOriginal,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Stack(
            children: [
              if (state.isDownloading)
                Positioned.fill(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: state.progress.clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state.isDownloading)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  else
                    Icon(
                      state.hasFailure
                          ? Icons.refresh_rounded
                          : Icons.visibility_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                  const SizedBox(width: 8),
                  Text(
                    state.isDownloading
                        ? '下载中 ${(state.progress * 100).toStringAsFixed(0)}%'
                        : state.hasFailure
                            ? '重新查看原图'
                            : (size.isEmpty ? '查看原图' : '查看原图 ($size)'),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoDownloadButton extends StatelessWidget {
  const _VideoDownloadButton({
    required this.state,
    required this.onTap,
  });

  final GalleryOriginalDownloadState state;
  final VoidCallback onTap;

  bool get _canTap =>
      !state.isDownloading && !state.isSaving && !state.isSaved;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _canTap ? onTap : null,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (state.isDownloading)
                SizedBox(
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(
                    value: state.progress > 0 ? state.progress : null,
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                ),
              Icon(
                state.isSaved
                    ? Icons.check_rounded
                    : state.hasFailure
                        ? Icons.refresh_rounded
                        : Icons.download_rounded,
                color: state.isSaved ? Colors.greenAccent : Colors.white,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
