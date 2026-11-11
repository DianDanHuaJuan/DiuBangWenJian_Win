import '../storage/share_reader.dart';
import '../storage/storage_root.dart';
import '../storage/storage_root_store.dart';
import 'file_entry.dart';
import 'file_provider.dart';

class LocalFileProvider implements FileProvider {
  LocalFileProvider({
    required ShareReader shareReader,
    required StorageRootStore rootStore,
  })  : _reader = shareReader,
        _roots = rootStore;

  final ShareReader _reader;
  final StorageRootStore _roots;

  @override
  bool get isRemote => false;

  @override
  bool get canUpload => false;

  @override
  bool get canDownload => false;

  @override
  bool get canDelete => true;

  @override
  Future<List<StorageRoot>> roots({bool includeHistory = true}) =>
      _reader.listAccessibleRoots(includeHistory: includeHistory);

  @override
  Future<List<FileEntry>> list({
    required String rootId,
    String path = '',
  }) async {
    final entries = await _reader.listDirectory(
      rootId: rootId,
      relativePath: path,
    );
    return entries
        .map(
          (e) => FileEntry(
            name: e.fileName,
            relativePath: e.relativePath,
            rootId: e.rootId,
            rootDisplayName: e.rootDisplayName,
            isDirectory: e.isDirectory,
            sizeBytes: e.sizeBytes,
            modifiedAtMs: e.modifiedAtMs,
            absolutePath: e.absolutePath,
          ),
        )
        .toList();
  }

  @override
  Future<bool> delete({
    required String rootId,
    required String relativePath,
  }) =>
      _reader.deleteEntry(rootId: rootId, relativePath: relativePath);

  Future<StorageRoot> ensureCurrent() => _roots.ensureCurrent();
}
