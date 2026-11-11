import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:path/path.dart' as path;
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

import '../common/app_logger.dart';
import '../common/key_value_store.dart';
import '../platform/app_platform.dart';

/// Windows 托盘 / 关窗 / 开机自启（docs/Win移植整体规划.md Q5–Q6）。
class DesktopRuntimeController with WindowListener {
  DesktopRuntimeController._();

  static final DesktopRuntimeController instance = DesktopRuntimeController._();

  static const launchMinimizedArgument = '--launch-minimized-to-tray';
  static const kvLaunchAtStartup = 'desktop.launch_at_startup';

  final WindowManager _windowManager = WindowManager.instance;
  final SystemTray _systemTray = SystemTray();

  KeyValueStore? _store;
  Future<void> Function()? _onExitCleanup;
  Future<void> Function(bool enabled)? _setNasEnabled;
  bool Function()? _isNasEnabled;

  bool _initialized = false;
  bool _trayReady = false;
  bool _trayInitAttempted = false;
  bool _launchHidden = false;
  bool _windowPresented = false;
  bool _isExiting = false;
  bool _isHidingWindow = false;

  static bool shouldLaunchHidden(List<String> startupArgs) {
    return AppPlatform.isWindows &&
        startupArgs.contains(launchMinimizedArgument);
  }

  bool get launchAtStartupEnabled =>
      _store?.getBool(kvLaunchAtStartup) ?? true;

  /// 托盘图标绝对路径（不依赖 CWD；优先 flutter_assets / 旁路 ico）。
  static String? resolveTrayIconPath() {
    if (!Platform.isWindows) return null;
    final executable = Platform.resolvedExecutable;
    final executableDir = path.dirname(executable);
    final candidates = <String>[
      path.join(executableDir, 'app_icon.ico'),
      path.join(
        executableDir,
        'data',
        'flutter_assets',
        'assets',
        'app_icon.ico',
      ),
      path.join(
        executableDir,
        'data',
        'flutter_assets',
        'windows',
        'runner',
        'resources',
        'app_icon.ico',
      ),
      path.join(executableDir, 'resources', 'app_icon.ico'),
      path.join(
        Directory.current.path,
        'windows',
        'runner',
        'resources',
        'app_icon.ico',
      ),
      path.join(Directory.current.path, 'assets', 'app_icon.ico'),
      path.normalize(
        path.join(
          executableDir,
          '..',
          '..',
          '..',
          '..',
          'windows',
          'runner',
          'resources',
          'app_icon.ico',
        ),
      ),
    ];
    for (final candidate in candidates) {
      final normalized = path.normalize(candidate);
      if (File(normalized).existsSync()) return normalized;
    }
    return null;
  }

  Future<void> prepareLaunch({
    required KeyValueStore store,
    required Future<void> Function() onExitCleanup,
    required Future<void> Function(bool enabled) setNasEnabled,
    required bool Function() isNasEnabled,
    required bool launchHidden,
  }) async {
    if (!AppPlatform.isWindows) return;

    _store = store;
    _onExitCleanup = onExitCleanup;
    _setNasEnabled = setNasEnabled;
    _isNasEnabled = isNasEnabled;
    _launchHidden = launchHidden;

    unawaited(_syncLaunchAtStartup(failSilently: true));

    if (_initialized) {
      await _ensureTrayInitialized();
      return;
    }

    await _windowManager.ensureInitialized();
    _windowManager.addListener(this);
    await _windowManager.setPreventClose(true);
    await _windowManager.setResizable(true);
    await _windowManager.setMinimumSize(const Size(960, 640));
    await _windowManager.setSize(const Size(1100, 720));

    _initialized = true;
    await _ensureTrayInitialized();
  }

  Future<void> presentWindowAfterFirstFrame() async {
    if (!AppPlatform.isWindows || !_initialized || _windowPresented) return;
    _windowPresented = true;

    await _windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1100, 720),
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        title: '铥棒文件',
      ),
      () async {
        await _ensureTrayInitialized();
        if (_launchHidden && _trayReady) {
          await _hideWindowToTray();
          return;
        }
        await showWindow();
      },
    );
  }

  Future<void> showWindow() async {
    if (!AppPlatform.isWindows) return;
    await _windowManager.setSkipTaskbar(false);
    await _windowManager.show();
    await _windowManager.focus();
    await _ensureTrayInitialized();
    if (_trayReady) {
      unawaited(_refreshTrayMenu());
    }
  }

  Future<void> setLaunchAtStartupEnabled(bool enabled) async {
    final store = _store;
    if (store == null) return;
    await store.setBool(kvLaunchAtStartup, enabled);
    await _syncLaunchAtStartup(failSilently: false);
    await _refreshTrayMenu();
  }

  Future<void> exitApplication() async {
    if (!AppPlatform.isWindows || _isExiting) return;
    _isExiting = true;
    try {
      try {
        await _onExitCleanup?.call();
      } catch (e, st) {
        AppLogger.log(
          'desktop exit cleanup failed',
          scope: 'desktop',
          error: e,
          stackTrace: st,
        );
      }
      if (_trayReady) {
        await _systemTray.destroy();
      }
      _windowManager.removeListener(this);
      await _windowManager.destroy();
    } finally {
      _isExiting = false;
    }
  }

  @override
  void onWindowClose() {
    if (_isExiting) return;
    if (_trayReady) {
      unawaited(_hideWindowToTray());
      return;
    }
    unawaited(exitApplication());
  }

  Future<void> _hideWindowToTray() async {
    if (_isHidingWindow) return;
    _isHidingWindow = true;
    try {
      await _windowManager.hide();
      await _windowManager.setSkipTaskbar(true);
    } finally {
      _isHidingWindow = false;
    }
  }

  Future<void> _ensureTrayInitialized() async {
    if (_trayReady) return;
    final iconPath = resolveTrayIconPath();
    if (iconPath == null) {
      if (!_trayInitAttempted) {
        AppLogger.log('tray icon missing', scope: 'desktop');
      }
      _trayInitAttempted = true;
      return;
    }
    _trayInitAttempted = true;
    try {
      await _systemTray.initSystemTray(
        iconPath: iconPath,
        toolTip: '铥棒文件',
      );
      _trayReady = true;
      _systemTray.registerSystemTrayEventHandler((eventName) {
        switch (eventName) {
          case kSystemTrayEventClick:
          case kSystemTrayEventDoubleClick:
            unawaited(showWindow());
            break;
          case kSystemTrayEventRightClick:
            unawaited(_systemTray.popUpContextMenu());
            break;
        }
      });
      await _refreshTrayMenu();
      AppLogger.log(
        'tray ready',
        scope: 'desktop',
        details: {'icon': iconPath},
      );
    } catch (e, st) {
      _trayReady = false;
      AppLogger.log(
        'tray init failed',
        scope: 'desktop',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _refreshTrayMenu() async {
    if (!_trayReady) return;
    final menu = Menu();
    final nasOn = _isNasEnabled?.call() ?? false;
    final visible = await _windowManager.isVisible();
    await menu.buildFrom([
      MenuItemLabel(
        label: visible ? '隐藏到托盘' : '显示主窗口',
        onClicked: (_) async {
          if (await _windowManager.isVisible()) {
            await _hideWindowToTray();
          } else {
            await showWindow();
          }
          await _refreshTrayMenu();
        },
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: nasOn ? '关闭 NAS' : '开启 NAS',
        onClicked: (_) async {
          final setNas = _setNasEnabled;
          if (setNas == null) return;
          await setNas(!nasOn);
          await _refreshTrayMenu();
        },
      ),
      MenuItemCheckbox(
        label: '开机自启',
        checked: launchAtStartupEnabled,
        onClicked: (_) async {
          await setLaunchAtStartupEnabled(!launchAtStartupEnabled);
        },
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: '退出',
        onClicked: (_) => unawaited(exitApplication()),
      ),
    ]);
    await _systemTray.setContextMenu(menu);
  }

  Future<void> _syncLaunchAtStartup({required bool failSilently}) async {
    try {
      final exe = Platform.resolvedExecutable;
      LaunchAtStartup.instance.setup(
        appName: '铥棒文件',
        appPath: exe,
        args: const [launchMinimizedArgument],
      );
      if (launchAtStartupEnabled) {
        await LaunchAtStartup.instance.enable();
      } else {
        await LaunchAtStartup.instance.disable();
      }
    } catch (e, st) {
      AppLogger.log(
        'launch_at_startup sync failed',
        scope: 'desktop',
        error: e,
        stackTrace: st,
      );
      if (!failSilently) rethrow;
    }
  }
}
