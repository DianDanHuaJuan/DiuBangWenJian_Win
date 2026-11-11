import 'backup_category.dart';

/// 正式接收/下载的唯一落点子目录：共享根下四分类。
///
/// 默认根：`Download/diubangfiles/{图片|视频|文档|其他}/`
/// 预览/查看原图/聊天气泡缩略图仍走应用缓存，不经本类。
abstract final class ShareReceivePaths {
  /// 按 MIME / 文件名归入四分类。
  static BackupCategory categoryFor({
    String? mimeType,
    required String fileName,
  }) =>
      BackupCategory.fromMimeOrName(mimeType: mimeType, fileName: fileName);

  /// [ShareWriter.relativeDir]：`图片` / `视频` / `文档` / `其他`。
  static String relativeDirFor({
    String? mimeType,
    required String fileName,
  }) =>
      categoryFor(mimeType: mimeType, fileName: fileName).folderName;
}
