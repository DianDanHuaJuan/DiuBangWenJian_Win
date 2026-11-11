import '../../../core/file_provider/file_entry.dart';

enum CategoryDownloadStatus {
  running,
  paused,
  success,
  failed,
  cancelled;

  bool get isActive =>
      this == CategoryDownloadStatus.running ||
      this == CategoryDownloadStatus.paused;

  String get label => switch (this) {
        CategoryDownloadStatus.running => '下载中',
        CategoryDownloadStatus.paused => '已中断',
        CategoryDownloadStatus.success => '已完成',
        CategoryDownloadStatus.failed => '有失败',
        CategoryDownloadStatus.cancelled => '已停止',
      };
}

class CategoryDownloadRun {
  const CategoryDownloadRun({
    required this.id,
    required this.peerFingerprint,
    required this.peerName,
    required this.category,
    required this.scopePath,
    required this.status,
    required this.listOffset,
    required this.listDone,
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
  final FileCategoryFilter category;
  final String scopePath;
  final CategoryDownloadStatus status;
  final int listOffset;
  final bool listDone;
  final int totalCount;
  final int successCount;
  final int skippedCount;
  final int failedCount;
  final String? errorMessage;
  final int startedAtMs;
  final int? endedAtMs;

  bool matches({
    required String peerFingerprint,
    required FileCategoryFilter category,
    required String scopePath,
  }) =>
      this.peerFingerprint == peerFingerprint &&
      this.category == category &&
      this.scopePath == scopePath;

  CategoryDownloadRun copyWith({
    CategoryDownloadStatus? status,
    int? listOffset,
    bool? listDone,
    int? totalCount,
    int? successCount,
    int? skippedCount,
    int? failedCount,
    String? errorMessage,
    int? endedAtMs,
    bool clearError = false,
  }) =>
      CategoryDownloadRun(
        id: id,
        peerFingerprint: peerFingerprint,
        peerName: peerName,
        category: category,
        scopePath: scopePath,
        status: status ?? this.status,
        listOffset: listOffset ?? this.listOffset,
        listDone: listDone ?? this.listDone,
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
        'category': category.name,
        'scope_path': scopePath,
        'status': status.name,
        'list_offset': listOffset,
        'list_done': listDone ? 1 : 0,
        'total_count': totalCount,
        'success_count': successCount,
        'skipped_count': skippedCount,
        'failed_count': failedCount,
        'error_message': errorMessage,
        'started_at_ms': startedAtMs,
        'ended_at_ms': endedAtMs,
      };

  factory CategoryDownloadRun.fromMap(Map<String, Object?> map) =>
      CategoryDownloadRun(
        id: map['id'] as String,
        peerFingerprint: map['peer_fingerprint'] as String,
        peerName: map['peer_name'] as String? ?? '',
        category: FileCategoryFilter.values.firstWhere(
          (e) => e.name == map['category'],
          orElse: () => FileCategoryFilter.other,
        ),
        scopePath: map['scope_path'] as String? ?? '',
        status: CategoryDownloadStatus.values.firstWhere(
          (e) => e.name == map['status'],
          orElse: () => CategoryDownloadStatus.failed,
        ),
        listOffset: (map['list_offset'] as num?)?.toInt() ?? 0,
        listDone: (map['list_done'] as num?)?.toInt() == 1,
        totalCount: (map['total_count'] as num?)?.toInt() ?? 0,
        successCount: (map['success_count'] as num?)?.toInt() ?? 0,
        skippedCount: (map['skipped_count'] as num?)?.toInt() ?? 0,
        failedCount: (map['failed_count'] as num?)?.toInt() ?? 0,
        errorMessage: map['error_message'] as String?,
        startedAtMs: (map['started_at_ms'] as num?)?.toInt() ?? 0,
        endedAtMs: (map['ended_at_ms'] as num?)?.toInt(),
      );
}

class CategoryDownloadItem {
  const CategoryDownloadItem({
    required this.id,
    required this.runId,
    required this.taskId,
    required this.remoteKey,
    required this.status,
  });

  final String id;
  final String runId;
  final String taskId;
  final String remoteKey;
  final String status;

  Map<String, Object?> toMap() => {
        'id': id,
        'run_id': runId,
        'task_id': taskId,
        'remote_key': remoteKey,
        'status': status,
      };

  factory CategoryDownloadItem.fromMap(Map<String, Object?> map) =>
      CategoryDownloadItem(
        id: map['id'] as String,
        runId: map['run_id'] as String,
        taskId: map['task_id'] as String,
        remoteKey: map['remote_key'] as String,
        status: map['status'] as String? ?? 'queued',
      );
}
