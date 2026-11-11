import 'package:flutter/material.dart';

/// 全项目唯一 Modal 底栏入口。见 `doc/统一底栏弹窗机制.md`。
///
/// 固定高度档：打开到关闭高度不变，避免内容到达时跳高。
/// 动画偏「长进短出 + 强减速」，大面板更连贯、少突兀。
abstract final class AppSheet {
  static const _radius = BorderRadius.vertical(top: Radius.circular(20));

  /// 选档惯例（屏高比例）：
  /// - 单开关/短说明 ≈ 0.30
  /// - 列表 ≈ 0.52
  /// - QR/表单 ≈ 0.55
  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    double heightFactor = 0.52,
  }) {
    final factor = heightFactor.clamp(0.22, 0.92);
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: _radius),
      clipBehavior: Clip.antiAlias,
      // 进场略拉长 + 强减速；退场更快，符合「重进轻出」
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
            height: mq.size.height * factor,
            child: builder(sheetContext),
          ),
        );
      },
    );
  }
}
