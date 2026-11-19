import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../../core/common/app_exception.dart';
import '../../../core/common/app_logger.dart';
import '../../../core/network/peer_api_client.dart';
import '../../../core/realtime/realtime_connection_registry.dart';
import '../../../core/realtime/realtime_event.dart';
import '../../../core/realtime/realtime_session_service.dart';
import '../../../core/storage/incomplete_file.dart';
import '../../../core/storage/share_writer.dart';
import '../../../core/storage/share_receive_paths.dart';
import '../../../core/task/sha256_stream_calculator.dart';
import '../../../core/task/transfer_task.dart';
import '../../../core/task/transfer_task_store.dart';
import '../../../core/transfer/transfer_keep_alive.dart';
import '../data/repositories/chat_repository.dart';
import '../domain/entities/chat_message.dart';
import 'chat_offer_media_cache.dart';
import 'chat_offer_poster.dart';

/// 默认报价 TTL（24h）。
const offerTtl = Duration(hours: 24);

/// 互传编排：发文件报价 / 同步 pending / 确认下载 / 回执。
class OfferAcceptService {
  OfferAcceptService({
    required TransferTaskStore taskStore,
    required ChatRepository chatRepository,
    required PeerApiClient peerApiClient,
    required ShareWriter shareWriter,
    required RealtimeSessionService session,
    required RealtimeConnectionRegistry hubRegistry,
    required Future<bool> Function(String peerFingerprint) ensurePeerWs,
    void Function(String peerFingerprint)? onInboundChatActivity,
    Sha256StreamCalculator sha256 = const Sha256StreamCalculator(),
    ChatOfferPoster? poster,
    Future<void> Function()? onOutboxChanged,
  })  : _tasks = taskStore,
        _chat = chatRepository,
        _api = peerApiClient,
        _writer = shareWriter,
        _session = session,
        _hub = hubRegistry,
        _ensurePeerWs = ensurePeerWs,
        _onInboundChatActivity = onInboundChatActivity,
        _sha256 = sha256,
        _poster = poster ?? ChatOfferPoster(),
        _onOutboxChanged = onOutboxChanged;

  final TransferTaskStore _tasks;
  final ChatRepository _chat;
  final PeerApiClient _api;
  final ShareWriter _writer;
  final RealtimeSessionService _session;
  final RealtimeConnectionRegistry _hub;
  final Future<bool> Function(String peerFingerprint) _ensurePeerWs;
  final void Function(String peerFingerprint)? _onInboundChatActivity;
  final Sha256StreamCalculator _sha256;
  final ChatOfferPoster _poster;
  final Future<void> Function()? _onOutboxChanged;

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  StreamSubscription<RealtimeEvent>? _sessionEventsSub;
  bool _sessionEventsAttached = false;

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _markUnread(String peerFingerprint) {
    _onInboundChatActivity?.call(peerFingerprint);
  }

  /// 全局监听出站 session 上的 chat/offer（与 hub onEvent 对称）。
  ///
  /// 文件页共用同一条 WS 时也能入库；勿再在 Page/Cubit 里重复订阅。
  void attachSessionEvents() {
    if (_sessionEventsAttached) return;
    _sessionEventsAttached = true;
    _sessionEventsSub = _session.events.listen((event) {
      final fp = _session.connectedPeer;
      if (fp == null || fp.isEmpty) return;
      switch (event.type) {
        case RealtimeEventType.chat:
        case RealtimeEventType.offer:
        case RealtimeEventType.accept:
        case RealtimeEventType.receipt:
          unawaited(handleInboundEvent(fp, event));
          return;
        case RealtimeEventType.ping:
        case RealtimeEventType.pong:
        case RealtimeEventType.peerStatus:
        case RealtimeEventType.peerStatusGet:
        case RealtimeEventType.unknown:
          return;
      }
    });
  }

  Future<void> detachSessionEvents() async {
    await _sessionEventsSub?.cancel();
    _sessionEventsSub = null;
    _sessionEventsAttached = false;
  }

  String _newId(String prefix) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final r = Random().nextInt(0xFFFFFF).toRadixString(16);
    return '${prefix}_${now}_$r';
  }

  /// 选文件 → 创建本机 offer 任务 + 出站聊天行 → 尽量推送给对端。
  ///
  /// 不在发送前整文件 hash（OTG 友好）；完整提供 payload 时流式算摘要。
  Future<List<TransferTask>> sendFiles({
    required String peerFingerprint,
    required List<File> files,
  }) async {
    final created = <TransferTask>[];
    for (final file in files) {
      if (!await file.exists()) continue;
      final size = await file.length();
      final id = _newId('offer');
      final now = DateTime.now().millisecondsSinceEpoch;
      final task = TransferTask(
        id: id,
        type: TransferTaskType.p2pOffer,
        state: TransferTaskState.offered,
        peerFingerprint: peerFingerprint,
        fileName: p.basename(file.path),
        sizeBytes: size,
        createdAtMs: now,
        updatedAtMs: now,
        localPath: file.path,
        ttlExpireAtMs: now + offerTtl.inMilliseconds,
      );
      await _tasks.upsert(task);
      await _chat.save(
        ChatMessage(
          id: _newId('msg'),
          peerFingerprint: peerFingerprint,
          direction: ChatDirection.outbound,
          kind: ChatMessageKind.offer,
          body: id,
          createdAtMs: now,
        ),
      );
      created.add(task);

      final event = RealtimeEvent.create(
        type: RealtimeEventType.offer,
        id: id,
        payload: {
          'taskId': id,
          'fileName': task.fileName,
          'sizeBytes': task.sizeBytes,
          'ttlExpireAtMs': task.ttlExpireAtMs,
        },
      );
      // 优先：本机 hub 上已有对端连入；其次主动拨号推送。
      final pushed = _hub.sendTo(peerFingerprint, event);
      if (!pushed) {
        final ok = await _ensurePeerWs(peerFingerprint);
        if (ok) await _session.send(event);
      }

      unawaited(
        _poster.ensureLocalPoster(task: task).then((_) => _notify()),
      );
    }
    await _onOutboxChanged?.call();
    _notify();
    return created;
  }

  /// 发送文字。
  Future<ChatMessage> sendText({
    required String peerFingerprint,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const AppException(code: 'empty', message: '消息为空');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final msg = ChatMessage(
      id: _newId('msg'),
      peerFingerprint: peerFingerprint,
      direction: ChatDirection.outbound,
      kind: ChatMessageKind.text,
      body: trimmed,
      createdAtMs: now,
    );
    await _chat.save(msg);

    final event = RealtimeEvent.create(
      type: RealtimeEventType.chat,
      payload: {'messageId': msg.id, 'text': trimmed},
    );
    final pushed = _hub.sendTo(peerFingerprint, event);
    if (!pushed) {
      final ok = await _ensurePeerWs(peerFingerprint);
      if (ok) await _session.send(event);
    }
    // HTTP 兜底：对端未在线 WS 时仍落对方库
    await _api.post(
      peerFingerprint,
      '/api/v1/chat',
      body: {
        'id': msg.id,
        'text': trimmed,
        'createdAtMs': now,
      },
    );
    _notify();
    return msg;
  }

  /// 从对端拉取 pending offers，写入本机 inbound 任务与聊天行。
  Future<int> syncPendingFromPeer(String peerFingerprint) async {
    final response = await _api.get(
      peerFingerprint,
      '/api/v1/transfer/pending',
    );
    if (response == null || response.data is! Map) return 0;
    final items = (response.data as Map)['items'] as List? ?? const [];
    var added = 0;
    for (final raw in items) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final id = map['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final existing = await _tasks.findById(id);
      if (existing != null) continue;
      final now = DateTime.now().millisecondsSinceEpoch;
      final task = TransferTask(
        id: id,
        type: TransferTaskType.p2pDownload,
        state: TransferTaskState.offered,
        peerFingerprint: peerFingerprint,
        fileName: map['fileName'] as String? ?? 'file',
        sizeBytes: map['sizeBytes'] as int? ?? 0,
        createdAtMs: map['createdAtMs'] as int? ?? now,
        updatedAtMs: now,
        sha256Hex: map['sha256'] as String?,
        ttlExpireAtMs: map['ttlExpireAtMs'] as int?,
      );
      await _tasks.upsert(task);
      await _chat.save(
        ChatMessage(
          id: _newId('msg'),
          peerFingerprint: peerFingerprint,
          direction: ChatDirection.inbound,
          kind: ChatMessageKind.offer,
          body: id,
          createdAtMs: task.createdAtMs,
        ),
      );
      added++;
    }
    if (added > 0) {
      _markUnread(peerFingerprint);
      _notify();
    }
    return added;
  }

  /// 处理入站 realtime 事件（hub / session）。
  Future<void> handleInboundEvent(
    String peerFingerprint,
    RealtimeEvent event,
  ) async {
    switch (event.type) {
      case RealtimeEventType.chat:
        final text = event.payload['text'] as String? ?? '';
        final id = event.payload['messageId'] as String? ?? event.id;
        if (text.isEmpty) return;
        final existing = await _chat.findById(id);
        if (existing != null) return;
        await _chat.save(
          ChatMessage(
            id: id,
            peerFingerprint: peerFingerprint,
            direction: ChatDirection.inbound,
            kind: ChatMessageKind.text,
            body: text,
            createdAtMs: event.timestampMs,
          ),
        );
        _markUnread(peerFingerprint);
        _notify();
        return;
      case RealtimeEventType.offer:
        await _ingestRemoteOffer(peerFingerprint, event.payload);
        return;
      case RealtimeEventType.accept:
        final taskId = event.payload['taskId'] as String?;
        if (taskId == null) return;
        await _tasks.updateState(taskId, TransferTaskState.accepted);
        _notify();
        return;
      case RealtimeEventType.receipt:
        final taskId = event.payload['taskId'] as String?;
        if (taskId == null) return;
        await onReceiptHttp(
          fromPeer: peerFingerprint,
          taskId: taskId,
          ok: event.payload['ok'] as bool? ?? false,
          error: event.payload['error'] as String?,
          sha256: event.payload['sha256'] as String?,
        );
        return;
      case RealtimeEventType.ping:
      case RealtimeEventType.pong:
      case RealtimeEventType.peerStatus:
      case RealtimeEventType.peerStatusGet:
      case RealtimeEventType.unknown:
        return;
    }
  }

  Future<void> _ingestRemoteOffer(
    String peerFingerprint,
    Map<String, dynamic> payload,
  ) async {
    final id = payload['taskId'] as String?;
    if (id == null) return;
    if (await _tasks.findById(id) != null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final task = TransferTask(
      id: id,
      type: TransferTaskType.p2pDownload,
      state: TransferTaskState.offered,
      peerFingerprint: peerFingerprint,
      fileName: payload['fileName'] as String? ?? 'file',
      sizeBytes: payload['sizeBytes'] as int? ?? 0,
      createdAtMs: now,
      updatedAtMs: now,
      sha256Hex: payload['sha256'] as String?,
      ttlExpireAtMs: payload['ttlExpireAtMs'] as int?,
    );
    await _tasks.upsert(task);
    await _chat.save(
      ChatMessage(
        id: _newId('msg'),
        peerFingerprint: peerFingerprint,
        direction: ChatDirection.inbound,
        kind: ChatMessageKind.offer,
        body: id,
        createdAtMs: now,
      ),
    );
    _markUnread(peerFingerprint);
    _notify();
    // 发送方 poster 异步生成：入站后预拉，避免气泡一试 404 后永久占位。
    if (ChatOfferPoster.isPosterFileName(task.fileName)) {
      unawaited(
        _poster.ensureRemotePoster(task).then((_) => _notify()),
      );
    }
  }

  /// 接收方确认：流式下载原件 → 落盘 → 校验 → 回执。
  ///
  /// 确认下载：整文件拉取；中断/失败删除未完成文件（不做单文件断点续传）。
  Future<void> acceptOffer(String taskId) async {
    final task = await _tasks.findById(taskId);
    if (task == null) {
      throw const AppException(code: 'not_found', message: '报价不存在');
    }
    // 失败后可重试：整文件重拉（不续传半成品）。
    final retryable = task.state == TransferTaskState.failed ||
        task.state == TransferTaskState.transferring ||
        task.state == TransferTaskState.accepted;
    if (task.state != TransferTaskState.offered &&
        task.state != TransferTaskState.accepted &&
        !retryable) {
      throw const AppException(code: 'bad_state', message: '报价状态不可确认');
    }
    final ttl = task.ttlExpireAtMs;
    if (ttl != null && DateTime.now().millisecondsSinceEpoch > ttl) {
      await _tasks.updateState(taskId, TransferTaskState.expired);
      _notify();
      throw const AppException(code: 'expired', message: '报价已过期');
    }

    // 重试前清掉上次残留半成品。
    await discardIncompleteFile(task.localPath);

    await _tasks.updateState(taskId, TransferTaskState.transferring);
    _notify();
    await TransferKeepAlive.start(
      title: '文件传输中',
      text: task.fileName,
    );

    // 通知发送方：已确认开始拉原件（WS accept；HTTP 回执仍以 receipt 为准）
    final acceptEvt = RealtimeEvent.create(
      type: RealtimeEventType.accept,
      payload: {'taskId': taskId},
    );
    _hub.sendTo(task.peerFingerprint, acceptEvt);
    unawaited(() async {
      final ok = await _ensurePeerWs(task.peerFingerprint);
      if (ok) await _session.send(acceptEvt);
    }());

    String? destPath;
    try {
      // 已看过原图进缓存：晋升公共库，禁止二次全量拉取（综合策略 §5.2）。
      final cachedPath = await ChatOfferMediaCache().cachedPathIfReady(task);
      if (cachedPath != null) {
        await _promoteCachedOffer(
          task: task,
          cachedPath: cachedPath,
        );
        return;
      }

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
      await _tasks.updateState(
        taskId,
        TransferTaskState.transferring,
        localPath: destPath,
        bytesTransferred: 0,
      );

      final dest = File(destPath);
      final acc = _sha256.accumulator();
      var lastReported = 0;
      final downloaded = await _api.downloadToFile(
        task.peerFingerprint,
        '/api/v1/transfer/payload',
        destFile: dest,
        query: {'id': taskId},
        onChunk: acc.add,
        onBytes: (n) {
          if (n - lastReported >= 256 * 1024) {
            lastReported = n;
            unawaited(
              _tasks.updateState(
                taskId,
                TransferTaskState.transferring,
                bytesTransferred: n,
                localPath: destPath,
              ),
            );
            _notify();
          }
        },
      );
      if (downloaded == null) {
        throw const AppException(code: 'download', message: '下载失败');
      }
      final digest = acc.finish();
      await _finishDownload(
        task: task,
        dest: dest,
        downloaded: downloaded,
        digest: digest,
      );
    } catch (e, st) {
      AppLogger.log(
        'accept failed: $e',
        scope: 'transfer',
        error: e,
        stackTrace: st,
      );
      await discardIncompleteFile(destPath);
      await _tasks.updateState(
        taskId,
        TransferTaskState.failed,
        errorMessage: e.toString(),
        bytesTransferred: 0,
        localPath: '',
      );
      final receipt = RealtimeEvent.create(
        type: RealtimeEventType.receipt,
        payload: {'taskId': taskId, 'ok': false, 'error': e.toString()},
      );
      await _api.post(
        task.peerFingerprint,
        '/api/v1/transfer/receipt',
        body: {'taskId': taskId, 'ok': false, 'error': e.toString()},
      );
      _hub.sendTo(task.peerFingerprint, receipt);
      _notify();
      rethrow;
    } finally {
      await TransferKeepAlive.stop();
    }
  }

  Future<void> _finishDownload({
    required TransferTask task,
    required File dest,
    required int downloaded,
    required String digest,
  }) async {
    if (task.sizeBytes > 0 && downloaded != task.sizeBytes) {
      throw AppException(
        code: 'size',
        message: '大小不符（$downloaded / ${task.sizeBytes}）',
      );
    }
    final expected = task.sha256Hex;
    if (expected != null && expected.isNotEmpty && digest != expected) {
      throw const AppException(code: 'checksum', message: '校验失败');
    }

    await _tasks.updateState(
      task.id,
      TransferTaskState.done,
      bytesTransferred: downloaded,
      localPath: dest.path,
      sha256Hex: digest,
    );

    final receipt = RealtimeEvent.create(
      type: RealtimeEventType.receipt,
      payload: {
        'taskId': task.id,
        'ok': true,
        'sha256': digest,
      },
    );
    _hub.sendTo(task.peerFingerprint, receipt);
    await _ensurePeerWs(task.peerFingerprint);
    await _session.send(receipt);
    await _api.post(
      task.peerFingerprint,
      '/api/v1/transfer/receipt',
      body: {'taskId': task.id, 'ok': true, 'sha256': digest},
    );
    await _discardChatPreviewCaches(task.id);
    _notify();
  }

  Future<void> _discardChatPreviewCaches(String taskId) async {
    try {
      await ChatOfferMediaCache().discard(taskId);
    } catch (_) {}
    try {
      await _poster.discard(taskId);
    } catch (_) {}
  }

  /// 缓存原图晋升到项目公共存储并回执（不再次走 payload）。
  Future<void> _promoteCachedOffer({
    required TransferTask task,
    required String cachedPath,
  }) async {
    final src = File(cachedPath);
    if (!await src.exists()) {
      throw const AppException(code: 'cache_miss', message: '缓存已失效');
    }
    final digest = await _sha256.hashFile(src);
    if (task.sha256Hex != null &&
        task.sha256Hex!.isNotEmpty &&
        digest != task.sha256Hex) {
      throw const AppException(code: 'checksum', message: '校验失败');
    }

    String? destPath;
    late final int len;
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
      await src.copy(dest.path);
      len = await dest.length();
      if (len <= 0) {
        throw const AppException(code: 'empty', message: '晋升文件为空');
      }
      await _tasks.updateState(
        task.id,
        TransferTaskState.done,
        bytesTransferred: len,
        localPath: dest.path,
        sha256Hex: digest,
      );
    } catch (_) {
      await discardIncompleteFile(destPath);
      rethrow;
    }

    final receipt = RealtimeEvent.create(
      type: RealtimeEventType.receipt,
      payload: {
        'taskId': task.id,
        'ok': true,
        'sha256': digest,
      },
    );
    _hub.sendTo(task.peerFingerprint, receipt);
    await _ensurePeerWs(task.peerFingerprint);
    await _session.send(receipt);
    await _api.post(
      task.peerFingerprint,
      '/api/v1/transfer/receipt',
      body: {'taskId': task.id, 'ok': true, 'sha256': digest},
    );
    await _discardChatPreviewCaches(task.id);
    _notify();
  }

  /// 本机作为发送方：对端回执 HTTP / WS 入口。
  Future<void> onReceiptHttp({
    required String fromPeer,
    required String taskId,
    required bool ok,
    String? error,
    String? sha256,
  }) async {
    final task = await _tasks.findById(taskId);
    if (task == null) return;
    if (task.peerFingerprint != fromPeer) return;

    var finalOk = ok;
    String? finalError = error;
    if (finalOk && sha256 != null && sha256.isNotEmpty) {
      var expected = task.sha256Hex;
      if (expected == null || expected.isEmpty) {
        final path = task.localPath;
        if (path != null && path.isNotEmpty && await File(path).exists()) {
          expected = await _sha256.hashFile(File(path));
          await _tasks.updateSha256Hex(taskId, expected);
        }
      }
      if (expected != null &&
          expected.isNotEmpty &&
          expected != sha256) {
        finalOk = false;
        finalError = '校验失败';
      } else if (expected == null || expected.isEmpty) {
        await _tasks.updateSha256Hex(taskId, sha256);
      }
    }

    await _tasks.updateState(
      taskId,
      finalOk ? TransferTaskState.done : TransferTaskState.failed,
      errorMessage: finalError,
      sha256Hex: finalOk ? sha256 : null,
    );
    await _onOutboxChanged?.call();
    _notify();
  }

  /// 本机作为接收方：对端 POST 聊天落库。
  Future<void> onChatHttp({
    required String fromPeer,
    required String id,
    required String text,
    required int createdAtMs,
  }) async {
    if (await _chat.findById(id) != null) return;
    await _chat.save(
      ChatMessage(
        id: id,
        peerFingerprint: fromPeer,
        direction: ChatDirection.inbound,
        kind: ChatMessageKind.text,
        body: text,
        createdAtMs: createdAtMs,
      ),
    );
    _markUnread(fromPeer);
    _notify();
  }

  /// TTL 清扫：过期 offered → expired。
  Future<int> expireOffers() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final offers = await _tasks.listOffers(state: TransferTaskState.offered);
    var n = 0;
    for (final t in offers) {
      final ttl = t.ttlExpireAtMs;
      if (ttl != null && now > ttl) {
        await _tasks.updateState(t.id, TransferTaskState.expired);
        n++;
      }
    }
    if (n > 0) {
      await _onOutboxChanged?.call();
      _notify();
    }
    return n;
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}
