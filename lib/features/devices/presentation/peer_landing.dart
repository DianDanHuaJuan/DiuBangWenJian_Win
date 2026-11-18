import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/di/service_locator.dart';
import '../../../app/router/route_paths.dart';
import '../../../app/ui/app_dialog.dart';
import '../../../core/discovery/peer_registry.dart';
import '../../../core/network/peer_api_client.dart';
import '../data/host_endpoints/ping_endpoint.dart';

/// 点进已配对设备前的 HTTPS 探活超时。
const enterPeerPingTimeout = Duration(seconds: 3);

bool _openingPeer = false;

/// 已配对设备落地页：NAS 开 → 文件预览；否则气泡聊天。
///
/// 连通性由 [openPairedPeer] 的 ping 负责；此处只做 NAS / 聊天分流。
Future<String> peerLandingPath(String fingerprint) async {
  final online = _onlineOf(fingerprint);
  if (online?.nasService == true) {
    return RoutePaths.deviceFilesFor(fingerprint);
  }

  try {
    final PeerApiResponse? response = await serviceLocator
        .peerApiClient()
        .get(
          fingerprint,
          '/api/v1/info',
          connectTimeout: enterPeerPingTimeout,
          receiveTimeout: enterPeerPingTimeout,
        );
    if (response != null && response.statusCode == 200) {
      final data = response.data;
      if (data != null) {
        final Map<String, dynamic> map = data is Map
            ? Map<String, dynamic>.from(data)
            : jsonDecode(data.toString()) as Map<String, dynamic>;
        final caps = map['caps'];
        if (caps is List && caps.any((c) => c.toString() == 'nas')) {
          serviceLocator.peerRegistry().markNasService(fingerprint, true);
          return RoutePaths.deviceFilesFor(fingerprint);
        }
      }
    }
  } catch (_) {}

  return RoutePaths.deviceChatFor(fingerprint);
}

/// 列表点进：灰灯弹窗拦截；绿灯先 ping，通了再进落地页。
///
/// [requireOnline] 为 false 时跳过 UDP 灯（刚配对、announce 可能尚未入表）。
Future<void> openPairedPeer(
  BuildContext context,
  String fingerprint, {
  bool requireOnline = true,
}) async {
  if (_openingPeer) return;
  if (requireOnline && _onlineOf(fingerprint) == null) {
    await _showOffline(context);
    return;
  }

  _openingPeer = true;
  var spinnerShown = false;
  try {
    if (!context.mounted) return;
    spinnerShown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Color(0xFF3D8A5A)),
                SizedBox(height: 16),
                Text('正在连接…'),
              ],
            ),
          ),
        ),
      ),
    );

    final reachable = await _pingReachable(fingerprint);
    if (!context.mounted) return;
    if (!reachable) {
      _popSpinner(context, spinnerShown);
      spinnerShown = false;
      await _showOffline(context);
      return;
    }

    final path = await peerLandingPath(fingerprint);
    if (!context.mounted) return;
    _popSpinner(context, spinnerShown);
    spinnerShown = false;
    // 点进该设备即清列表新消息红点（文字/图片统一走 ChatUnreadStore）。
    serviceLocator.chatUnreadStore().clear(fingerprint);
    // 聊天：进设备 Tab 右侧嵌入气泡（与设备页点选一致）；NAS 仍整页文件浏览。
    if (path == RoutePaths.deviceChatFor(fingerprint)) {
      serviceLocator.devicesChatPeerRequest.value = fingerprint;
      context.go(RoutePaths.devices);
    } else {
      context.go(path);
    }
  } finally {
    if (spinnerShown && context.mounted) {
      _popSpinner(context, true);
    }
    _openingPeer = false;
  }
}

Future<bool> _pingReachable(String fingerprint) async {
  try {
    final response = await serviceLocator.peerApiClient().get(
          fingerprint,
          PingEndpoint.path,
          connectTimeout: enterPeerPingTimeout,
          receiveTimeout: enterPeerPingTimeout,
        );
    return response != null && response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

Future<void> _showOffline(BuildContext context) {
  if (!context.mounted) return Future.value();
  return AppDialog.alert(
    context,
    title: '设备不在线',
    message: '对端设备当前不在线，无法进入。请确认对方 APP 在前台且已连上同一 Wi‑Fi。',
  );
}

void _popSpinner(BuildContext context, bool shown) {
  if (!shown || !context.mounted) return;
  final nav = Navigator.of(context, rootNavigator: true);
  if (nav.canPop()) nav.pop();
}

OnlinePeer? _onlineOf(String fingerprint) {
  for (final o in serviceLocator.peerRegistry().onlinePaired) {
    if (o.fingerprint == fingerprint) return o;
  }
  return null;
}
