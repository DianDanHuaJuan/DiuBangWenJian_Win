import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/discovery/discovery_foreground_guard.dart';
import 'di/service_locator.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';
import 'ui/app_dialog.dart';
import 'ui/stable_keyboard_insets.dart';

/// Root widget of the app.
class DiuBangApp extends StatefulWidget {
  const DiuBangApp({super.key});

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// 进程内单例，避免根 rebuild 时重建整棵导航树。
  static final GoRouter router = buildAppRouter(navigatorKey: navigatorKey);

  @override
  State<DiuBangApp> createState() => _DiuBangAppState();
}

class _DiuBangAppState extends State<DiuBangApp> with WidgetsBindingObserver {
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    serviceLocator.discoveryAlert.addListener(_onDiscoveryAlert);
  }

  @override
  void dispose() {
    serviceLocator.discoveryAlert.removeListener(_onDiscoveryAlert);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(serviceLocator.onAppResumed());
    }
  }

  void _onDiscoveryAlert() {
    final result = serviceLocator.discoveryAlert.value;
    if (result == null || result.ok) return;
    if (serviceLocator.discoveryFailurePrompted) return;
    unawaited(_showDiscoveryFailure(result));
  }

  Future<void> _showDiscoveryFailure(DiscoveryEnsureResult result) async {
    if (_dialogOpen) return;
    final nav = DiuBangApp.navigatorKey.currentState;
    final context = nav?.overlay?.context ?? nav?.context;
    if (context == null || !context.mounted) return;
    if (WidgetsBinding.instance.runtimeType
        .toString()
        .contains('TestWidgetsFlutterBinding')) {
      return;
    }

    serviceLocator.markDiscoveryFailurePrompted();
    _dialogOpen = true;
    try {
      final noNetwork = result.status == DiscoveryEnsureStatus.noNetwork;
      final retry = await AppDialog.confirm(
        context,
        title: noNetwork ? '网络未就绪' : '设备发现失败',
        message: noNetwork
            ? '当前没有可用局域网，附近设备列表可能为空。请连接 Wi‑Fi 或有线网络后重试。'
            : '无法加入局域网发现。可检查防火墙是否放行本应用，或稍后重试。',
        cancelLabel: '知道了',
        okLabel: '再试一次',
      );
      if (retry) {
        await serviceLocator.retryDiscoveryAfterPrompt();
      }
    } finally {
      _dialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: '铥棒文件',
      theme: buildAppTheme(),
      routerConfig: DiuBangApp.router,
      builder: (context, child) {
        return StableKeyboardInsets(
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
