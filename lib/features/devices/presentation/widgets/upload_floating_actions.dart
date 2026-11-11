import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app/di/service_locator.dart';
import '../../../../core/task/transfer_task.dart';
import '../../../../core/transfer/nas_transfer_service.dart';

/// 对端文件页的上传悬浮球：可拖动，点开后横向展开相册/文件。
///
/// 上传进度统一由壳层 [TransferProgressBar] 展示，此处上传中仅隐藏悬浮球，避免双条叠显。
class UploadFloatingActions extends StatefulWidget {
  const UploadFloatingActions({
    super.key,
    required this.peerId,
    required this.showUploadAction,
    required this.onUploadMediaTap,
    required this.onUploadFilesTap,
  });

  final String peerId;
  final bool showUploadAction;
  final VoidCallback onUploadMediaTap;
  final VoidCallback onUploadFilesTap;

  @override
  State<UploadFloatingActions> createState() => _UploadFloatingActionsState();
}

class _UploadFloatingActionsState extends State<UploadFloatingActions> {
  static const double _uploadBubbleSize = 68;
  static const double _optionBubbleSize = 56;
  static const double _screenMargin = 24;
  static const double _optionSpacing = 12;

  Offset? _uploadOffset;
  bool _menuExpanded = false;
  var _isUploading = false;
  late final NasTransferService _xfer;

  @override
  void initState() {
    super.initState();
    _xfer = serviceLocator.nasTransferService()..addListener(_onXferChanged);
    unawaited(_refreshUpload());
  }

  void _onXferChanged() => unawaited(_refreshUpload());

  @override
  void didUpdateWidget(UploadFloatingActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerId != widget.peerId) {
      unawaited(_refreshUpload());
    }
  }

  @override
  void dispose() {
    _xfer.removeListener(_onXferChanged);
    super.dispose();
  }

  Future<void> _refreshUpload() async {
    final tasks = await _xfer.snapshotLiveTasks();
    var uploading = false;
    for (final task in tasks) {
      if (task.type != TransferTaskType.nasUpload) continue;
      if (task.peerFingerprint != widget.peerId) continue;
      uploading = true;
      break;
    }
    if (!mounted || uploading == _isUploading) return;
    setState(() {
      _isUploading = uploading;
      if (uploading) _menuExpanded = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final obstruction = _bottomObstruction(mediaQuery);

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 上传中交给壳底栏进度条；本页不另画一条。
          if (_isUploading || !widget.showUploadAction) {
            return const SizedBox.shrink();
          }

          final uploadOffset = _resolveUploadOffset(
            constraints: constraints,
            obstruction: obstruction,
            padding: mediaQuery.padding,
          );
          _uploadOffset ??= uploadOffset;

          final expandToLeft = uploadOffset.dx > constraints.maxWidth / 2;
          final clusterLeft = _clusterLeft(
            uploadOffset,
            expandToLeft: expandToLeft,
          );

          return Stack(
            children: [
              if (_menuExpanded)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _collapseMenu,
                    child: const ColoredBox(color: Colors.transparent),
                  ),
                ),
              Positioned(
                left: clusterLeft,
                top: uploadOffset.dy,
                child: GestureDetector(
                  onPanStart: (_) {
                    if (_menuExpanded) _collapseMenu();
                  },
                  onPanUpdate: (details) {
                    final currentOffset = _uploadOffset ?? uploadOffset;
                    setState(() {
                      _uploadOffset = _clampOffset(
                        offset: Offset(
                          currentOffset.dx + details.delta.dx,
                          currentOffset.dy + details.delta.dy,
                        ),
                        constraints: constraints,
                        obstruction: obstruction,
                        padding: mediaQuery.padding,
                      );
                    });
                  },
                  child: _buildFabAnchor(expandToLeft: expandToLeft),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFabAnchor({required bool expandToLeft}) {
    final clusterWidth = _menuExpanded
        ? _expandedClusterWidth()
        : _uploadBubbleSize;
    final clusterHeight = _menuExpanded ? 80.0 : _uploadBubbleSize;

    return SizedBox(
      width: clusterWidth,
      height: clusterHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (_menuExpanded)
            Positioned(
              top: 0,
              right: expandToLeft ? _uploadBubbleSize + _optionSpacing : null,
              left: expandToLeft ? null : _uploadBubbleSize + _optionSpacing,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: _optionWidgets(expandToLeft: expandToLeft),
              ),
            ),
          Positioned(
            top: 0,
            right: expandToLeft ? 0 : null,
            left: expandToLeft ? null : 0,
            child: _UploadBubble(
              expanded: _menuExpanded,
              onTap: () => setState(() => _menuExpanded = !_menuExpanded),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _optionWidgets({required bool expandToLeft}) {
    final mediaOption = _UploadOptionBubble(
      label: '图片/视频',
      icon: Icons.photo_library_outlined,
      onTap: () {
        _collapseMenu();
        widget.onUploadMediaTap();
      },
    );
    final fileOption = _UploadOptionBubble(
      label: '文件',
      icon: Icons.insert_drive_file_rounded,
      onTap: () {
        _collapseMenu();
        widget.onUploadFilesTap();
      },
    );
    final options = expandToLeft
        ? <Widget>[fileOption, mediaOption]
        : <Widget>[mediaOption, fileOption];
    return [
      for (var index = 0; index < options.length; index++)
        Padding(
          padding: EdgeInsets.only(
            right: index < options.length - 1 ? _optionSpacing : 0,
          ),
          child: options[index],
        ),
    ];
  }

  double _expandedClusterWidth() {
    return _uploadBubbleSize +
        _optionSpacing +
        (_optionBubbleSize * 2) +
        _optionSpacing;
  }

  double _clusterLeft(Offset uploadOffset, {required bool expandToLeft}) {
    if (!_menuExpanded || !expandToLeft) return uploadOffset.dx;
    final shift = _expandedClusterWidth() - _uploadBubbleSize;
    final left = uploadOffset.dx - shift;
    return left < _screenMargin ? _screenMargin : left;
  }

  void _collapseMenu() {
    if (!_menuExpanded) return;
    setState(() => _menuExpanded = false);
  }

  Offset _resolveUploadOffset({
    required BoxConstraints constraints,
    required double obstruction,
    required EdgeInsets padding,
  }) {
    final current =
        _uploadOffset ??
        Offset(_maxLeft(constraints), _maxTop(constraints, obstruction));
    return _clampOffset(
      offset: current,
      constraints: constraints,
      obstruction: obstruction,
      padding: padding,
    );
  }

  Offset _clampOffset({
    required Offset offset,
    required BoxConstraints constraints,
    required double obstruction,
    required EdgeInsets padding,
  }) {
    final maxLeft = _maxLeft(constraints);
    final minTop = padding.top + _screenMargin;
    final maxTop = _maxTop(constraints, obstruction);
    return Offset(
      offset.dx.clamp(_screenMargin, maxLeft).toDouble(),
      offset.dy.clamp(minTop, maxTop < minTop ? minTop : maxTop).toDouble(),
    );
  }

  double _maxLeft(BoxConstraints constraints) {
    final value = constraints.maxWidth - _uploadBubbleSize - _screenMargin;
    return value < _screenMargin ? _screenMargin : value;
  }

  double _maxTop(BoxConstraints constraints, double obstruction) {
    final value =
        constraints.maxHeight - obstruction - _uploadBubbleSize - _screenMargin;
    final minTop = _screenMargin;
    return value < minTop ? minTop : value;
  }

  /// 壳层底栏高 72，再加系统手势条。避免球沉到导航下面。
  double _bottomObstruction(MediaQueryData mediaQuery) {
    final nav = 72 + mediaQuery.viewPadding.bottom;
    final padding = mediaQuery.padding.bottom;
    return padding > nav ? padding : nav;
  }
}

class _UploadBubble extends StatelessWidget {
  const _UploadBubble({required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      elevation: 4,
      shadowColor: const Color(0xFF000000).withValues(alpha: 0.18),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Ink(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Theme.of(context).colorScheme.primary,
          ),
          child: Center(
            child: Icon(
              expanded ? Icons.close_rounded : Icons.arrow_upward_rounded,
              color: Colors.white,
              size: 30,
            ),
          ),
        ),
      ),
    );
  }
}

class _UploadOptionBubble extends StatelessWidget {
  const _UploadOptionBubble({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          elevation: 3,
          shadowColor: const Color(0xFF000000).withValues(alpha: 0.14),
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Ink(
              width: 56,
              height: 56,
              decoration: BoxDecoration(shape: BoxShape.circle, color: primary),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: const Color(0xFF2E3C34),
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
