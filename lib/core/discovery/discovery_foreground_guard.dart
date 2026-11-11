import 'discovery_service.dart';

enum DiscoveryEnsureStatus {
  ready,
  noNetwork,
  failed,
}

class DiscoveryEnsureResult {
  const DiscoveryEnsureResult(this.status);

  final DiscoveryEnsureStatus status;

  bool get ok => status == DiscoveryEnsureStatus.ready;
}

/// 前台组播一层重建 + 条件重试（doc/设备探测与在线状态维护.md §3.4）。
class DiscoveryForegroundGuard {
  DiscoveryForegroundGuard({
    required this.stop,
    required this.start,
    required this.networkReady,
    this.maxAttempts = discoveryEnsureMaxAttempts,
    this.retryDelays = discoveryEnsureRetryDelays,
    Future<void> Function(Duration duration)? sleep,
  }) : sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final Future<void> Function() stop;
  final Future<bool> Function() start;
  final Future<bool> Function() networkReady;
  final int maxAttempts;
  final List<Duration> retryDelays;
  final Future<void> Function(Duration duration) sleep;

  Future<DiscoveryEnsureResult>? _inflight;
  bool _wantRebuild = false;

  Future<DiscoveryEnsureResult> ensure({required bool rebuild}) {
    if (rebuild) {
      _wantRebuild = true;
    }
    final existing = _inflight;
    if (existing != null) {
      return existing;
    }
    late final Future<DiscoveryEnsureResult> future;
    future = _drain(rebuild: rebuild);
    _inflight = future;
    return future.whenComplete(() {
      if (identical(_inflight, future)) {
        _inflight = null;
      }
    });
  }

  Future<DiscoveryEnsureResult> _drain({required bool rebuild}) async {
    var first = true;
    DiscoveryEnsureResult? last;
    while (first || _wantRebuild) {
      final doRebuild = _wantRebuild || (!first) || rebuild;
      _wantRebuild = false;
      first = false;
      last = await _run(rebuild: doRebuild);
    }
    return last!;
  }

  Future<DiscoveryEnsureResult> _run({required bool rebuild}) async {
    var lastWasNoNetwork = false;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {

      if (rebuild || attempt > 0) {
        await stop();
      }
      final netOk = await networkReady();

      if (!netOk) {
        lastWasNoNetwork = true;
        if (attempt < maxAttempts - 1) {
          await sleep(_delayFor(attempt));
        }
        continue;
      }
      lastWasNoNetwork = false;
      final ok = await start();

      if (ok) {
        return const DiscoveryEnsureResult(DiscoveryEnsureStatus.ready);
      }
      if (attempt < maxAttempts - 1) {
        await sleep(_delayFor(attempt));
      }
    }
    return DiscoveryEnsureResult(
      lastWasNoNetwork
          ? DiscoveryEnsureStatus.noNetwork
          : DiscoveryEnsureStatus.failed,
    );
  }

  Duration _delayFor(int attempt) {
    if (retryDelays.isEmpty) return Duration.zero;
    if (attempt < retryDelays.length) return retryDelays[attempt];
    return retryDelays.last;
  }
}
