/// 共享存储常量（决策 #14：默认 Download/diubangfiles，无自动切盘）。
///
/// 正式接收/下载落点：`{根}/图片|视频|文档|其他/`（见 [ShareReceivePaths]）。
/// 目录名 [folderName] 仅 ASCII：避免部分机型/MediaStore/跨端路径编码问题。
abstract final class StorageConstants {
  /// 共享根文件夹名（默认仅落在公共 Download 下）。
  static const folderName = 'diubangfiles';

  /// 设置/概览展示用相对路径文案（Windows 默认同目录名）。
  static const displayPathLabel = 'Downloads/diubangfiles';

  /// 写入前预留空间（字节）；不足则失败，不自动换根。
  static const reserveBytes = 100 * 1024 * 1024;

  static const kvCurrentRootId = 'storage.current_root_id';
  static const kvRootsJson = 'storage.roots_json';
}
