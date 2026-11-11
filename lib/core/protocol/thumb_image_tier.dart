/// 缩略图 / 预览图档位（docs/缩略图与预览图缓存方案.md）。
enum ThumbImageTier {
  grid,
  preview;

  static const gridMaxPx = 192;
  static const previewMaxPx = 800;

  /// 查询参数 `type` 取值。
  String get wireName => name;

  int get maxPx => switch (this) {
        ThumbImageTier.grid => gridMaxPx,
        ThumbImageTier.preview => previewMaxPx,
      };

  static ThumbImageTier? tryParse(String? raw) {
    final v = raw?.trim().toLowerCase() ?? '';
    return switch (v) {
      'grid' => ThumbImageTier.grid,
      'preview' => ThumbImageTier.preview,
      _ => null,
    };
  }
}
