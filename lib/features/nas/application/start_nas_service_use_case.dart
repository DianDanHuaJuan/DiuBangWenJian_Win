import '../../../core/nas/nas_keep_alive.dart';
import 'nas_service_switch.dart';

/// 开启 NAS：持久化开关 → 将宿主/发现装入 FGS 运行时。
class StartNasServiceUseCase {
  StartNasServiceUseCase({required NasServiceSwitch serviceSwitch})
      : _switch = serviceSwitch;

  final NasServiceSwitch _switch;

  Future<void> call() async {
    await _switch.setEnabled(true);
    await NasKeepAlive.sync(true);
  }
}
