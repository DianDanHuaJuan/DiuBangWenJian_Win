import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Unified debug logging entry (merges server + dio debug logging,
/// doc/02 §3.2 core/common). Later phases' shelf middleware and
/// dio interceptor route their output through this logger.
///
/// 同时走 [debugPrint]，保证 `flutter run` / logcat 能看到 `I/flutter:` 行
///（仅 [developer.log] 时用户粘贴的 log 常漏掉业务日志）。
///
/// **Release 一律静默**（[kReleaseMode]）。Debug 下成功路径刷屏日志走
/// [logVerbose]，需 [verboseDiscovery]=true 才输出。
abstract final class AppLogger {
  /// UDP RX / pulse、presence ping 成功等稳态日志开关（默认关）。
  /// 仅当前 isolate 有效；UI 与 NAS FGS 需各自置位。
  static bool verboseDiscovery = false;

  static void log(
    String message, {
    required String scope,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    if (kReleaseMode) return;
    _emit(
      message,
      scope: scope,
      error: error,
      stackTrace: stackTrace,
      details: details,
    );
  }

  /// 发现/在线成功路径与周期脉冲；默认不输出。
  static void logVerbose(
    String message, {
    required String scope,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    if (kReleaseMode || !verboseDiscovery) return;
    _emit(
      message,
      scope: scope,
      error: error,
      stackTrace: stackTrace,
      details: details,
    );
  }

  static void _emit(
    String message, {
    required String scope,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    final payload = <String, Object?>{
      'scope': scope,
      ...details,
    };
    final rendered = '[$scope] $message details=${jsonEncode(payload)}';
    debugPrint(rendered);
    if (error != null) {
      debugPrint('[$scope] error=$error');
    }
    developer.log(
      rendered,
      name: 'diubangwenjian.$scope',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
