import 'package:flutter/material.dart';

import '../../core/platform/app_platform.dart';
import 'app_anchored_panel.dart';

/// 全项目唯一 Modal 底栏入口。见 `doc/统一底栏弹窗机制.md`。
///
/// 固定高度档：打开到关闭高度不变，避免内容到达时跳高。
/// Windows 且提供 [anchorKey] 时改为卡片下方同宽锚定面板。
abstract final class AppSheet {
  static const _radius = BorderRadius.vertical(top: Radius.circular(20));

  /// 选档惯例（屏高比例）：
  /// - 单开关/短说明 ≈ 0.30
  /// - 列表 ≈ 0.52
  /// - QR/表单 ≈ 0.55
  ///
  /// [anchorHeightFactor]：本机卡等场景用「锚点高度 × 系数」定高（如 2/3），
  /// 优先于 [heightFactor]。
  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    double heightFactor = 0.52,
    GlobalKey? anchorKey,
    double? anchorHeightFactor,
    bool allowOverlapAnchor = true,
  }) {
    final factor = heightFactor.clamp(0.22, 0.92);
    if (AppPlatform.isWindows && anchorKey != null) {
      try {
        final anchored = AppAnchoredPanel.tryShow<T>(
          context: context,
          anchorKey: anchorKey,
          heightFactor: factor,
          anchorHeightFactor: anchorHeightFactor,
          allowOverlapAnchor: allowOverlapAnchor,
          builder: builder,
        );
        if (anchored != null) return anchored;
      } catch (_) {
        // 仅几何异常时回退。
      }
    }
    final sheetFactor = anchorHeightFactor != null
        ? (anchorHeightFactor.clamp(0.22, 0.85))
        : factor;
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: _radius),
      clipBehavior: Clip.antiAlias,
      sheetAnimationStyle: AnimationStyle(
        duration: const Duration(milliseconds: 420),
        reverseDuration: const Duration(milliseconds: 260),
        curve: Curves.easeOutQuint,
        reverseCurve: Curves.easeInCubic,
      ),
      builder: (sheetContext) {
        final mq = MediaQuery.of(sheetContext);
        return Padding(
          padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
          child: SizedBox(
            height: mq.size.height * sheetFactor,
            child: builder(sheetContext),
          ),
        );
      },
    );
  }
}
