import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/common/app_logger.dart';
import '../../../core/device/local_media_picker.dart';
import '../../../core/discovery/peer_registry.dart';
import '../../../core/storage/backup_category.dart';
import '../data/backup_local_store.dart';
import '../data/backup_remote_client.dart';
import '../domain/backup_models.dart';

/// 立即备份编排：单活跃槽、可继续/放弃、启动降级（反影子）。
class BackupEngine extends ChangeNotifier {
  BackupEngine({
    required BackupLocalStore store,
    required BackupRemoteClient remote,
    required PeerRegistry peerRegistry,
    LocalMediaPicker? mediaPicker,
  })  : _store = store,
        _remote = remote,
        _peers = peerRegistry,
        _picker = mediaPicker ?? const LocalMediaPicker();

  final BackupLocalStore _store;
  final BackupRemoteClient _remote;
  final PeerRegistry _peers;
  final LocalMediaPicker _picker;
  int _idSeq = 0;

  String _newId() {
    _idSeq += 1;
    return '${DateTime.now().microsecondsSinceEpoch}_$_idSeq';
  }

  BackupRun? _active;
  bool _loopRunning = false;
  bool _cancelRequested = false;
  String? _lastError;
  bool _bootstrapped = false;

  BackupRun? get activeRun => _active;
  String? get lastError => _lastError;
  bool get isRunningLoop => _loopRunning;

  Future<void> bootstrap() async {
    if (_bootstrapped) {
      await refresh();
      return;
    }
    _bootstrapped = true;
    // 反影子：冷启动不得保持 running / 不得自动弹窗续传。
    await _store.demoteRunningToPaused();
    await refresh();
  }

  Future<void> refresh() async {
    _active = await _store.findActiveRun();
    notifyListeners();
  }

  Future<List<BackupRun>> history() => _store.listHistory();

  /// 在线且 NAS 已开的已配对对端。
  List<OnlinePeer> nasOnlineTargets() =>
      _peers.onlinePaired.where((p) => p.nasService).toList(growable: false);

  /// 开始新备份；若已有未完成 Run 则拒绝。
  Future<String?> startNewBackup({
    required String peerFingerprint,
    required String peerName,
  }) async {
    await bootstrap();
    final existing = await _store.findActiveRun();
    if (existing != null) {
      _lastError = '已有未完成的备份，请先继续或放弃';
      notifyListeners();
      return _lastError;
    }
    final online = _peers.onlinePaired
        .where((p) => p.fingerprint == peerFingerprint && p.nasService)
        .toList();
    if (online.isEmpty) {
      _lastError = '目标设备离线或未开启 NAS';
      notifyListeners();
      return _lastError;
    }

    final scanned = await _picker.loadAllMediaFiltered(
      includeImages: true,
      includeVideos: true,
    );
    if (scanned.items.isEmpty) {
      _lastError = '未找到可备份的图片或视频';
      notifyListeners();
      return _lastError;
    }

    final runId = _newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    final run = BackupRun(
      id: runId,
      peerFingerprint: peerFingerprint,
      peerName: peerName,
      status: BackupRunStatus.running,
      totalCount: scanned.items.length,
      successCount: 0,
      skippedCount: 0,
      failedCount: 0,
      startedAtMs: now,
    );
    final items = <BackupRunItem>[];
    for (var i = 0; i < scanned.items.length; i++) {
      final m = scanned.items[i];
      final name = m.displayName.isNotEmpty
          ? m.displayName
          : p.basename(m.localPath);
      items.add(
        BackupRunItem(
          id: _newId(),
          runId: runId,
          sourceId: m.id,
          localPath: m.localPath,
          displayName: name,
          category: BackupCategory.fromMimeOrName(
            mimeType: m.mimeType,
            fileName: name,
          ),
          sizeBytes: m.size,
          mimeType: m.mimeType,
          status: BackupItemStatus.pending,
          sortIndex: i,
        ),
      );
    }

    try {
      await _store.upsertRun(run);
      await _store.insertItems(items);
    } catch (e, st) {
      AppLogger.log('backup create failed: $e', scope: 'backup', details: {
        'stack': '$st',
      });
      try {
        await _store.upsertRun(
          run.copyWith(
            status: BackupRunStatus.failed,
            errorMessage: '创建备份失败: $e',
            endedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      } catch (_) {}
      _active = null;
      _lastError = '创建备份失败: $e';
      notifyListeners();
      return _lastError;
    }
    _active = run;
    _lastError = null;
    _cancelRequested = false;
    notifyListeners();
    unawaited(_runLoop(runId));
    return null;
  }

  Future<String?> continueActive() async {
    await bootstrap();
    final run = await _store.findActiveRun();
    if (run == null) {
      _lastError = '没有可继续的备份';
      notifyListeners();
      return _lastError;
    }
    if (run.status == BackupRunStatus.running && _loopRunning) {
      return null;
    }
    final gate = _gate(run.peerFingerprint);
    if (gate != null) {
      _lastError = gate;
      notifyListeners();
      return gate;
    }
    final next = run.copyWith(
      status: BackupRunStatus.running,
      clearError: true,
    );
    await _store.upsertRun(next);
    _active = next;
    _cancelRequested = false;
    _lastError = null;
    notifyListeners();
    unawaited(_runLoop(run.id));
    return null;
  }

  /// 可靠放弃：停循环 → 取消明细 → Run=cancelled 落库。
  Future<void> abandonActive() async {
    _cancelRequested = true;
    final run = await _store.findActiveRun() ?? _active;
    if (run == null) {
      await refresh();
      return;
    }
    // 等待当前文件循环感知取消（最多短暂等待）。
    for (var i = 0; i < 50 && _loopRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await _store.cancelPendingItems(run.id);
    final ended = run.copyWith(
      status: BackupRunStatus.cancelled,
      errorMessage: '用户放弃',
      endedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    // 重新统计
    final items = await _store.listItems(run.id);
    var success = 0, skipped = 0, failed = 0;
    for (final it in items) {
      switch (it.status) {
        case BackupItemStatus.done:
          // done 含上传成功；跳过另计——此处用 error 区分不便，用 display 策略：
          // 跳过也是 done。用 error_message=='skipped' 标记。
          if (it.errorMessage == 'skipped') {
            skipped++;
          } else {
            success++;
          }
        case BackupItemStatus.failed:
          failed++;
        default:
          break;
      }
    }
    final finalRun = ended.copyWith(
      successCount: success,
      skippedCount: skipped,
      failedCount: failed,
    );
    await _store.upsertRun(finalRun);
    _active = null;
    _lastError = null;
    notifyListeners();
  }

  String? _gate(String peerFingerprint) {
    final hit = _peers.onlinePaired
        .where((p) => p.fingerprint == peerFingerprint && p.nasService);
    if (hit.isEmpty) {
      return '目标设备离线或未开启 NAS，无法继续';
    }
    return null;
  }

  Future<void> _runLoop(String runId) async {
    if (_loopRunning) return;
    _loopRunning = true;
    notifyListeners();
    try {
      while (!_cancelRequested) {
        var run = await _store.findRun(runId);
        if (run == null || run.status == BackupRunStatus.cancelled) break;
        if (run.status == BackupRunStatus.paused) break;

        final gate = _gate(run.peerFingerprint);
        if (gate != null) {
          await _pause(run, gate);
          break;
        }

        final pending = await _store.listPendingItems(runId);
        if (pending.isEmpty) {
          await _finish(run);
          break;
        }

        final item = pending.first;
        AppLogger.log(
          'backup item',
          scope: 'backup',
          details: {
            'name': item.displayName,
            'category': item.category.apiName,
            'size': item.sizeBytes,
          },
        );
        // 空间预检（单文件）
        final space = await _remote.preflightSpace(
          peerFingerprint: run.peerFingerprint,
          needBytes: max(item.sizeBytes, 0),
        );
        if (_cancelRequested) break;
        if (!space.ok) {
          await _failItem(item, space.error ?? '空间不足');
          await _refreshCounts(runId);
          // 空间不足：暂停整次，便于用户处理后再继续
          run = (await _store.findRun(runId))!;
          await _pause(run, space.error ?? '对端空间不足');
          break;
        }

        final exists = await _remote.fileExists(
          peerFingerprint: run.peerFingerprint,
          category: item.category,
          fileName: item.displayName,
        );
        if (_cancelRequested) break;
        if (exists) {
          await _store.updateItem(
            item.copyWith(
              status: BackupItemStatus.done,
              errorMessage: 'skipped',
            ),
          );
          await _refreshCounts(runId);
          continue;
        }

        await _store.updateItem(
          item.copyWith(status: BackupItemStatus.uploading, clearError: true),
        );
        notifyListeners();

        final file = File(item.localPath);
        if (!await file.exists()) {
          await _failItem(item, '本地文件不存在');
          await _refreshCounts(runId);
          continue;
        }

        final uploaded = await _remote.uploadFile(
          peerFingerprint: run.peerFingerprint,
          category: item.category,
          fileName: item.displayName,
          file: file,
        );
        if (_cancelRequested) {
          // 上传可能已完成；若失败则标回 pending 以便放弃流程取消
          if (!uploaded.ok) {
            await _store.updateItem(
              item.copyWith(status: BackupItemStatus.pending, clearError: true),
            );
          }
          break;
        }
        if (uploaded.ok) {
          await _store.updateItem(
            item.copyWith(status: BackupItemStatus.done, clearError: true),
          );
        } else {
          await _failItem(item, uploaded.error ?? '上传失败');
        }
        await _refreshCounts(runId);
      }
    } catch (e, st) {
      AppLogger.log('backup loop error: $e', scope: 'backup', details: {
        'stack': '$st',
      });
      final run = await _store.findRun(runId);
      if (run != null && !run.status.isTerminal) {
        await _pause(run, '备份异常: $e');
      }
    } finally {
      _loopRunning = false;
      if (_cancelRequested) {
        // abandonActive 负责写 cancelled
      } else {
        await refresh();
      }
      notifyListeners();
    }
  }

  Future<void> _failItem(BackupRunItem item, String message) async {
    await _store.updateItem(
      item.copyWith(status: BackupItemStatus.failed, errorMessage: message),
    );
  }

  Future<void> _pause(BackupRun run, String reason) async {
    final next = run.copyWith(
      status: BackupRunStatus.paused,
      errorMessage: reason,
    );
    await _store.upsertRun(next);
    _active = next;
    _lastError = reason;
    notifyListeners();
  }

  Future<void> _finish(BackupRun run) async {
    await _refreshCounts(run.id);
    final latest = await _store.findRun(run.id);
    if (latest == null) return;
    final items = await _store.listItems(run.id);
    final processed = latest.successCount + latest.skippedCount + latest.failedCount;
    // 明细丢失或尚未处理任何文件就结束 → 失败，禁止「成功 0/0/0」。
    if (items.isEmpty && latest.totalCount > 0) {
      final ended = latest.copyWith(
        status: BackupRunStatus.failed,
        errorMessage: '备份明细丢失，请重新发起',
        endedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _store.upsertRun(ended);
      _active = null;
      _lastError = ended.errorMessage;
      notifyListeners();
      return;
    }
    final status = latest.failedCount > 0 || processed == 0
        ? BackupRunStatus.failed
        : BackupRunStatus.success;
    final ended = latest.copyWith(
      status: status,
      endedAtMs: DateTime.now().millisecondsSinceEpoch,
      clearError: status == BackupRunStatus.success,
      errorMessage: status == BackupRunStatus.failed
          ? (processed == 0 ? '没有文件被处理' : '部分文件失败')
          : null,
    );
    await _store.upsertRun(ended);
    _active = null;
    notifyListeners();
  }

  Future<void> _refreshCounts(String runId) async {
    final run = await _store.findRun(runId);
    if (run == null) return;
    final items = await _store.listItems(runId);
    var success = 0, skipped = 0, failed = 0;
    for (final it in items) {
      if (it.status == BackupItemStatus.done) {
        if (it.errorMessage == 'skipped') {
          skipped++;
        } else {
          success++;
        }
      } else if (it.status == BackupItemStatus.failed) {
        failed++;
      }
    }
    final next = run.copyWith(
      successCount: success,
      skippedCount: skipped,
      failedCount: failed,
    );
    await _store.upsertRun(next);
    if (_active?.id == runId) {
      _active = next;
      notifyListeners();
    }
  }
}
