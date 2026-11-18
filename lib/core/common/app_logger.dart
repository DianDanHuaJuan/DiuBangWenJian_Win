import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Unified debug logging entry (merges server + dio debug logging,
/// doc/02 §3.2 core/common). Later phases' shelf middleware and
/// dio interceptor route their output through this logger.
///
/// **Release 一律静默**（[kReleaseMode]）。
///
/// Debug 默认只打「重要」路径（[log]）；高频成功路径用 [logVerbose]，
/// 并由分开关控制，避免 Windows 上 `debugPrint` 撑爆消息队列
/// （Failed to post message to main thread）。
///
/// 另有全局限速：任意 Debug 输出超过 [maxLinesPerSecond] 则丢弃，
/// 防止打开 verbose 或漏改热路径时再次自激。
abstract final class AppLogger {
  /// UDP RX / pulse、presence ping 成功等稳态日志（默认关）。
  static bool verboseDiscovery = false;

  /// host / nas_files / video_diag 等 HTTP 成功路径（默认关）。
  static bool verboseHttp = false;

  /// extvol / StorageVolumes 枚举明细（默认关）。
  static bool verboseExtvol = false;

  /// thumb_diag 明细（默认关；与 [ThumbDiag.verbose] 可同时开）。
  static bool verboseThumb = false;

  /// 防爆鸣：每秒最多落盘/打印行数（含 error 附属行）。
  static const maxLinesPerSecond = 40;

  static var _windowCount = 0;
  static DateTime _windowStart = DateTime.fromMillisecondsSinceEpoch(0);

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

  /// 高频/成功路径；需对应 verbose* 开关。
  static void logVerbose(
    String message, {
    required String scope,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    if (kReleaseMode || !isVerboseScope(scope)) return;
    _emit(
      message,
      scope: scope,
      error: error,
      stackTrace: stackTrace,
      details: details,
    );
  }

  /// 当前 scope 是否允许 verbose 输出。
  static bool isVerboseScope(String scope) {
    switch (scope) {
      case 'host':
      case 'nas_files':
      case 'video_diag':
        return verboseHttp;
      case 'extvol':
      case 'extvol_diag':
        return verboseExtvol;
      case 'thumb_diag':
        return verboseThumb;
      case 'discovery':
      case 'presence':
      case 'dial':
        return verboseDiscovery;
      default:
        return verboseDiscovery;
    }
  }

  static bool _rateLimitAllow() {
    final now = DateTime.now();
    if (now.difference(_windowStart) >= const Duration(seconds: 1)) {
      _windowStart = now;
      _windowCount = 0;
    }
    if (_windowCount >= maxLinesPerSecond) return false;
    _windowCount++;
    return true;
  }

  static void _emit(
    String message, {
    required String scope,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    if (!_rateLimitAllow()) return;
    final payload = <String, Object?>{
      'scope': scope,
      ...details,
    };
    final rendered = '[$scope] $message details=${jsonEncode(payload)}';
    debugPrint(rendered);
    if (error != null) {
      if (_rateLimitAllow()) {
        debugPrint('[$scope] error=$error');
      }
    }
    developer.log(
      rendered,
      name: 'diubangwenjian.$scope',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
