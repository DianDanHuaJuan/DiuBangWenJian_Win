import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import '../../../../core/common/app_logger.dart';
import '../../../../core/network/peer_address.dart';
import '../../../../core/pairing/pairing_services.dart';

String? _remoteIpFromRequest(Request request) {
  final info = request.context['shelf.io.connection_info'];
  if (info is! HttpConnectionInfo) return null;
  final address = info.remoteAddress.address;
  return PeerAddress.preferIpv4(address);
}

/// NASPAIR4 扫码配对端点（POST /api/v1/pair/enroll）。
class PairingEndpoint {
  static const path = '/api/v1/pair/enroll';

  PairingEndpoint({required this.hostService});

  final PairingHostService hostService;

  Handler get handler => (Request request) async {
        final remoteIp = _remoteIpFromRequest(request);
        final body = await request.readAsString();
        final parsed = _extractBody(body);
        if (parsed == null) {
          return Response(400, body: 'bad payload');
        }

        final response = await hostService.handleQrEnroll(
          sealed: parsed.sealed,
          clientPublicKey: parsed.clientPublicKey,
          ticket: parsed.ticket,
          remoteIp: remoteIp,
        );
        if (response == null) {
          AppLogger.log('HOST QR enroll REJECTED', scope: 'pairing');
          return Response(403, body: 'enroll rejected');
        }
        return Response.ok(
          jsonEncode({'sealed': response}),
          headers: {'content-type': 'application/json'},
        );
      };

  ({String sealed, String clientPublicKey, String ticket})? _extractBody(
    String body,
  ) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final sealed = json['sealed'] as String?;
      final clientPub = json['client_pub'] as String?;
      final ticket = json['ticket'] as String?;
      if (sealed == null ||
          clientPub == null ||
          ticket == null ||
          sealed.isEmpty ||
          clientPub.isEmpty ||
          ticket.isEmpty) {
        return null;
      }
      return (sealed: sealed, clientPublicKey: clientPub, ticket: ticket);
    } catch (_) {
      return null;
    }
  }
}

/// 密码配对端点（POST /api/v1/pair/password-enroll）。
class PairPasswordEndpoint {
  static const path = '/api/v1/pair/password-enroll';

  PairPasswordEndpoint({required this.hostService});

  final PairingHostService hostService;

  Handler get handler => (Request request) async {
        final remoteIp = _remoteIpFromRequest(request);
        final body = await request.readAsString();
        final sealed = _extractSealed(body);
        if (sealed == null) {
          return Response(400, body: 'bad payload');
        }

        final response = await hostService.handlePasswordEnroll(
          sealed: sealed,
          remoteIp: remoteIp,
        );
        if (response == null) {
          AppLogger.log('HOST password enroll REJECTED', scope: 'pairing');
          return Response(403, body: 'enroll rejected');
        }
        return Response.ok(
          jsonEncode({'sealed': response}),
          headers: {'content-type': 'application/json'},
        );
      };

  String? _extractSealed(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['sealed'] as String?;
    } catch (_) {
      return null;
    }
  }
}
