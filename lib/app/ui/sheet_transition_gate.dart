import 'package:flutter/material.dart';

/// 路由进场未完成前不挂载 [builder]，避免重活（如 QR 编码）吃掉滑动帧。
///
/// 业界常见做法：等 [ModalRoute.animation] 完成后再 mount 重子树，
/// 进场期间只画轻量 [placeholder]。
class SheetTransitionGate extends StatefulWidget {
  const SheetTransitionGate({
    super.key,
    required this.builder,
    this.placeholder,
  });

  final WidgetBuilder builder;
  final Widget? placeholder;

  @override
  State<SheetTransitionGate> createState() => _SheetTransitionGateState();
}

class _SheetTransitionGateState extends State<SheetTransitionGate> {
  Animation<double>? _animation;
  bool _ready = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _animation)) return;

    _animation?.removeStatusListener(_onStatus);
    _animation = animation;

    if (animation == null ||
        animation.status == AnimationStatus.completed ||
        animation.value >= 1.0) {
      _ready = true;
      return;
    }

    _ready = false;
    animation.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    // 再等一帧，避开进场最后一帧与首 layout 叠帧
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_ready) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_onStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.builder(context);
    return widget.placeholder ??
        const Center(child: CircularProgressIndicator());
  }
}
