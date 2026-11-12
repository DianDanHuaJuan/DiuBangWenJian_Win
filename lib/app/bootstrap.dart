import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/common/app_logger.dart';
import '../core/common/key_value_store.dart';
import '../core/desktop/desktop_runtime_controller.dart';
import '../core/nas/nas_keep_alive.dart';
import '../core/platform/app_platform.dart';
import '../core/storage/platform_sqlite.dart';
import '../features/nas/application/stop_nas_service_use_case.dart';
import 'di/service_locator.dart';

/// 启动编排：bindings → prefs → DI → 桌面壳。
Future<void> bootstrap({List<String> startupArgs = const []}) async {
  WidgetsFlutterBinding.ensureInitialized();
  PlatformSqlite.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final keyValueStore = KeyValueStore(sharedPreferences: prefs);
  await configureDependencies(keyValueStore: keyValueStore);

  if (AppPlatform.isWindows) {
    await DesktopRuntimeController.instance.prepareLaunch(
      store: keyValueStore,
      launchHidden:
          DesktopRuntimeController.shouldLaunchHidden(startupArgs),
      isNasEnabled: () => serviceLocator.isNasServiceEnabled,
      setNasEnabled: (enabled) async {
        final sw = serviceLocator.nasServiceSwitch();
        if (enabled) {
          await sw.setEnabled(true);
          await NasKeepAlive.sync(true);
        } else {
          await StopNasServiceUseCase(serviceSwitch: sw).call();
        }
      },
      onExitCleanup: () async {
        // 进程退出只停监听；NAS 开关保持上次用户选择，下次启动恢复。
        try {
          await serviceLocator.shutdownRuntimeForExit();
        } catch (_) {}
      },
    );
  }
}

void scheduleDeferredStartup() {
  SchedulerBinding.instance.addPostFrameCallback((_) {
    if (AppPlatform.isWindows) {
      unawaited(
        DesktopRuntimeController.instance.presentWindowAfterFirstFrame(),
      );
    }
    unawaited(
      serviceLocator.runDeferredStartup().catchError((Object e, StackTrace st) {
        AppLogger.log(
          'deferred startup FAILED',
          scope: 'boot',
          error: e,
          stackTrace: st,
        );
      }),
    );
  });
}
