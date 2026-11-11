/// 统一传输任务模型（doc/02 core/task；outbox 与传输合一）。
enum TransferTaskType {
  p2pOffer,
  p2pDownload,
  nasDownload,
  nasUpload,
}

/// 任务状态机：offered → accepted → transferring → done | failed | cancelled | expired
enum TransferTaskState {
  offered,
  accepted,
  transferring,
  done,
  failed,
  cancelled,
  expired,
}

class TransferTask {
  const TransferTask({
    required this.id,
    required this.type,
    required this.state,
    required this.peerFingerprint,
    required this.fileName,
    required this.sizeBytes,
    required this.createdAtMs,
    this.updatedAtMs,
    this.sha256Hex,
    this.localPath,
    this.remotePath,
    this.errorMessage,
    this.ttlExpireAtMs,
    this.bytesTransferred = 0,
  });

  final String id;
  final TransferTaskType type;
  final TransferTaskState state;

  /// 对端 Device ID（指纹）。
  final String peerFingerprint;

  final String fileName;
  final int sizeBytes;
  final int createdAtMs;
  final int? updatedAtMs;
  final String? sha256Hex;
  final String? localPath;
  final String? remotePath;
  final String? errorMessage;
  final int? ttlExpireAtMs;
  final int bytesTransferred;

  bool get isTerminal =>
      state == TransferTaskState.done ||
      state == TransferTaskState.failed ||
      state == TransferTaskState.cancelled ||
      state == TransferTaskState.expired;

  TransferTask copyWith({
    TransferTaskState? state,
    int? updatedAtMs,
    String? sha256Hex,
    String? localPath,
    String? remotePath,
    String? errorMessage,
    int? ttlExpireAtMs,
    int? bytesTransferred,
  }) =>
      TransferTask(
        id: id,
        type: type,
        state: state ?? this.state,
        peerFingerprint: peerFingerprint,
        fileName: fileName,
        sizeBytes: sizeBytes,
        createdAtMs: createdAtMs,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
        sha256Hex: sha256Hex ?? this.sha256Hex,
        localPath: localPath ?? this.localPath,
        remotePath: remotePath ?? this.remotePath,
        errorMessage: errorMessage ?? this.errorMessage,
        ttlExpireAtMs: ttlExpireAtMs ?? this.ttlExpireAtMs,
        bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'type': type.name,
        'state': state.name,
        'peer_fingerprint': peerFingerprint,
        'file_name': fileName,
        'size_bytes': sizeBytes,
        'created_at_ms': createdAtMs,
        'updated_at_ms': updatedAtMs,
        'sha256_hex': sha256Hex,
        'local_path': localPath,
        'remote_path': remotePath,
        'error_message': errorMessage,
        'ttl_expire_at_ms': ttlExpireAtMs,
        'bytes_transferred': bytesTransferred,
      };

  factory TransferTask.fromMap(Map<String, Object?> map) {
    return TransferTask(
      id: map['id'] as String,
      type: TransferTaskType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => TransferTaskType.p2pOffer,
      ),
      state: TransferTaskState.values.firstWhere(
        (e) => e.name == map['state'],
        orElse: () => TransferTaskState.offered,
      ),
      peerFingerprint: map['peer_fingerprint'] as String,
      fileName: map['file_name'] as String,
      sizeBytes: map['size_bytes'] as int? ?? 0,
      createdAtMs: map['created_at_ms'] as int? ?? 0,
      updatedAtMs: map['updated_at_ms'] as int?,
      sha256Hex: map['sha256_hex'] as String?,
      localPath: map['local_path'] as String?,
      remotePath: map['remote_path'] as String?,
      errorMessage: map['error_message'] as String?,
      ttlExpireAtMs: map['ttl_expire_at_ms'] as int?,
      bytesTransferred: map['bytes_transferred'] as int? ?? 0,
    );
  }
}
