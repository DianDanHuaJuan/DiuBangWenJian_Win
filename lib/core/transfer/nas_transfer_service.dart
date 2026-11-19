import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../common/app_exception.dart';
import '../common/app_logger.dart';
import '../network/peer_api_client.dart';
import '../protocol/nas_api_paths.dart';
import '../storage/incomplete_file.dart';
import '../storage/share_receive_paths.dart';
import '../storage/share_writer.dart';
import '../task/transfer_task.dart';
import '../task/transfer_task_store.dart';
import 'stream_transfer_tuning.dart';
import 'transfer_keep_alive.dart';

/// NAS 上传 / 下载任务编排（阶段 F）。
///
/// 上下行串行（[_maxConcurrent]=1）；传输中无字节进展超过
/// [StreamTransferTuning.midTransferIdleTimeout] 则取消并跳下一件。
/// 发完等响应不再用发送空闲看门狗（见 [_IdleWatchdog.releaseForResponse]）。
/// 底栏 / 上传条只认本进程 [liveTaskIds]；库表仅作持久化，冷启动会一刀切收尾非终态 NAS 任务。
class NasTransferService {
  NasTransferService({
    required Future<TransferTaskStore> Function() tasks,
    required PeerApiClient api,
    required ShareWriter writer,
  })  : _tasksFn = tasks,
        _api = api,
        _writer = writer;

  final Future<TransferTaskStore> Function() _tasksFn;
  final PeerApiClient _api;
  final ShareWriter _writer;

  final List<void Function()> _listeners = [];

  Future<TransferTaskStore> get _tasks => _tasksFn();

  /// NAS 上下行串行：单 peer 更稳；卡死靠空闲看门狗取消后跳下一件。
  static const _maxConcurrent = 1;
  int _active = 0;
  final List<String> _pendingIds = [];
  final Set<String> _runningIds = {};
  final Map<String, int> _liveBytes = {};
  var _coldStartDone = false;
  Future<void>? _coldStartFuture;

  /// 当前这一波下载成败 / 计划数（底栏批次文案与进度）。
  var _batchDlOk = 0;
  var _batchDlFail = 0;
  var _batchDlPlanned = 0;
  var _batchUlOk = 0;
  var _batchUlFail = 0;
  var _batchUlPlanned = 0;

  /// 本进程正在排队或执行的任务 id（底栏唯一数据源）。
  List<String> get liveTaskIds => [..._runningIds, ..._pendingIds];

  bool get hasLiveTasks => _runningIds.isNotEmpty || _pendingIds.isNotEmpty;

  Map<String, Object?> batchDownloadStats() => {
        'ok': _batchDlOk,
        'fail': _batchDlFail,
        'planned': _batchDlPlanned,
      };

  Map<String, Object?> batchUploadStats() => {
        'ok': _batchUlOk,
        'fail': _batchUlFail,
        'planned': _batchUlPlanned,
      };

  void _noteDlOk() => _batchDlOk++;

  void _noteDlFail() => _batchDlFail++;

  void _noteUlOk() => _batchUlOk++;

  void _noteUlFail() => _batchUlFail++;

  void addListener(void Function() listener) {
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void _notify() {
    for (final cb in List<void Function()>.of(_listeners)) {
      cb();
    }
  }

  /// 冷启动一次性：库内残留的 NAS 上下载非终态全部标失败，避免底栏/列表挂尸。
  Future<void> ensureColdStartCleanup() {
    return _coldStartFuture ??= () async {
      if (_coldStartDone) return;
      _coldStartDone = true;
      try {
        final n = await (await _tasks).abandonInFlightNasTransfers();
        if (n > 0) _notify();
      } catch (_) {}
    }();
  }

  /// 供 UI 读取：live 任务 + 内存进度覆盖。
  Future<List<TransferTask>> snapshotLiveTasks() async {
    await ensureColdStartCleanup();
    final store = await _tasks;
    final out = <TransferTask>[];
    for (final id in liveTaskIds) {
      final task = await store.findById(id);
      if (task == null || task.isTerminal) continue;
      final bytes = _liveBytes[id];
      out.add(
        bytes == null || bytes == task.bytesTransferred
            ? task
            : task.copyWith(bytesTransferred: bytes),
      );
    }
    return out;
  }

  String _newId(String prefix) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final r = Random().nextInt(0xFFFFFF).toRadixString(16);
    return '${prefix}_${now}_$r';
  }

  static String encodeRemotePath({
    required String rootId,
    required String relativePath,
  }) =>
      jsonEncode({'rootId': rootId, 'path': relativePath});

  static ({String rootId, String path})? decodeRemotePath(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final rootId = m['rootId'] as String? ?? '';
      final path = m['path'] as String? ?? '';
      if (rootId.isEmpty || path.isEmpty) return null;
      return (rootId: rootId, path: path);
    } catch (_) {
      return null;
    }
  }

  /// 从对端下载到本机共享根。
  Future<String> enqueueDownload({
    required String peerFingerprint,
    required String rootId,
    required String relativePath,
    required String fileName,
    int sizeBytes = 0,
  }) async {
    await ensureColdStartCleanup();
    final id = _newId('nasdl');
    final now = DateTime.now().millisecondsSinceEpoch;
    final task = TransferTask(
      id: id,
      type: TransferTaskType.nasDownload,
      state: TransferTaskState.accepted,
      peerFingerprint: peerFingerprint,
      fileName: fileName,
      sizeBytes: sizeBytes,
      createdAtMs: now,
      updatedAtMs: now,
      remotePath: encodeRemotePath(rootId: rootId, relativePath: relativePath),
    );
    await (await _tasks).upsert(task);
    _schedule(id, download: true);
    return id;
  }

  /// 上传本机文件到对端共享根。
  Future<String> enqueueUpload({
    required String peerFingerprint,
    required String localPath,
    required String fileName,
    int sizeBytes = 0,
    String? rootId,
    String directory = '',
  }) async {
    await ensureColdStartCleanup();
    final id = _newId('nasul');
    final now = DateTime.now().millisecondsSinceEpoch;
    final task = TransferTask(
      id: id,
      type: TransferTaskType.nasUpload,
      state: TransferTaskState.accepted,
      peerFingerprint: peerFingerprint,
      fileName: fileName,
      sizeBytes: sizeBytes,
      createdAtMs: now,
      updatedAtMs: now,
      localPath: localPath,
      remotePath: rootId == null || rootId.isEmpty
          ? null
          : jsonEncode({
              'rootId': rootId,
              'dir': directory,
            }),
    );
    await (await _tasks).upsert(task);
    _schedule(id, download: false);
    return id;
  }

  void _schedule(String id, {required bool download}) {
    final startingBatch = _pendingIds.isEmpty && _runningIds.isEmpty;
    if (startingBatch) {
      _batchDlOk = 0;
      _batchDlFail = 0;
      _batchDlPlanned = 0;
      _batchUlOk = 0;
      _batchUlFail = 0;
      _batchUlPlanned = 0;
    }
    if (download) {
      _batchDlPlanned++;
    } else {
      _batchUlPlanned++;
    }
    _pendingIds.add(id);
    _notify();
    _pump();
  }

  void _pump() {
    while (_active < _maxConcurrent && _pendingIds.isNotEmpty) {
      final id = _pendingIds.removeAt(0);
      _runningIds.add(id);
      _active++;
      _notify();
      unawaited(() async {
        try {
          await _run(id);
        } finally {
          _runningIds.remove(id);
          _liveBytes.remove(id);
          _active--;
          _notify();
          _pump();
        }
      }());
    }
  }

  Future<void> _run(String id) async {
    final task = await (await _tasks).findById(id);
    if (task == null || task.isTerminal) return;
    if (task.type == TransferTaskType.nasDownload) {
      await _runDownload(task);
    } else if (task.type == TransferTaskType.nasUpload) {
      await _runUpload(task);
    }
  }

  Future<void> _runDownload(TransferTask task) async {
    final store = await _tasks;
    final latest = await store.findById(task.id);
    if (latest == null || latest.isTerminal) return;
    final remote = decodeRemotePath(task.remotePath);
    if (remote == null) {
      await store.updateState(
        task.id,
        TransferTaskState.failed,
        errorMessage: '无效远程路径',
      );
      _noteDlFail();
      _notify();
      return;
    }

    await discardIncompleteFile(task.localPath);
    await store.updateState(task.id, TransferTaskState.transferring);
    _notify();
    await TransferKeepAlive.start(title: '正在下载', text: task.fileName);

    String? destPath;
    try {
      final root = await _writer.rootStore.ensureCurrent();
      final opened = await _writer.openWriteSink(
        preferredFileName: task.fileName,
        expectedLength: task.sizeBytes > 0 ? task.sizeBytes : null,
        relativeDir: ShareReceivePaths.relativeDirForReceive(
          root: root,
          fileName: task.fileName,
        ),
      );
      await opened.sink.close();
      destPath = opened.result.absolutePath;
      final dest = File(destPath);
      await store.updateState(
        task.id,
        TransferTaskState.transferring,
        localPath: dest.path,
        bytesTransferred: 0,
      );
      _liveBytes[task.id] = 0;
      _notify();

      final cancel = CancelToken();
      final idle = _IdleWatchdog(
        timeout: StreamTransferTuning.midTransferIdleTimeout,
        onIdle: () {
          if (!cancel.isCancelled) cancel.cancel('idle_timeout');
        },
      );
      final progress = StreamTransferTuning.downloadProgressThrottler();
      idle.touch();
      late final int? downloaded;
      try {
        downloaded = await _api.downloadToFile(
          task.peerFingerprint,
          NasApiPaths.filesContent,
          destFile: dest,
          cancelToken: cancel,
          query: {
            'rootId': remote.rootId,
            'path': remote.path,
          },
          onBytes: (n) {
            idle.touch();
            progress.reportValue(
              n,
              totalBytes: task.sizeBytes,
              onProgress: (reported) {
                _liveBytes[task.id] = reported;
                _notify();
                unawaited(
                  store.updateState(
                    task.id,
                    TransferTaskState.transferring,
                    bytesTransferred: reported,
                    localPath: dest.path,
                  ),
                );
              },
            );
          },
        );
      } finally {
        idle.dispose();
      }
      if (downloaded == null) {
        throw const AppException(code: 'download', message: '下载失败');
      }
      progress.completeValue(
        transferredBytes: downloaded,
        onProgress: (n) {
          _liveBytes[task.id] = n;
          _notify();
        },
      );
      _liveBytes[task.id] = downloaded;
      await store.updateState(
        task.id,
        TransferTaskState.done,
        bytesTransferred: downloaded,
        localPath: dest.path,
      );
      _noteDlOk();
      _notify();
    } catch (e) {
      AppLogger.log('nas download failed: $e', scope: 'nas');
      _noteDlFail();
      await discardIncompleteFile(destPath);
      await store.updateState(
        task.id,
        TransferTaskState.failed,
        errorMessage: '$e',
        bytesTransferred: 0,
        localPath: '',
      );
      _notify();
    } finally {
      await TransferKeepAlive.stop();
    }
  }

  ({String rootId, String dir})? _uploadTarget(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final rootId = map['rootId'] as String? ?? '';
      if (rootId.isEmpty) return null;
      return (rootId: rootId, dir: map['dir'] as String? ?? '');
    } catch (_) {
      return null;
    }
  }

  Future<void> _runUpload(TransferTask task) async {
    final store = await _tasks;
    final local = task.localPath;
    if (local == null || local.isEmpty) {
      await store.updateState(
        task.id,
        TransferTaskState.failed,
        errorMessage: '缺少本地路径',
      );
      _noteUlFail();
      _notify();
      return;
    }
    final file = File(local);
    if (!await file.exists()) {
      await store.updateState(
        task.id,
        TransferTaskState.failed,
        errorMessage: '本地文件不存在',
      );
      _noteUlFail();
      _notify();
      return;
    }

    await store.updateState(task.id, TransferTaskState.transferring);
    _liveBytes[task.id] = 0;
    _notify();
    await TransferKeepAlive.start(title: '正在上传', text: task.fileName);

    try {
      final length = await file.length();
      await store.updateState(
        task.id,
        TransferTaskState.transferring,
        bytesTransferred: 0,
      );
      final placed = _uploadTarget(task.remotePath);
      final cancel = CancelToken();
      final idle = _IdleWatchdog(
        timeout: StreamTransferTuning.midTransferIdleTimeout,
        onIdle: () {
          if (!cancel.isCancelled) cancel.cancel('idle_timeout');
        },
      );
      final progress = StreamTransferTuning.uploadProgressThrottler();
      idle.touch();
      late final PeerApiResponse? response;
      try {
        response = await _api.putStream(
          task.peerFingerprint,
          NasApiPaths.filesUpload,
          stream: StreamTransferTuning.bufferUploadStream(file.openRead()),
          contentLength: length,
          cancelToken: cancel,
          query: {
            'name': p.basename(task.fileName),
            if (placed != null) 'rootId': placed.rootId,
            if (placed != null) 'dir': placed.dir,
          },
          onSendProgress: (sent, total) {
            idle.touch();
            if (total > 0 && sent >= total) {
              // 发完后等对端写盘回包：停止发送空闲看门狗，交给 Dio receiveTimeout。
              idle.releaseForResponse();
            }
            progress.reportValue(
              sent,
              totalBytes: total,
              onProgress: (reported) {
                _liveBytes[task.id] = reported;
                _notify();
              },
            );
          },
        );
      } finally {
        idle.dispose();
      }
      if (response == null) {
        throw const AppException(code: 'upload', message: '上传失败');
      }
      progress.completeValue(
        transferredBytes: length,
        onProgress: (n) {
          _liveBytes[task.id] = n;
          _notify();
        },
      );
      _liveBytes[task.id] = length;
      await store.updateState(
        task.id,
        TransferTaskState.done,
        bytesTransferred: length,
      );
      _noteUlOk();
      _notify();
    } catch (e) {
      AppLogger.log('nas upload failed: $e', scope: 'nas');
      _noteUlFail();
      await store.updateState(
        task.id,
        TransferTaskState.failed,
        errorMessage: '$e',
      );
      _notify();
    } finally {
      await TransferKeepAlive.stop();
    }
  }
}

/// 进度空闲看门狗：有进展就重置；超时回调里应 cancel 请求。
///
/// [releaseForResponse]：发送已完成，不再用「无发送进度」判定卡死。
class _IdleWatchdog {
  _IdleWatchdog({
    required this.timeout,
    required this.onIdle,
  });

  final Duration timeout;
  final void Function() onIdle;
  Timer? _timer;
  var _awaitingResponse = false;

  void touch() {
    if (_awaitingResponse) return;
    _timer?.cancel();
    _timer = Timer(timeout, onIdle);
  }

  void releaseForResponse() {
    _awaitingResponse = true;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
