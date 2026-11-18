import '../common/app_logger.dart';

/// 缩略图诊断日志（默认收敛，避免刷爆 Windows PostMessage）。
abstract final class ThumbDiag {
  static const scope = 'thumb_diag';

  /// 打开后输出全量阶段日志（测试用）；或设 [AppLogger.verboseThumb]。
  static bool verbose = false;

  static const _always = {
    'warmup_start',
    'warmup_stop',
    'warmup_idle_stop',
    'warmup_root_changed',
    'daily_scan_begin',
    'daily_scan_end',
    'pipeline_generate_timeout',
    'backend_video_ffmpeg_fail',
    'cache_write_fail',
    'gate_overloaded',
  };

  /// 与 pipeline_generate_end 重复，默认不打（verbose 才出）。
  static const _redundant = {
    'image_compute_end',
    'backend_image_end',
  };

  static bool get _detailOn => verbose || AppLogger.verboseThumb;

  static void markPhase(String phase, {Map<String, Object?> details = const {}}) {
    if (!_detailOn) {
      if (_redundant.contains(phase)) return;
      if (!_always.contains(phase)) {
        final ms = details['ms'] ??
            details['genMs'] ??
            details['taskMs'] ??
            details['listMs'] ??
            details['scanMs'];
        // 仅极慢路径留一条；普通现算不再三条刷屏。
        if (ms is! int || ms < 2500) return;
      }
    }
    AppLogger.log(
      phase,
      scope: scope,
      details: {
        't': DateTime.now().toIso8601String(),
        ...details,
      },
    );
  }

  static void important(String phase, {Map<String, Object?> details = const {}}) {
    AppLogger.log(
      phase,
      scope: scope,
      details: {
        't': DateTime.now().toIso8601String(),
        ...details,
      },
    );
  }
}
