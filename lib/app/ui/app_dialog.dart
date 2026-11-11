import 'package:flutter/material.dart';

/// 确认 / 改名等对话框入口。见 `doc/统一底栏弹窗机制.md`。
abstract final class AppDialog {
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String cancelLabel = '取消',
    String okLabel = '确定',
    bool destructive = false,
    /// 取消按钮文字色；例如灰色「拒绝」。
    Color? cancelForegroundColor,
    /// 确定按钮背景色；例如绿色「开启」。覆盖 [destructive] 配色。
    Color? okBackgroundColor,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      useRootNavigator: true, // 盖在 AppSheet 底栏之上，互不顶掉
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            style: cancelForegroundColor == null
                ? null
                : TextButton.styleFrom(foregroundColor: cancelForegroundColor),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            style: okBackgroundColor != null || destructive
                ? FilledButton.styleFrom(
                    backgroundColor: okBackgroundColor ??
                        const Color(0xFFB3261E),
                  )
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(okLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  static Future<String?> prompt(
    BuildContext context, {
    required String title,
    String? initial,
    String hint = '',
    String cancelLabel = '取消',
    String okLabel = '保存',
  }) {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(cancelLabel),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              Navigator.of(dialogContext).pop(value.isEmpty ? null : value);
            },
            child: Text(okLabel),
          ),
        ],
      ),
    );
  }

  static Future<void> alert(
    BuildContext context, {
    required String title,
    required String message,
    String okLabel = '知道了',
  }) {
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(okLabel),
          ),
        ],
      ),
    );
  }
}
