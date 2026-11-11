import 'package:flutter/foundation.dart';

import '../../../core/file_provider/file_entry.dart';

/// 文件浏览对外编排面（doc/01 §七 期 C）。
///
/// Page 只渲染；视口缩略图、预览打开、传输入队经 Cubit 实现本契约，
/// 禁止 Page 直调 [FileThumbnailLoader] / MediaStore / PeerApi。
abstract class FileBrowseFacade {
  /// 网格缩略图缓存变更通知（仅 clear 等整表场景；格子刷新用 [watchThumb]）。
  Listenable get thumbCacheListenable;

  /// 视口可见区间请求缩略图（对齐 L0 队列）。
  ///
  /// [allowPreload] 滚动中应为 false；[scrollBias]：-1 向上 / 0 idle / 1 向下。
  void requestVisibleThumbs({
    required List<FileEntry> entries,
    required int firstIndex,
    required int lastIndex,
    bool allowPreload = true,
    int scrollBias = 0,
  });

  /// 单格缩略图到位流（驱动该格重绘，禁止整表 setState）。
  Stream<void> watchThumb(FileEntry entry);

  /// 只读 LRU，禁止 per-tile 拉网；不调整 LRU 顺序。
  Uint8List? peekThumb(FileEntry entry);

  /// 仅 seed 当前格已缓存缩略图，禁止整库预拉。
  Map<String, Uint8List> seedThumbnailsFor(FileEntry entry);
}
