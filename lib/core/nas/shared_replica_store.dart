import '../common/key_value_store.dart';

/// 配置世代：磁盘 generation++；单进程下无需跨 Engine IPC。
class SharedReplicaStore {
  SharedReplicaStore({required KeyValueStore keyValueStore}) : _kv = keyValueStore;

  static const generationKey = 'shared_replica.generation';

  final KeyValueStore _kv;

  int _localGeneration = 0;

  /// 世代变化后执行（reload 派生缓存 / announce 等）。
  Future<void> Function(String reason)? onApply;

  int get localGeneration => _localGeneration;

  Future<void> warmLocalGeneration() async {
    await _kv.reload();
    _localGeneration = _kv.getInt(generationKey) ?? 0;
  }

  Future<int> commit({required String reason}) async {
    final next = (_kv.getInt(generationKey) ?? _localGeneration) + 1;
    await _kv.setInt(generationKey, next);
    _localGeneration = next;
    final hook = onApply;
    if (hook != null) {
      await hook(reason);
    }
    return next;
  }
}
