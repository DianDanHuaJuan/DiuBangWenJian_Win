import 'dart:async';
import 'dart:collection';

import 'thumb_diag.dart';
import 'thumb_global_budget.dart';

enum ThumbGenPriority { remote, warmup }

/// 单档位（grid 或 preview）生成闸：remote 与 warmup 分队列，共享 [ThumbGlobalBudget]。
class ThumbGenerationGate {
  ThumbGenerationGate({
    required this.name,
    required ThumbGlobalBudget budget,
    this.maxRemote = defaultMaxRemote,
    this.maxWarmup = defaultMaxWarmup,
    this.maxPendingRemote = defaultMaxPendingRemote,
    bool Function()? shouldYieldWarmup,
  })  : _budget = budget,
        _shouldYieldWarmup = shouldYieldWarmup {
    _budget.addListener(_pump);
  }

  /// 定案：remote / warmup 生成并发一律 1。
  static const defaultMaxRemote = 1;

  /// 定案：warmup 仅 grid 闸启用，且 ≤ 1。
  static const defaultMaxWarmup = 1;

  /// remote 排队过深则拒收，避免完成风暴撑爆消息队列。
  static const defaultMaxPendingRemote = 24;

  final String name;
  final int maxRemote;
  final int maxWarmup;
  final int maxPendingRemote;
  final ThumbGlobalBudget _budget;
  final bool Function()? _shouldYieldWarmup;

  final Queue<_GateJob> _remote = Queue();
  final Queue<_GateJob> _warmup = Queue();
  var _runningRemote = 0;
  var _runningWarmup = 0;
  var _jobSeq = 0;
  DateTime? _lastOverloadLog;

  int get running => _runningRemote + _runningWarmup;
  int get runningRemote => _runningRemote;
  int get pendingRemote => _remote.length;
  int get pendingWarmup => _warmup.length;
  int get pendingTotal => pendingRemote + pendingWarmup;
  bool get hasRemoteDemand => _runningRemote > 0 || _remote.isNotEmpty;

  /// 兼容旧字段：本闸 remote 上限。
  int get maxConcurrent => maxRemote;

  bool get shouldYieldWarmup {
    if (hasRemoteDemand) return true;
    return _shouldYieldWarmup?.call() ?? false;
  }

  /// 真背压：有 remote 或全局满或本闸 warmup 已满则不再投 warmup。
  bool get canAcceptWarmup =>
      maxWarmup > 0 &&
      !shouldYieldWarmup &&
      _budget.hasCapacity &&
      (_runningWarmup + pendingWarmup) < maxWarmup;

  Future<T> run<T>({
    required ThumbGenPriority priority,
    required Future<T> Function() task,
    String label = '',
  }) {
    final completer = Completer<T>();
    final id = ++_jobSeq;
    final job = _GateJob(
      id: id,
      priority: priority,
      label: label,
      onDrop: () {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('gate dropped ($priority) id=$id name=$name'),
          );
        }
      },
      run: () async {
        try {
          final value = await task();
          if (!completer.isCompleted) completer.complete(value);
        } catch (e, st) {
          if (!completer.isCompleted) completer.completeError(e, st);
        }
      },
    );
    if (priority == ThumbGenPriority.remote) {
      if (_remote.length >= maxPendingRemote) {
        final now = DateTime.now();
        if (_lastOverloadLog == null ||
            now.difference(_lastOverloadLog!) >= const Duration(seconds: 2)) {
          _lastOverloadLog = now;
          ThumbDiag.important(
            'gate_overloaded',
            details: {
              'gate': name,
              'pending': _remote.length,
              'maxPending': maxPendingRemote,
              'label': label,
            },
          );
        }
        if (!completer.isCompleted) {
          completer.completeError(
            StateError(
              'gate overloaded ($name) pending=${_remote.length}',
            ),
          );
        }
        return completer.future;
      }
      _remote.add(job);
    } else {
      if (maxWarmup <= 0) {
        job.onDrop();
        return completer.future;
      }
      _warmup.add(job);
    }
    _pump();
    return completer.future;
  }

  void _pump() {
    // remote 优先占槽。
    while (_runningRemote < maxRemote &&
        _remote.isNotEmpty &&
        _budget.tryAcquire()) {
      final job = _remote.removeFirst();
      _runningRemote++;
      _launch(job, isRemote: true);
    }

    if (maxWarmup <= 0) return;
    if (shouldYieldWarmup) return;

    while (_runningWarmup < maxWarmup &&
        _warmup.isNotEmpty &&
        !shouldYieldWarmup &&
        _budget.tryAcquire()) {
      final job = _warmup.removeFirst();
      _runningWarmup++;
      _launch(job, isRemote: false);
    }
  }

  void _launch(_GateJob job, {required bool isRemote}) {
    () async {
      try {
        await job.run();
      } finally {
        if (isRemote) {
          _runningRemote--;
        } else {
          _runningWarmup--;
        }
        _budget.release();
        _pump();
      }
    }();
  }

  void clearWarmupQueue() {
    final n = _warmup.length;
    while (_warmup.isNotEmpty) {
      _warmup.removeFirst().onDrop();
    }
    if (n > 0) {
      ThumbDiag.important(
        'gate_clear_warmup',
        details: {'gate': name, 'dropped': n},
      );
    }
  }

  void dispose() {
    _budget.removeListener(_pump);
    clearWarmupQueue();
  }
}

class _GateJob {
  _GateJob({
    required this.id,
    required this.priority,
    required this.label,
    required this.run,
    required this.onDrop,
  });

  final int id;
  final ThumbGenPriority priority;
  final String label;
  final Future<void> Function() run;
  final void Function() onDrop;
}
