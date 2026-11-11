import 'dart:async';

import 'package:flutter/material.dart';

/// 键盘动画的中间高度不传给子树（Windows 无原生 inset 通道，仅 settle）。
class StableKeyboardInsets extends StatefulWidget {
  const StableKeyboardInsets({super.key, required this.child});

  final Widget child;

  @override
  State<StableKeyboardInsets> createState() => _StableKeyboardInsetsState();
}

class _StableKeyboardInsetsState extends State<StableKeyboardInsets> {
  static const _settle = Duration(milliseconds: 80);

  double _committed = 0;
  double _live = 0;
  Timer? _settleTimer;

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  void _onLive(double live) {
    if ((live - _live).abs() < 0.5) return;
    _live = live;
    _settleTimer?.cancel();
    if (live <= 0.5) {
      _commit(0);
      return;
    }
    _settleTimer = Timer(_settle, () {
      if (!mounted) return;
      _commit(_live);
    });
  }

  void _commit(double next) {
    if ((next - _committed).abs() < 0.5) return;
    setState(() => _committed = next);
  }

  @override
  Widget build(BuildContext context) {
    return _FrozenKeyboardInsets(
      committedBottom: _committed,
      onLive: _onLive,
      child: widget.child,
    );
  }
}

class _FrozenKeyboardInsets extends StatelessWidget {
  const _FrozenKeyboardInsets({
    required this.committedBottom,
    required this.onLive,
    required this.child,
  });

  final double committedBottom;
  final ValueChanged<double> onLive;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final liveBottom = mq.viewInsets.bottom;
    WidgetsBinding.instance.addPostFrameCallback((_) => onLive(liveBottom));
    return MediaQuery(
      data: mq.copyWith(
        viewInsets: mq.viewInsets.copyWith(bottom: committedBottom),
      ),
      child: child,
    );
  }
}
