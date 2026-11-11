import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../di/service_locator.dart';
import 'route_paths.dart';

/// 回到设备列表并结束当前对端 WS 会话。
///
/// 凡「退出设备业务面回到列表」都必须走这里（或先
/// [PeerWsSession.leaveToDevicesList] 再 `go(devices)`），
/// 勿只 `context.go(RoutePaths.devices)`，否则会漏断连。
/// 详见 docs/architecture_notes.md §对端 WS 会话。
Future<void> goToDevicesList(BuildContext context) async {
  await serviceLocator.peerWsSession().leaveToDevicesList();
  if (!context.mounted) return;
  context.go(RoutePaths.devices);
}
