import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../application/nas_service_switch.dart';
import '../../application/start_nas_service_use_case.dart';
import '../../application/stop_nas_service_use_case.dart';

class NasControlState {
  const NasControlState({
    required this.enabled,
  });

  final bool enabled;

  NasControlState copyWith({
    bool? enabled,
  }) =>
      NasControlState(
        enabled: enabled ?? this.enabled,
      );
}

/// 概览本机卡 NAS 开关（经 DI 状态流，决策 #15）。
class NasControlCubit extends Cubit<NasControlState> {
  NasControlCubit({
    required NasServiceSwitch serviceSwitch,
    required StartNasServiceUseCase start,
    required StopNasServiceUseCase stop,
  })  : _switch = serviceSwitch,
        _start = start,
        _stop = stop,
        super(
          NasControlState(
            enabled: serviceSwitch.isEnabled,
          ),
        ) {
    _sub = _switch.stream.listen((enabled) {
      emit(state.copyWith(enabled: enabled));
    });
  }

  final NasServiceSwitch _switch;
  final StartNasServiceUseCase _start;
  final StopNasServiceUseCase _stop;
  late final StreamSubscription<bool> _sub;

  Future<void> setEnabled(bool enabled) async {
    if (enabled) {
      await _start();
    } else {
      await _stop();
    }
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    return super.close();
  }
}
