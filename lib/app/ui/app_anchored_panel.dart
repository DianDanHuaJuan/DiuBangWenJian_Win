import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Windows 桌面：相对锚点卡片弹出**同左同宽**面板（替代全宽底栏）。
///
/// - [anchorKey]：左右、宽度；上沿默认在锚点底边下方
/// - [anchorHeightFactor]：若提供，高度严格 = 锚点高度 × 该系数（本机卡 2/3）
/// - 否则高度按屏高 [heightFactor]；下方不够时才压缩
abstract final class AppAnchoredPanel {
  static const _edge = 12.0;
  static const _minSide = 80.0;

  /// 仅当锚点/Overlay 量不到时返回 null。
  static Future<T?>? tryShow<T>({
    required BuildContext context,
    required GlobalKey anchorKey,
    required WidgetBuilder builder,
    double heightFactor = 0.52,
    double gap = 8,
    double? anchorHeightFactor,
    bool allowOverlapAnchor = true,
  }) {
    final rect = _anchorRectInOverlay(context, anchorKey);
    if (rect == null) return null;

    final overlaySize = rect.overlaySize;
    final maxLeft = math.max(_edge, overlaySize.width - _edge);
    final left = rect.left.clamp(_edge, maxLeft).toDouble();
    final maxWidth = math.max(_minSide, overlaySize.width - left - _edge);
    final width =
        rect.width.clamp(math.min(200.0, maxWidth), maxWidth).toDouble();

    final bottomLimit = overlaySize.height - _edge;
    final maxPanelH = math.max(_minSide, overlaySize.height - 2 * _edge);

    final preferredTop = rect.bottom + gap;
    final spaceBelow = math.max(0.0, bottomLimit - preferredTop);

    final double top;
    final double height;
    if (anchorHeightFactor != null) {
      // 本机卡规则：高度必须是卡高 × 系数，不因下方空间不足而裁矮。
      height = (rect.height * anchorHeightFactor.clamp(0.15, 1.0))
          .clamp(_minSide, maxPanelH)
          .toDouble();
      top = preferredTop + height <= bottomLimit
          ? preferredTop
          : math.max(_edge, bottomLimit - height);
    } else {
      final desired = (overlaySize.height * heightFactor.clamp(0.22, 0.85))
          .clamp(_minSide, maxPanelH)
          .toDouble();
      if (spaceBelow >= desired) {
        top = preferredTop;
        height = desired;
      } else if (spaceBelow >= _minSide) {
        top = preferredTop;
        height = spaceBelow;
      } else if (allowOverlapAnchor) {
        height = desired;
        top = math.max(_edge, bottomLimit - height);
      } else {
        final h = math.min(desired, maxPanelH);
        final minTop = math.max(_edge, bottomLimit - h);
        final flushTop = preferredTop - math.max(0.0, h - spaceBelow);
        height = h;
        top = math.max(minTop, math.min(flushTop, bottomLimit - h));
      }
    }

    return showGeneralDialog<T>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final slide = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                width: width,
                height: height,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 1),
                    end: Offset.zero,
                  ).animate(slide),
                  child: Material(
                    color: Colors.white,
                    elevation: 10,
                    shadowColor: Colors.black26,
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: builder(dialogContext),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          child,
    );
  }

  static _AnchorRect? _anchorRectInOverlay(
    BuildContext context,
    GlobalKey anchorKey,
  ) {
    final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayState = Overlay.maybeOf(context, rootOverlay: true);
    final overlayBox =
        overlayState?.context.findRenderObject() as RenderBox?;
    if (box == null ||
        !box.hasSize ||
        overlayBox == null ||
        !overlayBox.hasSize) {
      return null;
    }
    final origin =
        box.localToGlobal(Offset.zero) - overlayBox.localToGlobal(Offset.zero);
    return _AnchorRect(
      left: origin.dx,
      top: origin.dy,
      width: box.size.width,
      height: box.size.height,
      overlaySize: overlayBox.size,
    );
  }
}

class _AnchorRect {
  const _AnchorRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.overlaySize,
  });

  final double left;
  final double top;
  final double width;
  final double height;
  final Size overlaySize;

  double get bottom => top + height;
}
