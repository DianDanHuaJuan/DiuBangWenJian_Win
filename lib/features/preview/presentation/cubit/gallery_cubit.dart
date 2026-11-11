import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/file_provider/file_entry.dart';
import '../../../../core/storage/external_volume_browser.dart';
import '../../application/load_preview_use_case.dart';

class GalleryState {
  const GalleryState({
    required this.currentIndex,
    this.isVideoFullscreen = false,
  });

  final int currentIndex;
  final bool isVideoFullscreen;

  GalleryState copyWith({
    int? currentIndex,
    bool? isVideoFullscreen,
  }) =>
      GalleryState(
        currentIndex: currentIndex ?? this.currentIndex,
        isVideoFullscreen: isVideoFullscreen ?? this.isVideoFullscreen,
      );
}

/// 画廊页级状态：当前页索引、视频全屏、邻页预取。
class GalleryCubit extends Cubit<GalleryState> {
  GalleryCubit({
    required this.mediaFiles,
    required int initialIndex,
    required this.isSelf,
    this.peerFingerprint,
    LoadPreviewUseCase loadPreview = const LoadPreviewUseCase(),
  })  : _loadPreview = loadPreview,
        super(
          GalleryState(
            currentIndex: mediaFiles.isEmpty
                ? 0
                : initialIndex.clamp(0, mediaFiles.length - 1),
          ),
        );

  final List<FileEntry> mediaFiles;
  final bool isSelf;
  final String? peerFingerprint;
  final LoadPreviewUseCase _loadPreview;

  void setIndex(int index) {
    if (mediaFiles.isEmpty) return;
    final next = index.clamp(0, mediaFiles.length - 1);
    if (next == state.currentIndex) return;
    emit(state.copyWith(currentIndex: next));
    prefetchAround(next);
  }

  void setVideoFullscreen(bool value) {
    if (state.isVideoFullscreen == value) return;
    emit(state.copyWith(isVideoFullscreen: value));
  }

  void prefetchAround(int index) {
    if (mediaFiles.isEmpty) return;
    final center = index.clamp(0, mediaFiles.length - 1);
    // 外置卷走原图策略，不预取 preview（避免无效 /thumbnail）。
    if (mediaFiles[center]
        .rootId
        .startsWith(ExternalVolumeBrowser.rootIdPrefix)) {
      return;
    }
    final forPrefetch = [
      for (final e in mediaFiles)
        if (!e.rootId.startsWith(ExternalVolumeBrowser.rootIdPrefix)) e,
    ];
    if (forPrefetch.isEmpty) return;
    final current = mediaFiles[center];
    final mappedCenter = forPrefetch.indexWhere(
      (e) =>
          e.rootId == current.rootId &&
          e.relativePath == current.relativePath,
    );
    if (mappedCenter < 0) return;
    _loadPreview.prefetchNeighbors(
      mediaFiles: forPrefetch,
      centerIndex: mappedCenter,
      isSelf: isSelf,
      peerFingerprint: peerFingerprint,
      radius: 2,
    );
  }
}
