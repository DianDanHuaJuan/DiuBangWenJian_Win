/// 预览页入参（go_router extra）。
class PreviewArgs {
  const PreviewArgs({
    required this.title,
    this.localPath,
    this.bytes,
    this.peerFingerprint,
    this.rootId,
    this.relativePath,
  });

  final String title;

  /// 本机绝对路径（本机预览 / 已缓存文件）。
  final String? localPath;

  /// 已加载的图片字节（远程小图可直接传）。
  final List<int>? bytes;

  /// 远程视频：按需下载到临时文件时使用。
  final String? peerFingerprint;
  final String? rootId;
  final String? relativePath;

  bool get hasLocalFile => localPath != null && localPath!.isNotEmpty;
  bool get hasBytes => bytes != null && bytes!.isNotEmpty;
  bool get canFetchRemote =>
      peerFingerprint != null &&
      peerFingerprint!.isNotEmpty &&
      rootId != null &&
      rootId!.isNotEmpty &&
      relativePath != null &&
      relativePath!.isNotEmpty;
}
