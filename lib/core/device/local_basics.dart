import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

import '../storage/local_system_stats.dart' show LocalSystemStats, VolumeDiskStats;

/// 本机基本信息（局域网 IP + 内存/存储）轻量采集刷新。
///
/// 见 `doc/基本信息采集刷新机制.md`、`doc/概览渲染分区与可见性.md`。
class LocalBasics extends ChangeNotifier with WidgetsBindingObserver {
  LocalBasics({
    required Future<String> Function() refreshAddress,
    required Future<LocalSystemStats> Function() readStats,
    required String Function() currentAddress,
    VoidCallback? onAddressChanged,
  })  : _refreshAddress = refreshAddress,
        _readStats = readStats,
        _currentAddress = currentAddress,
        _onAddressChanged = onAddressChanged;

  static const period = Duration(seconds: 30);
  static const _connectivityDebounce = Duration(milliseconds: 400);

  final Future<String> Function() _refreshAddress;
  final Future<LocalSystemStats> Function() _readStats;
  final String Function() _currentAddress;
  final VoidCallback? _onAddressChanged;

  LocalSystemStats stats = LocalSystemStats.empty;

  bool _active = false;
  bool _busy = false;
  bool _pending = false;
  bool _pendingStats = false;
  bool _pendingAddress = false;
  bool _started = false;
  Timer? _timer;
  Timer? _connectivityDebounceTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  bool get isActive => _active;

  /// bootstrap：生命周期 + Connectivity（地址全局；stats 仅 active）。
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _connectivitySub = Connectivity().onConnectivityChanged.listen((_) {
      _connectivityDebounceTimer?.cancel();
      _connectivityDebounceTimer = Timer(_connectivityDebounce, () {
        unawaited(refresh(stats: false, address: true));
      });
    });
  }

  /// 概览 Tab 是否当前可见（由 [HomeShellPage] 驱动）。
  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    if (active) {
      // 地址立刻刷；stats 放到下一帧，减轻与首绘争抢
      unawaited(refresh(stats: false, address: true));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_active) {
          unawaited(refresh(stats: true, address: false));
        }
      });
    }
    _syncTimer();
  }

  /// [stats] 仅在 [isActive] 时真正采集；[address] 始终可采（供设置/发现）。
  Future<void> refresh({
    bool stats = true,
    bool address = true,
  }) async {
    final wantStats = stats && _active;
    final wantAddress = address;
    if (!wantStats && !wantAddress) return;

    if (_busy) {
      _pending = true;
      _pendingStats = _pendingStats || wantStats;
      _pendingAddress = _pendingAddress || wantAddress;
      return;
    }
    _busy = true;
    var statsChanged = false;
    var addressChanged = false;
    try {
      if (wantAddress) {
        final before = _currentAddress();
        final after = await _refreshAddress();
        addressChanged = after != before;
        if (addressChanged) {
          _onAddressChanged?.call();
        }
      }
      if (wantStats) {
        final next = await _readStats();
        final hasData = next.memTotalBytes > 0 ||
            next.storageTotalBytes > 0 ||
            next.volumes.isNotEmpty;
        final hadData = this.stats.memTotalBytes > 0 ||
            this.stats.storageTotalBytes > 0 ||
            this.stats.volumes.isNotEmpty;
        if (hasData || !hadData) {
          if (next.memAvailBytes != this.stats.memAvailBytes ||
              next.memTotalBytes != this.stats.memTotalBytes ||
              next.storageAvailBytes != this.stats.storageAvailBytes ||
              next.storageTotalBytes != this.stats.storageTotalBytes ||
              !_sameVolumes(next.volumes, this.stats.volumes)) {
            this.stats = next;
            statsChanged = true;
          }
        }
      }
      // 环区只听本 Listenable；IP 胶囊听 hostAddressListenable
      if (_active && statsChanged) {
        notifyListeners();
      }
    } finally {
      _busy = false;
      if (_pending) {
        final s = _pendingStats;
        final a = _pendingAddress;
        _pending = false;
        _pendingStats = false;
        _pendingAddress = false;
        unawaited(refresh(stats: s, address: a));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.resumed && _active) {
      unawaited(refresh(stats: true, address: true));
    }
    _syncTimer();
  }

  void _syncTimer() {
    final run =
        _active && _lifecycle == AppLifecycleState.resumed;
    if (run) {
      _timer ??= Timer.periodic(period, (_) {
        // 周期只刷 stats；地址靠 Connectivity / 进页 / 下拉
        unawaited(refresh(stats: true, address: false));
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  static bool _sameVolumes(
    List<VolumeDiskStats> a,
    List<VolumeDiskStats> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].letter != b[i].letter ||
          a[i].totalBytes != b[i].totalBytes ||
          a[i].availBytes != b[i].availBytes) {
        return false;
      }
    }
    return true;
  }

  @override
  void dispose() {
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _timer?.cancel();
    _timer = null;
    _connectivityDebounceTimer?.cancel();
    _connectivityDebounceTimer = null;
    unawaited(_connectivitySub?.cancel() ?? Future.value());
    _connectivitySub = null;
    super.dispose();
  }
}
