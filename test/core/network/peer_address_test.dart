import 'package:flutter_test/flutter_test.dart';

import 'package:diubangwenjian/core/network/peer_address.dart';

void main() {
  group('PeerAddress', () {
    test('IPv4 format / parse 往返', () {
      final formatted = PeerAddress.format('192.168.1.10', 5244);
      expect(formatted, '192.168.1.10:5244');
      final parsed = PeerAddress.tryParse(formatted);
      expect(parsed, isNotNull);
      expect(parsed!.host, '192.168.1.10');
      expect(parsed.port, 5244);
    });

    test('IPv6 带方括号 format / parse / https URI', () {
      final formatted = PeerAddress.format('fe80::1', 5244);
      expect(formatted, '[fe80::1]:5244');
      final parsed = PeerAddress.tryParse(formatted)!;
      expect(parsed.host, 'fe80::1');
      expect(parsed.port, 5244);
      expect(
        parsed.toHttpsUri('/api/v1/ping').toString(),
        'https://[fe80::1]:5244/api/v1/ping',
      );
    });

    test('裸 IPv6 无括号拒绝解析', () {
      expect(PeerAddress.tryParse('fe80::1:5244'), isNull);
    });

    test('占位地址 format 返回 null', () {
      expect(PeerAddress.format('0.0.0.0', 5244), isNull);
      expect(PeerAddress.format('::', 5244), isNull);
      expect(PeerAddress.format(null, 5244), isNull);
    });

    test('IPv4-mapped 转 IPv4', () {
      expect(
        PeerAddress.preferIpv4('::ffff:192.168.1.5'),
        '192.168.1.5',
      );
    });

    test('https URI 规范化 path', () {
      final addr = PeerAddress(host: '10.0.0.2', port: 5244);
      expect(
        addr.toHttpsUri('api/v1/ping').toString(),
        'https://10.0.0.2:5244/api/v1/ping',
      );
    });

    test('dialFromInboundPing：无 lastSeen 用默认端口', () {
      expect(
        PeerAddress.dialFromInboundPing(remoteIp: '192.168.1.20'),
        '192.168.1.20:5244',
      );
    });

    test('dialFromInboundPing：同 host 沿用 lastSeen 端口', () {
      expect(
        PeerAddress.dialFromInboundPing(
          remoteIp: '192.168.1.20',
          lastSeenAddress: '192.168.1.20:6000',
        ),
        '192.168.1.20:6000',
      );
    });

    test('dialFromInboundPing：host 变化用默认端口', () {
      expect(
        PeerAddress.dialFromInboundPing(
          remoteIp: '192.168.1.30',
          lastSeenAddress: '192.168.1.20:6000',
        ),
        '192.168.1.30:5244',
      );
    });

    test('dialFromInboundPing：坏 remote 返回 null', () {
      expect(PeerAddress.dialFromInboundPing(remoteIp: null), isNull);
      expect(PeerAddress.dialFromInboundPing(remoteIp: '0.0.0.0'), isNull);
    });
  });
}
