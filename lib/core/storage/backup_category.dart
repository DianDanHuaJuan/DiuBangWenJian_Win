/// 共享根下备份四分类（施工方案 §4）。
enum BackupCategory {
  image,
  video,
  document,
  other;

  /// 目录名（中文）。
  String get folderName => switch (this) {
        BackupCategory.image => '图片',
        BackupCategory.video => '视频',
        BackupCategory.document => '文档',
        BackupCategory.other => '其他',
      };

  /// API 传输用 ASCII。
  String get apiName => name;

  static BackupCategory? tryParse(String? raw) {
    final s = raw?.trim().toLowerCase() ?? '';
    return switch (s) {
      'image' || '图片' => BackupCategory.image,
      'video' || '视频' => BackupCategory.video,
      'document' || '文档' => BackupCategory.document,
      'other' || '其他' => BackupCategory.other,
      _ => null,
    };
  }

  /// 按 MIME / 扩展名归类（正式接收与备份共用）。
  ///
  /// 音频无单独目录，归入 [other]。
  static BackupCategory fromMimeOrName({
    String? mimeType,
    required String fileName,
  }) {
    final mime = (mimeType ?? '').toLowerCase();
    if (mime.startsWith('image/')) return BackupCategory.image;
    if (mime.startsWith('video/')) return BackupCategory.video;
    if (mime.startsWith('audio/')) return BackupCategory.other;
    final ext = fileName.contains('.')
        ? fileName.substring(fileName.lastIndexOf('.')).toLowerCase()
        : '';
    const images = {
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.heic',
      '.heif',
      '.bmp',
      '.dng',
    };
    const videos = {
      '.mp4',
      '.mov',
      '.mkv',
      '.webm',
      '.avi',
      '.m4v',
      '.3gp',
    };
    if (images.contains(ext)) return BackupCategory.image;
    if (videos.contains(ext)) return BackupCategory.video;
    const docs = {
      '.pdf',
      '.doc',
      '.docx',
      '.xls',
      '.xlsx',
      '.ppt',
      '.pptx',
      '.txt',
      '.csv',
    };
    if (docs.contains(ext)) return BackupCategory.document;
    return BackupCategory.other;
  }
}
