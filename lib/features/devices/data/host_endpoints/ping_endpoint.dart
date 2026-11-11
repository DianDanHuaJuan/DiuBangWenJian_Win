import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../../../../core/auth/peer_fingerprint_middleware.dart';
import '../../../../core/identity/device_identity_service.dart';
import '../../../../core/identity/peer.dart';

/// 点连接探活（GET /api/v1/ping）。
///
/// 列表绿/灰仍以 UDP announce 为准；点进已配对设备前会短超时调用本接口。
class PingEndpoint {
  static const path = '/api/v1/ping';

  PingEndpoint({required this.identityService});

  final DeviceIdentityService identityService;

  Handler get handler => (Request request) async {
        final peer = request.context[peerKey] as Peer?;

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
