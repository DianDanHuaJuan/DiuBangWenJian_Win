import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:diubangwenjian/core/identity/stable_device_id.dart';
import 'package:diubangwenjian/core/pairing/pairing_payload.dart';
import 'package:diubangwenjian/core/pairing/pairing_services.dart';

void main() {
  group('StableDeviceIdService.hashStableId', () {
    test('同输入确定性；不同输入不同哈希', () {
      final a = StableDeviceIdService.hashStableId('android-id-1');
      final b = StableDeviceIdService.hashStableId('android-id-1');
      final c = StableDeviceIdService.hashStableId('android-id-2');
      expect(a, b);
      expect(a, isNot(c));
      expect(a, hasLength(64));
    });
  });

  group('EnrollRequest/Response sid 字段', () {
    test('toJson/fromJson 往返保留 sid', () {
      final req = EnrollRequest(
        ticket: 't',
        fingerprint: 'aa' * 32,
        deviceName: 'A',
        model: 'M',
        listenPort: 5244,
        stableIdHash: 'sid-abc',
      );
      final round = EnrollRequest.fromJson(req.toJson());
      expect(round.stableIdHash, 'sid-abc');

      final resp = EnrollResponse(
        fingerprint: 'bb' * 32,
        deviceName: 'B',
        model: 'N',
        secret: '11' * 32,
        stableIdHash: 'sid-xyz',
      );
      expect(EnrollResponse.fromJson(resp.toJson()).stableIdHash, 'sid-xyz');
    });

    test('缺省 sid 兼容旧载荷', () {
      final req = EnrollRequest.fromJson({
        'ticket': '',
        'fp': 'aa' * 32,
        'name': 'A',
        'model': 'M',
        'listenPort': 5244,
      });
      expect(req.stableIdHash, isNull);
    });
  });

  group('PairingPayload sid', () {
    test('新码不编码 sid；旧码仍可解析 sid', () {
      final payload = PairingPayload(
        version: 4,
        host: '1.2.3.4',
        port: 5244,
        deviceName: 'N',
        model: 'M',
        fingerprint: 'ab' * 32,
        ticket: 'ticket1',
        serverPublicKey: 'dGVzdA',
        stableIdHash: 'sid-qr',
      );
      final decoded = PairingPayload.decode(payload.encode());
      expect(decoded!.stableIdHash, isNull);

      final legacyJson =
          '{"v":4,"host":"1.2.3.4","port":5244,"name":"N","model":"M",'
          '"fp":"${'ab' * 32}","ticket":"ticket1","pk":"dGVzdA","sid":"sid-qr"}';
      final legacy = PairingPayload.decode(
        'NASPAIR4:${base64Url.encode(utf8.encode(legacyJson))}',
      );
      expect(legacy!.stableIdHash, 'sid-qr');
    });
  });
}
