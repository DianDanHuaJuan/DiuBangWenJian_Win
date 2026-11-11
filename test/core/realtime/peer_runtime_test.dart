import 'package:diubangwenjian/core/realtime/peer_runtime.dart';
import 'package:diubangwenjian/core/realtime/peer_runtime_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PeerRuntime', () {
    test('merge 只覆盖出现的字段', () {
      const base = PeerRuntime(
        batteryPercent: 80,
        isCharging: false,
        memTotalBytes: 100,
      );
      final merged = base.merge(
        const PeerRuntime(batteryPercent: 79, isCharging: true),
      );
      expect(merged.batteryPercent, 79);
      expect(merged.isCharging, isTrue);
      expect(merged.memTotalBytes, 100);
    });

    test('toJson/fromJson 往返', () {
      const r = PeerRuntime(
        batteryPercent: 50,
        isCharging: true,
        externalPresent: false,
      );
      final again = PeerRuntime.fromJson(r.toJson());
      expect(again.batteryPercent, 50);
      expect(again.isCharging, isTrue);
      expect(again.externalPresent, isFalse);
    });
  });

  group('PeerRuntimeStore', () {
    test('apply / clear 通知 listenable', () {
      final store = PeerRuntimeStore();
      final listenable = store.listenable('fp1');
      expect(listenable.value, isNull);

      store.apply('fp1', const PeerRuntime(batteryPercent: 10));
      expect(listenable.value?.batteryPercent, 10);

      store.clear('fp1');
      expect(listenable.value, isNull);
      store.dispose();
    });
  });
}
