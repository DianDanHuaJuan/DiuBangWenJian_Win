/// 统一文件条目（本机 / 远程）。
class FileEntry {
  const FileEntry({
    required this.name,
    required this.relativePath,
    required this.rootId,
    required this.rootDisplayName,
    required this.isDirectory,
    required this.sizeBytes,
    required this.modifiedAtMs,
    this.absolutePath,
    this.contentUri,
    this.mediaKind,
  });

  final String name;
  final String relativePath;
  final String rootId;
  final String rootDisplayName;
  final bool isDirectory;
  final int sizeBytes;
  final int modifiedAtMs;

  /// 仅本机 path 根有值。
  final String? absolutePath;

  /// MediaStore contentUri（library 根）。
  final String? contentUri;

  /// MediaStore / 列表侧媒体类型：`image` | `video` | `audio`；文件树条目可为空。
  final String? mediaKind;

  String get extension {
    final i = name.lastIndexOf('.');
    if (i < 0 || isDirectory) return '';
    return name.substring(i + 1).toLowerCase();
  }

  bool get isImage =>
      !isDirectory &&
      (mediaKind == 'image' ||
          const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'}
              .contains(extension));

  bool get isVideo =>
      !isDirectory &&
      (mediaKind == 'video' ||
          const {'mp4', 'mkv', 'avi', 'mov', 'webm', '3gp'}.contains(extension));

  bool get isAudio =>
      !isDirectory &&
      (mediaKind == 'audio' ||
          const {'mp3', 'm4a', 'aac', 'wav', 'ogg', 'flac', 'amr'}
              .contains(extension));

  String get sizeLabel {
    if (isDirectory) return '';
    final n = sizeBytes;
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

enum FileCategoryFilter { photo, video, document, other }

extension FileCategoryFilterX on FileCategoryFilter {
  String get label => switch (this) {
        FileCategoryFilter.photo => '照片',
        FileCategoryFilter.video => '视频',
        FileCategoryFilter.document => '文档',
        FileCategoryFilter.other => '其他',
      };

  bool get isMediaLibraryCategory =>
      this == FileCategoryFilter.photo || this == FileCategoryFilter.video;

  bool matches(FileEntry e) {
    // 文档 / 其他只认共享目录里的文件，文件夹不占分类格子。
    if (e.isDirectory) return false;
    return switch (this) {
      FileCategoryFilter.photo => e.isImage,
      FileCategoryFilter.video => e.isVideo,
      FileCategoryFilter.document => _documentExtensions.contains(e.extension),
      FileCategoryFilter.other =>
        !e.isImage &&
            !e.isVideo &&
            !_documentExtensions.contains(e.extension),
    };
  }
}

const _documentExtensions = {
  'pdf',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'txt',
  'csv',
};

enum ShareSourceFilter { all, current, history }

extension ShareSourceFilterX on ShareSourceFilter {
  String get label => switch (this) {
        ShareSourceFilter.all => '全部',
        ShareSourceFilter.current => '本机',
        ShareSourceFilter.history => '外置/历史',
      };
}
