import 'dart:typed_data';

import '../../../core/file_provider/file_entry.dart';
import '../../../core/file_provider/file_thumbnail_loader.dart';

/// 加载预览级图像（客户端磁盘缓存 → preview 档，非原文件）。
class LoadPreviewUseCase {
  const LoadPreviewUseCase();

  Future<Uint8List?> call({
    required FileEntry entry,
    required bool isSelf,
    String? peerFingerprint,
  }) {
    return PreviewImageLoader.instance.loadPreview(
      entry: entry,
      isSelf: isSelf,
      peerFingerprint: peerFingerprint,
    );
  }

  Future<void> prefetchNeighbors({
    required List<FileEntry> mediaFiles,
    required int centerIndex,
    required bool isSelf,
    String? peerFingerprint,
    int radius = 2,
  }) {
    return PreviewImageLoader.instance.prefetchNeighbors(
      mediaFiles: mediaFiles,
      centerIndex: centerIndex,
      isSelf: isSelf,
      peerFingerprint: peerFingerprint,
      radius: radius,
    );
  }
}
