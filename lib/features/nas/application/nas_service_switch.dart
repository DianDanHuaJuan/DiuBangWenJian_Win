import 'dart:async';

import '../../../core/common/key_value_store.dart';

/// NAS 开关状态流（供 nas_route_guard / announce / 概览消费）。
///
/// 开关只控制对外文件面；共享根不变（决策 #14 / doc/08）。
class NasServiceSwitch {
  NasServiceSwitch({
    required KeyValueStore store,
    this.onChanged,
    this.onPersisted,
  }) : _store = store;

  static const enabledKey = 'nas.service_enabled';

  final KeyValueStore _store;
  final void Function(bool enabled)? onChanged;

  /// 开关已落盘后回调（冷总线 commit）。
  Future<void> Function()? onPersisted;

  final _controller = StreamController<bool>.broadcast();

  Stream<bool> get stream => _controller.stream;

  bool get isEnabled => _store.getBool(enabledKey) ?? false;

  Future<void> setEnabled(bool enabled) async {
    if (isEnabled == enabled) return;
    await _store.setBool(enabledKey, enabled);
    if (!_controller.isClosed) {
      _controller.add(enabled);
    }
    onChanged?.call(enabled);
    await onPersisted?.call();
  }

  /// FGS 等外进程已改 prefs 后：reload + 广播，供 UI 开关对齐。
  Future<void> syncFromStore() async {
    await _store.reload();
    final enabled = isEnabled;
    if (!_controller.isClosed) {
      _controller.add(enabled);
    }
    onChanged?.call(enabled);
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
