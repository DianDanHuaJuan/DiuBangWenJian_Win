import 'package:flutter_test/flutter_test.dart';

import 'package:diubangwenjian/core/discovery/discovery_foreground_guard.dart';

void main() {
  group('DiscoveryForegroundGuard', () {
    test('首次 start 成功不再重试', () async {
      var starts = 0;
      var stops = 0;
      final guard = DiscoveryForegroundGuard(
        stop: () async {
          stops++;
        },
        start: () async {
          starts++;
          return true;
        },
        networkReady: () async => true,
        sleep: (_) async {},
      );
      final result = await guard.ensure(rebuild: false);
      expect(result.ok, isTrue);
      expect(starts, 1);
      expect(stops, 0);
    });

    test('resumed 先 stop 再 start', () async {
      final order = <String>[];
      final guard = DiscoveryForegroundGuard(
        stop: () async {
          order.add('stop');
        },
        start: () async {
          order.add('start');
          return true;
        },
        networkReady: () async => true,
        sleep: (_) async {},
      );
      await guard.ensure(rebuild: true);
      expect(order, ['stop', 'start']);
    });

    test('网未好则等待并最多 3 次，结果 noNetwork', () async {
      var readyChecks = 0;
      var starts = 0;
      final delays = <Duration>[];
      final guard = DiscoveryForegroundGuard(
        stop: () async {},
        start: () async {
          starts++;
          return true;
        },
        networkReady: () async {
          readyChecks++;
          return false;
        },
        sleep: (d) async {
          delays.add(d);
        },
      );
      final result = await guard.ensure(rebuild: false);
      expect(result.status, DiscoveryEnsureStatus.noNetwork);
      expect(readyChecks, 3);
      expect(starts, 0);
      expect(delays, hasLength(2));
    });

    test('start 失败重试 3 次后 failed', () async {
      var starts = 0;
      final guard = DiscoveryForegroundGuard(
        stop: () async {},
        start: () async {
          starts++;
          return false;
        },
        networkReady: () async => true,
        sleep: (_) async {},
      );
      final result = await guard.ensure(rebuild: false);
      expect(result.status, DiscoveryEnsureStatus.failed);
      expect(starts, 3);
    });

    test('第二次成功即返回 ready', () async {
      var starts = 0;
      final guard = DiscoveryForegroundGuard(
        stop: () async {},
        start: () async {
          starts++;
          return starts >= 2;
        },
        networkReady: () async => true,
        sleep: (_) async {},
      );
      final result = await guard.ensure(rebuild: false);
      expect(result.ok, isTrue);
      expect(starts, 2);
    });
  });
}
