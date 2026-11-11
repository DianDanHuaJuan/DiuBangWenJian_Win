import '../../../core/storage/backup_category.dart';

/// 备份 Run 状态（施工方案 §6）。
enum BackupRunStatus {
  running,
  paused,
  success,
  failed,
  cancelled;

  bool get isTerminal =>
      this == BackupRunStatus.success ||
      this == BackupRunStatus.failed ||
      this == BackupRunStatus.cancelled;

  bool get isActive =>
      this == BackupRunStatus.running || this == BackupRunStatus.paused;

  String get label => switch (this) {
        BackupRunStatus.running => '进行中',
        BackupRunStatus.paused => '已中断',
        BackupRunStatus.success => '成功',
        BackupRunStatus.failed => '失败',
        BackupRunStatus.cancelled => '已取消',
      };
}

enum BackupItemStatus {
  pending,
  uploading,
  done,
  failed,
  cancelled,
}

class BackupRun {
  const BackupRun({
    required this.id,
    required this.peerFingerprint,
    required this.peerName,
    required this.status,
    required this.totalCount,
    required this.successCount,
    required this.skippedCount,
    required this.failedCount,
    required this.startedAtMs,
    this.errorMessage,
    this.endedAtMs,
  });

  final String id;
  final String peerFingerprint;
  final String peerName;
  final BackupRunStatus status;
  final int totalCount;
  final int successCount;
  final int skippedCount;
  final int failedCount;
  final String? errorMessage;
  final int startedAtMs;
  final int? endedAtMs;

  int get finishedCount => successCount + skippedCount + failedCount;

  BackupRun copyWith({
    BackupRunStatus? status,
    int? totalCount,
    int? successCount,
    int? skippedCount,
    int? failedCount,
    String? errorMessage,
    int? endedAtMs,
    bool clearError = false,
  }) =>
      BackupRun(
        id: id,
        peerFingerprint: peerFingerprint,
        peerName: peerName,
        status: status ?? this.status,
        totalCount: totalCount ?? this.totalCount,
        successCount: successCount ?? this.successCount,
        skippedCount: skippedCount ?? this.skippedCount,
        failedCount: failedCount ?? this.failedCount,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        startedAtMs: startedAtMs,
        endedAtMs: endedAtMs ?? this.endedAtMs,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'peer_fingerprint': peerFingerprint,
        'peer_name': peerName,
        'status': status.name,
        'total_count': totalCount,
        'success_count': successCount,
        'skipped_count': skippedCount,
        'failed_count': failedCount,
        'error_message': errorMessage,
        'started_at_ms': startedAtMs,
        'ended_at_ms': endedAtMs,
      };

  factory BackupRun.fromMap(Map<String, Object?> map) => BackupRun(
        id: map['id'] as String,
        peerFingerprint: map['peer_fingerprint'] as String,
        peerName: map['peer_name'] as String? ?? '',
        status: BackupRunStatus.values.firstWhere(
          (e) => e.name == map['status'],
          orElse: () => BackupRunStatus.failed,
        ),
        totalCount: (map['total_count'] as num?)?.toInt() ?? 0,
        successCount: (map['success_count'] as num?)?.toInt() ?? 0,
        skippedCount: (map['skipped_count'] as num?)?.toInt() ?? 0,
        failedCount: (map['failed_count'] as num?)?.toInt() ?? 0,
        errorMessage: map['error_message'] as String?,
        startedAtMs: (map['started_at_ms'] as num?)?.toInt() ?? 0,
        endedAtMs: (map['ended_at_ms'] as num?)?.toInt(),
      );
}

class BackupRunItem {
  const BackupRunItem({
    required this.id,
    required this.runId,
    required this.sourceId,
    required this.localPath,
    required this.displayName,
    required this.category,
    required this.sizeBytes,
    required this.status,
    required this.sortIndex,
    this.mimeType,
    this.errorMessage,
  });

  final String id;
  final String runId;
  final String sourceId;
  final String localPath;
  final String displayName;
  final BackupCategory category;
  final int sizeBytes;
  final String? mimeType;
  final BackupItemStatus status;
  final String? errorMessage;
  final int sortIndex;

  BackupRunItem copyWith({
    BackupItemStatus? status,
    String? errorMessage,
    bool clearError = false,
  }) =>
      BackupRunItem(
        id: id,
        runId: runId,
        sourceId: sourceId,
        localPath: localPath,
        displayName: displayName,
        category: category,
        sizeBytes: sizeBytes,
        mimeType: mimeType,
        status: status ?? this.status,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        sortIndex: sortIndex,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'run_id': runId,
        'source_id': sourceId,
        'local_path': localPath,
        'display_name': displayName,
        'category': category.apiName,
        'size_bytes': sizeBytes,
        'mime_type': mimeType,
        'status': status.name,
        'error_message': errorMessage,
        'sort_index': sortIndex,
      };

  factory BackupRunItem.fromMap(Map<String, Object?> map) => BackupRunItem(
        id: map['id'] as String,
        runId: map['run_id'] as String,
        sourceId: map['source_id'] as String,
        localPath: map['local_path'] as String,
        displayName: map['display_name'] as String,
        category: BackupCategory.tryParse(map['category'] as String?) ??
            BackupCategory.other,
        sizeBytes: (map['size_bytes'] as num?)?.toInt() ?? 0,
        mimeType: map['mime_type'] as String?,
        status: BackupItemStatus.values.firstWhere(
          (e) => e.name == map['status'],
          orElse: () => BackupItemStatus.pending,
        ),
        errorMessage: map['error_message'] as String?,
        sortIndex: (map['sort_index'] as num?)?.toInt() ?? 0,
      );
}
