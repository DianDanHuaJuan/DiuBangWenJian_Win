import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:diubangwenjian/app/app.dart';
import 'package:diubangwenjian/app/bootstrap.dart';

void main() {
  // sqflite 在 VM 测试环境无平台通道——切 ffi 工厂
  // （bootstrap → hostService → peerRepository → sqlite 链路需要）
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // 单测试单 bootstrap：静态 MigrationRegistry/ServiceLocator 单例不支持
  // 进程内二次装配（宿主链路 fire-and-forget，二次 bootstrap 会撞已注册版本）
  testWidgets('3-tab shell, overview identity card, devices list', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await bootstrap();
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const DiuBangApp());
    // 身份采集带超时兜底（VM 环境平台通道挂起）——指纹 3 次重试 × 5s
    // + 设备信息 5s，最长 20s；推进 fake 时钟越过全链路超时
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();

    // 三导航（决策 #16）：概览/设备/设置
    expect(find.text('概览'), findsWidgets);
    expect(find.text('设备'), findsWidgets);
    expect(find.text('设置'), findsWidgets);
    expect(find.text('连接'), findsOneWidget);
    expect(find.text('文件'), findsNothing);

    // 概览本机卡（方案 A：VM 环境平台通道异常走服务层兜底值）
    expect(find.text('未知设备'), findsOneWidget);
    expect(find.text('unknown'), findsOneWidget);
    expect(find.text('局域网 IP'), findsOneWidget);
    expect(find.text('内存'), findsOneWidget);
    expect(find.text('存储'), findsOneWidget);
    expect(find.text('暂无'), findsOneWidget);

    // 概览「连接」→ 配对本机弹层（QR/密码；进场动画用有限 pump）
    await tester.tap(find.text('连接'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('配对本机'), findsOneWidget);
    await tester.tapAt(const Offset(50, 50));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('配对本机'), findsNothing);

    // 切到设备 Tab：统一列表（本机置顶）+ 下拉刷新
    await tester.tap(find.text('设备'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();

    expect(find.text('未知设备'), findsWidgets);
    expect(find.textContaining('下拉刷新'), findsOneWidget);
    expect(find.text('搜索设备'), findsNothing);
    expect(find.text('已配对'), findsNothing);
    expect(find.text('附近设备'), findsNothing);

    // 点击本机行 → /devices/self/files
    await tester.tap(find.text('未知设备').last);
    await tester.pumpAndSettle();
    expect(find.text('本机文件'), findsOneWidget);
  });
}
