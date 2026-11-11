import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 与相册多选相同的连续范围：从按下的那张到手指当前的那张。
///
/// 起点未选中则选上这一段，起点已选中则取消这一段。手指回退时，离开这段的格子回到按下前的状态。
class RangeDragSelection {
  var active = false;
  var origin = 0;
  var paintSelect = true;
  var low = 0;
  var high = 0;
  Set<String> baseline = const {};

  void begin({
    required int index,
    required bool alreadySelected,
    required Set<String> selected,
  }) {
    active = true;
    origin = index;
    paintSelect = !alreadySelected;
    low = index;
    high = index;
    baseline = Set<String>.from(selected);
  }

  Set<String> apply(int index, List<String?> keys) {
    low = math.min(low, index);
    high = math.max(high, index);
    final from = math.min(origin, index);
    final to = math.max(origin, index);
    final next = Set<String>.from(baseline);
    final start = math.max(0, low);
    final end = math.min(high, keys.length - 1);
    for (var i = start; i <= end; i++) {
      final key = keys[i];
      if (key == null) continue;
      if (i < from || i > to) continue;
      if (paintSelect) {
        next.add(key);
      } else {
        next.remove(key);
      }
    }
    return next;
  }

  void end() {
    active = false;
  }
}

/// 均匀格子（网格或单列列表）上，把内容坐标换成条目序号。
int? uniformIndex({
  required double contentX,
  required double contentY,
  required double width,
  required int crossAxisCount,
  required double paddingLeft,
  required double paddingRight,
  required double paddingTop,
  required double crossSpacing,
  required double mainSpacing,
  required double cellWidth,
  required double cellHeight,
  required int itemCount,
}) {
  if (itemCount <= 0 || crossAxisCount <= 0) return null;
  if (cellWidth <= 0 || cellHeight <= 0) return null;
  final x = contentX - paddingLeft;
  final y = contentY - paddingTop;
  if (x < 0 || y < 0) return null;
  final strideX = cellWidth + crossSpacing;
  final strideY = cellHeight + mainSpacing;
  if (strideX <= 0 || strideY <= 0) return null;
  var column = (x / strideX).floor();
  final row = (y / strideY).floor();
  if (column < 0 || row < 0) return null;
  if (column >= crossAxisCount) column = crossAxisCount - 1;
  final index = row * crossAxisCount + column;
  if (index < 0 || index >= itemCount) return null;
  return index;
}

double gridCellExtent({
  required double width,
  required int crossAxisCount,
  required double paddingLeft,
  required double paddingRight,
  required double crossSpacing,
}) {
  final inner = width - paddingLeft - paddingRight;
  return (inner - (crossAxisCount - 1) * crossSpacing) / crossAxisCount;
}

/// 网格或列表上的滑动多选。垂直轻扫仍交给滚动视图；贴边时自动滚动。
class DragSelectLayer extends StatefulWidget {
  const DragSelectLayer({
    super.key,
    required this.enabled,
    required this.selectionActive,
    required this.controller,
    required this.metrics,
    required this.keys,
    required this.selected,
    required this.onSelection,
    required this.child,
    this.commitOnLongPress = true,
    this.onStationaryLongPress,
  });

  final bool enabled;
  final bool selectionActive;
  final ScrollController controller;
  final UniformDragMetrics metrics;
  final List<String?> keys;
  final Set<String> selected;
  final ValueChanged<Set<String>> onSelection;
  final bool commitOnLongPress;
  final ValueChanged<int>? onStationaryLongPress;
  final Widget child;

  static bool owns(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_DragSelectScope>();
    return scope?.owns ?? false;
  }

  @override
  State<DragSelectLayer> createState() => _DragSelectLayerState();
}

class UniformDragMetrics {
  const UniformDragMetrics({
    required this.crossAxisCount,
    required this.paddingLeft,
    required this.paddingRight,
    required this.paddingTop,
    required this.crossSpacing,
    required this.mainSpacing,
    this.fixedCellHeight,
  });

  final int crossAxisCount;
  final double paddingLeft;
  final double paddingRight;
  final double paddingTop;
  final double crossSpacing;
  final double mainSpacing;
  final double? fixedCellHeight;

  static const grid = UniformDragMetrics(
    crossAxisCount: 4,
    paddingLeft: 24,
    paddingRight: 24,
    paddingTop: 0,
    crossSpacing: 4,
    mainSpacing: 4,
  );

  static const fileList = UniformDragMetrics(
    crossAxisCount: 1,
    paddingLeft: 8,
    paddingRight: 8,
    paddingTop: 0,
    crossSpacing: 0,
    mainSpacing: 0,
    fixedCellHeight: 73,
  );
}

class _DragSelectScope extends InheritedWidget {
  const _DragSelectScope({required this.owns, required super.child});

  final bool owns;

  @override
  bool updateShouldNotify(_DragSelectScope oldWidget) => owns != oldWidget.owns;
}

class _DragSelectLayerState extends State<DragSelectLayer> {
  static const _slop = 12.0;
  /// 贴边自动滚：慢爬，避免拖选时格子抢手指。
  static const _autoScrollVelocity = 8.0;
  static const _bottomEdgeFraction = 0.38;
  static const _topEdgeFraction = 0.18;

  final _range = RangeDragSelection();
  EdgeDraggingAutoScroller? _auto;
  Offset? _startGlobal;
  Offset? _lastGlobal;
  var _moved = false;
  var _committed = false;
  var _listening = false;

  @override
  void dispose() {
    _stopAuto();
    _unlisten();
    super.dispose();
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    widget.controller.addListener(_onScrolled);
  }

  void _unlisten() {
    if (!_listening) return;
    _listening = false;
    widget.controller.removeListener(_onScrolled);
  }

  void _onScrolled() {
    final global = _lastGlobal;
    if (global == null || !_committed) return;
    _commitAt(global);
  }

  void _begin(Offset global, {required bool commitNow}) {
    if (!widget.controller.hasClients) return;
    if (widget.controller.position.isScrollingNotifier.value) return;
    final index = _indexAt(global);
    if (index == null) return;
    final key = widget.keys[index];
    _startGlobal = global;
    _lastGlobal = global;
    _moved = false;
    _committed = false;
    _range.begin(
      index: index,
      alreadySelected: key != null && widget.selected.contains(key),
      selected: widget.selected,
    );
    _ensureAuto();
    if (commitNow) {
      _moved = true;
      _commitAt(global);
    }
  }

  void _move(Offset global) {
    if (!_range.active) return;
    _lastGlobal = global;
    final start = _startGlobal;
    if (!_moved && start != null && (global - start).distance >= _slop) {
      _moved = true;
    }
    // 未真正开始刷选前不贴边滚动，避免格子先动。
    if (!_committed && !(widget.commitOnLongPress || _moved)) {
      return;
    }
    _commitAt(global);
    _followEdge(global);
  }

  void _commitAt(Offset global) {
    final index = _indexAt(global);
    if (index == null || !_range.active) return;
    _committed = true;
    _listen();
    final next = _range.apply(index, widget.keys);
    widget.onSelection(next);
  }

  void _end({required bool stationaryCallback}) {
    final index = _range.active ? _range.origin : null;
    final stationary = !_moved;
    _finish();
    if (stationaryCallback && stationary && index != null) {
      widget.onStationaryLongPress?.call(index);
    }
  }

  void _finish() {
    _stopAuto();
    _unlisten();
    _range.end();
    _startGlobal = null;
    _lastGlobal = null;
    _moved = false;
    _committed = false;
  }

  void _ensureAuto() {
    if (_auto != null || !widget.controller.hasClients) return;
    final ctx = widget.controller.position.context.notificationContext;
    if (ctx == null) return;
    final scrollable = Scrollable.maybeOf(ctx);
    if (scrollable == null) return;
    _auto = EdgeDraggingAutoScroller(
      scrollable,
      velocityScalar: _autoScrollVelocity,
    );
  }

  void _followEdge(Offset global) {
    if (!_committed) return;
    _ensureAuto();
    final auto = _auto;
    if (auto == null || !widget.controller.hasClients) return;
    final ctx = widget.controller.position.context.notificationContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final local = box.globalToLocal(global);
    final h = box.size.height;
    if (h <= 0) return;

    final nearBottom = local.dy >= h * (1 - _bottomEdgeFraction);
    final nearTop = local.dy <= h * _topEdgeFraction;
    if (!nearBottom && !nearTop) {
      auto.stopAutoScroll();
      return;
    }

    // 下沿更宽、探测区更大，方便缓缓露出下方未选；上沿更钝，减少内容下移盖住手指。
    final probeH = nearBottom ? 80.0 : 28.0;
    final biasY = nearBottom ? 20.0 : -6.0;
    auto.startAutoScrollIfNecessary(
      Rect.fromCenter(
        center: Offset(local.dx, local.dy + biasY),
        width: 24,
        height: probeH,
      ),
    );
  }

  void _stopAuto() {
    _auto?.stopAutoScroll();
    _auto = null;
  }

  int? _indexAt(Offset global) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !widget.controller.hasClients) {
      return null;
    }
    final origin = box.localToGlobal(Offset.zero);
    final metrics = widget.metrics;
    final cellWidth = gridCellExtent(
      width: box.size.width,
      crossAxisCount: metrics.crossAxisCount,
      paddingLeft: metrics.paddingLeft,
      paddingRight: metrics.paddingRight,
      crossSpacing: metrics.crossSpacing,
    );
    return uniformIndex(
      contentX: global.dx - origin.dx,
      contentY: global.dy - origin.dy + widget.controller.offset,
      width: box.size.width,
      crossAxisCount: metrics.crossAxisCount,
      paddingLeft: metrics.paddingLeft,
      paddingRight: metrics.paddingRight,
      paddingTop: metrics.paddingTop,
      crossSpacing: metrics.crossSpacing,
      mainSpacing: metrics.mainSpacing,
      cellWidth: cellWidth,
      cellHeight: metrics.fixedCellHeight ?? cellWidth,
      itemCount: widget.keys.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    return _DragSelectScope(
      owns: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: enabled
            ? (details) => _begin(
                  details.globalPosition,
                  commitNow: widget.commitOnLongPress,
                )
            : null,
        onLongPressMoveUpdate:
            enabled ? (details) => _move(details.globalPosition) : null,
        onLongPressEnd: enabled
            ? (_) => _end(stationaryCallback: !widget.commitOnLongPress)
            : null,
        onLongPressCancel: enabled ? _finish : null,
        onHorizontalDragStart: enabled && widget.selectionActive
            ? (details) => _begin(details.globalPosition, commitNow: true)
            : null,
        onHorizontalDragUpdate: enabled && widget.selectionActive
            ? (details) => _move(details.globalPosition)
            : null,
        onHorizontalDragEnd: enabled && widget.selectionActive
            ? (_) => _end(stationaryCallback: false)
            : null,
        onHorizontalDragCancel:
            enabled && widget.selectionActive ? _finish : null,
        child: widget.child,
      ),
    );
  }
}
