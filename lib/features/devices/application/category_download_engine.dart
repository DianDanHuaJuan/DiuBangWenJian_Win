import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/common/app_logger.dart';
import '../../../core/discovery/peer_registry.dart';
import '../../../core/file_provider/file_entry.dart';
import '../../../core/file_provider/remote_peer_file_provider.dart';
import '../../../core/file_provider/share_category_files.dart';
import '../../../core/network/peer_api_client.dart';
import '../../../core/storage/media_library_service.dart';
import '../../../core/task/transfer_task.dart';
import '../../../core/task/transfer_task_store.dart';
import '../../../core/transfer/nas_transfer_service.dart';
import '../data/category_download_store.dart';
import '../domain/category_download_run.dart';

/// 对端某一分类的整库下载。逐页入队，窗口内交给现有下载队列。
class CategoryDownloadEngine extends ChangeNotifier {
  CategoryDownloadEngine({
    required CategoryDownloadStore store,
    required Future<TransferTaskStore> Function() tasks,
    required NasTransferService transfers,
    required PeerRegistry peers,
    required PeerApiClient api,
  })  : _store = store,
        _tasks = tasks,
        _transfers = transfers,
        _peers = peers,
        _api = api;

  static const _window = 8;
  static const _pageSize = 120;

  final CategoryDownloadStore _store;
  final Future<TransferTaskStore> Function() _tasks;
  final NasTransferService _transfers;
  final PeerRegistry _peers;
  final PeerApiClient _api;

  CategoryDownloadRun? _active;
  bool _looping = false;
  bool _cancel = false;
  bool _bootstrapped = false;
  int _seq = 0;

  CategoryDownloadRun? get activeRun => _active;
  bool get isRunning => _looping;

  String _newId(String prefix) {
    _seq += 1;
    return '${prefix}_${DateTime.now().microsecondsSinceEpoch}_$_seq';
  }

  Future<void> bootstrap() async {
    if (_bootstrapped) {
      _active = await _store.findActive();
      notifyListeners();
      return;
    }
    _bootstrapped = true;
    await _store.demoteRunningToPaused();
    _active = await _store.findActive();
    notifyListeners();
  }

  Future<String?> start({
    required String peerFingerprint,
    required String peerName,
    required FileCategoryFilter category,
    required String scopePath,
  }) async {
    await bootstrap();
    if (_active != null) {
      return '请先继续或停止正在进行的「${_active!.category.label}」下载';
    }
    final gate = _gate(peerFingerprint);
    if (gate != null) return gate;

    final now = DateTime.now().millisecondsSinceEpoch;
    final run = CategoryDownloadRun(
      id: _newId('catdl'),
      peerFingerprint: peerFingerprint,
      peerName: peerName,
      category: category,
      scopePath: scopePath,
      status: CategoryDownloadStatus.running,
      listOffset: 0,
      listDone: false,
      totalCount: 0,
      successCount: 0,
      skippedCount: 0,
      failedCount: 0,
      startedAtMs: now,
    );
    await _store.upsertRun(run);
    _active = run;
    _cancel = false;
    notifyListeners();
    unawaited(_loop(run.id));
    return null;
  }

  Future<String?> continueActive() async {
    await bootstrap();
    final run = await _store.findActive();
    if (run == null) return '没有可继续的下载';
    final gate = _gate(run.peerFingerprint);
    if (gate != null) return gate;
    if (_looping) return null;
    final next = run.copyWith(
      status: CategoryDownloadStatus.running,
      clearError: true,
    );
    await _store.upsertRun(next);
    _active = next;
    _cancel = false;
    notifyListeners();
    unawaited(_loop(run.id));
    return null;
  }

  /// 停止：取消还没开始传的任务，已完成的文件保留。
  Future<void> stopActive() async {
    _cancel = true;
    final run = await _store.findActive() ?? _active;
    if (run == null) {
      await bootstrap();
      return;
    }
    final tasks = await _tasks();
    final items = await _store.listItems(run.id);
    for (final item in items) {
      if (item.status != 'queued') continue;
      final task = await tasks.findById(item.taskId);
      if (task != null &&
          task.state != TransferTaskState.transferring &&
          !task.isTerminal) {
        await tasks.updateState(
          task.id,
          TransferTaskState.cancelled,
          errorMessage: '用户停止',
        );
      }
      await _store.updateItemStatus(item.id, 'cancelled');
    }
    final ended = run.copyWith(
      status: CategoryDownloadStatus.cancelled,
      errorMessage: '已停止',
      endedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _store.upsertRun(ended);
    _active = null;
    notifyListeners();
  }

  String? _gate(String peerFingerprint) {
    final hit = _peers.onlinePaired.where(
      (p) => p.fingerprint == peerFingerprint && p.nasService,
    );
    if (hit.isEmpty) return '目标设备离线或未开启 NAS';
    return null;
  }

  Future<void> _loop(String runId) async {
    if (_looping) return;
    _looping = true;
    notifyListeners();
    try {
      final provider = RemotePeerFileProvider(
        peerFingerprint: (await _store.findRun(runId))!.peerFingerprint,
        api: _api,
      );
      while (!_cancel) {
        var run = await _store.findRun(runId);
        if (run == null || !run.status.isActive) break;
        if (run.status == CategoryDownloadStatus.paused) break;
        final gate = _gate(run.peerFingerprint);
        if (gate != null) {
          await _pause(run, gate);
          break;
        }
        await _syncItems(run);
        run = (await _store.findRun(runId))!;
        final open = await _openCount(run.id);
        if (run.listDone && open == 0) {
          await _finish(run);
          break;
        }
        if (run.listDone || open >= _window) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          continue;
        }
        final fed = await _feed(provider, run);
        if (!fed) break;
      }
    } catch (e, st) {
      AppLogger.log('category download: $e', scope: 'catdl', details: {
        'stack': '$st',
      });
      final run = await _store.findRun(runId);
      if (run != null && run.status == CategoryDownloadStatus.running) {
        await _pause(run, '下载异常: $e');
      }
    } finally {
      _looping = false;
      if (!_cancel) {
        _active = await _store.findActive();
      }
      notifyListeners();
    }
  }

  Future<bool> _feed(
    RemotePeerFileProvider provider,
    CategoryDownloadRun run,
  ) async {
    if (run.category.isMediaLibraryCategory) {
      return _feedLibrary(provider, run);
    }
    return _feedFolder(provider, run);
  }

  Future<bool> _feedLibrary(
    RemotePeerFileProvider provider,
    CategoryDownloadRun run,
  ) async {
    final kind = run.category == FileCategoryFilter.photo ? 'image' : 'video';
    final page = await provider.listPage(
      rootId: MediaLibraryService.rootId,
      path: kind,
      offset: run.listOffset,
      limit: _pageSize,
    );
    var skipped = run.skippedCount;
    final known = await _knownKeys(run.id);
    for (final entry in page.items) {
      if (_cancel) return false;
      if (entry.isDirectory || !run.category.matches(entry)) {
        skipped++;
        continue;
      }
      final queued = await _enqueue(run, entry, known);
      if (!queued) skipped++;
      while (!_cancel && await _openCount(run.id) >= _window) {
        final gate = _gate(run.peerFingerprint);
        if (gate != null) {
          await _pause(
            (await _store.findRun(run.id))!.copyWith(skippedCount: skipped),
            gate,
          );
          return false;
        }
        await _syncItems((await _store.findRun(run.id))!);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    final next = (await _store.findRun(run.id))!;
    final done = !page.hasMore;
    await _store.upsertRun(
      next.copyWith(
        listOffset: page.offset + page.items.length,
        listDone: done,
        totalCount: page.total,
        skippedCount: skipped,
      ),
    );
    _active = await _store.findRun(run.id);
    notifyListeners();
    if (done && page.total == 0 && skipped == 0 && next.successCount == 0) {
      await _finish((await _store.findRun(run.id))!, empty: true);
      return false;
    }
    return true;
  }

  Future<bool> _feedFolder(
    RemotePeerFileProvider provider,
    CategoryDownloadRun run,
  ) async {
    final files = await collectShareCategoryFiles(
      startPath: run.scopePath,
      listDirectory: (path) => provider.list(rootId: 'fs', path: path),
      include: run.category.matches,
    );
    final known = await _knownKeys(run.id);
    var skipped = run.skippedCount;
    var index = run.listOffset;
    while (index < files.length) {
      if (_cancel) return false;
      final gate = _gate(run.peerFingerprint);
      if (gate != null) {
        await _store.upsertRun(
          (await _store.findRun(run.id))!.copyWith(
            listOffset: index,
            totalCount: files.length,
            skippedCount: skipped,
          ),
        );
        await _pause((await _store.findRun(run.id))!, gate);
        return false;
      }
      while (!_cancel && await _openCount(run.id) >= _window) {
        await _syncItems((await _store.findRun(run.id))!);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (_cancel) return false;
      final queued = await _enqueue(run, files[index], known);
      if (!queued) skipped++;
      index++;
    }
    await _store.upsertRun(
      (await _store.findRun(run.id))!.copyWith(
        listOffset: index,
        listDone: true,
        totalCount: files.length,
        skippedCount: skipped,
      ),
    );
    _active = await _store.findRun(run.id);
    notifyListeners();
    if (files.isEmpty) {
      await _finish((await _store.findRun(run.id))!, empty: true);
      return false;
    }
    return true;
  }

  /// 已入队过的路径返回 false，调用方记为跳过。
  Future<bool> _enqueue(
    CategoryDownloadRun run,
    FileEntry entry,
    Set<String> known,
  ) async {
    final key = '${entry.rootId}|${entry.relativePath}';
    if (!known.add(key)) return false;
    final taskId = await _transfers.enqueueDownload(
      peerFingerprint: run.peerFingerprint,
      rootId: entry.rootId,
      relativePath: entry.relativePath,
      fileName: entry.name,
      sizeBytes: entry.sizeBytes,
    );
    await _store.insertItem(
      CategoryDownloadItem(
        id: _newId('item'),
        runId: run.id,
        taskId: taskId,
        remoteKey: key,
        status: 'queued',
      ),
    );
    return true;
  }

  Future<Set<String>> _knownKeys(String runId) async {
    final items = await _store.listItems(runId);
    return {for (final item in items) item.remoteKey};
  }

  Future<int> _openCount(String runId) async {
    final items = await _store.listItems(runId);
    return items.where((item) => item.status == 'queued').length;
  }

  Future<void> _syncItems(CategoryDownloadRun run) async {
    final tasks = await _tasks();
    final items = await _store.listItems(run.id);
    var success = 0;
    var failed = 0;
    for (final item in items) {
      var status = item.status;
      if (status == 'queued') {
        final task = await tasks.findById(item.taskId);
        if (task == null || task.state == TransferTaskState.failed) {
          status = 'failed';
        } else if (task.state == TransferTaskState.done) {
          status = 'done';
        } else if (task.state == TransferTaskState.cancelled ||
            task.state == TransferTaskState.expired) {
          status = 'cancelled';
        }
        if (status != 'queued') {
          await _store.updateItemStatus(item.id, status);
        }
      }
      if (status == 'done') success++;
      if (status == 'failed') failed++;
    }
    final next = run.copyWith(successCount: success, failedCount: failed);
    await _store.upsertRun(next);
    if (_active?.id == run.id) {
      _active = next;
      notifyListeners();
    }
  }

  Future<void> _pause(CategoryDownloadRun run, String reason) async {
    final next = run.copyWith(
      status: CategoryDownloadStatus.paused,
      errorMessage: reason,
    );
    await _store.upsertRun(next);
    _active = next;
    notifyListeners();
  }

  Future<void> _finish(CategoryDownloadRun run, {bool empty = false}) async {
    await _syncItems(run);
    final latest = await _store.findRun(run.id);
    if (latest == null) return;
    final status = latest.failedCount > 0
        ? CategoryDownloadStatus.failed
        : CategoryDownloadStatus.success;
    final ended = latest.copyWith(
      status: status,
      listDone: true,
      endedAtMs: DateTime.now().millisecondsSinceEpoch,
      errorMessage: empty
          ? '没有可下载的文件'
          : (status == CategoryDownloadStatus.failed ? '部分文件失败' : null),
      clearError: !empty && status == CategoryDownloadStatus.success,
    );
    await _store.upsertRun(ended);
    _active = null;
    notifyListeners();
  }
}
