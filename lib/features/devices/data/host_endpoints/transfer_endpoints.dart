import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import '../../../../core/auth/peer_fingerprint_middleware.dart';
import '../../../../core/identity/device_identity_service.dart';
import '../../../../core/identity/peer.dart';
import '../../../../core/task/sha256_stream_calculator.dart';
import '../../../../core/task/transfer_task.dart';
import '../../../../core/task/transfer_task_store.dart';
import '../../application/chat_offer_poster.dart';
import '../../application/offer_accept_service.dart';

/// GET /api/v1/transfer/pending —— 对端待接收的 offer 列表。
class PendingEndpoint {
  static const path = '/api/v1/transfer/pending';

  PendingEndpoint({required this.taskStore});

  final TransferTaskStore taskStore;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) {
          return Response.unauthorized('peer required');
        }
        final pending = await taskStore.listPendingForPeer(peer.fingerprint);
        return Response.ok(
          jsonEncode({
            'count': pending.length,
            'totalBytes': pending.fold<int>(0, (s, t) => s + t.sizeBytes),
            'items': pending
                .map(
                  (t) => {
                    'id': t.id,
                    'fileName': t.fileName,
                    'sizeBytes': t.sizeBytes,
                    'sha256': t.sha256Hex,
                    'createdAtMs': t.createdAtMs,
                    'ttlExpireAtMs': t.ttlExpireAtMs,
                  },
                )
                .toList(),
          }),
          headers: {'content-type': 'application/json'},
        );
      };
}

/// GET /api/v1/info —— 本机公开资料。
class DeviceInfoEndpoint {
  static const path = '/api/v1/info';

  DeviceInfoEndpoint({
    required this.identityService,
    this.nasEnabled,
  });

  final DeviceIdentityService identityService;

  /// 本机 NAS 是否开启（注入，避免端点反向依赖 ServiceLocator）。
  final bool Function()? nasEnabled;

  Handler get handler => (Request request) async {
        final identity = await identityService.identity;
        final caps = <String>[
          if (nasEnabled?.call() == true) 'nas',
        ];
        return Response.ok(
          jsonEncode({
            'fingerprint': identity.fingerprint,
            'name': identity.deviceName,
            'model': identity.model,
            'caps': caps,
          }),
          headers: {'content-type': 'application/json'},
        );
      };
}

/// GET /api/v1/transfer/poster?id= —— 视频封面 JPEG（小图）。
class PosterEndpoint {
  static const path = '/api/v1/transfer/poster';

  PosterEndpoint({
    required this.taskStore,
    ChatOfferPoster? poster,
  }) : _poster = poster ?? ChatOfferPoster();

  final TransferTaskStore taskStore;
  final ChatOfferPoster _poster;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) {
          return Response.unauthorized('peer required');
        }
        final id = request.url.queryParameters['id'];
        if (id == null || id.isEmpty) {
          return Response.badRequest(body: 'id required');
        }
        final task = await taskStore.findById(id);
        if (task == null ||
            task.type != TransferTaskType.p2pOffer ||
            task.peerFingerprint != peer.fingerprint) {
          return Response.notFound('offer not found');
        }
        final path = await _poster.ensureLocalPoster(task: task);
        if (path == null) {
          return Response.notFound('poster missing');
        }
        final file = File(path);
        return Response.ok(
          file.openRead(),
          headers: {
            'content-type': 'image/jpeg',
            'content-length': '${await file.length()}',
            'cache-control': 'private, max-age=3600',
          },
        );
      };
}

/// GET /api/v1/transfer/payload?id= —— 下载本机持有的 offer 原件。
class PayloadEndpoint {
  static const path = '/api/v1/transfer/payload';

  PayloadEndpoint({required this.taskStore});

  final TransferTaskStore taskStore;
  static const _sha256 = Sha256StreamCalculator();

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) {
          return Response.unauthorized('peer required');
        }
        final id = request.url.queryParameters['id'];
        if (id == null || id.isEmpty) {
          return Response.badRequest(body: 'id required');
        }
        final task = await taskStore.findById(id);
        if (task == null ||
            task.type != TransferTaskType.p2pOffer ||
            task.peerFingerprint != peer.fingerprint) {
          return Response.notFound('offer not found');
        }
        final path = task.localPath;
        if (path == null || path.isEmpty) {
          return Response.notFound('file missing');
        }
        final file = File(path);
        if (!await file.exists()) {
          return Response.notFound('file missing');
        }

        final length = await file.length();
        // 完整顺序读：边读边算 SHA，供回执对齐（不做单文件 Range 续传）。
        final acc = _sha256.accumulator();
        final stream = _hashTeeStream(
          file.openRead(),
          acc,
          onDone: (hex) {
            unawaited(taskStore.updateSha256Hex(id, hex));
          },
        );
        return Response.ok(
          stream,
          headers: {
            'content-type': 'application/octet-stream',
            'content-length': '$length',
            'x-sha256': task.sha256Hex ?? '',
            'x-file-name': Uri.encodeComponent(task.fileName),
          },
        );
      };
}

Stream<List<int>> _hashTeeStream(
  Stream<List<int>> source,
  Sha256Accumulator acc, {
  required void Function(String hex) onDone,
}) async* {
  try {
    await for (final chunk in source) {
      acc.add(chunk);
      yield chunk;
    }
    onDone(acc.finish());
  } catch (e) {
    rethrow;
  }
}

/// POST /api/v1/transfer/receipt —— 接收方回执。
class ReceiptEndpoint {
  static const path = '/api/v1/transfer/receipt';

  ReceiptEndpoint({required this.offerAccept});

  final OfferAcceptService offerAccept;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) {
          return Response.unauthorized('peer required');
        }
        final body = jsonDecode(await request.readAsString()) as Map;
        final taskId = body['taskId'] as String?;
        if (taskId == null) {
          return Response.badRequest(body: 'taskId required');
        }
        await offerAccept.onReceiptHttp(
          fromPeer: peer.fingerprint,
          taskId: taskId,
          ok: body['ok'] as bool? ?? false,
          error: body['error'] as String?,
          sha256: body['sha256'] as String?,
        );
        return Response.ok(
          jsonEncode({'ok': true}),
          headers: {'content-type': 'application/json'},
        );
      };
}

/// POST /api/v1/chat —— 文字消息 HTTP 兜底。
class ChatEndpoint {
  static const path = '/api/v1/chat';

  ChatEndpoint({required this.offerAccept});

  final OfferAcceptService offerAccept;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer == null) {
          return Response.unauthorized('peer required');
        }
        final body = jsonDecode(await request.readAsString()) as Map;
        final id = body['id'] as String?;
        final text = body['text'] as String?;
        if (id == null || text == null) {
          return Response.badRequest(body: 'id/text required');
        }
        await offerAccept.onChatHttp(
          fromPeer: peer.fingerprint,
          id: id,
          text: text,
          createdAtMs: body['createdAtMs'] as int? ??
              DateTime.now().millisecondsSinceEpoch,
        );
        return Response.ok(
          jsonEncode({'ok': true}),
          headers: {'content-type': 'application/json'},
        );
      };
}
