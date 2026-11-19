import 'backup_category.dart';
import 'storage_root.dart';

/// 正式接收/下载的落盘子目录策略。
///
/// - 安装时默认根会一次性创建四分类空目录（见 [StorageRootStore._createDefaultRoot]）
/// - 默认安装根 + 无当前目录 → 按 MIME/扩展名进四分类
/// - 已换存储位置的根 + 无当前目录 → 共享根顶层
/// - 有 [directory]（目录访问模式）→ 写该相对目录
///
/// 预览/聊天气泡缓存不经本类。
abstract final class ShareReceivePaths {
  /// 首次安装写入的默认根 id 前缀（换根后为 `path_` 等）。
  static const defaultRootIdPrefix = 'default_';

  static bool isDefaultInstallRoot(StorageRoot root) =>
      root.id.startsWith(defaultRootIdPrefix);

  /// 按 MIME / 文件名归入四分类（浏览筛选等仍可用）。
  static BackupCategory categoryFor({
    String? mimeType,
    required String fileName,
  }) =>
      BackupCategory.fromMimeOrName(mimeType: mimeType, fileName: fileName);

  /// 仅「默认安装根、无当前目录」时返回分类名；否则请用 [relativeDirForReceive]。
  static String relativeDirFor({
    String? mimeType,
    required String fileName,
  }) =>
      categoryFor(mimeType: mimeType, fileName: fileName).folderName;

  /// 正式落盘选路（上传/聊天接收/下载/备份/保存原图共用）。
  static String relativeDirForReceive({
    required StorageRoot root,
    String directory = '',
    String? mimeType,
    required String fileName,
  }) {
    final dir = directory.trim().replaceAll('\\', '/');
    if (dir.isNotEmpty) return dir;
    if (isDefaultInstallRoot(root)) {
      return relativeDirFor(mimeType: mimeType, fileName: fileName);
    }
    return '';
  }

  /// 备份协议仍带 category；默认根写入对应分类，换根后写顶层。
  static String relativeDirForBackup({
    required StorageRoot root,
    required BackupCategory category,
  }) {
    if (isDefaultInstallRoot(root)) return category.folderName;
    return '';
  }
}
