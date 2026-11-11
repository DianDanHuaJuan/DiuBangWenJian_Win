import '../../../core/nas/nas_keep_alive.dart';
import 'nas_service_switch.dart';

/// 关闭 NAS：写开关 → 停 FGS 运行时 → 路由守卫 503、交回 UI 宿主。
class StopNasServiceUseCase {
  StopNasServiceUseCase({required NasServiceSwitch serviceSwitch})
      : _switch = serviceSwitch;

  final NasServiceSwitch _switch;

  Future<void> call() async {
    await _switch.setEnabled(false);
    await NasKeepAlive.sync(false);
  }
}
