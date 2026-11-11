import 'package:flutter/material.dart';

/// 比设备卡略缩一号：上下 15 + 标题行 + 5 + 副标题行。
const double _kSettingsRowHeight =
    15 + (15 * 1.2) + 5 + (12 * 1.25) + 15;

/// 分组容器：轻微悬浮；行间居中约 3/4 宽细线。
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  /// 比 scaffold `#F5F4F1` 更白一点，仍低于纯白。
  static const Color _surface = Color(0xFFFCFBF9);
  static const Color _divider = Color(0xFFE7E3DA);

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Material(
      color: _surface,
      elevation: 1.5,
      shadowColor: Colors.black.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              const Align(
                child: FractionallySizedBox(
                  widthFactor: 0.75,
                  child: Divider(
                    height: 1,
                    thickness: 1,
                    color: _divider,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 设置行：高度 / 标题字号对齐设备卡；放入 [SettingsGroup] 内使用。
class SettingsEntryTile extends StatelessWidget {
  const SettingsEntryTile({
    super.key,
    required this.title,
    required this.onTap,
    this.icon,
    this.leading,
  });

  final IconData? icon;
  final Widget? leading;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: _kSettingsRowHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
            child: Row(
              children: [
                leading ??
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAF3EC),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(
                        icon,
                        size: 22,
                        color: const Color(0xFF3D8A5A),
                      ),
                    ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                      color: Color(0xFF1A1918),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: Colors.black.withValues(alpha: 0.32),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
