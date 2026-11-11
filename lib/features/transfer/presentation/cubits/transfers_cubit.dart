import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/task/transfer_task.dart';

class TransfersState {
  const TransfersState({
    this.loading = true,
    this.tasks = const [],
    this.error,
  });

  final bool loading;
  final List<TransferTask> tasks;
  final String? error;

  TransfersState copyWith({
    bool? loading,
    List<TransferTask>? tasks,
    String? error,
    bool clearError = false,
  }) =>
      TransfersState(
        loading: loading ?? this.loading,
        tasks: tasks ?? this.tasks,
        error: clearError ? null : (error ?? this.error),
      );
}

class TransfersCubit extends Cubit<TransfersState> {
  TransfersCubit() : super(const TransfersState());

  Timer? _poll;
  void Function()? _xferListener;

  Future<void> start() async {
    await refresh();
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(refresh(silent: true));
    });
    final xfer = serviceLocator.nasTransferService();
    _xferListener ??= () => unawaited(refresh(silent: true));
    xfer.addListener(_xferListener!);
  }

  Future<void> refresh({bool silent = false}) async {
    if (!silent) emit(state.copyWith(loading: true, clearError: true));
    try {
      final store = await serviceLocator.transferTaskStore();
      final tasks = await store.listRecent();
      emit(state.copyWith(loading: false, tasks: tasks, clearError: true));
    } catch (e) {
      emit(state.copyWith(loading: false, error: '$e'));
    }
  }

  Future<void> clearDone() async {
    final store = await serviceLocator.transferTaskStore();
    for (final t in state.tasks) {
      if (t.state == TransferTaskState.done ||
          t.state == TransferTaskState.cancelled ||
          t.state == TransferTaskState.expired ||
          t.state == TransferTaskState.failed) {
        await store.delete(t.id);
      }
    }
    await refresh();
  }

  @override
  Future<void> close() {
    _poll?.cancel();
    final listener = _xferListener;
    if (listener != null) {
      serviceLocator.nasTransferService().removeListener(listener);
    }
    return super.close();
  }
}
