import 'package:flutter/material.dart';

/// Sheet 内容统一四态骨架（doc/统一底栏弹窗机制.md §内容约定的落地件）。
///
/// 固定高度档下的四态渲染：
/// - 标题/副标题**首帧即绘**（先出壳），footer 贴底常驻；
/// - 主体区占满剩余空间，loading/error → content 仅做
///   淡出+缩放+淡入转场——**高度零变化**（壳层固定高度档），
///   各态内容在等大的主体区内居中或顶对齐，无占位高度需要对齐。
///
/// 用法：
/// ```dart
/// AppSheet.show(
///   context: context,
///   heightFactor: 0.62,
///   builder: (_) => AppSheetBody(
///     title: '配对本机',
///     subtitle: '对方可扫码…',
///     loading: payload == null,
///     child: QrBlock(payload),
///   ),
/// );
/// ```
class AppSheetBody extends StatelessWidget {
  const AppSheetBody({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.subtitleWidget,
    this.loading = false,
    this.errorText,
    this.onRetry,
    this.footer,
  });

  /// 标题（首帧即绘，不依赖异步）。
  final String title;

  /// 副标题；null 则不占位。与 [subtitleWidget] 二选一，后者优先。
  final String? subtitle;

  /// 自定义副标题（可点链接 / 关闭按钮等）；优先于 [subtitle]。
  final Widget? subtitleWidget;

  /// 主体内容（loading/error 时隐藏）。在等大的主体区内渲染；
  /// 内容应顶对齐布局，超出部分内部滚动（如内嵌 ListView）。
  final Widget child;

  /// 异步未完成 → 主体区显示居中进度圈。
  final bool loading;

  /// 非空即进入错误态（优先级高于 loading）。
  final String? errorText;

  /// 错误态重试回调；null 则不显示重试按钮。
  final VoidCallback? onRetry;

  /// 底部常驻区（如密码复制条，不受四态影响，首帧即绘）。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitleWidget != null) ...[
            const SizedBox(height: 6),
            subtitleWidget!,
          ] else if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 18),
          // 主体区：占满剩余高度，四态同区切换——高度恒为零变化
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              // fadeThrough：淡出+缩放+淡入（M3 转场）
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween(begin: 0.96, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
                  child: child,
                ),
              ),
              child: _buildBodyArea(context),
            ),
          ),
          if (footer != null) ...[const SizedBox(height: 18), footer!],
        ],
      ),
    );
  }

  Widget _buildBodyArea(BuildContext context) {
    if (errorText != null) {
      return _CenteredState(
        key: const ValueKey('error'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.warning_amber_outlined,
              size: 32,
              color: Colors.amber.shade700,
            ),
            const SizedBox(height: 10),
            Text(
              errorText!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      );
    }
    if (loading) {
      return const _CenteredState(
        key: ValueKey('loading'),
        child: CircularProgressIndicator(),
      );
    }
    // 内容态：占满主体区（内容自身顶对齐布局，留白/内部滚动由内容决定）
    return SizedBox.expand(key: const ValueKey('content'), child: child);
  }
}

/// loading/error 态：在等大主体区内居中。
class _CenteredState extends StatelessWidget {
  const _CenteredState({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(child: Center(child: child));
  }
}
