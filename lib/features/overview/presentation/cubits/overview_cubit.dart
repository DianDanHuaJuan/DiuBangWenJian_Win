import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/identity/device_identity_service.dart';

class OverviewState {
  const OverviewState({
    required this.identityFuture,
  });

  final Future<DeviceIdentity> identityFuture;

  OverviewState copyWith({
    Future<DeviceIdentity>? identityFuture,
  }) =>
      OverviewState(
        identityFuture: identityFuture ?? this.identityFuture,
      );
}

/// 概览页身份编排（doc/01 §七 期 D）。
/// 配对密码仅在连接码展示轮次中签发，不再由概览预拉。
class OverviewCubit extends Cubit<OverviewState> {
  OverviewCubit() : super(_initial());

  static OverviewState _initial() => OverviewState(
        identityFuture: serviceLocator.deviceIdentityService.identity,
      );

  void reloadFutures() {
    emit(_initial());
  }

  Future<void> refresh() async {
    reloadFutures();
    await Future.wait([
      state.identityFuture,
      serviceLocator.localBasics.refresh(),
      serviceLocator.peerStatusService().requestStatusFromConnectedPeers(),
      serviceLocator.probeOfflinePairedPeers(),
    ]);
  }

  Future<void> renameDevice(String newName) async {
    await serviceLocator.deviceIdentityService.rename(newName);
    await serviceLocator.publishLocalIdentityDisplay();
    reloadFutures();
  }
}
