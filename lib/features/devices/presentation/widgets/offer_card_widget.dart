import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/task/transfer_task.dart';
import '../../application/chat_offer_media_cache.dart';
import '../../application/chat_offer_poster.dart';
import '../../domain/entities/chat_message.dart';

/// 报价卡：图/视频小缩略图（无文件名、无列表内下载）；其它文件显示文件名 + 下载。
class OfferCardWidget extends StatefulWidget {
  const OfferCardWidget({
    super.key,
    required this.message,
    required this.task,
    this.onAccept,
    this.onOpenPreview,
    this.busy = false,
  });

  final ChatMessage message;
  final TransferTask? task;
  final VoidCallback? onAccept;
  final VoidCallback? onOpenPreview;
  final bool busy;

  @override
  State<OfferCardWidget> createState() => _OfferCardWidgetState();
}

class _OfferCardWidgetState extends State<OfferCardWidget> {
  String? _thumbPath;
  Uint8List? _thumbBytes;
  var _resolving = false;
  /// 入站图/视频：封面未到时转圈，而不是永久空白。
  var _awaitingThumb = false;
  Timer? _posterRetryTimer;
  /// 入站图片多等一会儿；视频稍短。
  var _posterRetryLeft = 0;

  @override
  void initState() {
    super.initState();
    _resetRetryBudget();
    _resolveThumb();
  }

  @override
  void dispose() {
    _posterRetryTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant OfferCardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task?.id != widget.task?.id ||
        oldWidget.task?.localPath != widget.task?.localPath ||
        oldWidget.task?.state != widget.task?.state) {
      _resetRetryBudget();
      _resolveThumb();
    }
  }

  void _resetRetryBudget() {
    final name = widget.task?.fileName ?? '';
    if (_isImageName(name)) {
      _posterRetryLeft = 40; // ~1 分钟（1.5s 间隔）
    } else if (_isVideoName(name)) {
      _posterRetryLeft = 20;
    } else {
      _posterRetryLeft = 0;
    }
  }

  Future<void> _resolveThumb() async {
    final task = widget.task;
    if (task == null) {
      if (mounted) {
        setState(() {
          _thumbPath = null;
          _thumbBytes = null;
          _awaitingThumb = false;
        });
      }
      return;
    }
    if (_isVideoName(task.fileName)) {
      await _resolveVideoThumb(task);
      return;
    }
    if (!_isImageName(task.fileName)) {
      if (mounted) {
        setState(() {
          _thumbPath = null;
          _thumbBytes = null;
          _awaitingThumb = false;
        });
      }
      return;
    }

    // 已落盘 / 出站：直接用实文件，不为气泡去拉原图。
    final local = task.localPath;
    if (local != null && local.isNotEmpty && File(local).existsSync()) {
      if (mounted) {
        setState(() {
          _thumbPath = local;
          _thumbBytes = null;
          _awaitingThumb = false;
        });
      }
      return;
    }

    if (_resolving) return;
    _resolving = true;
    if (mounted && _thumbPath == null && _thumbBytes == null) {
      setState(() => _awaitingThumb = true);
    }
    try {
      final preview = await ChatOfferMediaCache().cachedPathIfReady(task);
      if (preview != null) {
        if (mounted) {
          setState(() {
            _thumbPath = preview;
            _thumbBytes = null;
            _awaitingThumb = false;
          });
        }
        return;
      }
      // 入站未下载：拉轻量 poster，转圈等待，不为气泡拉原图。
      await _resolveRemoteOrLocalPoster(task);
    } finally {
      _resolving = false;
    }
  }

  Future<void> _resolveVideoThumb(TransferTask task) async {
    if (_resolving) return;
    _resolving = true;
    if (mounted &&
        task.type == TransferTaskType.p2pDownload &&
        _thumbPath == null &&
        _thumbBytes == null) {
      setState(() => _awaitingThumb = true);
    }
    try {
      final poster = ChatOfferPoster();
      final local = task.localPath;
      if (local != null &&
          local.isNotEmpty &&
          File(local).existsSync()) {
        final bytes = await poster.thumbBytesForLocalFile(local);
        if (mounted) {
          setState(() {
            _thumbBytes = bytes;
            _thumbPath = null;
            _awaitingThumb = false;
          });
        }
        return;
      }

      final cached = await poster.cachedPathIfReady(task.id);
      if (cached != null) {
        if (mounted) {
          setState(() {
            _thumbPath = cached;
            _thumbBytes = null;
            _awaitingThumb = false;
          });
        }
        return;
      }

      await _resolveRemoteOrLocalPoster(task);
    } finally {
      _resolving = false;
    }
  }

  Future<void> _resolveRemoteOrLocalPoster(TransferTask task) async {
    final poster = ChatOfferPoster();
    String? path;
    if (task.type == TransferTaskType.p2pOffer) {
      path = await poster.ensureLocalPoster(task: task);
    } else if (task.type == TransferTaskType.p2pDownload) {
      path = await poster.ensureRemotePoster(task);
    }
    if (!mounted) return;
    if (path != null) {
      setState(() {
        _thumbPath = path;
        _thumbBytes = null;
        _awaitingThumb = false;
      });
      return;
    }
    final lateHit = await poster.cachedPathIfReady(task.id);
    if (mounted && lateHit != null) {
      setState(() {
        _thumbPath = lateHit;
        _thumbBytes = null;
        _awaitingThumb = false;
      });
      return;
    }
    // 发送方仍在生成：转圈并稍后重试（图片尤甚，尽量不永久缺失）。
    if (task.type == TransferTaskType.p2pDownload && _posterRetryLeft > 0) {
      _posterRetryLeft--;
      if (mounted) setState(() => _awaitingThumb = true);
      _posterRetryTimer?.cancel();
      _posterRetryTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted && _thumbPath == null && _thumbBytes == null && !_resolving) {
          _resolveThumb();
        }
      });
      return;
    }
    if (mounted) setState(() => _awaitingThumb = false);
  }

  @override
  Widget build(BuildContext context) {
    final mine = widget.message.direction == ChatDirection.outbound;
    final task = widget.task;
    final state = task?.state ?? TransferTaskState.offered;
    final name = task?.fileName ?? '文件';
    final size = task == null ? '' : _formatSize(task.sizeBytes);
    final isImage = _isImageName(name);
    final isVideo = _isVideoName(name);
    final isMedia = isImage || isVideo;
    final showListDownload = !isMedia && widget.onAccept != null;
    final hasThumb = _thumbPath != null || _thumbBytes != null;

    if (isMedia) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: widget.onOpenPreview,
          child: Column(
            crossAxisAlignment:
                mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (hasThumb)
                _MediaThumb(
                  path: _thumbPath,
                  bytes: _thumbBytes,
                  showPlayBadge: isVideo,
                )
              else if (_awaitingThumb || _resolving)
                _MediaThumbLoading(isVideo: isVideo)
              else
                _MediaPlaceholder(isVideo: isVideo),
              if (state == TransferTaskState.transferring &&
                  task != null &&
                  task.sizeBytes > 0) ...[
                const SizedBox(height: 6),
                SizedBox(
                  width: 120,
                  child: LinearProgressIndicator(
                    value: (task.bytesTransferred / task.sizeBytes)
                        .clamp(0.0, 1.0),
                  ),
                ),
              ],
              if (state == TransferTaskState.failed &&
                  task?.errorMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  task!.errorMessage!,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.68,
      ),
      child: Material(
        color: const Color(0xFFEAF3EC),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onOpenPreview,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.insert_drive_file_outlined,
                      color: Theme.of(context).colorScheme.primary,
                      size: 36,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          if (size.isNotEmpty)
                            Text(
                              size,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _statusLabel(state, mine: mine),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                if (showListDownload) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: widget.busy ? null : widget.onAccept,
                      icon: widget.busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_rounded, size: 18),
                      label: Text(widget.busy ? '处理中' : '下载'),
                    ),
                  ),
                ],
                if (task?.errorMessage != null &&
                    state == TransferTaskState.failed) ...[
                  const SizedBox(height: 6),
                  Text(
                    task!.errorMessage!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _isImageName(String name) {
    final lower = name.toLowerCase();
    const images = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic'];
    return images.any(lower.endsWith);
  }

  bool _isVideoName(String name) {
    final lower = name.toLowerCase();
    const videos = ['.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v', '.3gp'];
    return videos.any(lower.endsWith);
  }

  String _statusLabel(TransferTaskState state, {required bool mine}) {
    switch (state) {
      case TransferTaskState.offered:
        return mine ? '等待对方确认' : '待下载';
      case TransferTaskState.accepted:
        return '已确认';
      case TransferTaskState.transferring:
        return '传输中…';
      case TransferTaskState.done:
        return mine ? '对方已接收' : '已保存';
      case TransferTaskState.failed:
        return '失败';
      case TransferTaskState.cancelled:
        return '已取消';
      case TransferTaskState.expired:
        return '已过期';
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// 小缩略图（约一格预览大小，勿撑满气泡宽）。
class _MediaThumb extends StatelessWidget {
  const _MediaThumb({
    this.path,
    this.bytes,
    this.showPlayBadge = false,
  });

  final String? path;
  final Uint8List? bytes;
  final bool showPlayBadge;

  static const double _edge = 120;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheW = (_edge * dpr).round().clamp(96, 256);
    Widget image;
    if (bytes != null && bytes!.isNotEmpty) {
      image = Image.memory(
        bytes!,
        fit: BoxFit.cover,
        width: _edge,
        height: _edge,
        cacheWidth: cacheW,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, error, stackTrace) => const ColoredBox(
          color: Color(0xFFD8E5DB),
          child: Center(child: Icon(Icons.broken_image_outlined)),
        ),
      );
    } else if (path != null && path!.isNotEmpty) {
      image = Image.file(
        File(path!),
        fit: BoxFit.cover,
        width: _edge,
        height: _edge,
        cacheWidth: cacheW,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, error, stackTrace) => const ColoredBox(
          color: Color(0xFFD8E5DB),
          child: Center(child: Icon(Icons.broken_image_outlined)),
        ),
      );
    } else {
      image = const ColoredBox(
        color: Color(0xFFD8E5DB),
        child: Center(child: Icon(Icons.broken_image_outlined)),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: _edge,
        height: _edge,
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            if (showPlayBadge)
              const Center(
                child: Icon(
                  Icons.play_circle_fill,
                  color: Colors.white70,
                  size: 36,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MediaThumbLoading extends StatelessWidget {
  const _MediaThumbLoading({required this.isVideo});

  final bool isVideo;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: const Color(0xFFEAF3EC),
        child: SizedBox(
          width: _MediaThumb._edge,
          height: _MediaThumb._edge,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                isVideo ? Icons.videocam_outlined : Icons.image_outlined,
                color: const Color(0xFF3D8A5A).withValues(alpha: 0.35),
                size: 36,
              ),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(0xFF3D8A5A),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder({required this.isVideo});

  final bool isVideo;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: const Color(0xFFEAF3EC),
        child: SizedBox(
          width: _MediaThumb._edge,
          height: _MediaThumb._edge,
          child: Icon(
            isVideo ? Icons.videocam_outlined : Icons.image_outlined,
            color: const Color(0xFF3D8A5A),
            size: 36,
          ),
        ),
      ),
    );
  }
}
