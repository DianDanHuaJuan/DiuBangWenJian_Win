/// 共享存储常量（决策 #14：默认 Download/diubangfiles，无自动切盘）。
///
/// 正式落盘：默认安装根按四分类；换根后顶层；目录模式写当前 dir（见 [ShareReceivePaths]）。
/// 四分类空目录仅在首次创建默认根时建一次。
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
