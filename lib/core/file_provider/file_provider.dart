import '../storage/storage_root.dart';
import 'file_entry.dart';

/// 统一文件访问（阶段 B：list / delete；读写在上传下载阶段补强）。
abstract class FileProvider {
  bool get isRemote;
  bool get canUpload;
  bool get canDownload;
  bool get canDelete;

  Future<List<StorageRoot>> roots({bool includeHistory = true});

  Future<List<FileEntry>> list({
    required String rootId,
    String path = '',
  });

  Future<bool> delete({
    required String rootId,
    required String relativePath,
  });

  /// 在 [path] 下创建名为 [name] 的子目录；成功返回相对路径，失败返回 null。
  Future<String?> mkdir({
    required String rootId,
    required String path,
    required String name,
  });
}
