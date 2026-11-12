import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import '../../../../core/auth/peer_fingerprint_middleware.dart';
import '../../../../core/identity/device_identity_service.dart';
import '../../../../core/identity/peer.dart';
import '../../../../core/network/peer_address.dart';

/// 点连接探活（GET /api/v1/ping）。
///
/// 列表绿/灰以 UDP announce 为主；出站 / **入站已认证** HTTPS ping 均可参与拉绿与续命。
/// 点进已配对设备前也会短超时调用本接口。
class PingEndpoint {
  static const path = '/api/v1/ping';

  PingEndpoint({
    required this.identityService,
    this.onAuthenticatedInboundPing,
  });

  final DeviceIdentityService identityService;

  /// 鉴权通过后的入站探活钩子（presence 标绿；失败不影响 pong）。
  final void Function(Peer peer, String? remoteIp)? onAuthenticatedInboundPing;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;
        if (peer != null) {
          try {
            onAuthenticatedInboundPing?.call(peer, _remoteIpFromRequest(request));
          } catch (_) {}
        }

        final identity = await identityService.identity;
        return Response.ok(
          jsonEncode({
            'pong': true,
            'server': {
              'fingerprint': identity.fingerprint,
              'name': identity.deviceName,
              'model': identity.model,
            },
            'peer': peer == null
                ? null
                : {
                    'fingerprint': peer.fingerprint,
                    'name': peer.name,
                  },
          }),
          headers: {'content-type': 'application/json'},
        );
      };
}

String? _remoteIpFromRequest(Request request) {
  final info = request.context['shelf.io.connection_info'];
  if (info is! HttpConnectionInfo) return null;
  return PeerAddress.preferIpv4(info.remoteAddress.address);
}
