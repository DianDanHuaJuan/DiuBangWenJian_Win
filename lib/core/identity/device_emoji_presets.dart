import 'dart:math';

/// 本机 / 对端展示用 emoji 预置（设置页与首次安装共用）。
abstract final class DeviceEmojiPresets {
  /// 固定 48 个：少量表情 + 动物 / 自然 / 食物 / 物品（无手势、无运动）。
  static const list = <String>[
    // 表情（原序列仅保留第 6、第 7）
    '😉', '😎',
    // 动物
    '🐱', '🐶', '🐼', '🦊', '🐸', '🐯', '🦁', '🐨',
    '🐵', '🐰', '🐻', '🦄', '🐝', '🦋', '🐙', '🐬',
    // 自然
    '🌸', '🍀', '🌻', '🌈', '☀️', '🌙',
    // 食物
    '🍎', '🍉', '🍇', '🍓', '🍕', '🍣', '🍩', '☕',
    // 物品
    '⭐', '🔥', '💡', '💎', '🎯', '🏆', '🎨', '📱',
    '💻', '📷', '🎧', '🎵', '🎮', '🏠', '🚗', '🚀',
  ];

  static String random([Random? random]) {
    final r = random ?? Random();
    return list[r.nextInt(list.length)];
  }
}
