import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../app/ui/app_sheet.dart';
import '../../../../app/ui/app_sheet_body.dart';
import '../../../../core/pairing/pairing_payload.dart';
import '../cubits/pairing_flow_cubit.dart';
import '../peer_landing.dart';
import '../../data/datasources/pairing_remote_data_source.dart';

/// 附近设备点入时优先打开的入口。
enum PairingSheetMode { menu, password, scan, qrShow }

/// 配对弹层入口（列表级顶栏「+」/空态引导/附近设备预填，doc/04 §4.2）。
Future<void> showPairingSheet(
  BuildContext context, {
  String? prefillHost,
  int? prefillPort,
  PairingSheetMode preferredMode = PairingSheetMode.menu,
  GlobalKey? anchorKey,
  /// 与本机卡弹窗一致：高度 = 锚点卡高 × 系数（概览连接码用 2/3）。
  double? anchorHeightFactor,
  /// 与本机卡弹窗一致：字号缩小约一号。
  bool compactText = false,
}) {
  final cubit = PairingFlowCubit(
    hostService: serviceLocator.pairingHostService(),
    clientService: serviceLocator.pairingClientService(),
    deviceIdentityService: serviceLocator.deviceIdentityService,
    transport: const PairingRemoteDataSource(),
    onPaired: (peer) => serviceLocator.onPairingSettled(peer),
  );
  if (preferredMode == PairingSheetMode.password) {
    cubit.startPassword();
  } else if (preferredMode == PairingSheetMode.scan) {
    cubit.startScan();
  } else if (preferredMode == PairingSheetMode.qrShow) {
    unawaited(cubit.startQrShow());
  }

  return AppSheet.show<void>(
    context: context,
    heightFactor: preferredMode == PairingSheetMode.qrShow ? 0.52 : 0.62,
    anchorKey: anchorKey,
    anchorHeightFactor: anchorHeightFactor,
    builder: (sheetContext) {
      Widget body = BlocProvider.value(
        value: cubit,
        child: BlocListener<PairingFlowCubit, PairingFlowState>(
          listener: (ctx, state) {
            if (state is PairingFlowSuccess) {
              final peerName = state.peerName;
              final peerFp = state.peerFingerprint;
              Future.delayed(const Duration(milliseconds: 900), () async {
                if (sheetContext.mounted) {
                  Navigator.of(sheetContext).maybePop();
                }
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('配对成功：$peerName')),
                );
                await openPairedPeer(
                  context,
                  peerFp,
                  requireOnline: false,
                );
              });
            }
          },
          child: PairingSheetBody(
            prefillHost: prefillHost,
            prefillPort: prefillPort,
            preferredMode: preferredMode,
          ),
        ),
      );
      if (compactText) {
        body = MediaQuery(
          data: MediaQuery.of(sheetContext).copyWith(
            textScaler: const TextScaler.linear(0.875),
          ),
          child: body,
        );
      }
      return body;
    },
  ).whenComplete(cubit.close);
}

class PairingSheetBody extends StatefulWidget {
  const PairingSheetBody({
    super.key,
    this.prefillHost,
    this.prefillPort,
    this.preferredMode = PairingSheetMode.menu,
  });

  final String? prefillHost;
  final int? prefillPort;
  final PairingSheetMode preferredMode;

  @override
  State<PairingSheetBody> createState() => _PairingSheetBodyState();
}

class _PairingSheetBodyState extends State<PairingSheetBody> {
  late final TextEditingController _passwordController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;

  @override
  void initState() {
    super.initState();
    _passwordController = TextEditingController();
    _hostController = TextEditingController(text: widget.prefillHost ?? '');
    _portController = TextEditingController(
      text: '${widget.prefillPort ?? defaultHostPort}',
    );
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: BlocBuilder<PairingFlowCubit, PairingFlowState>(
        builder: (context, state) => switch (state) {
          PairingFlowIdle() => _buildIdle(context),
          PairingFlowQrShow(
            :final payload,
            :final password,
            :final expiresAt,
            :final expired,
          ) =>
            _QrShowPanel(
              payload: payload,
              password: password,
              expiresAt: expiresAt,
              expired: expired,
            ),
          PairingFlowRunning(:final mode) => switch (mode) {
              PairingMode.qrShow => const AppSheetBody(
                  title: '连接码',
                  loading: true,
                  child: SizedBox.shrink(),
                ),
              PairingMode.scan => _buildScan(context),
              PairingMode.password => _buildPasswordForm(context),
            },
          PairingFlowFailed(:final message) => _buildFailed(context, message),
          PairingFlowSuccess(:final peerName) => _buildSuccess(peerName),
        },
      ),
    );
  }

  Widget _buildIdle(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 16),
        Text('添加设备', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.qr_code_2),
          title: const Text('我的二维码'),
          subtitle: const Text('展示给对方扫一扫'),
          onTap: () => context.read<PairingFlowCubit>().startQrShow(),
        ),
        ListTile(
          leading: const Icon(Icons.password_outlined),
          title: const Text('输入密码接入'),
          subtitle: const Text('输入对方连接码弹窗中的配对密码'),
          onTap: () => context.read<PairingFlowCubit>().startPassword(),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildScan(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('扫一扫', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text(
            'Windows 版暂不支持摄像头扫码，请使用「我的二维码」或「输入密码接入」。',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => context.read<PairingFlowCubit>().backToIdle(),
            child: const Text('返回'),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildPasswordForm(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('输入密码接入', style: Theme.of(context).textTheme.titleMedium),
          if (_hostController.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '目标 ${_hostController.text}:${_portController.text}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '配对密码',
              hintText: '对方连接码中的 8 位数字',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _hostController,
            decoration: const InputDecoration(
              labelText: '对方 IP 地址',
              hintText: '如 192.168.1.20',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _portController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '端口',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      context.read<PairingFlowCubit>().backToIdle(),
                  child: const Text('返回'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _submitPassword,
                  child: const Text('配对'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  void _submitPassword() {
    final password = _passwordController.text.trim();
    final host = _hostController.text.trim();
    if (password.isEmpty || host.isEmpty) return;
    final port = int.tryParse(_portController.text.trim()) ?? defaultHostPort;
    context.read<PairingFlowCubit>().submitPassword(
          password: password,
          host: host,
          port: port,
        );
  }

  Widget _buildFailed(BuildContext context, String message) {
    final fromQr =
        widget.preferredMode == PairingSheetMode.qrShow;
    return AppSheetBody(
      title: fromQr ? '连接码' : '添加设备',
      errorText: message,
      onRetry: () {
        if (fromQr) {
          context.read<PairingFlowCubit>().startQrShow();
        } else {
          context.read<PairingFlowCubit>().retry();
        }
      },
      child: const SizedBox.shrink(),
    );
  }

  Widget _buildSuccess(String peerName) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, size: 48, color: Colors.green),
          const SizedBox(height: 12),
          const Text('配对成功'),
          Text(peerName, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// 连接码展示：倒计时到期作废，提示刷新；不自动换新。
class _QrShowPanel extends StatefulWidget {
  const _QrShowPanel({
    required this.payload,
    required this.password,
    required this.expiresAt,
    required this.expired,
  });

  final PairingPayload payload;
  final String password;
  final DateTime expiresAt;
  final bool expired;

  @override
  State<_QrShowPanel> createState() => _QrShowPanelState();
}

class _QrShowPanelState extends State<_QrShowPanel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _armTimer();
    });
  }

  @override
  void didUpdateWidget(covariant _QrShowPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expiresAt != widget.expiresAt ||
        oldWidget.expired != widget.expired) {
      _armTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _armTimer() {
    _timer?.cancel();
    if (widget.expired) return;
    final left = widget.expiresAt.difference(DateTime.now());
    if (left <= Duration.zero) {
      unawaited(context.read<PairingFlowCubit>().markDisplayExpired());
      return;
    }
    _timer = Timer(left, () {
      if (!mounted) return;
      unawaited(context.read<PairingFlowCubit>().markDisplayExpired());
    });
  }

  @override
  Widget build(BuildContext context) {
    final expired = widget.expired;
    final passwordText = expired
        ? '········'
        : (widget.password.isEmpty ? '…' : widget.password);

    return AppSheetBody(
      title: '连接码',
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (expired) ...[
            const Text(
              '二维码已过期，请刷新。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Color(0xFF8B867C)),
            ),
            const SizedBox(height: 10),
          ],
          Material(
            color: const Color(0xFFF5F4F1),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    Icons.key_outlined,
                    size: 20,
                    color: expired
                        ? const Color(0xFFB8B4AA)
                        : const Color(0xFF3D8A5A),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '配对密码',
                    style: TextStyle(
                      fontSize: 14,
                      color: expired
                          ? const Color(0xFFB8B4AA)
                          : const Color(0xFF8B867C),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    passwordText,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                      color: expired
                          ? const Color(0xFFB8B4AA)
                          : const Color(0xFF1A1918),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => context.read<PairingFlowCubit>().startQrShow(),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('刷新'),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = (constraints.maxWidth < constraints.maxHeight
                  ? constraints.maxWidth
                  : constraints.maxHeight)
              .clamp(120.0, 220.0);
          return Center(
            child: Opacity(
              opacity: expired ? 0.28 : 1,
              child: QrImageView(
                data: widget.payload.encode(),
                size: side,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
          );
        },
      ),
    );
  }
}
