import 'package:flutter/material.dart';

/// 三导航页顶栏标题：居中、适中字号；可选右侧操作（如设备页「+」）。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
  });

  final String title;
  final Widget? trailing;

  static const double titleSize = 20;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleLarge?.copyWith(
          fontSize: titleSize,
          fontWeight: FontWeight.w400,
        );
    if (trailing == null) {
      return Text(title, textAlign: TextAlign.center, style: style);
    }
    return SizedBox(
      height: 36,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(title, textAlign: TextAlign.center, style: style),
          Align(
            alignment: Alignment.centerRight,
            child: trailing!,
          ),
        ],
      ),
    );
  }
}
