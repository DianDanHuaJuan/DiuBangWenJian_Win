import 'storage_constants.dart';

/// 共享根类型：文件系统路径 或 SAF 树 URI。
enum StorageRootKind { path, saf }

/// 共享根模型（doc/02 core/storage：当前根写入口；历史根仅浏览联合）。
class StorageRoot {
  const StorageRoot({
    required this.id,
    required this.kind,
    required this.uriOrPath,
    required this.displayName,
    required this.addedAtMs,
    this.revoked = false,
  });

  final String id;
  final StorageRootKind kind;

  /// path 根为绝对路径；saf 根为 content tree URI 字符串。
  final String uriOrPath;

  /// UI 展示名（如 `Download/diubangfiles` 或用户自命名 OTG 目录）。
  final String displayName;

  final int addedAtMs;

  /// 权限丢失 / 用户移除后标记；不再作为当前写根，仍可出现在历史。
  final bool revoked;

  bool get isPath => kind == StorageRootKind.path;
  bool get isSaf => kind == StorageRootKind.saf;

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'uriOrPath': uriOrPath,
        'displayName': displayName,
        'addedAtMs': addedAtMs,
        'revoked': revoked,
      };

  factory StorageRoot.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'] as String? ?? StorageRootKind.path.name;
    return StorageRoot(
      id: json['id'] as String,
      kind: StorageRootKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => StorageRootKind.path,
      ),
      uriOrPath: json['uriOrPath'] as String,
      displayName:
          json['displayName'] as String? ?? StorageConstants.displayPathLabel,
      addedAtMs: json['addedAtMs'] as int? ?? 0,
      revoked: json['revoked'] as bool? ?? false,
    );
  }

  StorageRoot copyWith({
    String? displayName,
    bool? revoked,
  }) =>
      StorageRoot(
        id: id,
        kind: kind,
        uriOrPath: uriOrPath,
        displayName: displayName ?? this.displayName,
        addedAtMs: addedAtMs,
        revoked: revoked ?? this.revoked,
      );
}
