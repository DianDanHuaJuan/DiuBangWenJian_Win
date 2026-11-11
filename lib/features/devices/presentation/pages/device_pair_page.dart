import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/discovery/peer_registry.dart';
import '../../../../core/network/peer_address.dart';
import '../../data/datasources/pairing_remote_data_source.dart';
import '../cubits/pairing_flow_cubit.dart';
import '../peer_landing.dart';

/// 连接/配对页（对齐旧客户端 ServerConnectForm）：
/// 设备信息 + 扫描主按钮 + 密钥配对描边按钮（密码在居中小弹窗输入）。
class DevicePairPage extends StatelessWidget {
  const DevicePairPage({super.key, required this.device});

  final OnlinePeer device;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => PairingFlowCubit(
        hostService: serviceLocator.pairingHostService(),
        clientService: serviceLocator.pairingClientService(),
        deviceIdentityService: serviceLocator.deviceIdentityService,
        transport: const PairingRemoteDataSource(),
        onPaired: (peer) => serviceLocator.onPairingSettled(peer),
      ),
      child: _DevicePairView(device: device),
    );
  }
}

class _DevicePairView extends StatefulWidget {
  const _DevicePairView({required this.device});

  final OnlinePeer device;

  @override
  State<_DevicePairView> createState() => _DevicePairViewState();
}

class _DevicePairViewState extends State<_DevicePairView> {
  late final String _host;
  late final int _port;

  @override
  void initState() {
    super.initState();
    final parsed = PeerAddress.tryParse(widget.device.address);
    _host = parsed?.host ?? '';
    _port = parsed?.port ?? defaultHostPort;
  }

  Future<void> _openScanner() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Windows 版暂不支持摄像头扫码，请使用密码配对'),
      ),
    );
  }

  Future<void> _showPasswordDialog() async {
    if (_host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设备地址无效，请重新搜索')),
      );
      return;
    }

    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => const _PasswordPairDialog(),
    );
    if (!mounted || password == null || password.isEmpty) return;

    final cubit = context.read<PairingFlowCubit>();
    cubit.startPassword();
    await cubit.submitPassword(
      password: password,
      host: _host,
      port: _port,
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return BlocConsumer<PairingFlowCubit, PairingFlowState>(
      listener: (context, state) async {
        if (state is PairingFlowSuccess) {
          final messenger = ScaffoldMessenger.of(context);
          messenger.showSnackBar(
            SnackBar(content: Text('配对成功：${state.peerName}')),
          );
          if (!context.mounted) return;
          Navigator.of(context).pop();
          if (!context.mounted) return;
          await openPairedPeer(
            context,
            state.peerFingerprint,
            requireOnline: false,
          );
        }
      },
      builder: (context, state) {
        final busy = state is PairingFlowRunning;
        final failed = state is PairingFlowFailed ? state.message : null;

        // 字号/色值对齐概览：主色 #3D8A5A、辅文 #8B867C、脚手架 #F5F4F1
        const overviewPrimary = Color(0xFF3D8A5A);
        const overviewMuted = Color(0xFF8B867C);
        final buttonStyle = ElevatedButton.styleFrom(
          backgroundColor: overviewPrimary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: overviewPrimary.withValues(alpha: 0.45),
          disabledForegroundColor: Colors.white.withValues(alpha: 0.9),
          minimumSize: const Size.fromHeight(48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            ),
        );
        final outlinedStyle = OutlinedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: overviewPrimary,
          disabledBackgroundColor: Colors.white,
          disabledForegroundColor: overviewPrimary.withValues(alpha: 0.45),
          minimumSize: const Size.fromHeight(48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          side: const BorderSide(color: overviewPrimary),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            ),
        );

        return Scaffold(
          backgroundColor: const Color(0xFFF5F4F1),
          appBar: AppBar(
            title: const Text('连接设备'),
            backgroundColor: const Color(0xFFF5F4F1),
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Text(
                  '请扫描对方连接二维码完成配对；或使用配对密码。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 13,
                        color: overviewMuted,
                      ),
                ),
                const SizedBox(height: 16),
                _DeviceInfoCard(
                  name: widget.device.name,
                  address: widget.device.address,
                ),
                if (failed != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8E8E6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      failed,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
                if (busy) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F3EB),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: primary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '正在配对…',
                            style: TextStyle(
                              color: primary,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                // 对齐旧客户端：主按钮扫码 + 次按钮密钥（尺寸/字色贴近概览）
                ElevatedButton.icon(
                  onPressed: busy ? null : _openScanner,
                  style: buttonStyle,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.qr_code_scanner_rounded, size: 18),
                  label: Text(busy ? '正在连接…' : '扫描连接二维码'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: busy ? null : _showPasswordDialog,
                  style: outlinedStyle,
                  icon: const Icon(Icons.lock_outline_rounded, size: 18),
                  label: const Text('配对密码接入'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 居中小弹窗输入配对密码（对齐旧客户端管理员账密登录窗口）。
class _PasswordPairDialog extends StatefulWidget {
  const _PasswordPairDialog();

  @override
  State<_PasswordPairDialog> createState() => _PasswordPairDialogState();
}

class _PasswordPairDialogState extends State<_PasswordPairDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _passwordController;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate() || _submitting) return;
    setState(() => _submitting = true);
    Navigator.of(context).pop(_passwordController.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return AlertDialog(
      title: const Text('配对密码接入'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _passwordController,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '配对密码',
                hintText: '对方连接码中的 8 位数字',
                prefixIcon: Icon(Icons.lock_outline_rounded),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return '请输入配对密码';
                }
                return null;
              },
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _submitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: primary,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(48),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('配对'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed:
                  _submitting ? null : () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: primary,
                minimumSize: const Size.fromHeight(48),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                side: BorderSide(color: primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceInfoCard extends StatelessWidget {
  const _DeviceInfoCard({
    required this.name,
    required this.address,
  });

  final String name;
  final String address;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        // 概览软绿底，区别于页面奶油脚手架
        color: const Color(0xFFE8F3EB),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.devices_rounded,
              size: 22,
              color: Color(0xFF3D8A5A),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? '未知设备' : name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1A1918),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  address.isEmpty ? '地址未知' : address,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: Color(0xFF8B867C),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
