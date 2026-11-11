import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/backup/presentation/pages/backup_page.dart';
import '../../features/devices/presentation/pages/device_chat_page.dart';
import '../../features/devices/presentation/pages/device_files_page.dart';
import '../../features/devices/presentation/pages/devices_page.dart';
import '../../features/home/presentation/pages/home_shell_page.dart';
import '../../features/overview/presentation/pages/overview_page.dart';
import '../../features/preview/presentation/pages/video_preview_page.dart';
import '../../features/preview/presentation/preview_args.dart';
import '../../core/identity/device_identity_service.dart';
import '../../features/settings/presentation/pages/device_identity_page.dart';
import '../../features/settings/presentation/pages/settings_page.dart';
import '../../features/transfer/presentation/pages/transfers_page.dart';
import 'route_paths.dart';

/// 三导航路由表（doc/04 §7.2，决策 #16）：
/// Tab0 概览（初始）/ Tab1 设备（列表级→chat|files）/ Tab2 设置；
/// 传输、设备详情信息、预览、备份、peer 管理为顶层 push，阶段 2-4 陆续接入。
GoRouter buildAppRouter({GlobalKey<NavigatorState>? navigatorKey}) {
  return GoRouter(
    navigatorKey: navigatorKey,
    initialLocation: RoutePaths.overview,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShellPage(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: RoutePaths.overview,
                builder: (context, state) => const OverviewPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: RoutePaths.devices,
                builder: (context, state) => const DevicesPage(),
                routes: [
                  // self 保留字路由须声明在 :peerId 之前（匹配顺序）
                  GoRoute(
                    path: 'self/files',
                    builder: (context, state) =>
                        const DeviceFilesPage(isSelf: true),
                  ),
                  GoRoute(
                    path: ':peerId',
                    // 旧 interact 容器已删：裸 :peerId 默认进聊天
                    redirect: (context, state) {
                      final peerId = state.pathParameters['peerId']!;
                      final path = state.uri.path;
                      if (path == '/devices/$peerId') {
                        return RoutePaths.deviceChatFor(peerId);
                      }
                      return null;
                    },
                    routes: [
                      GoRoute(
                        path: 'chat',
                        builder: (context, state) => DeviceChatPage(
                          peerId: state.pathParameters['peerId']!,
                        ),
                      ),
                      GoRoute(
                        path: 'files',
                        builder: (context, state) => DeviceFilesPage(
                          isSelf: false,
                          peerId: state.pathParameters['peerId']!,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: RoutePaths.settings,
                builder: (context, state) => const SettingsPage(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: RoutePaths.transfers,
        builder: (context, state) => const TransfersPage(),
      ),
      GoRoute(
        path: RoutePaths.settingsIdentity,
        builder: (context, state) {
          final extra = state.extra;
          return DeviceIdentityPage(
            initialIdentity: extra is DeviceIdentity ? extra : null,
          );
        },
      ),
      GoRoute(
        path: RoutePaths.backupPlans,
        builder: (context, state) => const BackupPage(),
      ),
      GoRoute(
        path: RoutePaths.previewVideo,
        builder: (context, state) {
          final args = state.extra;
          if (args is! PreviewArgs) {
            return const Scaffold(
              body: Center(child: Text('缺少预览参数')),
            );
          }
          return VideoPreviewPage(args: args);
        },
      ),
    ],
  );
}
