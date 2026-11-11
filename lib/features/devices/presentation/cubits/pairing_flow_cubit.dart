import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/common/app_logger.dart';
import '../../../../core/identity/device_identity_service.dart';
import '../../../../core/identity/peer.dart';
import '../../../../core/pairing/pairing_payload.dart';
import '../../../../core/pairing/pairing_services.dart';
import '../../data/datasources/pairing_remote_data_source.dart';
import '../../data/host_endpoints/pairing_endpoint.dart';

/// 配对弹层一次性状态机①（doc/04 §4.2，决策 #16）。
///
/// idle → pairing（qrShow | scan | password）→ success | failed；
/// 失败可重试回 idle。成功由 UI 层 toast + 关闭弹层（副作用不进状态）。
sealed class PairingFlowState {
  const PairingFlowState();
}

/// 初始：三个引导入口（我的二维码 / 扫一扫 / 输密码）。
class PairingFlowIdle extends PairingFlowState {
  const PairingFlowIdle();
}

/// 二维码展示态（等待被扫；payload 生成完成后进入）。
class PairingFlowQrShow extends PairingFlowState {
  const PairingFlowQrShow(
    this.payload, {
    required this.password,
    required this.expiresAt,
    this.expired = false,
  });

  final PairingPayload payload;

  /// 本轮配对密码（扫码备选，对方可手输接入）。
  final String password;

  /// 本轮过期时刻。
  final DateTime expiresAt;

  /// 已到期作废，等待用户刷新。
  final bool expired;

  PairingFlowQrShow copyWith({bool? expired}) => PairingFlowQrShow(
        payload,
        password: password,
        expiresAt: expiresAt,
        expired: expired ?? this.expired,
      );
}

/// 执行中（相机取景 / 密码提交 / 载荷生成）。
class PairingFlowRunning extends PairingFlowState {
  const PairingFlowRunning(this.mode);

  final PairingMode mode;
}

enum PairingMode { qrShow, scan, password }

/// 失败（密码错/票据失效/网络不可达/指纹不一致）；可重试回 idle。
class PairingFlowFailed extends PairingFlowState {
  const PairingFlowFailed(this.message);

  final String message;
}

/// 成功：双向写 peer 表完成（toast+落地跳转由 UI 层消费）。
class PairingFlowSuccess extends PairingFlowState {
  const PairingFlowSuccess({
    required this.peerName,
    required this.peerFingerprint,
  });

  final String peerName;
  final String peerFingerprint;
}

class PairingFlowCubit extends Cubit<PairingFlowState> {
  PairingFlowCubit({
    required Future<PairingHostService> hostService,
    required Future<PairingClientService> clientService,
    required this.deviceIdentityService,
    required this.transport,
    this.onPaired,
  })  : _hostService = hostService,
        _clientService = clientService,
        super(const PairingFlowIdle());

  final Future<PairingHostService> _hostService;
  final Future<PairingClientService> _clientService;
  final DeviceIdentityService deviceIdentityService;
  final PairingEnrollTransport transport;

  /// 配对成功钩子（传入刚写入的对方 peer；UI 注入 onPairingSettled）。
  final Future<void> Function(Peer peer)? onPaired;

  /// 「连接码」：开启展示轮次（QR + 密码，约 3 分钟）。
  ///
  /// 出码轮次：本进程宿主签发 ticket（与 enroll 同源）。
  Future<void> startQrShow() async {
    emit(const PairingFlowRunning(PairingMode.qrShow));
    try {
      // 展码前经 LocalBasics 刷新本机 IP（保留用户已选偏好）
      await serviceLocator.localBasics.refresh(stats: false, address: true);
      final identity = await deviceIdentityService.identity;
      if (identity.fingerprint == 'unavailable') {
        emit(const PairingFlowFailed('本机身份未就绪，请稍后重试'));
        return;
      }
      final round = await _beginDisplayRoundRouted();
      emit(
        PairingFlowQrShow(
          round.payload,
          password: round.password,
          expiresAt: round.expiresAt,
        ),
      );
    } catch (error) {
      AppLogger.log('QR show failed', scope: 'pairing', error: error);
      emit(const PairingFlowFailed('二维码生成失败，请重试'));
    }
  }

  /// 展示轮次到期：服务端作废，UI 进入过期态（等用户刷新）。
  Future<void> markDisplayExpired() async {
    final current = state;
    if (current is! PairingFlowQrShow || current.expired) return;
    await _endDisplayRoundRouted();
    emit(current.copyWith(expired: true));
  }

  /// 关闭弹窗时调用：立刻作废本轮码与密码。
  Future<void> endDisplaySession() async {
    await _endDisplayRoundRouted();
  }

  Future<PairingDisplayRound> _beginDisplayRoundRouted() async {
    final host = await _hostService;
    return host.beginDisplayRound();
  }

  Future<void> _endDisplayRoundRouted() async {
    final host = await _hostService;
    host.endDisplayRound();
  }

  @override
  Future<void> close() async {
    await endDisplaySession();
    return super.close();
  }

  /// 「扫一扫」：进入相机取景（扫码方）。
  void startScan() => emit(const PairingFlowRunning(PairingMode.scan));

  /// 「输密码」：进入密码表单（发起方）。
  void startPassword() =>
      emit(const PairingFlowRunning(PairingMode.password));

  /// 扫码结果回调（MobileScanner onDetect）。
  Future<void> handleScanned(String raw) async {
    if (state is! PairingFlowRunning ||
        (state as PairingFlowRunning).mode != PairingMode.scan) {
      return;
    }
    final payload = PairingPayload.decode(raw);
    if (payload == null) return;
    await _enrollQr(payload);
  }

  /// 密码提交。
  Future<void> submitPassword({
    required String password,
    required String host,
    required int port,
  }) async {
    if (state is! PairingFlowRunning ||
        (state as PairingFlowRunning).mode != PairingMode.password) {
      return;
    }
    try {
      await serviceLocator.ensureHostRunning();
      final identity = await deviceIdentityService.identity;
      final client = await _clientService;

      final sealed = await client.buildPasswordEnroll(
        password: password,
        fingerprint: identity.fingerprint,
        deviceName: identity.deviceName,
        brand: identity.brand,
        model: identity.model,
        listenPort: serviceLocator.hostPort,
        stableIdHash: await _selfStableIdHash(),
      );
      final sealedResponse = await transport.postEnroll(
        host: host,
        port: port,
        path: PairPasswordEndpoint.path,
        sealed: sealed,
      );
      if (sealedResponse == null) {
        emit(const PairingFlowFailed('无法连接对方或密码错误'));
        return;
      }
      final result = await client.consumePasswordResponse(
        password: password,
        sealedResponse: sealedResponse,
        host: host,
        port: port,
      );
      if (result == null) {
        emit(const PairingFlowFailed('应答校验失败，配对未完成'));
        return;
      }
      await onPaired?.call(result.peer);
      emit(PairingFlowSuccess(
        peerName: result.peer.name,
        peerFingerprint: result.peer.fingerprint,
      ));
    } on PairingTransportException catch (error) {
      AppLogger.log(
        'password enroll transport failed',
        scope: 'pairing',
        details: {'message': error.message},
      );
      emit(PairingFlowFailed(error.message));
    } catch (error, st) {
      AppLogger.log(
        'password enroll exception',
        scope: 'pairing',
        error: error,
        stackTrace: st,
      );
      emit(PairingFlowFailed('配对失败：$error'));
    }
  }

  void retry() {
    if (state is PairingFlowFailed) emit(const PairingFlowIdle());
  }

  void backToIdle() => emit(const PairingFlowIdle());

  Future<void> _enrollQr(PairingPayload payload) async {
    emit(const PairingFlowRunning(PairingMode.qrShow));
    try {
      await serviceLocator.ensureHostRunning();
      final identity = await deviceIdentityService.identity;
      final client = await _clientService;

      final package = await client.buildQrEnroll(
        payload: payload,
        fingerprint: identity.fingerprint,
        deviceName: identity.deviceName,
        brand: identity.brand,
        model: identity.model,
        listenPort: serviceLocator.hostPort,
        stableIdHash: await _selfStableIdHash(),
      );
      final sealedResponse = await transport.postEnroll(
        host: payload.host,
        port: payload.port,
        path: PairingEndpoint.path,
        sealed: package.sealed,
        expectedFingerprint: payload.fingerprint,
        extraBody: {
          'client_pub': package.clientPublicKey,
          'ticket': payload.ticket,
        },
      );
      if (sealedResponse == null) {
        emit(const PairingFlowFailed('无法连接对方或配对被拒绝'));
        return;
      }
      final result = await client.consumeQrResponse(
        payload: payload,
        sealedResponse: sealedResponse,
        sessionKey: package.sessionKey,
      );
      if (result == null) {
        emit(const PairingFlowFailed('应答校验失败（指纹不一致），配对未完成'));
        return;
      }
      await onPaired?.call(result.peer);
      emit(PairingFlowSuccess(
        peerName: result.peer.name,
        peerFingerprint: result.peer.fingerprint,
      ));
    } on PairingTransportException catch (error) {
      AppLogger.log(
        'QR enroll transport failed',
        scope: 'pairing',
        details: {'message': error.message},
      );
      emit(PairingFlowFailed(error.message));
    } catch (error, st) {
      AppLogger.log(
        'QR enroll exception',
        scope: 'pairing',
        error: error,
        stackTrace: st,
      );
      emit(PairingFlowFailed('配对失败：$error'));
    }
  }

  Future<String?> _selfStableIdHash() async {
    try {
      return await serviceLocator.stableDeviceIdService.stableIdHash();
    } catch (_) {
      return null;
    }
  }
}
