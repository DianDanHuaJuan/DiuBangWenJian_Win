import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/di/service_locator.dart';
import '../../../core/discovery/peer_registry.dart';
import '../../../core/network/peer_address.dart';
import '../data/datasources/pairing_remote_data_source.dart';
import 'cubits/pairing_flow_cubit.dart';
import 'peer_landing.dart';

/// 右上角「密码连接」：先选定附近的一台设备，再只向它提交密码。
Future<void> pairByPassword(BuildContext context) async {
  final choice = await showDialog<_PasswordTarget>(
    context: context,
    builder: (dialogContext) => const _OverviewPasswordDialog(),
  );
  if (!context.mounted || choice == null) return;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF3D8A5A)),
              SizedBox(height: 16),
              Text('正在配对…'),
            ],
          ),
        ),
      ),
    ),
  );

  final cubit = PairingFlowCubit(
    hostService: serviceLocator.pairingHostService(),
    clientService: serviceLocator.pairingClientService(),
    deviceIdentityService: serviceLocator.deviceIdentityService,
    transport: const PairingRemoteDataSource(),
    onPaired: (peer) => serviceLocator.onPairingSettled(peer),
  );

  late final PairingFlowState result;
  try {
    cubit.startPassword();
    await cubit.submitPassword(
      password: choice.password,
      host: choice.host,
      port: choice.port,
    );
    result = cubit.state;
  } finally {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    await cubit.close();
  }

  if (!context.mounted) return;
  if (result is PairingFlowSuccess) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('配对成功：${result.peerName}')),
    );
    await openPairedPeer(
      context,
      result.peerFingerprint,
      requireOnline: false,
    );
  } else if (result is PairingFlowFailed) {
    final rejected = result.message.contains('拒绝') ||
        result.message.contains('密码');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(rejected ? '密码错误' : '无法连接该设备')),
    );
  }
}

class _PasswordTarget {
  const _PasswordTarget({
    required this.password,
    required this.host,
    required this.port,
  });

  final String password;
  final String host;
  final int port;
}

class _OverviewPasswordDialog extends StatefulWidget {
  const _OverviewPasswordDialog();

  @override
  State<_OverviewPasswordDialog> createState() =>
      _OverviewPasswordDialogState();
}

class _OverviewPasswordDialogState extends State<_OverviewPasswordDialog> {
  final _passwordController = TextEditingController();
  late List<OnlinePeer> _peers;
  String? _selectedFp;
  StreamSubscription<List<OnlinePeer>>? _nearbySub;

  @override
  void initState() {
    super.initState();
    _peers = _reachable(serviceLocator.peerRegistry().nearby);
    if (_peers.length == 1) _selectedFp = _peers.first.fingerprint;
    _passwordController.addListener(() => setState(() {}));
    _nearbySub = serviceLocator.peerRegistry().nearbyStream.listen((list) {
      if (!mounted) return;
      final next = _reachable(list);
      setState(() {
        _peers = next;
        final stillThere = next.any((peer) => peer.fingerprint == _selectedFp);
        if (!stillThere) {
          _selectedFp = next.length == 1 ? next.first.fingerprint : null;
        }
      });
    });
  }

  @override
  void dispose() {
    unawaited(_nearbySub?.cancel() ?? Future<void>.value());
    _passwordController.dispose();
    super.dispose();
  }

  List<OnlinePeer> _reachable(List<OnlinePeer> peers) {
    return [
      for (final peer in peers)
        if (PeerAddress.tryParse(peer.address) != null) peer,
    ];
  }

  void _submit() {
    final password = _passwordController.text.trim();
    final fp = _selectedFp;
    if (password.isEmpty || fp == null) return;
    OnlinePeer? peer;
    for (final item in _peers) {
      if (item.fingerprint == fp) {
        peer = item;
        break;
      }
    }
    final parsed = peer == null ? null : PeerAddress.tryParse(peer.address);
    if (parsed == null) return;
    Navigator.of(context).pop(
      _PasswordTarget(password: password, host: parsed.host, port: parsed.port),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final password = _passwordController.text.trim();
    final canSubmit = password.isNotEmpty && _selectedFp != null;
    return AlertDialog(
      title: const Text('选择目标设备'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_peers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '附近没有可配对的设备',
                  style: TextStyle(fontSize: 14, color: Color(0xFF8B867C)),
                ),
              )
            else
              Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFF3D8A5A)),
                ),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 168),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _peers.length,
                    itemBuilder: (context, index) {
                      final peer = _peers[index];
                      final selected = peer.fingerprint == _selectedFp;
                      final name =
                          peer.name.trim().isEmpty ? '未知设备' : peer.name;
                      return InkWell(
                        onTap: () =>
                            setState(() => _selectedFp = peer.fingerprint),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 22,
                                child: selected
                                    ? const Icon(
                                        Icons.check,
                                        size: 18,
                                        color: Color(0xFF3D8A5A),
                                      )
                                    : null,
                              ),
                              Expanded(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF1A1918),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              autofocus: _peers.isNotEmpty,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              style: const TextStyle(fontSize: 14, height: 1.2),
              decoration: const InputDecoration(
                isDense: true,
                labelText: '配对密码',
                hintText: '8 位数字',
                prefixIcon: Icon(Icons.lock_outline_rounded, size: 20),
                prefixIconConstraints: BoxConstraints(
                  minWidth: 40,
                  minHeight: 48,
                ),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canSubmit ? _submit : null,
          style: FilledButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: Colors.white,
          ),
          child: const Text('连接'),
        ),
      ],
    );
  }
}
