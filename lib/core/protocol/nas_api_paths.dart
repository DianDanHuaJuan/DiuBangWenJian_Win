/// NAS REST 路径契约（core 与 features/nas 共用）。
///
/// 依据 doc/01 §五：客户端与 handlers 只依赖本文件，禁止 core → features/nas。
abstract final class NasApiPaths {
  static const files = '/api/v1/files';
  static const filesContent = '/api/v1/files/content';
  static const filesUpload = '/api/v1/files/upload';
  static const filesBatchDelete = '/api/v1/files/batch-delete';
  static const filesMkdir = '/api/v1/files/mkdir';
  static const storageVolumes = '/api/v1/storage/volumes';

  static const thumbnail = '/api/v1/thumbnail';

  static const backupPreflight = '/api/v1/backup/preflight';
  static const backupExists = '/api/v1/backup/exists';
  static const backupUpload = '/api/v1/backup/upload';
  static const previewHls = '/api/v1/preview/hls';
}

/// NAS 业务错误码（JSON `code` 字段；客户端按码识别，勿依赖文案）。
abstract final class NasApiErrorCodes {
  /// 同时在线设备槽已满。
  static const peerLimit = 'NAS_PEER_LIMIT';
}

/// 查询参数键（与 handlers 约定一致，避免散落魔法字符串）。
abstract final class NasApiQuery {
  static const rootId = 'rootId';
  static const path = 'path';
  static const name = 'name';
  /// 缩略图档位：`grid` | `preview`（见 [ThumbImageTier] / docs/缩略图与预览图缓存方案.md）。
  static const type = 'type';
  static const max = 'max';
  static const offset = 'offset';
  static const limit = 'limit';
}
