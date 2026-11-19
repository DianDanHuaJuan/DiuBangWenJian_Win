import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../app/router/peer_session_navigation.dart';
import '../../../../app/ui/app_sheet.dart';
import '../../../../app/ui/app_sheet_body.dart';
import '../../../../core/common/app_logger.dart';
import '../../../../core/discovery/peer_registry.dart';
import '../../../../core/identity/device_identity_service.dart';
import '../../../../core/identity/peer.dart';
import '../../../../core/network/local_ipv4.dart';
import '../../../../core/network/peer_address.dart';
import '../../../../core/realtime/peer_runtime.dart';
import '../../../common/widgets/section_header.dart';
import '../../../devices/presentation/pairing_scan_helper.dart';
import '../../../devices/presentation/peer_landing.dart';
import '../../../devices/presentation/widgets/pairing_sheet.dart';
import '../../../nas/presentation/cubits/nas_control_cubit.dart';
import '../../../nas/presentation/widgets/nas_share_scope_section.dart';
import '../cubits/overview_cubit.dart';

/// 概览：本机信息卡（左）+ 伙伴设备（右）。
class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => OverviewCubit(),
      child: const _OverviewView(),
    );
  }
}

class _OverviewView extends StatefulWidget {
  const _OverviewView();

  @override
  State<_OverviewView> createState() => _OverviewViewState();
}

class _OverviewViewState extends State<_OverviewView> {
  /// 本机信息卡：弹窗同宽；高度 = 卡高 × 0.5。
  final GlobalKey _localCardKey = GlobalKey();

  /// 伙伴设备卡：连接码面板锚点。
  final GlobalKey _partnerCardKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => context.read<OverviewCubit>().refresh(),
          // 卡片按内容高度排布，不撑满视口：否则锚点贴底，下方同宽面板无空间可放。
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeader(
                  title: '概览',
                  trailing: _OverviewPairMenuButton(
                    partnerCardKey: _partnerCardKey,
                  ),
                ),
                const SizedBox(height: 16),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _LocalHeroCard(cardKey: _localCardKey),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: KeyedSubtree(
                          key: _partnerCardKey,
                          child: const _PartnerDevicesCard(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 概览标题右侧「+」：仿微信即时气泡（无动画、顶角、分隔项）。
class _OverviewPairMenuButton extends StatefulWidget {
  const _OverviewPairMenuButton({required this.partnerCardKey});

  final GlobalKey partnerCardKey;

  @override
  State<_OverviewPairMenuButton> createState() =>
      _OverviewPairMenuButtonState();
}

class _OverviewPairMenuButtonState extends State<_OverviewPairMenuButton> {
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _entry;

  static const _menuWidth = 152.0;
  /// 贴近本机信息可点行的浅底，不用微信黑底。
  static const _menuColor = Color(0xFFFAF9F7);
  static const _dividerColor = Color(0xFFE7E3DA);
  static const _fgColor = Color(0xFF1A1918);
  static const _iconColor = Color(0xFF3D8A5A);
  static const _arrowH = 7.0;
  static const _arrowW = 14.0;

  @override
  void dispose() {
    _dismiss();
    super.dispose();
  }

  void _dismiss() {
    _entry?.remove();
    _entry = null;
  }

  void _toggle() {
    if (_entry != null) {
      _dismiss();
      return;
    }
    _show();
  }

  void _show() {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    // 必须用 rootOverlay：左侧导航下内容区可能有嵌套 Overlay，
    // 若用局部 Overlay + 全局坐标，菜单会偏到窗口右侧外。
    final overlayState = Overlay.maybeOf(context, rootOverlay: true);
    final overlayBox =
        overlayState?.context.findRenderObject() as RenderBox?;
    if (box == null ||
        !box.hasSize ||
        overlayState == null ||
        overlayBox == null ||
        !overlayBox.hasSize) {
      return;
    }

    final origin = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final btnSize = box.size;
    final overlaySize = overlayBox.size;
    final btnCenterX = origin.dx + btnSize.width / 2;
    // 菜单右缘对齐加号右缘（仿微信），并夹在 overlay 内。
    var menuLeft = origin.dx + btnSize.width - _menuWidth;
    menuLeft = menuLeft.clamp(8.0, overlaySize.width - _menuWidth - 8);
    var menuTop = origin.dy + btnSize.height + 4;
    // 预估菜单高度（两项 + 箭头），必要时改向上展开。
    const estimatedMenuH = _arrowH + 48.0 * 2 + 1;
    if (menuTop + estimatedMenuH > overlaySize.height - 8) {
      menuTop = (origin.dy - estimatedMenuH - 4).clamp(8.0, overlaySize.height);
    }
    final arrowLeft = (btnCenterX - menuLeft - _arrowW / 2)
        .clamp(10.0, _menuWidth - _arrowW - 10);

    _entry = OverlayEntry(
      builder: (ctx) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _dismiss,
              ),
            ),
            Positioned(
              left: menuLeft,
              top: menuTop,
              child: Material(
                color: Colors.transparent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(left: arrowLeft),
                      child: CustomPaint(
                        size: const Size(_arrowW, _arrowH),
                        painter: const _MenuUpArrowPainter(color: _menuColor),
                      ),
                    ),
                    Container(
                      width: _menuWidth,
                      decoration: BoxDecoration(
                        color: _menuColor,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _dividerColor),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _menuItem(
                            icon: Icons.lock_outline_rounded,
                            label: '密码连接',
                            onTap: () {
                              _dismiss();
                              unawaited(pairByPassword(context));
                            },
                          ),
                          const Divider(
                            height: 1,
                            thickness: 1,
                            color: _dividerColor,
                          ),
                          _menuItem(
                            icon: Icons.qr_code_2_outlined,
                            label: '连接码',
                            onTap: () {
                              _dismiss();
                              unawaited(
                                showPairingSheet(
                                  context,
                                  preferredMode: PairingSheetMode.qrShow,
                                  anchorKey: widget.partnerCardKey,
                                  anchorHeightFactor: 2 / 3,
                                  compactText: true,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
    overlayState.insert(_entry!);
  }

  Widget _menuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(icon, size: 20, color: _iconColor),
              const SizedBox(width: 12),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  color: _fgColor,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 视觉 22×22，点击区约 36×36；锚点挂在整块点击区上，避免坐标漂移。
    return GestureDetector(
      key: _anchorKey,
      onTap: _toggle,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 36,
        height: 36,
        child: Center(
          child: Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF1A1918),
                width: 1.25,
              ),
            ),
            child: const Icon(
              Icons.add,
              size: 14,
              color: Color(0xFF1A1918),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuUpArrowPainter extends CustomPainter {
  const _MenuUpArrowPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(0, size.height)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _MenuUpArrowPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 白底信息卡（与奶油脚手架形成对比）。
BoxDecoration get _surfaceCard => BoxDecoration(
  color: Colors.white,
  borderRadius: BorderRadius.circular(18),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.06),
      blurRadius: 16,
      offset: const Offset(0, 6),
    ),
  ],
);

/// 本机信息栏：展示名/品牌/型号；可点 NAS 与局域网 IP。
class _LocalHeroCard extends StatefulWidget {
  const _LocalHeroCard({required this.cardKey});

  final GlobalKey cardKey;

  @override
  State<_LocalHeroCard> createState() => _LocalHeroCardState();
}

class _LocalHeroCardState extends State<_LocalHeroCard> {
  @override
  Widget build(BuildContext context) {
    return BlocBuilder<OverviewCubit, OverviewState>(
      builder: (context, overview) {
        return Container(
          key: widget.cardKey,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          decoration: _surfaceCard,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '本机信息',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A1918),
                ),
              ),
              const SizedBox(height: 22),
              FutureBuilder<DeviceIdentity>(
                future: overview.identityFuture,
                builder: (context, snapshot) {
                  final identity = snapshot.data;
                  return Column(
                    children: [
                      _InfoDisplayRow(
                        icon: Icons.badge_outlined,
                        label: '本机名',
                        value: identity?.deviceName.trim().isNotEmpty == true
                            ? identity!.deviceName.trim()
                            : '—',
                        valueColor: const Color(0xFF3D8A5A),
                      ),
                      const SizedBox(height: 16),
                      _InfoDisplayRow(
                        icon: Icons.business_outlined,
                        label: '品牌',
                        value: identity?.brand.trim().isNotEmpty == true
                            ? identity!.brand.trim()
                            : '—',
                      ),
                      const SizedBox(height: 16),
                      _InfoDisplayRow(
                        icon: Icons.computer_outlined,
                        label: '型号',
                        value: identity?.model.trim().isNotEmpty == true
                            ? identity!.model.trim()
                            : '—',
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              ValueListenableBuilder<String>(
                valueListenable: serviceLocator.hostAddressListenable,
                builder: (context, address, _) {
                  return _ActionChip(
                    icon: Icons.wifi_outlined,
                    label: address.isNotEmpty && address != '0.0.0.0'
                        ? (serviceLocator.hostInterfaceName.isEmpty
                            ? address
                            : '$address · ${serviceLocator.hostInterfaceName}')
                        : '局域网 IP',
                    onTap: () => _showLocalAddressPicker(context),
                    onLongPress: () {
                      if (address.isNotEmpty && address != '0.0.0.0') {
                        Clipboard.setData(ClipboardData(text: address));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制 IP')),
                        );
                      }
                    },
                  );
                },
              ),
              const SizedBox(height: 16),
              _NasServiceChip(widthAnchorKey: widget.cardKey),
              const SizedBox(height: 18),
              const Divider(height: 1, color: Color(0xFFE7E3DA)),
              const SizedBox(height: 18),
              ListenableBuilder(
                listenable: serviceLocator.localBasics,
                builder: (context, _) {
                  final stats = serviceLocator.localBasics.stats;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 16,
                      alignment: WrapAlignment.start,
                      children: [
                        _CompactMetric(
                          title: '内存',
                          progress: stats.memUsedRatio,
                          percentLabel: stats.memTotalBytes > 0
                              ? '${(stats.memUsedRatio * 100).round()}%'
                              : '—',
                          sizeLabel: stats.memTotalBytes > 0
                              ? '${_formatBytes(stats.memUsedBytes)}/${_formatBytes(stats.memTotalBytes)}'
                              : '—/—',
                        ),
                        for (final disk in stats.volumes)
                          _CompactMetric(
                            title: disk.label,
                            progress: disk.usedRatio,
                            percentLabel:
                                '${(disk.usedRatio * 100).round()}%',
                            sizeLabel:
                                '${_formatBytes(disk.usedBytes)}/${_formatBytes(disk.totalBytes)}',
                          ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showLocalAddressPicker(BuildContext context) {
    return AppSheet.show<void>(
      context: context,
      anchorKey: widget.cardKey,
      // 本机卡下方弹窗：高度 = 信息卡高度 × 2/3。
      anchorHeightFactor: 2 / 3,
      builder: (ctx) => _shrinkSheetText(
        ctx,
        child: const _LocalAddressSheetBody(),
      ),
    );
  }
}

/// 本机卡弹窗：字号整体缩小约一号（含硬编码 fontSize）。
Widget _shrinkSheetText(BuildContext context, {required Widget child}) {
  return MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: const TextScaler.linear(0.875),
    ),
    child: child,
  );
}

/// 本机信息栏只读行：无灰底；左图标+标签，值靠右。
class _InfoDisplayRow extends StatelessWidget {
  const _InfoDisplayRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor = const Color(0xFF1A1918),
  });

  final IconData icon;
  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF3D8A5A)),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF8B867C),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// NAS 胶囊：状态局限本组件，不触发身份/环区重建。
class _NasServiceChip extends StatelessWidget {
  const _NasServiceChip({this.widthAnchorKey});

  final GlobalKey? widthAnchorKey;

  Future<void> _setEnabled(
    BuildContext context,
    NasControlCubit cubit,
    bool value,
  ) async {
    if (!value) {
      await cubit.setEnabled(false);
      return;
    }

    // UI 线程预建共享根，避免首个远端 fs 请求触发建根。
    try {
      await serviceLocator.storageRootStore().ensureCurrent();
    } catch (e) {
      // 建根失败仍允许开 NAS（媒体墙可用）；fs 会带明确错误。
      AppLogger.log(
        'NAS enable ensureCurrent failed',
        scope: 'storage',
        error: e,
      );
    }
    if (!context.mounted) return;

    await cubit.setEnabled(true);
  }

  Future<void> _showNasDetailSheet(BuildContext context) {
    final cubit = serviceLocator.nasControlCubit();
    return AppSheet.show<void>(
      context: context,
      anchorKey: widthAnchorKey,
      anchorHeightFactor: 2 / 3,
      builder: (sheetContext) {
        return _shrinkSheetText(
          sheetContext,
          child: BlocProvider.value(
            value: cubit,
            child: BlocBuilder<NasControlCubit, NasControlState>(
              builder: (context, state) {
                return AppSheetBody(
                  title: 'NAS 服务',
                  child: Column(
                    children: [
                      Material(
                        color: const Color(0xFFF5F4F1),
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.dns_outlined,
                                size: 20,
                                color: Color(0xFF3D8A5A),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Text(
                                  'NAS服务',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF1A1918),
                                  ),
                                ),
                              ),
                              Text(
                                state.enabled ? '开启' : '关闭',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF8B867C),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Switch.adaptive(
                                value: state.enabled,
                                onChanged: (value) =>
                                    _setEnabled(context, cubit, value),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Expanded(
                        child: SingleChildScrollView(
                          child: NasShareScopeSection(),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: serviceLocator.nasControlCubit(),
      child: BlocBuilder<NasControlCubit, NasControlState>(
        builder: (context, state) {
          return _ActionChip(
            icon: Icons.dns_outlined,
            label: state.enabled ? 'NAS 服务 · 开' : 'NAS 服务 · 关',
            onTap: () => _showNasDetailSheet(context),
          );
        },
      ),
    );
  }
}

/// IP 胶囊：先出壳，列表在 sheet 内加载；重检不关 sheet。
class _LocalAddressSheetBody extends StatefulWidget {
  const _LocalAddressSheetBody();

  @override
  State<_LocalAddressSheetBody> createState() => _LocalAddressSheetBodyState();
}

class _LocalAddressSheetBodyState extends State<_LocalAddressSheetBody> {
  List<LocalIpv4Candidate>? _candidates;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await serviceLocator.localBasics.refresh(stats: false, address: true);
      final list = await serviceLocator.listLocalIpv4();
      if (!mounted) return;
      setState(() {
        _candidates = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _candidates;
    return ValueListenableBuilder<String>(
      valueListenable: serviceLocator.hostAddressListenable,
      builder: (context, selected, _) => AppSheetBody(
        title: '本机IP地址',
        subtitle: '多网卡设备可能会有多个本机IP，请选择合适的地址。',
        loading: _loading,
        errorText: _error != null ? '检测失败：$_error' : null,
        onRetry: () => unawaited(_reload()),
        footer: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.refresh, size: 20),
              title: const Text('重新检测网卡'),
              onTap: _loading ? null : () => unawaited(_reload()),
            ),
          ],
        ),
        child: candidates == null || candidates.isEmpty
            ? const Center(child: Text('未发现可用 IPv4'))
            : ListView(
                children: [
                  for (final c in candidates)
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(
                        c.address == selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 20,
                      ),
                      title: Text(c.address),
                      subtitle: Text(c.interfaceName),
                      selected: c.address == selected,
                      onTap: () async {
                        await serviceLocator.selectLocalAddress(
                          c.address,
                          interfaceName: c.interfaceName,
                        );
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    ),
                ],
              ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.onLongPress,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFAF9F7),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 18, color: const Color(0xFF3D8A5A)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1A1918),
                  ),
                ),
              ),
              const Icon(Icons.expand_more, size: 18, color: Color(0xFF8B867C)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 指标：标题在上、环心百分比、下方具体容量如 3.4GB/11GB。
class _CompactMetric extends StatelessWidget {
  const _CompactMetric({
    required this.title,
    required this.progress,
    required this.percentLabel,
    required this.sizeLabel,
  });

  final String title;
  final double progress;
  final String percentLabel;
  final String sizeLabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      child: Column(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF8B867C),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: 64,
            height: 64,
            child: CustomPaint(
              painter: _RingPainter(
                progress: progress.clamp(0.0, 1.0),
                color: const Color(0xFF3D8A5A),
                track: const Color(0xFFE8F3EB),
              ),
              child: Center(
                child: Text(
                  percentLabel,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF3D8A5A),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            sizeLabel,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A1918),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.track,
  });

  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 3.5;
    const stroke = 5.0;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = track
        ..strokeWidth = stroke
        ..style = PaintingStyle.stroke,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -3.141592653589793 / 2,
      2 * 3.141592653589793 * progress,
      false,
      Paint()
        ..color = color
        ..strokeWidth = stroke
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)}KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    final mb = bytes / (1024 * 1024);
    return mb >= 100
        ? '${mb.toStringAsFixed(0)}MB'
        : '${mb.toStringAsFixed(1)}MB';
  }
  final gb = bytes / (1024 * 1024 * 1024);
  return gb >= 100
      ? '${gb.toStringAsFixed(0)}GB'
      : '${gb.toStringAsFixed(1)}GB';
}

/// 伙伴设备：已配对列表；排序 已连接 → 在线 → 离线。
enum _PartnerLinkState { connected, online, offline }

class _PartnerDevicesCard extends StatefulWidget {
  const _PartnerDevicesCard();

  @override
  State<_PartnerDevicesCard> createState() => _PartnerDevicesCardState();
}

class _PartnerDevicesCardState extends State<_PartnerDevicesCard> {
  List<Peer> _peers = const [];
  List<OnlinePeer> _online = const [];
  StreamSubscription<List<OnlinePeer>>? _onlineSub;
  bool _listening = false;

  /// 用户手动折叠/展开；未记录时：已连接默认展开，其余默认收起。
  final Map<String, bool> _expandedOverride = {};

  @override
  void initState() {
    super.initState();
    serviceLocator.overviewVisible.addListener(_onVisibility);
    _onVisibility();
  }

  @override
  void dispose() {
    serviceLocator.overviewVisible.removeListener(_onVisibility);
    _stopListening();
    super.dispose();
  }

  void _onVisibility() {
    if (serviceLocator.overviewVisible.value) {
      _startListening();
    } else {
      _stopListening();
    }
  }

  void _startListening() {
    if (_listening) return;
    _listening = true;
    _peers = List.unmodifiable(serviceLocator.pairedPeers.value);
    _online = List.unmodifiable(serviceLocator.peerRegistry().onlinePaired);
    serviceLocator.pairedPeers.addListener(_onPeers);
    _onlineSub =
        serviceLocator.peerRegistry().onlinePairedStream.listen(_onOnline);
    serviceLocator.realtimeRegistry().changes.addListener(_onWsLinkChanged);
    serviceLocator.realtimeSession().changes.addListener(_onWsLinkChanged);
    if (mounted) setState(() {});
  }

  void _stopListening() {
    if (!_listening) return;
    _listening = false;
    serviceLocator.pairedPeers.removeListener(_onPeers);
    unawaited(_onlineSub?.cancel() ?? Future.value());
    _onlineSub = null;
    serviceLocator.realtimeRegistry().changes.removeListener(_onWsLinkChanged);
    serviceLocator.realtimeSession().changes.removeListener(_onWsLinkChanged);
  }

  void _onPeers() {
    if (!mounted || !_listening) return;
    setState(() {
      _peers = List.unmodifiable(serviceLocator.pairedPeers.value);
    });
  }

  void _onOnline(List<OnlinePeer> online) {
    if (!mounted || !_listening) return;
    setState(() {
      _online = List.unmodifiable(online);
    });
  }

  void _onWsLinkChanged() {
    if (!mounted || !_listening) return;
    setState(() {});
  }

  _PartnerLinkState _linkState(String fingerprint, OnlinePeer? online) {
    final session = serviceLocator.realtimeSession();
    final outbound =
        session.isConnected && session.connectedPeer == fingerprint;
    final inbound = serviceLocator.realtimeRegistry().get(fingerprint) != null;
    if (outbound || inbound) return _PartnerLinkState.connected;
    if (online != null) return _PartnerLinkState.online;
    return _PartnerLinkState.offline;
  }

  bool _isExpanded(String fp, _PartnerLinkState state) {
    return _expandedOverride[fp] ?? (state == _PartnerLinkState.connected);
  }

  void _toggleExpanded(String fp, _PartnerLinkState state) {
    final next = !_isExpanded(fp, state);
    setState(() {
      _expandedOverride[fp] = next;
    });
    if (next && state == _PartnerLinkState.connected) {
      unawaited(serviceLocator.peerStatusService().requestStatus(fp));
    }
  }

  List<Peer> _sortedPeers(Map<String, OnlinePeer> onlineByFp) {
    final list = List<Peer>.from(_peers);
    int rank(Peer p) {
      switch (_linkState(p.fingerprint, onlineByFp[p.fingerprint])) {
        case _PartnerLinkState.connected:
          return 0;
        case _PartnerLinkState.online:
          return 1;
        case _PartnerLinkState.offline:
          return 2;
      }
    }

    list.sort((a, b) {
      final c = rank(a).compareTo(rank(b));
      if (c != 0) return c;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final onlineByFp = {for (final o in _online) o.fingerprint: o};
    final peers = _sortedPeers(onlineByFp);
    final onlineCount = peers
        .where(
          (p) =>
              _linkState(p.fingerprint, onlineByFp[p.fingerprint]) !=
              _PartnerLinkState.offline,
        )
        .length;

    return Container(
      decoration: _surfaceCard,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '伙伴设备',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const Spacer(),
              if (peers.isNotEmpty)
                Text(
                  '在线 $onlineCount',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: const Color(0xFF3D8A5A),
                        fontWeight: FontWeight.w700,
                      ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (peers.isEmpty)
            InkWell(
              onTap: () => unawaited(goToDevicesList(context)),
              borderRadius: BorderRadius.circular(12),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Text(
                  '暂无已配对设备',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Color(0xFF8B867C)),
                ),
              ),
            )
          else
            for (var i = 0; i < peers.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              _PartnerDeviceTile(
              peer: peers[i],
              online: onlineByFp[peers[i].fingerprint],
              linkState: _linkState(
                peers[i].fingerprint,
                onlineByFp[peers[i].fingerprint],
              ),
              expanded: _isExpanded(
                peers[i].fingerprint,
                _linkState(
                  peers[i].fingerprint,
                  onlineByFp[peers[i].fingerprint],
                ),
              ),
              onToggle: () => _toggleExpanded(
                peers[i].fingerprint,
                _linkState(
                  peers[i].fingerprint,
                  onlineByFp[peers[i].fingerprint],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PartnerDeviceTile extends StatelessWidget {
  const _PartnerDeviceTile({
    required this.peer,
    required this.linkState,
    required this.expanded,
    required this.onToggle,
    this.online,
  });

  final Peer peer;
  final OnlinePeer? online;
  final _PartnerLinkState linkState;
  final bool expanded;
  final VoidCallback onToggle;

  String get _statusLabel => switch (linkState) {
        _PartnerLinkState.connected => '已连接',
        _PartnerLinkState.online => '在线',
        _PartnerLinkState.offline => '离线',
      };

  BoxDecoration get _cardDecoration {
    switch (linkState) {
      case _PartnerLinkState.connected:
        return BoxDecoration(
          color: const Color(0xFFF0F9F0),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFC5E0C8)),
        );
      case _PartnerLinkState.online:
        return BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF3D8A5A), width: 1.25),
        );
      case _PartnerLinkState.offline:
        return BoxDecoration(
          color: const Color(0xFFF0EFEC),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF1A1918), width: 1),
        );
    }
  }

  Color get _statusColor => switch (linkState) {
        _PartnerLinkState.connected ||
        _PartnerLinkState.online =>
          const Color(0xFF3D8A5A),
        _PartnerLinkState.offline => const Color(0xFF9E9B94),
      };

  @override
  Widget build(BuildContext context) {
    final canOpen = linkState != _PartnerLinkState.offline;
    final rawAddress = online?.address ?? peer.lastSeenAddress;
    final ip = PeerAddress.tryParse(rawAddress)?.host ??
        (rawAddress != null && rawAddress.isNotEmpty ? rawAddress : '');
    final subtitleBits = <String>[
      _statusLabel,
      if (ip.isNotEmpty) ip,
    ];

    return Container(
      decoration: _cardDecoration,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: canOpen
                      ? () => unawaited(
                            openPairedPeer(context, peer.fingerprint),
                          )
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          peer.name.trim().isEmpty
                              ? '未命名设备'
                              : peer.name.trim(),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: linkState == _PartnerLinkState.offline
                                ? const Color(0xFF6E6B64)
                                : const Color(0xFF1A1918),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text.rich(
                          TextSpan(
                            style: const TextStyle(fontSize: 12),
                            children: [
                              for (var i = 0; i < subtitleBits.length; i++) ...[
                                if (i > 0)
                                  const TextSpan(
                                    text: ' · ',
                                    style: TextStyle(
                                      color: Color(0xFF8B867C),
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                TextSpan(
                                  text: subtitleBits[i],
                                  style: TextStyle(
                                    fontWeight: i == 0
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                    color: i == 0
                                        ? _statusColor
                                        : (linkState ==
                                                _PartnerLinkState.offline
                                            ? const Color(0xFF9E9B94)
                                            : const Color(0xFF8B867C)),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // 展开区单独可点，并扩大热区，避免误进聊天。
              InkWell(
                onTap: onToggle,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                  child: Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 22,
                    color: const Color(0xFF8B867C),
                  ),
                ),
              ),
            ],
          ),
          if (expanded) ...[
            const Divider(height: 1, color: Color(0xFFE7E3DA)),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 14),
              child: _PartnerDetailBody(
                peer: peer,
                online: online,
                linkState: linkState,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 伙伴详情：按连接态裁剪字段；电量/环图仅「已连接」展示。
class _PartnerDetailBody extends StatelessWidget {
  const _PartnerDetailBody({
    required this.peer,
    required this.linkState,
    this.online,
  });

  final Peer peer;
  final OnlinePeer? online;
  final _PartnerLinkState linkState;

  @override
  Widget build(BuildContext context) {
    final brand = peer.brand.trim().isNotEmpty
        ? peer.brand.trim()
        : (online?.brand.trim().isNotEmpty == true
            ? online!.brand.trim()
            : '—');
    final model = peer.model.trim().isEmpty ? '—' : peer.model.trim();
    final address = online?.address ?? peer.lastSeenAddress;
    final parsed = PeerAddress.tryParse(address);
    final ip = parsed?.host.isNotEmpty == true
        ? parsed!.host
        : (address != null && address.isNotEmpty ? address : '—');
    final nasLabel = online == null
        ? '未知'
        : (online!.nasService ? '已开启' : '已关闭');

    final showNetwork = linkState != _PartnerLinkState.offline;
    final showRuntime = linkState == _PartnerLinkState.connected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoDisplayRow(
          icon: Icons.business_outlined,
          label: '品牌',
          value: brand,
        ),
        const SizedBox(height: 14),
        _InfoDisplayRow(
          icon: Icons.phone_android_outlined,
          label: '型号',
          value: model,
        ),
        if (showNetwork) ...[
          const SizedBox(height: 14),
          _InfoDisplayRow(
            icon: Icons.wifi_outlined,
            label: '局域网',
            value: ip,
          ),
          const SizedBox(height: 14),
          _InfoDisplayRow(
            icon: Icons.dns_outlined,
            label: 'NAS服务',
            value: nasLabel,
          ),
        ],
        if (showRuntime) ...[
          const SizedBox(height: 14),
          _PartnerRuntimeSection(fingerprint: peer.fingerprint),
        ],
      ],
    );
  }
}

/// 动态区：仅订阅 Runtime，不拖累品牌/型号行。
class _PartnerRuntimeSection extends StatelessWidget {
  const _PartnerRuntimeSection({required this.fingerprint});

  final String fingerprint;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PeerRuntime?>(
      valueListenable:
          serviceLocator.peerRuntimeStore().listenable(fingerprint),
      builder: (context, runtime, _) {
        final bat = runtime?.batteryPercent;
        final charging = runtime?.isCharging == true;
        final batteryLabel = bat == null
            ? '—'
            : '${bat.clamp(0, 100)}%${charging ? ' · 充电中' : ''}';

        final memTotal = runtime?.memTotalBytes ?? 0;
        final memAvail = runtime?.memAvailBytes ?? 0;
        final memUsed = memTotal > 0 ? (memTotal - memAvail).clamp(0, memTotal) : 0;
        final storageTotal = runtime?.storageTotalBytes ?? 0;
        final storageAvail = runtime?.storageAvailBytes ?? 0;
        final storageUsed = storageTotal > 0
            ? (storageTotal - storageAvail).clamp(0, storageTotal)
            : 0;
        final extPresent = runtime?.externalPresent == true;
        final extTotal = runtime?.externalTotalBytes ?? 0;
        final extAvail = runtime?.externalAvailBytes ?? 0;
        final extUsed =
            extTotal > 0 ? (extTotal - extAvail).clamp(0, extTotal) : 0;

        final gap = extPresent && extTotal > 0 ? 10.0 : 16.0;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _InfoDisplayRow(
              icon: Icons.battery_std_outlined,
              label: '电量',
              value: batteryLabel,
              valueColor: charging
                  ? const Color(0xFF3D8A5A)
                  : const Color(0xFF1A1918),
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _CompactMetric(
                    title: '内存',
                    progress: memTotal > 0 ? memUsed / memTotal : 0,
                    percentLabel: memTotal > 0
                        ? '${((memUsed / memTotal) * 100).round()}%'
                        : '—',
                    sizeLabel: memTotal > 0
                        ? '${_formatBytes(memUsed)}/${_formatBytes(memTotal)}'
                        : '—/—',
                  ),
                ),
                SizedBox(width: gap),
                Expanded(
                  child: _CompactMetric(
                    title: '存储',
                    progress: storageTotal > 0 ? storageUsed / storageTotal : 0,
                    percentLabel: storageTotal > 0
                        ? '${((storageUsed / storageTotal) * 100).round()}%'
                        : '—',
                    sizeLabel: storageTotal > 0
                        ? '${_formatBytes(storageUsed)}/${_formatBytes(storageTotal)}'
                        : '—/—',
                  ),
                ),
                if (extPresent && extTotal > 0) ...[
                  SizedBox(width: gap),
                  Expanded(
                    child: _CompactMetric(
                      title: '外置',
                      progress: extUsed / extTotal,
                      percentLabel: '${((extUsed / extTotal) * 100).round()}%',
                      sizeLabel:
                          '${_formatBytes(extUsed)}/${_formatBytes(extTotal)}',
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}
