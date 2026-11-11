/// Gallery 单项：查看原图（缓存）与「下载原图」（共享根四分类）状态。
class GalleryOriginalDownloadState {
  static const Object _sentinel = Object();

  static const GalleryOriginalDownloadState idle =
      GalleryOriginalDownloadState();

  final String? localPath;
  final String? publicUri;
  final double progress;
  final bool isDownloading;
  final bool isSaving;
  final String? errorMessage;

  const GalleryOriginalDownloadState({
    this.localPath,
    this.publicUri,
    this.progress = 0,
    this.isDownloading = false,
    this.isSaving = false,
    this.errorMessage,
  });

  bool get hasLocalPath => localPath != null && localPath!.trim().isNotEmpty;

  bool get hasPublicUri => publicUri != null && publicUri!.trim().isNotEmpty;

  bool get isOriginalReady =>
      hasLocalPath && !isDownloading && !isSaving && !hasFailure;

  bool get isCached => isOriginalReady;

  bool get isSaved => hasPublicUri;

  bool get hasFailure =>
      errorMessage != null && errorMessage!.trim().isNotEmpty;

  GalleryOriginalDownloadState copyWith({
    Object? localPath = _sentinel,
    Object? publicUri = _sentinel,
    double? progress,
    bool? isDownloading,
    bool? isSaving,
    Object? errorMessage = _sentinel,
  }) {
    return GalleryOriginalDownloadState(
      localPath: identical(localPath, _sentinel)
          ? this.localPath
          : localPath as String?,
      publicUri: identical(publicUri, _sentinel)
          ? this.publicUri
          : publicUri as String?,
      progress: progress ?? this.progress,
      isDownloading: isDownloading ?? this.isDownloading,
      isSaving: isSaving ?? this.isSaving,
      errorMessage: identical(errorMessage, _sentinel)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }
}
