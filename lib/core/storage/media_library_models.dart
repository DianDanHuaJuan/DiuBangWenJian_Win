import '../file_provider/file_entry.dart';

abstract final class MediaLibraryIds {
  static const rootId = 'library';
  static const rootDisplayName = '系统存储';
}

/// 媒体墙条目（扁平 /library）。
class MediaLibraryAsset {
  const MediaLibraryAsset({
    required this.id,
    required this.contentUri,
    required this.displayName,
    required this.sizeBytes,
    required this.modifiedAtMs,
    required this.mediaKind,
    this.absolutePath,
    this.mimeType = '',
    this.bucketDisplayName = '',
  });

  final String id;
  final String contentUri;
  final String displayName;
  final int sizeBytes;
  final int modifiedAtMs;
  final String mediaKind; // image | video | audio
  final String? absolutePath;
  final String mimeType;
  final String bucketDisplayName;

  bool get isVideo => mediaKind == 'video';
  bool get isImage => mediaKind == 'image';
  bool get isAudio => mediaKind == 'audio';

  /// 对外相对路径：用稳定 id，避免重名覆盖。
  String get relativePath => id;

  factory MediaLibraryAsset.fromMap(Map<String, dynamic> map) {
    final type = (map['mediaType'] as String? ?? '').toLowerCase();
    return MediaLibraryAsset(
      id: map['id']?.toString() ?? '',
      contentUri: map['contentUri'] as String? ?? '',
      displayName: map['displayName'] as String? ?? '',
      sizeBytes: (map['size'] as num?)?.toInt() ?? 0,
      modifiedAtMs: (map['dateModified'] as num?)?.toInt() ?? 0,
      mediaKind: type.isEmpty ? 'image' : type,
      absolutePath: (map['absolutePath'] as String?)?.trim(),
      mimeType: map['mimeType'] as String? ?? '',
      bucketDisplayName: map['bucketDisplayName'] as String? ?? '',
    );
  }

  FileEntry toFileEntry() => FileEntry(
        name: displayName.isEmpty ? id : displayName,
        relativePath: relativePath,
        rootId: MediaLibraryIds.rootId,
        rootDisplayName: MediaLibraryIds.rootDisplayName,
        isDirectory: false,
        sizeBytes: sizeBytes,
        modifiedAtMs: modifiedAtMs,
        absolutePath: absolutePath,
        contentUri: contentUri,
        mediaKind: mediaKind,
      );
}

/// 媒体墙分页结果。
class MediaLibraryPage {
  const MediaLibraryPage({
    required this.items,
    required this.total,
    required this.offset,
    required this.limit,
    required this.hasMore,
  });

  final List<MediaLibraryAsset> items;
  final int total;
  final int offset;
  final int limit;
  final bool hasMore;
}
