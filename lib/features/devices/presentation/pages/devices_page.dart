import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../app/router/route_paths.dart';
import '../../../../app/ui/app_dialog.dart';
import '../../../../core/discovery/peer_registry.dart';
import '../../../../core/identity/device_identity_service.dart';
import '../../../../core/identity/peer.dart';
import '../../../../core/network/peer_address.dart';
import '../../../common/widgets/section_header.dart';
import '../../../nas/presentation/cubits/nas_control_cubit.dart';
import '../peer_landing.dart';
import 'device_pair_page.dart';

/// 设备页：统一列表（本机置顶 + 已配对/新发现），底栏「搜索设备」。
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  Future<DeviceIdentity> _identity =
      serviceLocator.deviceIdentityService.identity;

  List<Peer> _paired = const [];
  List<OnlinePeer> _nearby = const [];
  List<OnlinePeer> _onlinePaired = const [];
  StreamSubscription<List<OnlinePeer>>? _nearbySub;
  StreamSubscription<List<OnlinePeer>>? _onlineSub;
  bool _listening = false;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    serviceLocator.devicesVisible.addListener(_onVisibility);
    _onVisibility();
  }

  @override
  void dispose() {
    serviceLocator.devicesVisible.removeListener(_onVisibility);
    _stopListening();
    super.dispose();
  }

  void _onVisibility() {
    if (serviceLocator.devicesVisible.value) {
      _startListening();
      // 从设置改名/换 emoji 返回时刷新本机卡。
      if (mounted) {
        setState(() {
          _identity = serviceLocator.deviceIdentityService.identity;
        });
      }
    } else {
      _stopListening();
      if (_searching && mounted) setState(() => _searching = false);
    }
  }

  void _startListening() {
    if (_listening) return;
    _listening = true;
    _paired = List.unmodifiable(serviceLocator.pairedPeers.value);
    _nearby = List.unmodifiable(serviceLocator.peerRegistry().nearby);
    _onlinePaired =
        List.unmodifiable(serviceLocator.peerRegistry().onlinePaired);
    serviceLocator.pairedPeers.addListener(_onPaired);
    _nearbySub =
        serviceLocator.peerRegistry().nearbyStream.listen(_onNearby);
    _onlineSub = serviceLocator
        .peerRegistry()
        .onlinePairedStream
        .listen(_onOnlinePaired);
    // 收包管道 + 过期报价清理；列表红点统一走 ChatUnreadStore。
    unawaited(_ensureOfferInbox());
    unawaited(
      serviceLocator.localBasics.refresh(stats: false, address: true),
    );
    // NAS FGS 占用发现时向后台要一帧在线快照。
    unawaited(serviceLocator.announceNowRouted());
    if (mounted) setState(() {});
  }

  Future<void> _ensureOfferInbox() async {
    try {
      await serviceLocator.ensureTransferStack();
      final offers = await serviceLocator.offerAcceptService();
      await offers.expireOffers();
    } catch (_) {}
  }

  void _stopListening() {
    if (!_listening) return;
    _listening = false;
    serviceLocator.pairedPeers.removeListener(_onPaired);
    unawaited(_nearbySub?.cancel() ?? Future.value());
    unawaited(_onlineSub?.cancel() ?? Future.value());
    _nearbySub = null;
    _onlineSub = null;
  }

  void _onPaired() {
    if (!mounted || !_listening) return;
    setState(() {
      _paired = List.unmodifiable(serviceLocator.pairedPeers.value);
    });
  }

  void _onNearby(List<OnlinePeer> list) {
    if (!mounted || !_listening) return;
    setState(() => _nearby = List.unmodifiable(list));
  }

  void _onOnlinePaired(List<OnlinePeer> list) {
    if (!mounted || !_listening) return;
    setState(() => _onlinePaired = List.unmodifiable(list));
  }

  Future<void> _refreshDevices() async {
    setState(() => _searching = true);
    try {
      await serviceLocator.forceDiscoveryColdStart(reason: 'devices_pull');
      await serviceLocator.probeOfflinePairedPeers();
      await serviceLocator.localBasics.refresh(stats: false, address: true);
      await Future<void>.delayed(const Duration(milliseconds: 800));
    } catch (_) {
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onlineByFp = {
      for (final o in _onlinePaired) o.fingerprint: o,
    };
    // 设备列表只展示在线项（已配对且在线 + 新发现）；离线已配对不出现在此。
    final others = <_DeviceRowData>[
      for (final peer in _paired)
        if (onlineByFp[peer.fingerprint] != null)
          _DeviceRowData.paired(
            peer: peer,
            online: onlineByFp[peer.fingerprint]!,
          ),
      for (final n in _nearby) _DeviceRowData.discovered(n),
    ];

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          color: const Color(0xFF3D8A5A),
          onRefresh: _refreshDevices,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 112),
            children: [
              const SectionHeader(
                title: '设备',
                // 占位：日后手动添加对端 IP；暂不展示入口。
                trailing: SizedBox(width: 36, height: 36),
              ),
              const SizedBox(height: 18),
              BlocBuilder<NasControlCubit, NasControlState>(
                bloc: serviceLocator.nasControlCubit(),
                builder: (context, nasState) {
                  return ValueListenableBuilder<String>(
                    valueListenable: serviceLocator.hostAddressListenable,
                    builder: (context, hostIp, _) {
                      return FutureBuilder<DeviceIdentity>(
                        future: _identity,
                        builder: (context, snapshot) {
                          final name = snapshot.data?.deviceName ?? '本机';
                          final ip = _displayIp(hostIp);
                          return _DeviceCard(
                            emoji: snapshot.data?.emoji ?? '',
                            title: name,
                            tags: const [
                              _DeviceTagLabel(
                                text: '本机',
                                color: _tagSelfBlue,
                              ),
                            ],
                            subtitle: _ipLine(
                              ip: ip,
                              nasOn: nasState.enabled,
                            ),
                            onTap: () =>
                                context.go(RoutePaths.devicesSelfFiles),
                            trailing: const Icon(
                              Icons.chevron_right,
                              size: 22,
                              color: Color(0xFFB0ADA6),
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              ),
              for (final row in others) ...[
                const SizedBox(height: 12),
                _RemoteDeviceCard(data: row),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

const Color _cardBg = Color(0xFFF0F9F0);
const Color _cardBorder = Color(0xFFD0E8D4);
const Color _tagSelfBlue = Color(0xFF3B82F6);
const Color _tagTrustedGreen = Color(0xFF2F6B45);
const Color _tagDiscoveredGreen = Color(0xFF5FA87A);
const Color _subtitleGray = Color(0xFF5C5A55);
const Color _nasHintGreen = Color(0xFF7DB892);
const Color _unreadDotRed = Color(0xFFE53935);

String _displayIp(String? raw) {
  final s = raw?.trim() ?? '';
  if (s.isEmpty || s == '0.0.0.0' || s == '::') return '';
  final parsed = PeerAddress.tryParse(s);
  if (parsed != null) return parsed.host;
  // 已是裸 IP（无端口）
  if (!s.contains(':') || s.startsWith('[')) {
    return PeerAddress.preferIpv4(s) ?? s;
  }
  return parsed?.host ?? '';
}

/// 副标题：仅 IP（+ 可选 NAS 标注），不含品牌。
String _ipLine({required String ip, bool nasOn = false}) {
  final base = ip.isNotEmpty ? ip : '地址未知';
  if (!nasOn) return base;
  return '$base · NAS服务';
}

TextSpan _subtitleSpans(String subtitle) {
  const nasSuffix = 'NAS服务';
  const baseStyle = TextStyle(
    fontSize: 13,
    height: 1.25,
    color: _subtitleGray,
  );
  const nasStyle = TextStyle(
    fontSize: 13,
    height: 1.25,
    fontWeight: FontWeight.w700,
    color: _nasHintGreen,
  );
  final idx = subtitle.lastIndexOf(nasSuffix);
  if (idx < 0) {
    return TextSpan(text: subtitle, style: baseStyle);
  }
  return TextSpan(
    children: [
      TextSpan(text: subtitle.substring(0, idx), style: baseStyle),
      const TextSpan(text: nasSuffix, style: nasStyle),
    ],
  );
}

class _DeviceRowData {
  const _DeviceRowData._({
    required this.title,
    required this.ip,
    required this.kind,
    required this.nasOn,
    this.peer,
    this.discovered,
    this.online,
  });

  factory _DeviceRowData.paired({
    required Peer peer,
    required OnlinePeer online,
  }) {
    return _DeviceRowData._(
      title: peer.name,
      ip: _displayIp(online.address),
      kind: _DeviceKind.paired,
      nasOn: online.nasService,
      peer: peer,
      online: online,
    );
  }

  factory _DeviceRowData.discovered(OnlinePeer device) {
    return _DeviceRowData._(
      title: device.name,
      ip: _displayIp(device.address),
      kind: _DeviceKind.discovered,
      nasOn: device.nasService,
      discovered: device,
      online: device,
    );
  }

  final String title;
  final String ip;
  final _DeviceKind kind;
  final bool nasOn;
  final Peer? peer;
  final OnlinePeer? discovered;
  final OnlinePeer? online;

  String get subtitle => _ipLine(ip: ip, nasOn: nasOn);

  /// 优先 peers 表，其次 announce 在线视图。
  String get emoji {
    final stored = peer?.emoji.trim() ?? '';
    if (stored.isNotEmpty) return stored;
    return online?.emoji.trim() ?? '';
  }

  /// 已信任（已配对在线）/ 新发现（未配对在线）。
  List<_DeviceTagLabel> get tags {
    if (kind == _DeviceKind.paired) {
      return const [
        _DeviceTagLabel(text: '已信任', color: _tagTrustedGreen),
      ];
    }
    return const [
      _DeviceTagLabel(text: '新发现', color: _tagDiscoveredGreen),
    ];
  }
}

enum _DeviceKind { paired, discovered }

class _RemoteDeviceCard extends StatelessWidget {
  const _RemoteDeviceCard({required this.data});

  final _DeviceRowData data;

  @override
  Widget build(BuildContext context) {
    final fp = data.peer?.fingerprint;
    final unread = serviceLocator.chatUnreadStore();
    return ListenableBuilder(
      listenable: unread,
      builder: (context, _) {
        // 文字 / 图片等入站统一：仅 ChatUnreadStore 红点，不显示数目。
        final showTip = fp != null &&
            data.kind == _DeviceKind.paired &&
            unread.hasUnread(fp);
        return _DeviceCard(
          emoji: data.emoji,
          title: data.title,
          tags: data.tags,
          subtitle: data.subtitle,
          onTap: () => _onTap(context),
          onLongPress: data.kind == _DeviceKind.paired
              ? () => unawaited(_confirmRevoke(context))
              : null,
          trailing: data.kind == _DeviceKind.discovered
              ? const Icon(Icons.link, size: 20, color: Color(0xFF3D8A5A))
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showTip)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 12,
                          height: 12,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: _unreadDotRed,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    const Icon(
                      Icons.chevron_right,
                      size: 22,
                      color: Color(0xFFB0ADA6),
                    ),
                  ],
                ),
        );
      },
    );
  }

  void _onTap(BuildContext context) {
    if (data.kind == _DeviceKind.discovered) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DevicePairPage(device: data.discovered!),
        ),
      );
      return;
    }
    unawaited(openPairedPeer(context, data.peer!.fingerprint));
  }

  Future<void> _confirmRevoke(BuildContext context) async {
    final peer = data.peer!;
    final ok = await AppDialog.confirm(
      context,
      title: '解除配对',
      message: '确定忘记「${peer.name}」？双方需各自解除后才能重新配对。',
      okLabel: '解除',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await serviceLocator.revokePeer(peer.fingerprint);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已解除与「${peer.name}」的配对')),
    );
  }
}

class _DeviceTagLabel {
  const _DeviceTagLabel({required this.text, required this.color});

  final String text;
  final Color color;
}

/// 单台设备卡片：淡绿底 + 淡绿描边，略放大字号与内边距。
class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.title,
    required this.tags,
    required this.subtitle,
    required this.onTap,
    this.emoji = '',
    this.onLongPress,
    this.trailing,
  });

  final String emoji;
  final String title;
  final List<_DeviceTagLabel> tags;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final face = emoji.trim().isEmpty ? '🙂' : emoji.trim();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          decoration: BoxDecoration(
            color: _cardBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _cardBorder, width: 1.25),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF3D8A5A).withValues(alpha: 0.07),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 5,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF3EC),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(face, style: const TextStyle(fontSize: 24)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          color: Color(0xFF1A1918),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text.rich(
                        _subtitleSpans(subtitle),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // 标签靠右、与展开箭头留间隙，勿贴标题也不贴 trailing。
                for (final tag in tags)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, right: 10),
                    child: Text(
                      tag.text,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: tag.color,
                        height: 1.2,
                      ),
                    ),
                  ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
